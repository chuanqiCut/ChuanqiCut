# ChuanqiCut 项目长期约定

> 只记 AGENTS/ADR/模块册之外仍需跨会话保留的事实。架构与门禁规则以
> `.ai/source/AGENTS.root.md`、`.ai/modules/*.md`、ADR 为准 —— 这里不重复抄。

## 用户协作偏好（传哲）
- 称呼「传哲」；直给、少填充，主动指出事实错误、矛盾与未验证假设。
- **全量门禁 / 合并快检 / 真机测试必须先询问**，同意后才执行。
- 交付必报：具体命令、通过/失败数字、跳过项、剩余风险；未跑门禁不得称「验收完成」。
- 估算标 `[E]`，推测标 `hypothesis`；只有实测可作验收阈值，引用基线须带机器环境。
- **（ADR-0034）不急于求成**：做全做透，不模仿个形状就算完；批次可并行（写集不相交），
  **一批未验收不得在其上叠加下一批**。
- **（ADR-0034）严禁临时方案**：「先 XX 顶着 / 以后替换」一律不采用，被下层阻塞就排队等地基
  （已两次踩「两套渲染路径」的坑，ADR-0014）。
- **（ADR-0034）交付节奏**：写代码 → 出真机问卷 → 传哲实测 → 集成机纠偏登记；
  **问卷未回收不得标记完成**（门禁绿 ≠ 功能可用）。
- 决策必须署名带时间戳（模型/时间/决策/代码/拍板/调整），登记 `docs/reports/LEDGER-*.md`
  （append-only），不留在对话里。

## 多 agent 并行（同一工作区是常态）
① **写集不相交是硬约束**，撞车的文件先核再动；② 发现对方改动**不碰、不顺手提交**，只登记上报；
③ 交接写到**文件 + 行号级**（谁改了哪几行、区间是否重叠）；④ **不用 `git pull --rebase`**
（会动别人未推送的本地提交）；⑤ 自己的门禁数字**不能当对方回归基线**。
核查：`git show --name-only <c>` 逐个核自己提交里有没有混进对方文件。

## 本机角色与工具链（集成机）
- 本机 = 集成机：全局册单写者、唯一发号器、全量门禁与真机的唯一验收口径。
- 机器：macOS 26.7.1 / Xcode 26.6 / Swift 6.3.3 / **Intel x86_64** / 无 Homebrew / CP 1.17.0。
  **任何构建或性能结论都要带上 Intel 这个前提**。
- `ctest` 不在 PATH：`~/.workbuddy/binaries/cmake/CMake.app/Contents/bin/ctest --test-dir build`。
  SharedUI 无 Tests 目标（`swift test` 恒 no tests found，非失败）；SPM 须 `--disable-sandbox`
  + `--scratch-path "$ROOT/build/spm/<包>"`；构建产物不得入库，临时编译放根 `/build/`。
- 最近全量门禁（2026-10-12）：`run_gate.sh` **PASS 14 / FAIL 0**（22m14s），core 各 48/48。
  ⚠️ **门禁不含 App 壳构建**（池 [18]）。
- 编号取号前必须 `git fetch` 核远端（并发时现取现核）。2026-10-15：ADR 到 0041，
  pitfalls 下一号 **P134**，池下一号 **[19]**。
- 收工同步顺序：模块册 → ADR → TASK → HANDOFF → pitfalls → baselines → 当日日志 → 本文件。

## Apple 端验证口径（P129，UI 改动必守）
- **本机 macOS 的 `swift build/test` 整文件跳过 `#if os(iOS)`** → SPM 全绿**不是** UIKit 侧证据。
- 最小自证 = **两端壳构建**：
  `cd apps/apple/ios && xcodebuild -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutApp -destination generic/platform=iOS build`；
  `cd apps/apple/mac && xcodebuild -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutMacApp -arch x86_64 ONLY_ACTIVE_ARCH=YES build`
  （macOS 壳**不带 `-destination`**，与 `-arch` 冲突会报 "destination implies architecture"）。
- iOS/macOS 是**两个独立 Pods 工程**：podspec 涉及文件增删改名 → **两端各跑一次
  `bundle exec pod install`**，否则 `cannot find 'X' in scope`。
- 检索纪律（P126/P133）：本机 `grep` 是 **toybox 0.8.13，不支持 `\|`**，多模式一律 `grep -E`
  或 Grep 工具；关键否定结论用 python 逐行扫复核（已出过假阴性）。

## 自绘 UIView 的图层铁律（P131，2026-10-14 事故后确立）
- **自绘 CALayer 一律挂专用容器层** `canvasLayer`（init 挂 `layer.addSublayer`，
  `layoutSubviews` 置 `frame = bounds`），重建只清 `canvasLayer.sublayers`。
- **绝不清 UIView 的 backing layer**（`layer.sublayers = nil` / `forEach { removeFromSuperlayer() }`
  / `removeAll()` 全禁）—— 里面**混着子视图的 layer**，全清让 UIKit 持有「有 view / 无 layer」
  畸形状态 → CA 首次提交事务时 `superview` 解引用野指针 SIGSEGV。
- 机器兜底 `tools/compliance/check_uiview_layer_hygiene.py`（`run_gate.sh` 步骤 2c）：能拦同一写法
  复发，**拦不住等价语义其它形态**；CR 也拦不住 —— 危险由「后来一次合法改动」激活。

## 真机联调配方（iPhone 17 Pro UDID 0FA3CFBB-50FB-541F-971B-7FF65F5ED9A7）
- 起进程：`xcrun devicectl device process launch --device <UDID> --console --terminate-existing
  -e '{"CQ_AUTO_ROUTE":"editor"}' com.chuanqi.cut`；**日志走 stderr**（stdout 全缓冲会丢）。
- 自动入口：`CQ_AUTO_ROUTE=editor|camera`（直挂 root）、`CQ_AUTO_PUSH_EDITOR=1`（自动 push 编辑页
  —— 真机无法脚本点按，靠它复现 push 转场）。
- **崩溃取证只有一条路**：devicectl 启动不落 .ips，lldb `device process attach` 取不到栈 →
  进程内 `DebugCrashDumper`（DEBUG，信号处理器打 `Thread.callStackSymbols` 到 stderr）；符号化
  `iOS DeviceSupport/<版本>/Symbols` + `atos -o <镜像> -l <基址> <地址>`（P132）。
- 本机 macOS **无 `timeout`**：用 `nohup ... &` + `sleep N` 控时长。

## 功能路线与轨道区（详见 ADR-0040 / RESEARCH-010）
- B0 已提交 `2e8b55d`（ctest 52/52）但**问卷未回收 → 未标记完成，回收前不得叠加批次**；
  B1 ✅；B2 部分（AUDIO-004 已提交，PALA-030 未做）。B5.5 空间与交互地基在 B4 后、B6/B7 前，
  B3 持久化排其后；B6/B7 可并行，B8 串在 B7 后。
- 轨道区**唯一判定/命令真源 = `TrackInteraction.swift`**；展示层只翻译事件、消费 Intent。
- 配色走本包 `TimelinePalette`（不直接改 `SharedUI/Theme`）；**把手宽度复用
  `TimelineLayout.trimHandleWidth`**（所见 = 可按中）。
- 内核**无写 `CQTrackInfo.muted` 的 ABI** → 轨道头做 disabled 只读态，欠账池 [19]，禁止假开关。
- 对标 App视觉规格源自截图，但**模型不支持读图（P128），我并没实际看到** → 尺寸/配色一律标 [E]。

## 关键实现契约
- Timeline 变更只走 CommandHistory；提交后 `refreshFromKernel()`；拖拽结束只提交一条命令。
- 预览渲染只在 PreviewPump 线程；主线程 Request + Lock/blit/Unlock，持锁期间不 Request。
- 异步等待必须同时有超时和独立内存上界；回调先交付数据再登记完成。
- Camera：检测坐标左上原点归一化；Vision 翻转只在转换层一次；人像无算法即直通，不退化为全画面滤镜。
- 日志按 Level/Stage/Workflow；偏离正轨一律 Warn 且 Release 可见。

## 命名与结构（改动前先看）
- **`PAL` 已改名 `Platform`**（ADR-0035）：`engine/core/cq/platform/` + `engine/platform/`；
  历史卡号 `PALA-xxx`/`PALD-xxx` **有意保留**（改了断链）。动 platform 三条红线：
  ① `check_platform_headers.py` 的 `CONTRACT_DIR_NAMES` 白名单写死目录名 → 目录改不同步**静默漏扫**（P95）；
  ② ctest 名随 target 改，文档 `ctest -R <name>` 必须同步；③ 编译过 ≠ pod install 过。
- **全仓机械替换必须排除 append-only 文件**（P103）：`docs/reports/LEDGER-*.md`、
  `.workbuddy/memory/*.md`；替换后**专门复核 `→` 形式的行**（`A → A` 式破坏 grep 计数看不出来）。
- **壳工程已冻结入库**（ADR-0037，XcodeGen 退役）：app 内加删文件 = 纯文件系统操作；
  agent **禁止裸编 project.pbxproj**，结构化改动走 `tools/build/edit_project.rb`。

## 竞品：对标 App iOS 编辑 SDK
- 结论全在 `docs/research/RESEARCH-016-对标平台编辑SDK架构逆向与借鉴评估.md`（材料
  `/Users/zhuning/Documents/test/` 只有头文件）→ **动手前先看它，勿重复调研**。
- 关键可借鉴：`commit`（渲染同步点，高频、不入 undo 栈）与 `done`（事务边界）**是两层**，
  我们 `ChqCommandHistory::Execute` 三件事合一，「拖拽结束只提一条」目前靠纪律而非机制。
- **他们不如我们的地方**（勿被「大厂也这么干」说服）：预览与导出两条管线（我们红线 #9 更先进）、
  双数据模型、Meepo 与 其轨道 UI 组件库 100 个同名头文件并存（ADR-0014 同款坑）。

## 未决事项
- FFmpeg LGPL v2.1+ 处置**已定**（ADR-0036）：声明 + 源码可获得 + 可重链接归档，
  义务载体 `engine/NOTICE.md`；**SDK 本体 License 仍待定**。
- PERF-001 未建立正式性能基线；Intel Mac 无 ANE/ProRes 硬编，其数字不得作产品阈值。
- 2026-10-08 以前 baselines 中「本机实测」仍需逐条归属真实机器 A/B/C。
