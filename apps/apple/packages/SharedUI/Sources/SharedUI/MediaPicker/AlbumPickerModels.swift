// SharedUI — 自研相册浏览器：纯逻辑层（UIA-013，Spec docs/specs/UIA-013-自研相册浏览器.md）
//
// 本文件全部是**纯值类型 / 纯函数**（同 TimelineLayout 的"纯函数、可单测"手法）：
// 不 import Photos、不碰主线程状态，AlbumPickerTests 直接覆盖。
// PhotoKit 取数在 PhotoKitAlbumStore，屏幕状态在 MediaPickerViewModel，视图在
// AlbumPickerScreen / MediaGridCell。交互范式对齐 ZLPhotoBrowser / HXPhotoPicker
// 的成熟约定（序号徽标 / 满选置灰 / 时长过滤），UI 走编辑器暗色主题（Theme）。

import Foundation

// MARK: - 数据面（与 PhotoKit 解耦的值类型）

/// 相册里的一条视频素材（UI 层描述符）。duration 是 PhotoKit 边界值
/// （PHAsset.duration，浮点秒），**仅用于角标显示与选取过滤**，不进时间轴模型 ——
/// 模型时间一律有理数（红线 #4）。
struct AssetDescriptor: Identifiable, Equatable {
    /// PHAsset.localIdentifier
    let id: String
    let durationSeconds: TimeInterval
    /// true = 缩略图请求时确认本地可用；false = 疑似仅云端（iCloud），cell 显示云徽标
    let isLocallyAvailable: Bool
}

/// 相簿条目（智能相簿 / 用户相簿；最近项目是合成条目）。
struct AlbumSummary: Identifiable, Equatable {
    let id: String
    let title: String
    let assetCount: Int
}

// MARK: - 配置

struct AlbumPickerConfiguration: Equatable {
    /// 单批选取上限。与 UIA-012 批量导入的 tmp 落盘体积约束同源（Spec UIA-013 §4.3）。
    var maxSelectionCount: Int = 20
    /// 视频时长过滤区间；nil = 不过滤。区间内可选，区间外置灰并给出原因。
    var allowedDuration: ClosedRange<TimeInterval>? = nil
    /// 网格列宽下限（自适应列数：iPhone 4 列 / iPad、Mac 更多）。
    var minColumnWidth: CGFloat = 88

    static let standard = AlbumPickerConfiguration()
}

// MARK: - 时长过滤（纯函数）

enum DurationFilter {

    /// 返回 nil = 可选；返回文本 = 不可选原因（cell 置灰展示 + 选取时提示）。
    static func rejectionReason(durationSeconds: TimeInterval,
                                allowed: ClosedRange<TimeInterval>?) -> String? {
        guard let allowed else { return nil }
        if durationSeconds < allowed.lowerBound {
            return "时长不足 \(Int(allowed.lowerBound.rounded(.up))) 秒"
        }
        if durationSeconds > allowed.upperBound {
            return "超过 \(Int(allowed.upperBound.rounded(.down))) 秒上限"
        }
        return nil
    }
}

// MARK: - 多选状态机（纯值类型）

/// 有序、去重、带上限的选取状态。toggled 对"满选再增"原样返回 —— 是否被拒
/// 由 wouldRejectAdd 预判，调用方（ViewModel）据此给出"已达上限"反馈。
struct SelectionState: Equatable {

    private(set) var orderedIDs: [String] = []
    let maxCount: Int

    init(maxCount: Int) {
        self.maxCount = max(1, maxCount)
    }

    var count: Int { orderedIDs.count }
    var isEmpty: Bool { orderedIDs.isEmpty }
    var isFull: Bool { count >= maxCount }

    func contains(_ id: String) -> Bool { orderedIDs.contains(id) }

    /// 徽标序号（1 起）；未选中 = nil。
    func orderNumber(of id: String) -> Int? {
        orderedIDs.firstIndex(of: id).map { $0 + 1 }
    }

    /// 切换选中态（选中 = 追加到队尾，保持选取顺序；取消 = 移除并让后续序号前移）。
    func toggled(_ id: String) -> SelectionState {
        if let index = orderedIDs.firstIndex(of: id) {
            var next = self
            next.orderedIDs.remove(at: index)
            return next
        }
        guard !isFull else { return self }
        var next = self
        next.orderedIDs.append(id)
        return next
    }

    /// 这次 toggle 是否会被"满选"拒绝（cell 置灰与抖动提示的判定源）。
    func wouldRejectAdd(_ id: String) -> Bool {
        !contains(id) && isFull
    }
}

// MARK: - 文案（汇总样式与 UIA-012 导入汇总结对齐）

enum AlbumPickerText {

    /// 确认导出的进度文案（iCloud 素材拉取可能持续数秒）。
    static func preparingProgress(index: Int, total: Int) -> String {
        "正在读取所选视频 \(index)/\(total)…"
    }

    /// 确认导出全部失败的错误文案（保持选择器打开，不交付）。
    static func allResolveFailed(detail: String) -> String {
        "视频读取失败：\(detail)"
    }

    /// 部分失败仍交付成功部分时的提示（成功的汇入编辑器，失败的留在下次选择）。
    static func partialResolveSummary(delivered: Int, failed: Int) -> String {
        "\(delivered) 条视频已就绪，\(failed) 条读取失败"
    }
}
