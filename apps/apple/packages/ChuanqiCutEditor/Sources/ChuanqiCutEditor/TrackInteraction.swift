// TrackInteraction — 时间线手势 reducer（UIA-041 / U0，RESEARCH-013 §5.1 → RESEARCH-017 §3 落地）
//
// ## 为什么要有这个文件
//
// 此前存在**两份时间线实现**，各自持有一段逐字相同的状态机：
//   * SwiftUI：`EditorTimelineView`（beginDragIfNeeded / onChanged / onEnded / commit）
//   * UIKit  ：`TimelineContentView.handlePan` + `EditorViewController.commitDrag`
//
// `commitDrag` 的文件注释里写着「语义逐字对照 SwiftUI 版 EditorTimelineView.commit」——
// 这句话本身就是出手时就带着的隐患证据：一段含 **4 个分支、4 个 RationalTime 换算、1 个跨轨判定**
// 的逻辑被抄了两份，UIA-039/040 每次都是改动两遍。
//
// 本文件把它收敛成**值类型 reducer**：
//
//      输入 = 归一化手势事件（与 UI 框架无关） + 当前几何（TimelineLayout，纯值类型）
//      输出 = 新状态 + 意图列表（TrackIntent，由宿主翻译成 ViewModel 命令）
//
// ## 硬约束
//
// * **不 import SwiftUI / UIKit** —— 展示层是用 SwiftUI 还是 UIKit 与这里无关，
//   两边都只做「收集手势点 → 发事件 → 按 Intent 调 VM」的翻译。
// * **不持内核 Session、不碰模型** —— reducer 唯一产生副作用的方式是**吐出 Intent**，
//   由宿主执行。这是红线 #5（UI 绝不直接改模型）的机械保证：想漏副作用都漏不出去，
//   因为 reducer 里根本没有 session 可碰。
// * **CMTime→Double 的换算**集中在 `ClipInfo` extension（本文件底部），
//   红线 #4 的立场不变：换算结果只用于「渲染刻度/手势位移」，**提交口径仍是整数
//   RationalTime**（见 `TrackClipEdit` —— 它携带的就是 RationalTime，不是秒）。
//
// ## 与 EDIT-012（B5.5，commit/done 双层 PreviewSync）的关系
//
// reducer 是 **UI 侧事件收敛**，EDIT-012 是**内核侧提交通道**。二者会师点：
// `TrackIntent.commitEdit` 今天由宿主翻译成「一条 Command + refreshFromKernel」，
// B5.5 之后拖拽中间态改走 PreviewSync（高频、不入撤销栈），松手仍是 commitEdit → done。
// 届时**只需改宿主的翻译层**，reducer 与两个展示层不动。
//
// ## 刻意不收敛的部分（不是半残）
//
// **scrub 的机械路径保留两侧各自实现**：UIKit 走原生 `UIScrollView` 的 scrollViewDidScroll
// （有惯性/减速/边界回弹，是 iOS 原生手感），SwiftUI 走 DragGesture 的位移累加。
// 强行收敛要么是 UIKit 丢掉原生滚动，要么是给 SwiftUI 手搓惯性 —— 都是倒退。
// 被统一的是**其中的数学**（`scrubSeconds` 纯函数 + `TimelineZoomMath.snapToFrame`），
// 而不是各自的车底盘。

import CoreGraphics
import ChuanqiCutEngine

// MARK: - 事件（归一化，与 UI 框架无关）

/// 归一化的手势事件。两个展示层的职责就是把 UIKit/SwiftUI 的原始回调翻译成这 5 个值。
enum TrackGestureEvent: Equatable {
    /// 零位移点按（落在片段上或空白）。
    case tap(location: CGPoint)
    /// 拖拽开始：判定这次是「编辑片段」还是「无命中」。
    case dragBegan(location: CGPoint)
    /// 拖拽推进：`translation` 是**相对 began 起点**的累计位移（pt）。
    case dragChanged(translation: CGSize)
    /// 松手：可能产出 `.commitEdit`（也可能因为零位移而不产出）。
    case dragEnded(translation: CGSize)
    /// 手势被系统取消（来电 / 手势识别器让位）：不提交，宿主回到内核真值。
    case dragCancelled
}

// MARK: - 意图（reducer 请求的副作用，宿主执行）

/// 一次片段编辑的最终形态。**携带 RationalTime（整数）而非秒** —— 这是提交口径的唯一真源。
enum TrackClipEdit: Equatable {
    /// 移动（同轨内改起点）。
    case move(clipId: UInt64, start: RationalTime)
    /// 左缘裁剪：内核按「右缘不动」联动推导 sourceIn / duration（EDIT-008）。
    case trimStart(clipId: UInt64, start: RationalTime)
    /// 右缘裁剪：改 duration，不动起点与 sourceIn。
    case trimEnd(clipId: UInt64, duration: RationalTime)
    /// 跨轨：改所属轨道，必要时一并改起点（UIA-040）。
    case moveToTrack(clipId: UInt64, trackId: UInt64, start: RationalTime)
}

/// reducer 请求宿主执行的动作。**reducer 自己一个都不执行。**
enum TrackIntent: Equatable {
    /// 选中片段（nil = 点空白，取消选中）。宿主 → `VM.selectClip`。
    case selectClip(UInt64?)
    /// 提交一次片段编辑。宿主 → VM 命令 + `refreshFromKernel()`。
    case commitEdit(TrackClipEdit)
}

// MARK: - 状态与渲染态

/// reducer 的内部状态。**只装交互期临时量** —— 选中 id 是 ViewModel 的（@Published），
/// 不在这里复制第三份，否则又是一次「双真源」。
struct TrackInteractionState: Equatable {
    /// 进行中的拖拽（nil = 不在拖拽中）。
    var drag: ClipDrag?
    /// 是否已知这次手势「没命中片段」（UIKit 据此让 UIScrollView 接管 = scrub）。
    var isScrubbing: Bool = false

    static let idle = TrackInteractionState()
}

/// 展示层渲染所需的全部派生量。**渲染只读这里，两侧不再各自判几次 nil。**
struct TrackRenderState: Equatable {
    /// 拖拽预览几何（nil = 无预览，画内核真值）。
    let override: ClipPreviewOverride?
    /// 跨轨预览行（nil = 画真实轨道行）。
    let rowOverride: Int?
    /// 正在被拖的片段（画 dragging 色）。
    let draggingClipId: UInt64?

    static let idle = TrackRenderState(override: nil, rowOverride: nil, draggingClipId: nil)
}

// MARK: - Reducer

enum TrackInteraction {

    /// 零位移阈值（秒）。低于此值视为「用户没真的拖」，不提交。
    ///
    /// ⚠️ **收敛时修掉的一处双实现分歧**：此守卫原先**只在 UIKit 版有**
    /// （`TimelineContentView.handlePan` 的 `.ended` 分支），SwiftUI 版的 `commit`
    /// 是**无条件提交**的。也就是说同一操作在两条路径上会产生不同的撤销栈内容。
    /// 统一后：零位移一律不提交。
    static let minCommitDeltaSeconds: Double = 1e-9

    /// 核心：`(state, event) → (state', intents)`。
    ///
    /// `layout` 作为入参而非成员，是因为它随缩放/滚动/模型版本每帧变化；
    /// 把它塞进 state 会让 state 每帧失效（也会让 reducer 无法单测）。
    @discardableResult
    static func reduce(_ state: inout TrackInteractionState,
                       event: TrackGestureEvent,
                       layout: TimelineLayout) -> [TrackIntent] {
        switch event {
        case .tap(let location):
            let hit = layout.hitTest(location)
            return [.selectClip(hit?.clip.clipId)]

        case .dragBegan(let location):
            guard let hit = layout.hitTest(location) else {
                // 没命中片段 → 交给宿主的 scrub 路径（UIKit = UIScrollView 原生平移，
                // SwiftUI = 位移累加）。reducer 不参与 scrub 的机械实现，只记账。
                state.drag = nil
                state.isScrubbing = true
                return []
            }
            let row = layout.trackRow(forTrackId: hit.clip.trackId) ?? 0
            state.drag = ClipDrag(clipId: hit.clip.clipId,
                                  region: hit.region,
                                  originStart: hit.clip.startSeconds,
                                  originDuration: hit.clip.durationSeconds,
                                  originTrackRow: row,
                                  targetTrackRow: row)
            state.isScrubbing = false
            return []

        case .dragChanged(let translation):
            guard var drag = state.drag else { return [] }
            apply(translation: translation, to: &drag, layout: layout)
            state.drag = drag
            return []

        case .dragEnded(let translation):
            guard var drag = state.drag else {
                state.isScrubbing = false
                return []
            }
            // 末次位移以 ended 携带的 translation 为准（两个平台的最后一次回调都可能
            // 带来一小段 changed 之后才停住的位移）。此处原先两侧不一致：
            // UIKit 沿用最后一次 changed 的值，SwiftUI 重算 —— 统一为重算（更准）。
            apply(translation: translation, to: &drag, layout: layout)
            state.drag = nil
            state.isScrubbing = false
            guard shouldCommit(drag) else { return [] }
            return [.commitEdit(edit(for: drag, tracks: layout.tracks))]

        case .dragCancelled:
            state.drag = nil
            state.isScrubbing = false
            return []
        }
    }

    /// 渲染态派生（两个展示层的唯一渲染输入）。
    static func renderState(_ state: TrackInteractionState) -> TrackRenderState {
        guard let drag = state.drag else { return .idle }
        return TrackRenderState(
            override: drag.override,
            rowOverride: drag.targetTrackRow != drag.originTrackRow ? drag.targetTrackRow : nil,
            draggingClipId: drag.clipId)
    }

    /// **平台仲裁**：一个 pan 手势该由「编辑片段」接管，还是交给 scrub？
    ///
    /// UIKit 需要它来决定 `gestureRecognizerShouldBegin` 的返回值（不接管 → UIScrollView
    /// 原生的平移/惯性/回弹生效）；SwiftUI 没有原生滚动视图，不需要这条。
    /// 把它放进 reducer 域是为了让「此处有片段吗」这个判断只有一处定义 ——
    /// 展示层不自己写 `layout.hitTest(...) != nil`。
    static func ownsPan(at location: CGPoint, layout: TimelineLayout,
                        state: TrackInteractionState) -> Bool {
        // 已在拖拽中：必须继续接管，不能被滚动抢走。
        if state.drag != nil { return true }
        return layout.hitTest(location) != nil
    }

    /// scrub 的共享数学：把手势位移换算成**已按帧栅格取整**的秒值。
    ///
    /// 两侧 scrub 的车底盘不同（见文件头），但这一步必须一致 —— 否则同一手势在
    /// 两条路径上停到不同的帧。
    static func scrubSeconds(anchorSeconds: Double, translationWidth: CGFloat,
                            layout: TimelineLayout) -> Double {
        let raw = max(0, anchorSeconds + Double(translationWidth / layout.pixelsPerSecond))
        return TimelineZoomMath.snapToFrame(seconds: raw,
                                            frameDuration: TimelineZoomMath.defaultFrameDuration)
    }

    // MARK: 内部

    /// scrub 的共享数学：把手势位移换算成**已按帧栅格取整**的秒值。
    ///
    /// 两侧 scrub 的车底盘不同（见文件头），但这一步必须一致 —— 否则同一手势在
    /// 两条路径上停到不同的帧。

    private static func apply(translation: CGSize, to drag: inout ClipDrag,
                              layout: TimelineLayout) {
        guard layout.pixelsPerSecond > 0 else { return }
        drag.deltaSeconds = Double(translation.width / layout.pixelsPerSecond)
        drag.targetTrackRow = ClipDrag.dropTrackRow(
            originRow: drag.originTrackRow,
            deltaY: translation.height,
            rowPitch: layout.trackHeight + TimelineLayout.trackSpacing,
            rowCount: layout.tracks.count)
    }

    /// 是否值得提交一条命令。**零位移 + 没跨轨 = 不提交**（不给撤销栈塞垃圾记录）。
    private static func shouldCommit(_ drag: ClipDrag) -> Bool {
        let moved = abs(drag.deltaSeconds) > minCommitDeltaSeconds
        let crossedTrack = drag.targetTrackRow != drag.originTrackRow
        return moved || crossedTrack
    }

    /// 命令拼装（原本在 SwiftUI `commit` 与 UIKit `commitDrag` 各一份）。
    ///
    /// 分支顺序与既有语义一致：**跨轨优先**于 region —— 跨轨拖拽即使 region 是
    /// `.trimStart` 也按整段移动处理（与历史行为对齐，变更此顺序属行为改动，需单测说明理由）。
    private static func edit(for drag: ClipDrag, tracks: [TrackInfo]) -> TrackClipEdit {
        let timescale = RationalTime.projectTimescale
        let startTicks = Int64((drag.previewStart * Double(timescale)).rounded())

        if drag.targetTrackRow != drag.originTrackRow, drag.targetTrackRow < tracks.count {
            return .moveToTrack(clipId: drag.clipId,
                                trackId: tracks[drag.targetTrackRow].trackId,
                                start: RationalTime(value: startTicks, timescale: timescale))
        }

        switch drag.region {
        case .move:
            return .move(clipId: drag.clipId,
                         start: RationalTime(value: startTicks, timescale: timescale))
        case .trimStart:
            return .trimStart(clipId: drag.clipId,
                              start: RationalTime(value: startTicks, timescale: timescale))
        case .trimEnd:
            let durationTicks = Int64((drag.previewDuration * Double(timescale)).rounded())
            return .trimEnd(clipId: drag.clipId,
                            duration: RationalTime(value: durationTicks, timescale: timescale))
        }
    }
}

// MARK: - 时间换算（渲染刻度专用）

extension ClipInfo {
    /// 起点（秒）。**仅用于渲染刻度与手势位移计算** —— 提交口径仍走 RationalTime 本值（红线 #4）。
    var startSeconds: Double {
        Double(start.value) / Double(start.timescale)
    }

    /// 时长（秒）。同上。
    var durationSeconds: Double {
        Double(duration.value) / Double(duration.timescale)
    }

    /// 终点（秒）。
    var endSeconds: Double { startSeconds + durationSeconds }
}

// MARK: - Intent → ViewModel（统一的执行入口）

/// 把 reducer 吐出的 Intent 落到 ViewModel 上。**这份翻译全仓只有一份**。
///
/// 为什么连翻译也能统一：两个宿主（SwiftUI 的 `EditorTimelineView`、UIKit 的
/// `EditorViewController`）拿到的都是同一个 `EditorViewModel`（`@MainActor`），
/// 走的都是同一批命令入口，所以没有理由同时存在两份 switch。
/// 统一之后两个宿主的调用都退化成一行：
///
///     TrackIntentApplier.apply(intents, to: viewModel)
///
/// 这也让「UI 唯一产生副作用的地方」从「每个视图各一处」收敛到**一处**，
/// 红线 #5 的落点更集中：想新增副作用，只有一个 switch 可以改。
@MainActor
enum TrackIntentApplier {

    static func apply(_ intents: [TrackIntent], to viewModel: EditorViewModel) {
        for intent in intents {
            switch intent {
            case .selectClip(let clipId):
                // 命中片段 → 选中/再点取消；点空白 = nil → 取消选中（UIA-039）。
                viewModel.selectClip(clipId)
            case .commitEdit(let edit):
                applyEdit(edit, to: viewModel)
                // 提交后主动回到内核真值：防「幽灵位置」（被拒时 UI 停留预览值）。
                viewModel.refreshFromKernel()
            }
        }
    }

    private static func applyEdit(_ edit: TrackClipEdit, to viewModel: EditorViewModel) {
        switch edit {
        case .move(let clipId, let start):
            viewModel.moveClip(clipId: clipId, to: start)
        case .trimStart(let clipId, let start):
            // 左缘裁剪（EDIT-008）：只提交新起点，sourceIn / duration 由内核
            // 按「右缘不动」联动推导 —— UI 侧绝不自算。
            viewModel.trimClipIn(clipId: clipId, start: start)
        case .trimEnd(let clipId, let duration):
            viewModel.trimClip(clipId: clipId, duration: duration)
        case .moveToTrack(let clipId, let trackId, let start):
            // 跨轨（UIA-040）：类型不匹配/重叠由内核拒绝，refreshFromKernel 回真值。
            viewModel.moveClipToTrack(clipId: clipId, to: trackId, start: start)
        }
    }
}
