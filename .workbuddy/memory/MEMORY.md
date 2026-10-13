# ChuanqiCut 项目长期约定

> 仅记录 AGENTS/ADR 之外仍需跨会话保留的事实；架构与门禁规则以 `.ai/source/AGENTS.root.md`、模块册、ADR 为准。

## 用户协作偏好（传哲）
- 称呼「传哲」；直给、少填充，主动指出事实错误、矛盾和未验证假设。
- **全量门禁、合并快检、真机测试都必须先询问**，得到明确同意后执行。
- 交付必须报告：具体命令、通过/失败数字、跳过项、剩余风险；未跑门禁不能称“验收完成”。
- 估算标 `[E]`，推测标 `hypothesis`；只有实测可作验收阈值，引用基线必须带机器环境。
- 计数埋点绑定真实效果完成，不绑定代码路径到达；成功计数放在命令缓冲完成且无错后，并有 failureCount 防伪绿。
- **（2026-10-10 新增，ADR-0034）不急于求成**：要耐心、逐步推进、稳扎稳打；功能点要做全做透，不能模仿个形状就算完；方案必须全局考虑。批次可并行（写集不相交），但**一批未验收不得在其上叠加下一批**。
- **（2026-10-10 新增，ADR-0034）严禁临时方案**：任何“先 XX 顶着 / 以后替换 / 本期先用 Swift 写”一律不采用；被下层阻塞就排队等地基。已是第二次踩「两套渲染路径」的坑（ADR-0014 代价），不得再犯。
- **（2026-10-10 新增，ADR-0034）交付节奏固化**：写代码 → 出真机问卷 → 传哲实测给表现 → 集成机纠偏登记。**问卷未回收不得标记完成**（呼应 P99：门禁绿 ≠ 功能可用）。
- **Mac 与 iOS 分端形态**（ADR-0034 §6）：不再把 iOS 视图塞进 Mac 窗口。iOS 走移动端单焦点抽屉范式，macOS 走桌面专业范式（常驻属性面板 + 顶部工具栏 + 菜单命令 + 多窗口 + 快捷键全表 + 拖拽导入）。两端只共享 ViewModel 与 Command 链路，UI/交互/菜单/快捷键不共享。
- **决策必须署名带时间戳**：什么模型、什么时间、做了什么决策、写了什么代码、传哲拍板了什么、做了什么调整 —— 全部登记 `docs/reports/LEDGER-*.md`（append-only），不留在对话里。

## 当前协作与工程事实
- 本机是集成机：全局册单写者、唯一发号器、唯一可信全量门禁/真机口径；其他设备按模块线开发。
- **（2026-10-11 新增）多 agent 并行协作是常态**：传哲会同时开多个 agent 在**同一工作区**
  跑不同模块线（如 2026-10-11 我跑 INFRA-022 整改、另一 agent 跑 DEPS-012 FFmpeg 集成）。
  规则：① **写集不相交是硬约束**，撞车的文件先核再动，不抢；② 发现对方改动后
  **不碰、不顺手提交**，只登记事实并上报；③ 交接要写到**文件 + 行号级**
  （谁改了哪几行、是否行区间重叠），只说「别打架」不可执行；④ **不用 `git pull --rebase`**
  （会动别人未推送的本地提交）；⑤ 自己的门禁数字**不能当对方的回归基线**
  （各自跑出来的版本不同）。交叉点核查命令：`git show --name-only <c>` 逐个核自己的提交里
  有没有混进对方文件。
- **可追溯三件套（ADR-0034，2026-10-10 起必用）**：`docs/reports/LEDGER-W42.md`（决策与实现台账，append-only，含模型/时间/写集/验证/拍板）、`docs/reviews/TEMPLATE-真机问卷.md`（交付必附）、`docs/reviews/QUESTIONNAIRE-<批号>-<主题>.md`（实例）。
- **编辑功能对齐路线（2026-10-13 已重构，见 ADR-0040）**：`RESEARCH-010` §5 批次表已更新。
  - B0 渲染地基 **已提交 `2e8b55d`**（ctest 52/52）；**真机问卷未回收 → 按 ADR-0034 未标记完成**。
  - B1 模型命令 ✅；B2 部分（AUDIO-004 `chq_mix` 已提交，PALA-030 未做）；B3/B4+ 未开工。
  - **新增 B5.5「空间与交互地基」（传哲 2026-10-13 拍板：B4 之后、B6/B7 之前）**：
    `MODEL-004`（ChqTransform + layer + speed + keyframes）+ `EDIT-012`（commit/done 双层 PreviewSync）。
    由来：RESEARCH-016 比对出 `ChqClip` 缺 transform/layer/speed/keyframes/relative，
    原批次表没给这些数据留地基，照原排期到 B7 才补会重演 ADR-0014。放 B4 后是为**不推迟可见出口**。
  - B6/B7 自此**可并行**（都只依赖 B0+B5.5）；B8 仍串在 B7 后。**B3 持久化建议排到 B5.5 之后**。
  - **B0 问卷回收前，不得在 B0 之上叠加任何批次**（ADR-0034）。
- **本机 `ctest` 不在 PATH**：须用
  `/Users/zhuning/.workbuddy/binaries/cmake/CMake.app/Contents/bin/ctest --test-dir build`。
  另：SharedUI 包**无 Tests 目标**，`swift test` 恒 `no tests found`（非失败，只能验编译）；
  SPM 在本会话须加 `--disable-sandbox`（沙箱嵌套）。详见 pitfalls **P127**。
- 热点文件（`cq_sdk.h`、CMake、podspec、Podfile、project.yml、构建脚本、真源、CI）及 ABI/依赖变更须由集成机处理。
- 收工同步顺序：模块册 → 必要 ADR → TASK → HANDOFF → pitfalls → baselines → 当日日志 → 本文件（仅新增长期规则时）。
- 构建产物不得入库；临时编译统一放根 `/build/`。SPM 必须指定 `--scratch-path "$ROOT/build/spm/<包>"`。
- **壳工程已冻结入库（ADR-0037，2026-10-11，XcodeGen 退役）**：`ChuanqiCut.xcodeproj`/`.xcworkspace` 是手工源文件——Xcode 可视化改动即真源、直接提交，禁止任何工具重新生成。依赖变更只跑 `bundle exec pod install`；**podspec 增删文件后必须重跑**（Pods.xcodeproj 是文件清单快照，旧清单会编已改名/已删除的文件——2026-10-11 实踩：旧清单编已不存在的 pal_frame_provider.cpp）。
- **壳工程 agent 通道（ADR-0037 台阶 1/2，2026-10-11）**：① app 目标源码已是 synchronized groups——**app 内加/删文件 = 纯文件系统操作**（放 iOSApp//MacApp/ 即编译，Info.plist 已设成员例外）；② agent **禁止裸编 project.pbxproj 文本**，结构化改动（设置/脚本阶段/引用）一律走 `tools/build/edit_project.rb`（xcodeproj gem）；③ 动同步组先核 sourceTree casing（必须小写 `<group>`，P107）。
- iOS App 构建只认 `ChuanqiCutApp` scheme + `iphoneos` generic device；模拟器 MetalFX 解析失败是 SDK 限制，不改代码规避。
- macOS App 构建只认 `ChuanqiCutMacApp` scheme，命令行必须带 `-arch x86_64 ONLY_ACTIVE_ARCH=YES`（本机 Intel；默认 universal 会编 arm64，而 SDK 26.5 无该 slice 的预编译 Swift 模块 → 一片 `Unable to resolve module dependency`，P96）。报双壳结论时写明架构。
- 分发静态库默认关闭 LTO，打包后必须消费者侧链接冒烟；Swift 绑定验收含 `swift test` 与 `run_smoke.sh`。
- 系统框架清单以 `ChuanqiCut.podspec` 为单一真源，需同步 Package.swift 与 run_smoke.sh。

## 关键实现契约
- Timeline 变更只走 CommandHistory；提交后 `refreshFromKernel()`；拖拽结束只提交一条命令。
- 预览渲染只在 PreviewPump 线程；主线程 Request + Lock/blit/Unlock，持锁期间不 Request，不 waitUntilCompleted。
- 异步等待必须同时有超时和独立内存上界；回调先交付数据再登记完成；Platform 逐帧入口自带 `@autoreleasepool`。
- Camera：检测坐标左上原点归一化；Vision 翻转只在转换层一次；采集/渲染/检测三队列；人像能力无算法即直通，不退化为全画面滤镜。
- CIContext 显式 gamma sRGB；区域三态：faces=nil 全画面兜底、空数组直通、非空区域蒙版。
- 日志按 Level/Stage/Workflow；偏离正轨一律 Warn 且 Release 可见；慢调用统一 `CQ_SLOW_CALL_WF`。

## 命名：`PAL` 已统一改名为 `Platform`（ADR-0035，2026-10-11 执行完毕）
- 目录 `engine/core/cq/platform/`（契约）+ `engine/platform/`（实现）+ `tools/platform/`；
  全仓不再有 `pal` / `PAL`（**历史卡号 `PALA-xxx` / `PALD-xxx` 除外，有意保留，改了会断链**）。
- 代码标识符一律用新名：`PlatformPtr<T>`、`IPlatformResource`、`CQ_PLATFORM_*_H_`、
  `cq_platform_apple`（CMake target）、`cq_tests_platform_apple_*`（test target）、
  `platform_apple_*`（ctest 名）。
- **动 platform 模块前先读这三条红线**：
  ① 门禁脚本 `tools/platform/check_platform_headers.py` 的 `CONTRACT_DIR_NAMES` **白名单写死目录名**，
  目录再改不同步 → **静默漏扫**（P95 复发，本次踩过）；
  ② ctest 名随 target 改，**文档里的 `ctest -R <name>` 必须同步**（编译抓不到，只有跑测试才炸）；
  ③ podspec 路径不走 CMake 链路，**编译过 ≠ pod install 过**。
- **全仓机械替换必须显式排除 append-only 文件**（P103）：`docs/reports/LEDGER-*.md`、
  `.workbuddy/memory/YYYY-MM-DD.md`、`.zcode/plans/*`。替换后**专门复核 `→` 形式的行**是否仍成立
  （`A → A` 式破坏 grep 计数看不出来）。

## 目录与 Pod 边界（ADR-0033，2026-10-09 定案）
- 内核头与实现**共置**在 `engine/core/cq/<功能>/`；Apple Platform 分 `engine/platform/apple/{base,gfx,media}`。CMake include root = `engine/core`，`#include "cq/..."` 不变。
- Engine 两个 Pod：`CChuanqiCut`（C ABI + C++20 + Platform，**唯一 public 头 `core/cq/cq_sdk.h`**）+ `ChuanqiCutEngine`（Swift adapter，消费端仍 `import ChuanqiCutEngine`）。**两个本地 spec 必须都在 Podfile 显式 `:path`**。
- 已废弃：主工程头文件 folder reference、`pods_post_install.rb` 补 PBX 引用、UI Pod 手工传播 `SWIFT_INCLUDE_PATHS`。头文件可见性只由 podspec 的 public/private 边界决定。
- XCFramework 只打包 `cq_sdk.h`（staging 目录），不要把整个 `core/cq` 当 public headers。
- 门禁脚本凡「按目录递归」的（如 `check_platform_headers.py`），扫描范围必须显式写死语义；目录重构后必重跑（P95）。
- MultiCam 定则：`AVCaptureMultiCamSession` **不支持 sessionPreset**（抛 NSException，canSet* 拦不住）；其 activeFormat 还必须在 `isMultiCamSupported` 子集内（P93/P94）。相机域「选哪个」的逻辑一律做成契约层纯函数 + 单测。

## 当前工具链与编号
- 当前集成机实测：macOS 26.7.1 / Xcode 26.6 / Swift 6.3.3；cmake 4.4.3 位于 `~/.workbuddy/binaries/cmake/CMake.app`；无 Homebrew；CocoaPods 1.17.0。**CPU 是 Intel（`uname -m` = x86_64）** —— 报任何构建/性能结论都要带上这个前提。
- 最近一次全量门禁（**2026-10-12**）：`run_gate.sh` **PASS 14 / FAIL 0 / SKIP 0**（22m14s）；
  core Debug/Release 各 **48/48**；bindings 26 / camera 77 / import 16 / editor 65 / player 52
  全 0 failure；deps/headers/artifacts/golden 均 PASS。
  ⚠️ **门禁不含 App 壳构建**（池 [18]）→ `*.metal` 的 `-fcikernel` 编译与壳内 Swift
  完全在门禁外，改 shader 必须另跑
  `cd apps/apple/ios && xcodebuild -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutApp
  -destination generic/platform=iOS build`（壳工程在 `apps/apple/ios/`，**不在仓库根**）。
- 编号（2026-10-12 12:10 核）：ADR 已到 0039；pitfalls 下一号 **P125**（P122/P123/P124 本批已占）；
  池下一号 **[19]**（[17] 真机未结项、[18] 门禁覆盖缺口）。
- 历史：2026-10-08 门禁 PASS 14/FAIL 0（core 各 46/46）。2026-10-11 core Debug 46/46。
- 编号取号前必须 `git fetch` 核远端；截至 2026-10-11 09:40：ADR 下一号 **0037**（0035 我用、0036 被 DEPS 线同日取用），INFRA 卡下一号 025（024 已用），pitfalls 下一号 **P104**（P98/P99/P100/P101/P102/P103 已占）。**并发时更要现取现核** —— 两个 agent 同日取号极易撞。

- 静态库裁剪档位「体积/符号/GPL 三绿」≠ 可用：**必须链接闭合冒烟一次**（P104，脚本已内置）。
- FFmpeg 头在 C++ TU 必须 extern "C" 包裹（FFmpeg 9 头无自带保护）；消费 libffmpeg.a 需
  CoreFoundation/CoreVideo/CoreMedia/VideoToolbox 框架（hwcontext 拉入，P105）。

## 竞品参考：对标平台/对标 App iOS 编辑 SDK（RESEARCH-016，2026-10-13 逆向）

材料 `/Users/zhuning/Documents/test/`（**只有头文件、无 .m**，结论由声明推断），
详见 `docs/research/RESEARCH-016-对标平台编辑SDK架构逆向与借鉴评估.md`。**避免重复调研，先看它。**

- **分层与直觉相反**：`其媒体引擎层`（623 头，最大）是**媒体引擎层**不是 App 层（实测 VC 数 = 0）；
  `其编辑语义层`（134 头）才是编辑语义层。依赖单向：UI → NLE → 其媒体引擎层 → 算法（实测反向引用 0）。
- **`commit` / `done` 是两层**：commit = 渲染同步点（高频、触发 diff、不入 undo 栈）；
  done = 事务边界（两次 done 之间合成一条 undo）。对比我们 `ChqCommandHistory::Execute` 三件事合一，
  「拖拽结束只提一条」目前靠纪律而非机制 —— 拟加 PreviewSync 通道（**待传哲拍板**）。
- **他们不如我们的地方（勿被"大厂也这么干"说服）**：预览与导出是**两条管线**
  （`其编辑器会话` vs `其编辑器组件*`）→ 我们红线 #9 更先进；双数据模型（其数据模型 + 其播放数据层 + 转换器）；
  Meepo 与 其轨道 UI 组件库 **100 个同名头文件**（两代并存，ADR-0014 同款坑）。
- **跨层 API 纪律（待拍板，未生效）**：他们把 5 态 `其播放器状态枚举` 降级成 `BOOL`、
  丢掉 seek 完成回调，根因是**引擎侧没给状态订阅通道**（注释还自相矛盾："不能KVO" vs "可监听"）。
  拟立规矩：跨层签名枚举必须具名、异步必须有完成回调、**禁止用标量布尔表达状态机**。

## 未决事项
- FFmpeg LGPL v2.1+ 处置**已定**（2026-10-11 传哲拍板，ADR-0036）：ARCH-002 §5.1 路径 1（App 内声明 + 源码可获得 + 可重链接归档），义务载体 engine/NOTICE.md；SDK 本体 License 仍待定。
- PERF-001 尚未建立正式性能基线；Intel Mac 无 ANE/ProRes 硬编，不得用其数字作产品阈值。
- 2026-10-08 以前 baselines 中“本机实测”仍需逐条归属真实机器 A/B/C。

## Apple 端 UI 改动的验证口径（2026-10-13 起，P129）
- **本机 macOS 的 `swift build/test` 完全跳过 `#if os(iOS)` 里的文件**（如 `UIKit/Editor*UIView.swift`
  `EditorViewController.swift`）→ SPM 全绿**不是** UIKit 侧改动的证据。
- Apple 端 UI 批的最小自证 = **两端壳构建**：
  * `cd apps/apple/ios && xcodebuild -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutApp -destination generic/platform=iOS build`
  * `cd apps/apple/mac && xcodebuild -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutMacApp -arch x86_64 ONLY_ACTIVE_ARCH=YES build`
    （⚠️ macOS 壳**不要带 `-destination`** —— 带 `-arch` 会报 "destination implies architecture"）
- **iOS 与 macOS 是两个独立 Pods 工程**：podspec 触及的文件增删/改名 → **两端各跑一次
  `bundle exec pod install`**，否则报 `cannot find 'X' in scope`（文件清单快照过期）。
- 检索纪律（P126 更正）：本机 `grep` 是 **toybox 0.8.13**，**不支持 `\|`**，多模式一律 `grep -E`；
  关键否定结论用 python 逐行扫交叉复核。

## 轨道区交互与视觉（UIA-041 起）
- **唯一判定/命令真源 = `TrackInteraction.swift`**（reducer 值类型 + `TrackIntentApplier`）；
  两个展示层（SwiftUI `EditorTimelineView` / UIKit `EditorTimelineUIView`）只翻译事件、消费 Intent。
  新增展示层前先确认它不会重新引入第二份判定。
- 轨道区配色走 **`TimelinePalette`**（本包内），不直接改 `SharedUI/Theme`（写集边界）；
  RGBA 一处定义，取 `.cgColor`(CALayer) / `.uiColor`(UIView.backgroundColor) / `.color`(SwiftUI)。
- **把手宽度必须复用 `TimelineLayout.trimHandleWidth`** —— 保证「看到的」=「按得中的」。
- 内核**无写 `CQTrackInfo.muted` 的 ABI**（只能单向读出）→ 轨道头做 disabled 只读态，
  欠账 **池 [19]**；ABI 到位前不要做能点的原声开关（假功能）。
- 视觉规格源于传哲给的 6 张对标 App截图，但**本会话模型不支持读图（P128），我并没实际看到**，
  故尺寸/配色一律标 [E]，以真机问卷回收校准为准（不得让用户误以为我看过图）。
