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
- **（2026-10-15 传哲定）commit message 只写 `TASK-ID: 一句话`**，不写长篇作文。
  详细内容放任务卡 `docs/tasks/TASK-<ID>.md` 与台账，不塞进 commit message。

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
- 最近全量门禁（2026-10-16 晚，INFRA-034）：`run_gate.sh` **17 步 PASS=17 / FAIL=0 / SKIP=0**
  （墙钟 **10m57s 暖缓存** / 18m58s 冷缓存），core Debug+Release 各 **52/52**，包段合计 **252**。
  ⚠️ 那一次**不含 App 壳构建**（池 [18] 当时未收）。2026-10-17 起池 [18] 已收：新增第 6 步
  `apple-shells`（两端真编，冷 280s / 暖 39s），静态清点是 **18 步**——**这个数字还没被一次全量跑证实**，
  跑完以摘要 `PASS=` 为准。且 17/17 的绿成立在暖缓存上（见下条 P160 铁律）。
- CI core 段**干净复现**（2026-10-17 早，`rm -rf build` 四遍）：toolchain/build/ctest 全 rc=0、
  **51/51**，四遍都打印排除名单 `Test #45: platform_apple_decode`；干净单遍 **6m48s~11min**。
  ⚠️ 本机 **ctest 墙钟不可当指标**（四遍 186.74 / 172.84 / 271.32 / 83.52s，同是 51/51 全过）。
- 编号取号前必须 `git fetch` 核远端（并发时现取现核）。2026-10-17 水位：ADR 到 **0045**（本机已推，
  `origin/main` = 已同步），pitfalls 下一号 **P166**，池下一号 **[24]**（[18]/[22] 已关闭、[23] 定调按案处理），
  HANDOFF 下一份 **026**，BACKLOG §15 为布局整改批（036/037 为其收尾两张）。
- **INFRA-026~035 已提交到本地 main（2026-10-17 10:3x，未 push，`origin/main` 仍在 `5cfcdcb`）**：
  三段 = `294d518` 搬家 / `a7a20b8` 治理 / `b08f78a` 活文档，第四段是 P163 修复。
  tracked **856 → 878**（收工口径取**提交后**复测的那一列）。
- 收工同步顺序：模块册 → ADR → TASK → HANDOFF → pitfalls → baselines → 当日日志 → 本文件。

## 构建期依赖铁律（P160/P162 → **ADR-0045**，2026-10-17 立）

- **任何构建期依赖必须有一个入库脚本能从零产出它**。"本机能编"不是证据，
  本机那台机器可能带着从没登记在仓库里的历史产物（案底：SHADER-001 要的
  glslang + spirv-cross 两个二进制只活在 `build/tools/`，仓库里从来没有产出它们的脚本，
  于是清 `build/` / 新克隆 / CI runner 一律编不出内核，症状是停在 27% 然后 **50/51 用例
  "找不到可执行文件"** —— 看着像测试崩，实际全是那一个 error 的下游）。
- **判据必须至少在"空产物根"上定期跑**：`tools/ci/run_gate.sh` 是暖缓存口径，
  复刻 CI 时用真破坏性动作（`rm -rf build`），**增量复现只会复述已知的绿**。
- 新增的装配脚本自身也要在**空树**上验：本批就是这么顺手抓到脚本自己的第二个坑
  （日志重定向目标 `build/tools/` 在新克隆机上不存在，真实失败被 shell 错误盖掉）。
- 出问题的构建期工具一律走 `tools/build/build_shader_toolchain.sh`（pin 从 `manifest.toml` 读，
  脚本内不写死 commit）；CI 里该步必须在 `build_core.sh` **之前**（`--clean` 会连它一起清掉）。
- **两侧各自拼的路径必须逐字一致**（P160 规则 5）：装配脚本写 `build/tools/SPIRV-Cross/`、
  消费方默认找 `build/tools/spirv-cross/`，本机靠 APFS 不区分大小写"碰巧能用"，
  换 Linux runner 就是"工具链装好了但找不到"。大小写判据只在敏感卷上才成立。
- **只读/dry-run 模式不许有任何删除，且要在函数入口短路**（P162）；grep CMake cache 键时
  类型段写成可选 `^KEY(:[A-Z]+)?=` —— 裸 `-D` 落的是 `:UNINITIALIZED=`，写死 `:STRING=`
  等于一条**恒不命中**的判据（幂等守卫因此每遍误删重编）。

## 判据自证铁律（P163，2026-10-17 立）

- **新判据必须在"自己已被 `git add` 之后"再跑一遍**：扫描集取自 `git ls-files` 的判据，
  在脚本自身仍是 `??` 时**测不到自己**（案底：`check_repo_hygiene.sh` 的旧路径判据提交后
  立刻命中自己的正则定义行 4/4 → 3/4 FAIL）。未跟踪态的绿只算**半个证据**。
- 显式决定"判据脚本自己参不参与"：不参与就写 `SELF` 排除并注释原因；参与就把会被自己命中的
  字面量拆成不可匹配的写法。**两种都不是默认**，但要写下来。
- **提交动作本身会改变判据输入**，所以收尾必须"提交后再复跑一次"，不能拿提交前的复跑当终态。

## 构建 scratch 落点铁律（P164，2026-10-17 立；传哲当场指出「怎么又在代码文件夹里搞 build」）

- **交给外部工具当输出根的参数一律 `"${ROOT_DIR}/…"` 绝对**。凡是"`cd` 进子目录再把相对路径交给
  xcodebuild/SPM/CMake"的写法，**默认按 bug 处理**：`-derivedDataPath ../../build/…` 在
  `cd apps/apple/ios` 之后落的是 `apps/build/`（实测留下 **1.5G**）。同一个坑第三次
  （`apps/` 曾 5.5G → SPM `--scratch-path` 钉回 `build/spm/` → 这次 derivedData）。
- **注释拦不住下一次，要机械防**：落点前缀断言 + 跑完自查 + `check_repo_hygiene.sh` 判据 5
  `scratch-dirs`。**不要给 `apps/build/` 加 .gitignore**：忽略 = 从 `git status` 消失，而"能被看见"
  正是这条判据的原料（宁红不隐）。
- **反证探针必须用未被忽略的文件名**：判据 5 扫 `git status --porcelain -z` 的 `??`，用 `x.o`
  做探针会得到**假绿**（`*.o` 已忽略），要用 `x.txt`。恒不命中的反证比没有反证更危险（P162）。

## 长表格行的编辑纪律（P165，2026-10-17 立）

- 本仓 `TASK-BACKLOG.md` / 模块册**一行 1~2KB**（实测数字全在行内）。Edit 是精确子串替换、**不是按行**：
  锚点只取"行首"→ 只删掉行首，剩下的行尾嫁接到替换文本后面，整行看起来还在、其实错位
  （案底：INFRA-035 行被吃掉、结果串跑到 INFRA-037 行尾）。
- 锚点**要么覆盖整行到行尾 `|`，要么落在行与行的边界**；落账后回读一次行号表（`grep -n "^| INFRA-0"`），
  复原一律与 `git show HEAD:<file>` 同法产物 `cmp` 逐字节比，不靠"看着像"。

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
- **带 `--console` 的 launch 由我的 shell 持有**：shell 结束时 App 收到 **signal 1 (SIGHUP)**
  （`App terminated due to signal 1`）= **不是崩溃**（CrashDumper 不打栈）。要让 App 留在设备
  前台给传哲看，必须 launch **不带 `--console`**。
- devicectl **无截图子命令**（只有 copy/info/install/notification/orientation/process/reboot/
  sysdiagnose/uninstall）→ UI 外观只能由传哲在设备上看，务必发问卷。
- 推素材到真机：`devicectl device copy to --device <UDID> --source <本地文件>
  --domain-type appDataContainer --domain-identifier com.chuanqi.cut --destination /Documents/<名>`，
  再 `CQ_DEMO_VIDEO=<名>` + `CQ_DEMO_SECONDS=<秒>` + `CQ_AUTO_ROUTE=editor` 启动（DEBUG 冒烟装载）。

## 功能路线与轨道区（详见 ADR-0040 / RESEARCH-010）
- B0 已提交 `2e8b55d`（ctest 52/52）但**问卷未回收 → 未标记完成，回收前不得叠加批次**；
  B1 ✅；B2 部分（AUDIO-004 已提交，PALA-030 未做）。B5.5 空间与交互地基在 B4 后、B6/B7 前，
  B3 持久化排其后；B6/B7 可并行，B8 串在 B7 后。
- 轨道区**唯一判定/命令真源 = `TrackInteraction.swift`**；展示层只翻译事件、消费 Intent。
- 配色走本包 `TimelinePalette`（不直接改 `SharedUI/Theme`）；**把手宽度复用
  `TimelineLayout.trimHandleWidth`**（所见 = 可按中）。
- 内核**无写 `CQTrackInfo.muted` 的 ABI** → 轨道头做 disabled 只读态，欠账池 [19]，禁止假开关。
- 对标 App 视觉规格源自截图，但**模型不支持读图（P128），我并没实际看到** → 尺寸/配色一律标 [E]。

## scrub 快速 seek（P142 / ADR-0043，2026-10-16，提交 c5d4bf5 未 push）
- 拖轨道 scrub 每 delta 曾走 `kExact` → **每次从最近关键帧重解整个 GOP**，占满泵线程单核与滚动主线程抢核
  → 卡顿（逆向更贵）。core `ChqSystemFrameProvider` 早已实现 `kKeyframeBefore/kNearest`，被「Platform 接缝不携带
  policy」挡死。
- 修法（传哲定口径）：滑动中 `kKeyframeBefore` + **限频 24Hz**；seek 在泵子线程；有新帧按 seq 收敛再刷；
  **松手补一次 `kExact` 精确帧**。`onScrubEnded` 是 `EditorTimelineKitView` 新增出口。
- **跨层契约**：`ChqSeekPolicy` 用中立 `int32_t`(0/1/2) 穿 Platform 接缝（`chq_frame_provider.h` 已 include
  `chq_media.h`，反向 include **成环** = P142），只在 core 层转回；`RenderFrame` 新参放**末位**保既有 3 参调用。
  C ABI 新增 `cq_preview_pump_request_ex`（原函数保留=传 0）；Swift `PreviewPump.SeekPolicy`。
  导出/播放/单帧/golden 一律仍走 kExact。新接平台不支持非精确策略须**显式拒绝**，不得静默当精确。
- 验证：iOS 壳 BUILD SUCCEEDED；`ctest -R "preview_pump|preview_renderer|system_frame_provider|c_abi_preview|sequential"`
  **6/6 PASS**（含真素材 `media_sequential_real` 69s）；新增预览泵第 9 组「策略透传」断言。**真机问卷未回收**。
- **写集隔离**：内核+绑定+测试+ADR+HANDOFF 已提交 `c5d4bf5`（复核零 WIP 混杂）；**UI 层改动与 TimelineKit WIP
  同文件交织，留在工作树未提交**，且 `onScrubEnded` 依赖未跟踪的 `EditorTimelineKitView.swift` →
  完整 P142 功能要等 TimelineKit WIP 落地才生效（HANDOFF-024 有详述）。

## 轨道区 = TimelineKit（ADR-0042，2026-10-15 起；早期自绘轨道区已删除）
- 本地 Pod 源：`/Users/zhuning/Documents/ChatGPT/zui`（**只读，不改动组件**；UIKit-only）。
  真入口 = iPhone 竖屏 `EditorViewController`；macOS/iPad 横屏仍是 SwiftUI 旧实现（组件物理不可用）。
- **内核唯一真源**：`TimelineStore` 只是渲染外衣 —— 灌入 = 内核快照重建 store+view；
  回写 = store `.projectChanged` 唯一入口 → `TrackIntent` → `TrackIntentApplier`。
  **不存在 Kit→内核 持久化**；翻译不了的命令（轨道排序/静音/锁定/轨内重排/转场/关键帧）一律回滚重灌。
- `TimelineStore` **没有**整体替换 project 的入口、也没有新增媒体资产的命令 → 只能按快照重建；
  zoom 必须自己带走（`.zoomChanged` 记录，重建时回填）。提交后一律 `force` 重灌（内核可能拒绝）。
- ID 编码 `cq-t-<id>` / `cq-c-<id>` / `cq-m-<id>`：**唯一**编码方式，反解前缀不符即 nil。
  `RationalTime ⇄ TimelineTime` 直搬 (value, timescale)，**不经过浮点秒**。
- podspec 已拆 `Core`（默认，两端）/ `TimelineKitTrack`（iOS 专属）子 spec：
  **新增 iOS-only 文件必须同时改 `Core.exclude_files` 与 `TimelineKitTrack.source_files`**（P134）。

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
- 结论全在 `docs/research/RESEARCH-016（对标产品编辑 SDK 架构调研；原件存于仓库外材料目录，不入库）`（材料
  `/Users/zhuning/Documents/test/` 只有头文件）→ **动手前先看它，勿重复调研**。
- 关键可借鉴：`commit`（渲染同步点，高频、不入 undo 栈）与 `done`（事务边界）**是两层**，
  我们 `ChqCommandHistory::Execute` 三件事合一，「拖拽结束只提一条」目前靠纪律而非机制。
- **他们不如我们的地方**（勿被「大厂也这么干」说服）：预览与导出两条管线（我们红线 #9 更先进）、
  双数据模型、其早期一代组件 与 其轨道 UI 组件库 100 个同名头文件并存（ADR-0014 同款坑）。

## 未决事项
- FFmpeg LGPL v2.1+ 处置**已定**（ADR-0036）：声明 + 源码可获得 + 可重链接归档，
  义务载体 `engine/NOTICE.md`；**SDK 本体 License 仍待定**。
- PERF-001 未建立正式性能基线；Intel Mac 无 ANE/ProRes 硬编，其数字不得作产品阈值。
- 2026-10-08 以前 baselines 中「本机实测」仍需逐条归属真实机器 A/B/C。
