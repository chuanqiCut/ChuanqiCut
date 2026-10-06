# 模块：Apple UI（SwiftUI）

**边界**：`apps/apple/packages/SharedUI/`、`apps/apple/iOSApp/`、`apps/apple/MacApp/`、`apps/apple/project.yml`

## 原则
**UI 不跨平台共享，共享的是会话状态与命令**（ARCH-005）。

```
用户手势 → SwiftUI → submit(Command) → EditorSession(C++) → 快照 → UI diff 刷新
                                                          └→ 渲染请求 → RenderGraph
```

## 工程结构（INFRA-009 拆分版，2026-10-02；替代 UIA-002 单工程形态）

```
apps/apple/
├── packages/SharedUI/             # SwiftUI 共享包
│   ├── SharedUI.podspec           # App 集成真源（pod）
│   ├── Package.swift              # 仅 swift test 测试宿主，不在 App 依赖链
│   ├── Sources/SharedUI/
│   │   ├── AppEntry.swift         # EditorViewModel（Session 唯一持有者）
│   │   ├── Editor/                # EditorView / EditorLayout / 三区桩视图
│   │   └── Common/Theme.swift
│   └── Tests/SharedUITests/
├── ios/                           # iOS 独立工程
│   ├── project.yml                # xcodegen 真源（ChuanqiCutApp，iOS 16+）
│   ├── Podfile / Gemfile(.lock)   # 本目录独立维护
│   └── iOSApp/
└── mac/                           # macOS 独立工程
    ├── project.yml                # xcodegen 真源（ChuanqiCutMacApp，macOS 15.4+）
    ├── Podfile / Gemfile(.lock)   # 本目录独立维护
    └── MacApp/                    # 窗口 1280×720 / 最小 960×540
```

**依赖链**（INFRA-009 起，全部走 CocoaPods，App 不用 SPM）：
App → SharedUI (pod) → ChuanqiCut (pod，**默认 Source 模式**：现场编译
C++20 内核 + ObjC++ PAL + Swift 绑定) → CChuanqiCut (clang module，
经 SWIFT_INCLUDE_PATHS 共用 `bindings/swift/Sources/CChuanqiCut/include/`)。
`bindings/swift/Package.swift` 仅作绑定层 `swift test` 测试宿主。
集成细节与红线见 `docs/COCOAPODS.md` 与 pitfalls P9~P12。

**工程生成**（clone 后 / project.yml 或 Podfile 变更后，在 ios/ 或 mac/ 下）：
```bash
xcodegen generate            # 本机装在 ~/tools/xcodegen/xcodegen/bin/
bundle install               # Gemfile.lock 钉住 CocoaPods 1.17.0（lock 必须入库）
bundle exec pod install      # 生成 .xcworkspace；打开 workspace 而非 xcodeproj
```
Info.plist 由 project.yml 的 `info:` 段生成，仓库不存手工副本。
ChuanqiCut.xcodeproj / .xcworkspace 均为生成产物（.gitignore 已排除）。

## 硬约束
1. **UI 不得直接改模型**，一切变更走 `EditorViewModel.submit()`（Command）
2. **时间线必须自绘**（Metal/Canvas），不得把每个片段做成 UI 组件 —— 数百片段会直接掉帧
3. 拖拽只更新"拖拽预览层"，拖拽结束才提交 Command
4. 缩略图与波形异步加载，主线程不解码
5. **预览画面不经 UI 合成路径**：`MTKView` 直接绘制（UIA-003）
6. 平台差异（iOS 手势 vs Mac 菜单/快捷键）收敛在 `EditorLayout.swift`，业务视图不写条件编译
7. App 入口必须 `ChuanqiCut.markMainThread()`；可抛构造进 `*State(wrappedValue:)`
   前**先建值后包装**（见 pitfalls P8）

## 当前状态（UIA-002 完成）
- 三区布局（Preview / Timeline / PropertyPanel）均为**桩视图**，架构位已留：
  - UIA-003 替换 PreviewZone → MTKView
  - UIA-004 替换 TimelineZone → 自绘时间线
  - UIA-006 替换 PropertyPanelZone → 真实参数（走 Command）
- `EditorViewModel`：@MainActor，唯一持有 `ChuanqiCut.Session`；快照 observer
  经 `Task { @MainActor }` 回流；`refreshCapabilities()` 缓存能力查询
- **iOS 构建策略：只跑真机**（用户决策 2026-10-01），不建模拟器版本；
  真机（iPhone 17 Pro）当前 unavailable，iOS 侧停在"代码已生成"

## 性能验收
- 时间线拖拽期间主线程单帧 < 16ms
- 1080p 三轨预览 ≥ 55fps（高端机）
- 打开项目到出画面 < 1.5s（1080p）

## 验证
```bash
# SharedUI 包（macOS 宿主，需先产出 xcframework：build_core_apple.sh && prepare.sh）
cd apps/apple/packages/SharedUI && swift test --disable-sandbox

# macOS App（INFRA-009 起，workspace 编译）
cd apps/apple/mac && xcodegen generate && bundle install && bundle exec pod install
xcodebuild build -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutMacApp \
    -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO

# iOS App（INFRA-009 起，workspace 编译）
cd apps/apple/ios && xcodegen generate && bundle install && bundle exec pod install
xcodebuild build -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutApp \
    -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
# 真机 SDK 需带版本号（platform runtime 缺失时 destination 解析不了）：
#   -sdk iphoneos18.4 CODE_SIGNING_ALLOWED=NO
#   destination 报"not installed"时的等价 legacy 链（pod 目标与 app 目标建到同一 BUILD_DIR）：
#     for T in ChuanqiCut SharedUI Pods-ChuanqiCutApp; do \
#       SYMROOT="$PWD/build" BUILD_DIR="$PWD/build" xcodebuild build \
#         -project Pods/Pods.xcodeproj -target $T -sdk iphoneos18.4; done
#     xcodebuild build -project ChuanqiCut.xcodeproj -target ChuanqiCutApp \
#       -sdk iphoneos18.4 CODE_SIGNING_ALLOWED=NO
# 模拟器侧（不需要真机/签名，日常门禁用这个）：
#   -sdk iphonesimulator -destination 'generic/platform=iOS Simulator'
# 运行仅在真机可用时（xcodebuild -destination 'platform=iOS'）

# ⚠️ 生成顺序必须是 xcodegen generate **先于** pod install：
#    generate 会重写 xcodeproj，把 pod install 注入的 Pods 引用清掉（P54/P56）。
# ⚠️ 多人/多会话共用机器时务必加 -derivedDataPath 隔离，否则撞
#    `unable to attach DB ... database is locked`。

# CIKernel 产物验收（ADR-0021）：编译绿 ≠ metallib 可用
strings .../ChuanqiCutApp.app/beauty_bilateral.metallib | grep cq_beauty   # 两个 kernel 名
ls -l   .../ChuanqiCutApp.app/beauty_bilateral.metallib                    # ~8.4KB；96B = 空壳
```

## 相关
ARCH-005、TASK-UIA-002、pitfalls P7/P8


---

# UIA-004 落地（2026-10-03）：时间线自绘

- `apps/apple/packages/SharedUI/Sources/SharedUI/Timeline/EditorTimelineView.swift`
  （⚠️ 不叫 TimelineView —— SwiftUI 有同名系统类型，P22 同款）
- 几何纯函数 `TimelineLayout`（时间↔像素 / 可见裁剪 / 标尺自适应）——可单测可 measure
- **单 Canvas 绘制**（轨道行/片段/标尺/播放头），非组件堆叠
- 数据流：快照 observer → 版本推进 → Session.queryTracks/queryClips（主线程直读
  内核快照）→ EditorViewModel.timeline（@Published）→ Canvas
- 实测：500 片段布局 0.663 ms/帧（< 16ms 预算的 4%，见 baselines）
- 拖拽/裁剪/选择交互归 UIA-005；波形成略图等媒体分析后续任务


# UIA-009 子步骤 3 落地（2026-10-03）：素材库面板与导入流程

- **PropertyPanelZone 重写**：素材库（fileImporter 导入按钮 + 列表 + 失效标记）
  + 属性桩保留（UIA-006 接真实参数）。签名改为无参 + `@EnvironmentObject`。
- **EditorViewModel.importMedia(url)**（主线程，用户动作低频）：
  security scope（iOS）→ `probeMediaDuration`（同步探测时长）→ `registerAsset`
  （id 本地单调分配）→ 目标轨道（第一条视频轨，无则建 + RunLoop 泵等 id）→
  `addClip` 追加到该轨末尾（追加式不重叠）。失败全链路干净返回（探测失败/
  提交失败不留半截状态）。
- **失效标记（D3 决策的落地）**：MVP 引用原路径不拷贝 —— `LibraryAsset.exists`
  由 FileManager 实时判定，文件被移走显示「⚠ 文件不在原路径（已失效）」，
  渲染侧届时以 kInvalidArgument 暴露。素材库整理（拷入沙箱）后续任务。
- 媒体类型白名单：movie/video/mpeg4Movie。
- **测试路径 helper 唯一真源**：`RepoPath`（SharedUI）/`TestPaths`（bindings），
  #filePath 上溯链**不得在新测试里手写**（本轮两次踩层数错误，P30）。


# UIA-005 落地（2026-10-03）：拖拽 / 裁剪交互 + 撤销入口

决策见 ADR-0012。要点（三条反直觉的，改代码前必读）：

- **拖拽期间不提交命令**：`ClipDrag`（本地状态）+ `ClipPreviewOverride`
  （几何覆盖）只影响绘制；松手时提交**一条** Move/Trim Command。
  → 不引入 coalescing：需求来自「每帧提交」，而每帧提交会污染 Undo 栈。
- **提交后必须 `refreshFromKernel()`**：内核拒绝（重叠 / duration ≤ 0）时
  **不触发 observer 回流**，不主动回查就会留下"幽灵片段"。代价：成功时有
  一次旧值回弹 —— 正确性优先。
- **左边缘不裁剪**：`TrimClipCommand` 只改 duration 不动 source_in；左边缘
  归「移动」（要动 source_in 的是另一条命令，本期不做）。

结构：

| 位置 | 内容 |
|---|---|
| `Timeline/TimelineLayout.swift` | `hitTest(point, override)`（`ClipHitRegion.move` / `.trimEnd`，右边缘 8pt）+ `rect(for:override:)`；**纯函数、可单测** |
| `Timeline/EditorTimelineView.swift` | `ClipDrag`（夹取：起点 ≥ 0、时长 ≥ 0.05s）+ DragGesture 分支（命中片段=编辑 / 空白=平移）+ `commit()` |
| `Editor/AppEntry.swift` | `moveClip/trimClip/undo/redo` + `canUndo/canRedo`（@Published）+ `refreshFromKernel()` |
| `Editor/TimelineZone.swift` | 撤销/重做按钮（`disabled` 绑能力标志，macOS 吃 Cmd+Z / Cmd+Shift+Z） |

⚠️ **iOS 摇一摇撤销未实现**（需 UIViewController 代表层，SharedUI 是纯
SwiftUI）—— 两端通用的是按钮入口，摇一摇留给后续任务。

⚠️ **未被自动测试覆盖**：SwiftUI 手势（DragGesture 的 onChanged/onEnded）
无法在 XCTest 里驱动。故命中判定、夹取规则、提交结果都抽成纯函数/ViewModel
方法去测；手势接线靠 App 冒烟与人工验证。


---

# UIA-011 落地（2026-10-04）：相册素材导入（PhotosPicker 入口）

Spec：`docs/specs/UIA-011-相册素材导入.md`。**选型结论**：用系统
`PhotosPicker`（PhotosUI，iOS 16 / macOS 13+，基线内），**不引第三方相册库**
（红线 #10 治理成本 > 收益）；自定义相册浏览 UI 是后续任务，替换挂载点 =
按钮 + item→URL 胶水，导入链路不动。

- **PropertyPanelZone 双入口汇一**：「从文件导入」（fileImporter）+「从相册导入」
  （`PhotosPicker(selection:matching: .videos)`，单选）。两条路**都汇入
  `EditorViewModel.importMedia(url:)`** —— ViewModel / 内核 / 绑定层零改动。
- **胶水 `PhotoLibraryImporter`**（同文件内，@MainActor ObservableObject）：
  loading 翻转（防重复点击）+ errorMessage 自持；`run(resolveURL:importURL:)`
  **闭包全部注入** —— loadTransferable 需要真实 PHAsset，XCTest 宿主没有
  相册数据，注入后状态机可单测（PhotoImportTests，5 个注入态用例 + 1 个
  与真 ViewModel 组合的 golden 全链路用例）。
- **权限**：PHPicker 是进程外选择器，**无需** `NSPhotoLibraryUsageDescription`，
  不动 project.yml 的 info 段。
- **onChange 细节**：`Task { @MainActor in ... }`（onChange 闭包非 actor 隔离，
  显式跳，同 applySnapshot 手法）；完成后 `photoItem = nil` 清 selection ——
  PhotosPickerItem 按 itemIdentifier 判等，不清空则再次选取同一条素材
  不触发 onChange。
- **D3 沿用**：相册视频由系统落到 tmp 的 URL，App 重启后可能被清理 →
  届时素材列表同样显示「⚠ 已失效」，与文件路径行为一致（非回归）；
  素材库整理（拷入沙箱）任务两条路径一起收口。

⚠️ **本轮门禁未执行**：当前机器无 Swift 6.1 工具链（Xcode 13.1 / Swift 5.5 /
macOS 12.6，见 pitfalls P45），只做了 `swiftc -parse` 语法级检查；swift test /
两平台 xcodebuild 待真实构建机执行后才算验收通过。

> **补充决策(2026-10-04,传哲确认)**:低配设备(本机 Mac mini 2014,
> i5-4278U / 8GB / macOS 12.7.6)**暂时**不跑真机测试 —— 真机验证**延期非取消**,
> 待高配构建机 / 真机可用时恢复(HEVC / 4K / iCloud 素材届时一并验证);
> 不作为 UIA-011 当前验收门槛。剩余验收缺口仅剩构建机上的编译门禁
> (swift test + macOS/iOS 编译)。

---

# 相册导入后续规划(2026-10-04):UIA-012 / UIA-013 立项

应"是否有好的三方相册库 / 自研可行性"的选型问题做了调研,分层选型固化在
**ADR-0015**(系统过渡、不引三方、B 期自研)。调研时点结论:ZLPhotoBrowser
(Apache-2.0,活跃)、HXPhotoPicker(MIT,活跃;**旧名 HXPHPicker 仓库已归档,
勿引错**)、AnyImageKit(停滞);Android / 鸿蒙官方方向均为系统 picker。

- **UIA-012(A 期,近期)**:系统 `PhotosPicker` 多选(`maxSelectionCount`=20),
  逐条汇入 `importMedia`、部分失败不中断、条间 `Task.yield()`(红线 #8)。
  仍是零权限零依赖;同文件(PropertyPanelZone)串行于 UIA-011 之后。
  Spec UIA-012。
- **UIA-013(B 期,伞任务)**:自研 SwiftUI 相册浏览器(网格 / 相簿 / 多选
  序号徽标 / 时长过滤 / iCloud 未下载拉取 / `.limited` 受限模式),替换
  UIA-011 挂载点(按钮 + item→URL 胶水保留,换选择器本体)。**显式偏离
  零权限惯例**:新增 `NSPhotoLibraryUsageDescription` + 隐私标签申报
  (ADR-0015 决策 3)。**方向锚**:core 的 probe/解码消费文件 URL,自研只换
  选择 UI,不改变"选中项 → 文件 URL → importMedia"落盘路径(撞 PAL 红线
  #2 的路不走)。Spec UIA-013。
- **三端**:不强行统一相册选择 UI(Android 系统 Photo Picker / 鸿蒙
  PhotoViewPicker),三端统一的是"选择结果 → importMedia → Command"链路
  (ADR-0015 决策 4)。三方库仅作设计参考(读源码提炼边缘 case 清单,
  不拷代码)。

---

# UIA-012 落地(2026-10-04):相册多选批量导入

Spec UIA-012 / ADR-0015。分支 `mini.zhu/UIA-012-photo-multiselect`。

- **入口**:`PhotosPicker(selection:matching:maxSelectionCount: 20)`
  (常量 `maxPhotoImportCount`,Spec §6.2 可调),状态改为
  `photoItems: [PhotosPickerItem]`,完成后清空数组(重选同批依赖
  itemIdentifier 判等,语义同单选版)。
- **批量胶水 `PhotoLibraryImporter.runBatch(count:resolveURL:importURL:)`**:
  逐条 resolve→import,条间 `Task.yield()`(红线 #8);**部分失败不中断**,
  有失败才写 errorMessage —— 全失败 = 最后一条详情(文案前缀同单条路径)、
  部分失败 = 「成功 M 条,失败 K 条(最后详情)」、全成功 = nil(素材入表
  即反馈)。UIA-011 单条语义以 count:1 特例保留(PhotoImportTests 前 5 用例)。
- **批量顺序保证 `sequencedImport(into:)`**:importMedia 成功后等
  **"clips 计数增加"(片段在快照可见)**再导下一条 —— 下一条的追加起点
  取自快照该轨末尾(AppEntry.importMedia §4),不等就会用同一 end 提交、
  被内核按重叠拒绝;**不能只等版本推进**(建轨也 bump 版本,会提前放行)。
  泵手法同 AppEntry 建轨等待(5s 兜底,超时由下一条的重叠拒绝兜住并计入
  失败汇总)。
- **importMedia 不按路径去重**:同一文件导 N 次 = 素材表 N 条(批量 golden
  用例按此断言,3 次导入 = 3 素材 3 片段首尾衔接)。
- ⚠️ 门禁:本机 tools version 6.1 拒跑(P45);`swiftc -parse` 新代码零新增
  错误(PropertyPanelZone 仅剩 UIA-011 既有 5.7 简写噪音 1 处);
  swift test / 两平台编译待真实构建机执行。

---

# UIA-013 落地(2026-10-04,提前启动):自研相册浏览器 MediaPicker/

Spec UIA-013 / ADR-0015(决策 3:B 期任务经用户决策提前)。**挂载点替换**:
PropertyPanelZone 的系统 PhotosPicker 已移除,换 `AlbumPickerScreen` sheet;
确认交付的 URL 列表走 UIA-012 同款 `runBatch(count:resolveURL:importURL:)`
→ `sequencedImport` → importMedia,导入链路零分叉。权限:双端 project.yml
新增 `NSPhotoLibraryUsageDescription`(显式偏离零权限,ADR-0015 批准)。

- **分层**(MediaPicker/ 六文件,取数 seam 挡 PhotoKit):
  `AlbumPickerModels`(纯逻辑:AssetDescriptor / AlbumSummary / 配置 /
  SelectionState 有序多选状态机 / DurationFilter / 文案)→
  `AlbumPermissionModel`(PHAuthorizationStatus 纯映射 + 注入式请求)→
  `PhotoKitAlbumStore`(AlbumFetching 协议生产实现)→
  `MediaPickerViewModel`(装配:装载/切换/选取反馈/确认导出)→
  `MediaGridCell` + `AlbumPickerScreen`(视图)。测试注入夹具取数器
  (AlbumPickerTests 12 用例),PhotoKit 运行时行为靠冒烟/真机。
- **PhotoKit 两个关键处理**(承 ZL/HX 经验,见 store 头注释):
  ① iCloud 判定 = 缩略图请求 `isNetworkAccessAllowed=false` + 
  PHImageResultIsInCloudKey(云端 cell 显示占位 + 云徽标,不在此联网);
  ② 选中项 → 文件 URL = PHAssetResourceManager.writeData 落我方 tmp
  (确认导出时联网拉取,进度上抛给完成按钮)—— 不改"选中项落成文件 URL"
  的导入落盘路径(Spec §2 方向锚),落盘优化归素材库整理任务。
- **交互范式**(对齐 ZLPhotoBrowser/HXPhotoPicker):序号徽标(选取顺序
  可视化,取消后序号前移)、满选置灰 + 抖动提示、时长角标 + 区间过滤
  (超限灰化 + 原因)、底部已选托盘(跨相簿持久,点缩略图取消)、相簿切换
  菜单(最近项目/智能相簿/用户相簿,剔除最近删除)、受限横幅、权限拒绝
  引导(去设置)、iOS 轻触震动。暗色,强调色 PickerTheme.accent 与时间线
  片段蓝同族。
- **已知留白**(Spec §7,后续增量):.limited 的"管理可选照片"系统面板
  只有 UIKit 入口(SwiftUI 接线待做,横幅暂为说明性);选择器内点击预览
  播放器未做;PHFetchResult 变更增量刷新未做(MVP 整段 reload)。
- ⚠️ 门禁:同 UIA-012(P45 拒跑);parse 零新增错误类别;构建机验收 +
  真机项(权限弹窗/.limited/iCloud/滚动帧率)待执行。

**v1.1 交互升级(同日,对齐剪映素材面板)**:默认**单击即插入**(点 cell →
loading 覆盖 → 落 tmp → async 交付 → importMedia → loading 解除 + toast,
面板保持打开,连续导入流);「多选」为显式模式(顶栏切换/长按 cell 直达,
退出清空已选,批量按钮「添加（N）」,成功后托盘清空)。`MediaPickerViewModel`
的交付回调改为 **async**(`onConfirm: ([URL]) async -> Void`)—— VM await
父层 runBatch 完成才解除 cell loading,反馈闭环覆盖"落盘+进时间线"全程;
`insertingIDs` 驱动 cell loading 覆盖层,`isPreparingFiles` 串行化快速连点
(importInFlight 重入拒绝不触发)。iOS 半屏 detents(medium/large)+拖拽
指示器(16.0 API),macOS 固定窗口。UIA-013 Spec 升 v1.1。

# CAM-011 落地（2026-10-04）：Vision 检测桥 + 帧间平滑（B 期第 1 卡）

- **新增目录** `apps/apple/ios/iOSApp/Camera/Detection/`（xcodegen `sources: [iOSApp]`
  递归收集，project.yml 零改动）：
  - `VisionDetector.swift` — 检测桥。`offer(pixelBuffer, pts)` 从**采集队列**进，
    锁内降频闸门（默认 15Hz [E] 可配）+ busy 信号量（latest-wins），异步转
    **专用检测队列** `cq.camera.detection` —— 与采集/渲染队列互不阻塞。
    人脸 76 点级 + 人体 19 关节 + 动物物种（`VNRecognizeAnimalsRequest`）+
    动物姿态（iOS 17+ 门控，类型引用全收在门控内）。
  - `FaceObservation.swift` — 中性观测结构（与 Vision 解耦，检测器可替换）：
    人脸 12 区域 + yaw/pitch/roll、`BodyJoint` 19 关节、`AnimalJoint` 5 头部关节、
    `DetectionSnapshot`（pts + face + body + animals）。
- **SharedUI 新增** `Camera/DetectionSmoothing.swift`（纯函数，macOS 可测）：
  - `smoothKeypoints(previous:current:params:)` — One-Euro 简化款自适应 EMA
    （静止重平滑抗抖、快速移动 alpha→1 低延迟跟随）；缺失点保持上帧、
    形状变更重置；**平滑状态由检测器携带，onResult 交付的观测已平滑**。
  - `visionPointToImageNormalized` / `visionRectToImageNormalized` — 坐标映射。
- **坐标契约（B 期全链，013/014 消费方照此）**：图像归一化坐标、**origin 左上**、
  两轴 0...1，与像素尺寸/方向无关；Vision 的左下原点在检测器内翻转，消费方不再翻。
- **接线状态**：`offer()` 尚未挂进 `CameraViewModel.wireCallbacks`（本卡 write_set
  不含该文件）——**CAM-013 首个消费方落地时接线**，届时一并把
  `smoothingStrength` 接美颜面板。
- 诊断埋点：`lastDetectionDurationMs` / `totalDetections` / `totalDroppedByRate` /
  `totalFailed`（真机耗时入 baselines 的数据源）。
- 验证：simulator SDK `-typecheck` 0 错 0 警（比 -parse 强，抓出 4 个 API 形状错，
  见 P46）+ macOS 宿主执行数学断言 19/19；包级 swift test 待新 Xcode 机器（P46）。

# CAM-012 落地（2026-10-04）：Metal 磨皮替换 CI 高斯近似（B 期第 2 卡）

- **新增目录** `apps/apple/ios/iOSApp/Camera/Effects/`（App 层特效资产，ADR-0014 §3
  红线 #6 边界，不进 SDK shader 清单）：
  - `beauty_bilateral.metal` — 双 pass 亮度域双边：Pass1 下采样(2x2 盒)+水平双边
    （输出半分辨率 extent）；Pass2 垂直双边+双线性上采样+与原图按强度混合
    （输出原图 extent）。随 Xcode **编译期内建**为 default.metallib（iOS 17.2 SDK
    的 CIKernel 无源码串初始化器，只有 `fromMetalLibraryData:`，P47）。
  - `BeautyKernel.swift` — 从 bundle 扫 metallib → CIKernel×2 → 双 pass apply；
    `BeautyKernelProfile` 纯函数映射（taps 2...5 / σr 0.03+0.08s / mix=s，单调不减）；
    加载失败/非零 origin/引擎放弃一律返回 nil → SharedUI 默认实现兜底。
- **SharedUI `CameraBeauty.swift` 改薄封装（契约层）**：新增
  `CameraBeautySmoothingEngine`（@Sendable `(CIImage, Double) -> CIImage?`）注入点
  `CameraBeautyEngine.smoothing`（锁保护类，Swift 5.9/6.x 双兼容，无
  nonisolated(unsafe)）。`apply` 语义不变：off 恒等直通（===）→ 引擎优先 →
  引擎放弃/未注入回落默认 CI 高斯（**保留为兜底不是死代码**，macOS 一直走它）。
  调用方（预览/拍照/录制）零改动。
- **装配**：`CameraViewModel.init` Metal 分支末行
  `BeautyKernel.installSharedSmoothingIfNeeded()`（幂等；bundle 无 metallib 静默降级）。
- **A 期存量编译错误修复（P48，7 处）**：CameraRenderer（缺 import MetalKit、
  latest 重声明、render(toDestination:) 在 iOS 17.2 SDK 不存在→改 toMTLTexture
  变体）、CameraRecorder（sourcePixelBufferAttributes 标签、
  CVPixelBufferPoolCreatePixelBuffer 3 参桥接）、CameraView（iOS 17 两参 onChange
  用于 iOS 16 部署目标）、CameraViewModel（缺 import UIKit、wireCallbacks 引用
  局部化去 self 捕获）。
- **验证新工具** `tools/qa/beauty_harness/build_and_run.sh`：`metal -fcikernel` 编
  同一 .metal → metallib，连同真 BeautyKernel/CameraBeauty 在 macOS 宿主 GPU 上
  跑算法断言（profile 单调/方差单调/边缘过渡宽度/平台对比度/1080p 耗时），
  诊断开关 `CQ_DEBUG_PROFILE=1`。真机指标（≤8ms）仍待实测回填 baselines。

---

# AIEDIT 立项（2026-10-04）：智能成片入口（SmartCut/ 域）

Spec AIEDIT-001 / ADR-0020 / TASK-AIEDIT-000。首页 `HomeView.swift` 新增第三张
入口卡「智能成片」（Route: `.smartCut`），新域目录
`SharedUI/Sources/SharedUI/SmartCut/`（Wizard / Result / Chat / Voice 四子域，
组织方式照 MediaPicker：纯逻辑抽可测类型 + SwiftUI 接线冒烟）。

- **选素材复用 UIA-013**：`AlbumPickerScreen` 多选模式 → `runBatch` → importMedia
  → asset_id 就绪后进分析（C ABI `cq_ai_*`，AIEDIT-007）。
- **结果页双出口**：直接导出（EXPORT-001 落地前置灰 + 标注）/「进编辑器精修」
  push 现有 EditorView —— **同一 CQSession**，plan 批次在撤销栈原样可见。
- **对话框（AIEDIT-009）**：文字 + 按住说话（SFSpeechRecognizer → 文字进框）；
  逐轮增量 plan 逐条接受/拒绝（拒绝项剔除后再校验应用）；"撤销本轮"按批次 id
  定位。隐私：语音仅本地转文字，音频不上传；STT 权限文案随 project.yml info 段。
- **决策透明 UI**：结构时间条（片头/发展/高潮）+ 每段 reason 抽屉（学 Opus，
  不做黑盒成片）；断网出片时显式标注"离线模式"（local_rules）。
- 高冲突文件：HomeView.swift（AIEDIT-008 独占批次）、project.yml info 段
  （AIEDIT-009，NSSpeechRecognitionUsageDescription + 麦克风）。
- 状态：立项（12 张任务卡落盘，未开工；关键路径 001→005→007→008→009）。

---

# UI 视觉升级调研（2026-10-04）：RESEARCH-004 结论

应"拍摄/编辑 UI 比较丑，调研 iOS/Mac 主流做法"命题完成调研，全文见
`docs/research/RESEARCH-004-拍摄与编辑UI主流方案调研.md`。要点：

- **定性**：丑的根源是"缺设计系统 + iOS 竖屏塞了桌面三区 + 细节打磨为零"，
  不是框架问题——主流剪辑 App 无一靠第三方 UI 库变好看，拍摄 UI 不引库
  （NextLevel/SwiftyCam/Mijick Camera 均只管采集；与 ADR-0015 同构逻辑）。
- **主流形状**：iOS 拍摄页 = 全屏取景 + 玻璃悬浮控件 + 滤镜缩略图卡 + 全屏
  结果页；iOS 剪辑页 = 剪映式"单焦点+抽屉"（预览最大化/时间线中部/底部图标
  工具栏/属性 bottom sheet，无常驻侧栏）；macOS = 标准 NLE 五区 + Mac 惯例
  （工具栏/可折叠 Inspector/可拖分隔条/菜单栏），现有 HSplitView 布局同构，
  缺惯例化与打磨。
- **基线策略（建议，待拍板立 ADR）**：双轨——Theme 2.0 语义令牌先行（两端
  共享令牌值，对应 ARCH-005"共享状态不共享 UI"）；Liquid Glass 需 SDK 26
  构建 + 26+ 运行，自定义效果一律 #available 门控、低版本回退系统材质。
  先决条件：构建机升 Xcode 26（现 SDK iphoneos18.4）。
- **任务批次建议**：UIA-014 设计系统（Theme.swift 一次改净，后续只读）→
  UIA-015 iOS 相机页 / UIA-016 iOS 剪辑页 / UIA-017 macOS 惯例化 →
  UIA-018 时间线视觉（缩略图异步，主线程不解码红线不变）。均为纯视图层，
  Command/ViewModel/Session 不动。下一步：cq-spec-authoring 出 SPEC-UIA-014。

# UI 操作逻辑深拆调研（2026-10-05）：RESEARCH-006 结论

应"调研全球顶级拍摄编辑 UI 布局与面板逻辑"命题完成，全文见
`docs/research/RESEARCH-006-顶级拍摄剪辑App布局与操作逻辑深度调研.md`
（18 家：Blackmagic/Kino/Halide/FC Camera/FiLMiC/iOS 26 相机/TikTok/Reels/
Snapchat + CapCut/Edits/VN/Videoleap + FCP/Resolve/FCP iPad/Premiere/CapCut 桌面）。
RESEARCH-004/005 结论全部维持，本文补**操作层**，关键增量：

- **拍摄页八律**：高频下沉拇指弧；侧列只放录制前设置；自动默认+手动按需浮层
  （Kino/Halide/FC Camera 范式，**不学** BMD 常驻芯片条）；色彩预设一级入口实时可换；
  单指变焦（Snapchat）；状态反馈一条带；拍完必进编辑（流水线）；改版保肌肉记忆回退
  （iOS 26 相机争议与回调的教训）。
- **编辑页八律**：核心 = **一个工具栏槽位、两套内容、选中驱动**（CapCut 定式：
  一级项目工具栏 ↔ 片段编辑条同槽替换）——UIA-016 的关键细化；撤销/重做恒置预览区顶；
  参数不遮预览；二级面板 sheet 幅度随复杂度；关键帧三层收纳；面板组织三范式
  （分页/情境/浮动，轻剪辑取情境）；Inspector 按属性域分组（Video/Audio/Color）；
  新范式默认+旧范式逃生门（FCP Position、VN Quick/Pro）。
- **手势词汇表趋同**（双指缩放/平移时间线、长按拿起、边缘 trim）——UIA-016/018 对齐，
  不自创手势。
- **落地**：§5 delta 表逐任务列了 UIA-015/016/017/018/019 的新增输入；
  UIA-019 PanelRoute 状态机需增加"工具栏槽位状态"。明确不采纳：Resolve Pages、
  Premiere 浮动面板、BMD 芯片条。未核实项已标 [hypothesis]，精确控件排布
  待真机走查截图核对（§6.2）。
