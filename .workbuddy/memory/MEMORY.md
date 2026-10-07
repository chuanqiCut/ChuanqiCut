# ChuanqiCut 项目长期约定

> 精简整理 2026-10-07（第 2 次；前版 29KB 超注入上限被截断。规则全保留，只压叙事与已闭环的历史说明）

## 0. 用户协作偏好（传哲）
- **跑门禁与真机必须先询问**（2026-10-07 深夜拍板）：集成机全量门禁/合并快检/真机趟一律先问过再执行。ADR-0030 触发条件不变，但触发后要人点头；待验证项照旧登记 TODO-POOL。
- 称呼「传哲」。直给、少废话，不要「好的/很高兴为您」类填充语。
- 要求**批判性审视**：事实错误、未验证假设、矛盾点直接指出并给依据。他不介意我推翻自己上一轮结论，只要给理由（已发生两次）。
- 交付判定 = 门禁通过，**不接受「已完成」自述**：须报「执行了什么命令 / 通过失败 / 跳过什么 / 剩余风险」。门禁写具体数字（Debug 44/44、Release 44/44），不写"全绿"。
- 数字可追溯：估算标 `[E]`，推测标 `hypothesis`，**只有实测能做验收阈值**；引用 baselines 必须带机器环境。
- **计数类埋点必须绑定「真的出了效果」而非「代码走到了这一步」**（P60）：CIContext.render 非 throws 且不进 commandBuffer.error，黑屏也能让帧计数涨。UI 计数器加到「命令缓冲完成且无错」回调，配 `failureCount` 作伪绿探针。

## 1. 项目定性
- 跨平台视频编辑 SDK + 各端原生 App：`core/` C++20 内核（对外纯 C ABI），`pal/<platform>/` 适配，`apps/<platform>/` 原生 UI。
- **iOS / macOS P0** → Android P1（须给方案）→ HarmonyOS P2（本期只做 `pal/ohos/` 接口编译检查）。
- **双机并行三线**（PLAN-三线并行）：**本机 = 集成机**（唯一真构建机 + 唯一发号器）。其他设备性能差、无真机、门禁不可信（P78）。
- 真机参考 iPhone 17 Pro，等 iOS 跑通由传哲本人实测 → **日志与埋点必须先行做扎实**。
- 最低系统版本 **iOS 16 / macOS 15.4**（ADR-0010）。容器格式沿用 17 demuxer 子集。

## 2. 不可协商的基线
- 性能基线 = 高端满足、**中端可用**、**明确不适配低端机**（不为低端机写专用降级路径）。
- 但**能力缺失降级要做**（无硬解→软解、无 compute→fragment）—— 中端机也可能缺某项能力。
- Shader 双层：Portable（`shaders/src/`，禁平台扩展，经 SPIR-V）+ Platform-Native（`pal/<platform>/shaders/`，可用满平台特性，永远可选，**收益 < 20% 不合并**）。
- 「本期明确不支持」要写进头文件/文档，不要只在对话里说。

## 3. AI 协作机制（ADR-0029/0030/0031）
- 单一真源 `.ai/source/AGENTS.root.md` → `tools/ai/sync_context.py` 生成 AGENTS.md/CLAUDE.md/.cursorrules 等。**改规则改真源再跑脚本**，禁手改产物。
- 编码阶段：**一个任务一个新会话**，开场读真源 + 模块文档 + 任务单卡。
- **模块归属**（PLAN-三线并行 §1a，各 `.ai/modules/*.md` 头部有归属行）：A=编辑器/UI（ui-apple/ui-android/model/session/preview/project + AIEDIT）、B=相机（camera）、C=内核/媒体/渲染（media/render/gfx/audio/shader/export）、集成机=core/pal/pal-android/deps/热点。`pal-apple` 集成机归口、B/C 分子域。**一机同一时间只待一条线**。
- **模块册分册制（ADR-0030）**：调研/任务/进度/测试及门禁记录写 `.ai/modules/<模块>.md` 末尾「模块册」，由归属线更新；新 RESEARCH/SPEC/REVIEW 落 `docs/` 原位但须在模块册登记指针。
- **全局册单写者 = 集成机**：TASK-BACKLOG、两份 README、pitfalls、baselines、PLAN、ADR、workbuddy/MEMORY —— 开发机零直写，要改走池条目或提案；开发机过程记录写自己模块册 + 池条目，**不写共享当日日志**。
- **开发机 = 简化档（编码优先）**：不等门禁；自查 = 编译 + 相关单测（Swift 必须 `-typecheck`）；不跑全量门禁、不碰真机；收工把待验项 append 进 `docs/tasks/TODO-POOL-门禁真机待办池.md`，推送即收工。
- **集成机 = 阶段批（ADR-0030 修订日批）**：**合并快检必做**（core 编译 + SharedUI 测试窄检 + **双壳 App target 真编译**（P83 补入）+ 冲突/旧号扫描，**远端"已验证"按未验证处理**）；**全量门禁 + 真机一趟多单按阶段触发**（PLAN 阶段收尾 / 一批卡闭环 / 真机单攒齐 / 周度兜底）。池 append-only 归开发机，清扫/关闭/编号只归集成机（P82）。
- **热点文件豁免排除**：`cq_sdk.h`、CMakeLists、podspec、Podfile、project.yml、构建脚本、真源、CI 及任何 ABI/依赖变更**不受简化档豁免**，仍须先提案给集成机。
- **收工逐项勾清单**：`.ai/modules/` → ADR（改了既有惯例必新增）→ TASK 卡 → HANDOFF → pitfalls → baselines → 当日日志 → MEMORY.md。模糊的"要回写"等于没写（连漏两轮的教训）。HANDOFF 任务状态要**对着 commit 历史核**，不能照抄上一版。
- **发号水位（2026-10-07 深夜三轮后）**：ADR 下一号 **0032**（0025~0028 预占素材库多轨）；pitfalls 下一号 **P86**（已用 P83/P84/P85）；INFRA-013~020 全部 ✅。
- **命名与答疑（2026-10-07 深夜拍板）**：①SDK pod 改名 **ChuanqiCutEngine**（`s.module_name='ChuanqiCut'`，`import ChuanqiCut` 零改动，podspec 同名）；②Pods 导航器里的 docs/**.md = CocoaPods 自动文档探测（pod 根=仓库根，无害无开关，记 docs/COCOAPODS.md）；③core 头文件以 preserve_paths 进导航器（编译走 HEADER_SEARCH_PATHS，**头文件永不进 source_files**）；④周报 `docs/reports/WEEKLY-<年>-W<周>.md`，集成机每周出刊（与周度兜底同轮）。

### 3.1 壳工程与功能 Pod（ADR-0031）—— **全域完成**
- 主工程 = 壳（AppEntry/装配/路由/权限）；Pod = ChuanqiCut（SDK，不动）+ SharedUI（瘦身基座）+ Player/Import/Assets/Camera/Draft/Editor 七功能 Pod。**功能 Pod 横向零依赖**（交接走壳装配/基座注入点）。Camera 仅 iOS。
- 终态：SharedUI 仅 `Common/`（Theme 已 public + PlayerPreview/EditorEntry/MediaLibrary 三注入器）；测试守恒 140（Player 52 / Import 16 / Camera 36 / Editor 36 随域迁出）；Draft 骨架占位未接线；**INFRA-017 Assets 改挂 LIB 依赖**（素材逻辑与 EditorViewModel 不可分，随 LIB-001 建域）。
- **域迁移开工前必须做全符号跨域引用分析**（grep 未限定标识符）。
- **P85 三假绿**：①.metal 不进 source_files（内建 Metal 阶段会编）；②静态 Pod script_phase 产物进不了 App bundle，无 inputs/outputs 会被跳过（管线留壳工程）；③scheme 必须在 project.yml 显式声明（xcuserdata 被 regen 清 → 零 phase 假成功）。依赖 SharedUI 的 Pod 自带 CChuanqiCut `SWIFT_INCLUDE_PATHS`。**门禁 PASS 基线 = 12 步**（含 artifacts + apple-camera）。
- **编辑页 UIKit 重建（UIA-034~036，ADR-0024）**：Editor Pod 内 `UIKit/` 新域（全 `#if os(iOS)`）；CADisplayLink 直读 `vm.playhead` 驱动播放头独立层/时间码（SwiftUI 零参与、VM 零改动）；交互语义逐字对照旧版（ADR-0012）。macOS/横屏仍 SwiftUI。真机 <16ms 走查 = 池 [3]。

### 3.2 构建产物零入库（P84 硬规则）
①`.gitignore` 已通配 `apps/apple/packages/*/.build/` 与根 `/.build/`，新建可构建目录须确认覆盖；②`run_gate.sh` 有 **artifacts 步**（`.build/`、根 `build/`、`DerivedData`、`.xcuserstate`、`.DS_Store` 被跟踪 = 一票否决）；③**临时编译统一 `/build/`**：SPM 一律 `swift test --disable-sandbox --scratch-path "$ROOT/build/spm/<包名>"`；④`git add -A` 前必看 `git status` 甄别产物。`.gitignore` 目录规则必须 `/dir/` 锚定根（裸 `build/` 曾吞掉 `tools/build/`）。

## 4. 产物打包与链接
- **分发的静态库不开 LTO**（`build_core_apple.sh` 默认 `--lto=off`）：Release+LTO 产出 bitcode-only `.o`，`create-xcframework` 拒绝；Release `-O3` 保留。主构建仍开 LTO，开关 `CQ_ENABLE_LTO_RELEASE`；**不可**用 `-DCMAKE_INTERPROCEDURAL_OPTIMIZATION_RELEASE=OFF`（该变量 FORCE 写入，命令行 `-D` 静默失效）。
- **打包后必须做消费者侧链接冒烟**（`tools/build/smoke_link.cpp`）：能打包 ≠ 能链接。
- 静态库命名一律 `lib<Name>.a`（`-lNAME` 只匹配此名；`swift build` 只编译不链接 → 假绿，到 `swift test` 才炸）。
- Swift 绑定两条验收路径：`swift test`（SPM）+ `run_smoke.sh`（swiftc 直编，不依赖 binaryTarget）。
- **core 不调 PAL 工厂**；确需调时隔离独立 TU（`pal_frame_provider.cpp` / `cq_sdk_preview.cpp`）。回归：`cq_tests_c_abi` 只链 `cq_core` 必须保持通过。
- 抽象放哪层看实现必然落在哪：只能平台原生实现的放 PAL（如 `IBlitPass`），上层走逃生口 `PalDevice()/PalEncoder()`。
- 系统框架依赖清单单一真源 = `ChuanqiCut.podspec` 的 `ss.frameworks`；`Package.swift` linkerSettings 与 `run_smoke.sh` **三处同步**（P23）。

## 5. 跨层句柄
- 契约写了「reinterpret 为平台对象」的句柄，**必须有跨层测试真的 reinterpret 并消费它**（P20：GetColorTexture 曾假绿，Swift 首用即崩）。导出用（裸原生纹理）与 SetTexture 用（CqTexture* 包装）语义已写进 `pal/gfx.h`。
- 本机 Intel Mac + AMD GPU：`MTLTexture.getBytes` 读不到 GPU 写入内容 → 读回一律 blit→Shared Buffer→contents（P21）。

## 6. 模型与时间线
- 时间一律有理数 `RationalTime{value, timescale}`，禁浮点秒（timescale 见 ADR-0006/0009）。
- **Timeline 只能经 CommandHistory 变更**；Add/Insert 的 Redo 走 `RestoreTrack/RestoreClip` 恢复原 id（id 单调分配，回放不能重分配）。编辑类命令只存增量，结构类只允许持**单个实体**，禁止模型快照。
- **拖拽期间不提交命令**，松手提交**一条**；不引入 coalescing（污染 Undo 栈）。
- **提交后必须 `refreshFromKernel()`**：内核拒绝不触发 observer 回流 → 留「幽灵片段」。正确性优先于动画平滑。
- Undo/Redo 也是 session 线程操作（异步入队）。撤销栈能力走 `EditorModelState` 原子量，不得直读 CommandHistory；`cq_session_can_undo/redo` 返回 **0/1 数据**不是状态码（P26）。
- 裁剪只改 duration 不动 source_in；左边缘裁剪本期不做。
- 新 ABI 返回值语义单一：错误码 XOR 数据（P26）；条数一律 out 参数。
- 测试同步点 = **哨兵法**（P31，基准版本在提交前读）；`#filePath` 上溯链不得手写（P30，用 TestPaths.root / RepoPath.root）。
- `mv/rm` 源文件后立即 grep 文件名引用并重跑受影响脚本（P27）。

## 7. 依赖治理（ADR-0008）
- FFmpeg upstream = GitHub 官方镜像。**源码集成的 git 依赖一律 `pin="commit"` + 40 位 hash，禁 `pin="tag"`**；「定期拉最新」= 人工 bump + 完整 CI，CI 绝不跟随分支/HEAD。
- `version` 字段必须 `git ls-remote` 核对（曾 6 处编造版本号，E6）。
- LGPL：不用 GPL、保持 LGPL-2.1+。**LGPL ≠ 无义务**，静态链接需提供 relink 能力（当前产物未接入任何构建目标，义务未触发）。CORE-006 PAL Media 接口**不得依赖 FFmpeg 类型**。
- 授权档位（2026-09-25 拍板）：`LGPL-2.1-or-later`、`CONFIG_GPL=0`、`CONFIG_LGPLV3=0`、`profile=demux`。

## 8. 预览 / 解码 / 取帧
- **取帧渲染只在 `PreviewPump` 泵线程**（内核拥有）；主线程只 Request + Lock→blit→Unlock。挂泵后任何线程禁调 `cq_preview_render_frame` / `cq_preview_resize`（改尺寸走 `cq_preview_pump_request_resize`）。
- 消费端持锁期间不要 Request（P36 死锁），不要 `waitUntilCompleted`（堵泵）。UI blit 必须用内核共享队列 `cq_preview_shared_queue`（Metal 只保证同队列内顺序）。
- 请求合并合并的是"画面"不是"命令"（UIA-005 拒绝的是后者）。
- **修性能前先分段埋点**（没加 `cq_preview_last_timings` 会误判方向：实测取帧占 94%）。挪线程 ≠ 提帧率。
- 取帧循环一律「先 Feed 一包，再连续 PopFrame」（MEDIA-021/ADR-0017）：平台回调序 = 完成序不是显示序；区间归属依赖 duration 报准（首帧兜底用 dts 差）；异步 Flush = 先等在途落地再清（P41）；seek 目标被消费后重复同目标须重新 seek；测试请求网格用整数 ticks。

## 9. 内存与异步等待纪律（MEDIA-027 血泪）
- **任何「等某判据成立」的重排/同步循环，都必须配一条不依赖该判据的内存上界闸门**。反例（P75）：输出队列靠「显示序连续性」弹出，判据失效就只进不出 → 8.3MB/帧 × 数百帧 = footprint 3375MB → jetsam signal 9（「播放 5 秒后永久冻结」）。判据正确性不可能零缺陷，闸门不能省。
- **判据失败分支必须区分「还没来」与「永远不会来」**，后者放行阈值按**连续次数**给（B 帧重排余量），**不能取 1** —— 取 1 会跳 B 帧（实测 fast=128000/slow=116000，提前 3 帧，media_sequential_real 直接挂）。
- **回调内「登记完成」必须在「交付数据」之后**：反序让等待方的「完成」不蕴含数据可见，旧区间数据漏进新区间（与 MEDIA-021「Seek 后首弹弹出旧 GOP」同形）。
- **等异步回调一律禁止无上界阻塞**（VTWait 系）：PopFrame 与 **Flush** 都要管 —— Flush 每次 Seek 都走，漏它就是慢路径永久阻塞入口。
- **泵线程是纯 C++ `std::thread`，没有 autorelease pool**：PAL 侧被逐帧调用的函数（demux RebuildReader/ReadPacket、decode Feed）必须自带 `@autoreleasepool`（实测 +13.8MB/60s → 加池后 +0.5MB/60s）。
- **真机「卡死 + signal 9」必须能区分 jetsam 与解码追赶失败** → DEBUG 剖面行恒带 `footprint`（`task_vm_info.phys_footprint`）与 `nonok/s`。
- 真机剖面用 `devicectl device process launch --console` + **stderr**（stdout 全缓冲）；设备锁定会报 `FBSOpenApplicationErrorDomain error 7`，测前先确认解锁。

## 10. 排障纪律
- **flaky 消除的判定 = 根因机制闭环 + 失败签名可解释**，不是连绿次数（P33：同一签名背后有第二根因）。
- **并发 bug 的验收一定是 A/B 单变量对照**（P77）：只差那一行修复编两个二进制，制造负载（12 核各挂 2 个 `yes`）交错轮流跑，报「未修复 x/N 崩 vs 修复 y/N」+ 巧合概率。真机/门禁偶发 SIGSEGV 先看 `~/Library/Logs/DiagnosticReports/*.ips`：堆栈有 `std::map/std::deque` 树平衡/迭代器帧 = **并发写坏容器**，不是内存踩踏。
- **跨线程共享容器：顺序对了 ≠ 互斥对了。** 注释出现「回调 / 另一线程 / 异步」就问「那把锁是谁」。加字段/加访问点前先 grep 该字段**全部**访问点并逐个指认守卫互斥量；不变量写在**头文件成员旁**（P77）。
- 异步命令「等待落地」等**目标效果本身**（如 queryTracks 出现视频轨，10ms 轮询），不要等版本号越过基线。
- 框架回调「被触发」≠「成功」；对平台回调 `DISPATCH_TIME_FOREVER` 无限等是挂死隐患，一律有限超时 + 诚实错误码。
- **引用「实测无 error」必须注明校验层开关状态**（P65/P61）：Metal API Validation（DEBUG scheme 默认开、GPU 抓帧强制开）**开与关改变运行时合法性**，关键结论必须在**校验层开启**下复测过才成立。
- 手法：给可疑分支加「分支名 + 内核状态码 + 计时」临时诊断，全量复跑抓现行。

## 11. 相机模块（B 期，ADR-0014）
- 检测观测 = 图像归一化坐标、origin 左上、0...1；Vision 左下翻转**只在转换层做一次**。
- 采集/渲染/检测三队列互不阻塞，检测 latest-wins，平滑状态只在检测队列持有。
- iOS 17+ 才有的 Vision 类型，引用要收进 `@available` 分支或用基类持有。
- **特效 = App 层资产**（`iOSApp/Camera/Effects/`），SharedUI 只持契约层 + 默认 CI 兜底；原生引擎经 `CameraBeautyEngine.smoothing` 注入，**加载失败必须回落默认，引擎永不制造黑帧**。
- CIKernel：编译链接**都要** `-fcikernel` 且都用 `metal`（`xcrun metallib` 产出 96 字节空壳，全绿但查不到 kernel）；验收 = `strings` 查 kernel 名 + 看大小（正常 ~8.4KB）。
- **drawable 走渲染 pass，不走 blit**（CAM-016 终态）：Metal 禁止对 framebufferOnly 纹理 blit（校验层下 SIGABRT）；终态 = 中间纹理 → 显式 UV 渲染 pass（colorAttachment 是 framebufferOnly 唯一合法写法）→ drawable 保持 `framebufferOnly = true`。v 轴符号 = CI 行序补偿（`ciWritesBottomUp`，真机一验定案）。
- **三套方向枚举 landscape 命名互换**（P67）：`UIInterfaceOrientationLandscapeLeft`（home 在右）≡ `AVCaptureVideoOrientation.landscapeRight` —— 同名直映必错；映射只准落在 `CameraManager.rotationAngle/videoOrientation` 一处，改前 grep SDK 头文件注释。
- **相机页 UI 栈（2026-10-05 拍板）**：SwiftUI + UIViewRepresentable(MTKView) 混合，**不引 SnapKit/RxSwift**（SnapKit 只有 Auto Layout 语义、RxSwift 与 SwiftUI 状态模型重复）；引任何 UI 三方必须走 manifest.toml + cq-dependency-governance。双摄（CAM-021）开关必须独立于前后翻转按钮。

### 11.1 CI 色彩域与蒙版契约（CAM-018/019）
- **CIContext 一律显式 `workingColorSpace`（gamma sRGB）**，禁依赖默认线性域（P80）：凡 harness 定标的 CI 参数，真机运行域必须与定标域一致；新增 CI 消费方先核域再调参。
- **美颜区域化三态契约**：`apply(to:faces:)` —— nil=全画面兜底、[]=**直通**（与美型"无脸直通"同口径）、非空=归一化框（左上）→ FaceMask 蒙版。引擎注入签名 `(CIImage, Double) -> CIImage?` 不加 mask，蒙版在 apply 内用 `CIBlendWithMask` 施加。
- **CIImage DAG 宿主脚本先行**（P81）：自定义几何/渐变/合成先跑宿主实渲染采样再落正式测试。已实锤三坑：`CIRadialGradient` extent 有限、`cropped` 只做交集、`CGPoint+CGVector` 不存在。

## 12. 日志：三维模型与 workflow 筛选（CORE-010）
- 三维彼此正交：**Level**（trace…error）/ **Stage**（帧走到哪步，只用于带 pts 的帧级 trace）/ **Workflow**（我在排查哪条链路：core/model/import/demux/decode/framecache/preview/render/export/camera/gfx/perf/mem/ai）。
- 输出前缀 `[wf:xxx]`，`grep '\[wf:decode\]'` 即筛。真机切换靠环境变量（Scheme → Run → Arguments，`CQ_LOG_LEVEL` / `CQ_LOG_WORKFLOW` 白名单 / `CQ_LOG_WF_LEVEL`），**不改代码不重编译**。App 侧在 `EditorViewModel.init()` 最早处调 `ChuanqiCut.configureLogFromEnvironment()`。
- **分级原则**：问它报的是「系统正在偏离正轨」还是「我想看细节」。前者（降级发生、队列/追帧上界命中、慢调用、看门狗）一律 **Warn 且 Release 可见**；后者才 Debug/Trace。
- 硬规则：日志一律走 `CQ_LOG_*_WF(wf, ...)`，禁裸 `fprintf`；慢调用统一 `CQ_SLOW_CALL_WF`（`core/base/perf.h`，阈值 500ms），**不许在 .cpp/.mm 里自抄 RAII**（旧版 4 文件各抄一份、阈值还不一致）；**Debug-only 的诊断在 Release 包里等于不存在**（P76），Release 才是真机常态；**改了依赖 NDEBUG 的代码必须 Debug + Release 双向编译验证**（解开一处 NDEBUG 后它依赖的成员往往还在块里，Debug 绿、Release 炸，踩过 3 次）。

## 13. 构建验证纪律（iOS 侧）
- **iOS App 编译验证必须 `-scheme ChuanqiCutApp`**：workspace 里 `ChuanqiCut` 是 Pods 生成的静态库 target，编不到 `iOSApp/` 却能 BUILD SUCCEEDED + 0 警告假绿（P61）。日志里 `Target dependency graph (1 target)` 就是线索。
- **不确定某 Swift 文件是否被真编译 → 先塞必然报错的 canary（`1 + "x"`）跑一次，确认真炸再拿掉。**
- **`swiftc -parse` 绿不是绿**（P46/P48/P49 第四犯，P78）：`-parse` 只验语法不验类型。Swift 轻量验证唯一合格形态 = **iphonesimulator SDK 全量 `-typecheck` 且带 `-swift-version 6`**。任务卡 `verification` 里出现 `-parse` 条目应直接驳回 —— 已有人靠它把 38 处类型错误和一个从未提交的类型推上主干。
- **外部/其他会话的产物进主干前必须在合并侧跑完整门禁**，不能因对方自称验证过就放行。归属不清时：`git diff --cached origin/main -- <dir>` 证明「我这边没动它」+ `git log --all -S <缺失符号>` 定位「提到它但没实现它」的提交。

## 14. Apple 端工程与门禁（ADR-0021 / CODE-001）
- "cannot find X in scope" 先查工程引用：xcodeproj 是 xcodegen 生成产物、不入库、易陈旧。核对：`git ls-files` vs `find` vs grep `project.pbxproj`。
- 改工程顺序：**`project.yml` → `xcodegen generate` → `bundle exec pod install`（顺序不能反）**。xcodegen 2.46 三坑：不写 `PRODUCT_NAME`（多命令冲突）、`excludes` 必须 glob、Metal flag 塞不进去。
- **门禁 = `tools/ci/run_gate.sh`**（deps + PAL 头纯净 + Debug/Release 全量单测 + XCFramework + Swift 绑定 + SharedUI + golden，一票否决）。
- 风格唯一标准 `docs/CODESTYLE.md`，巡检落 `docs/reviews/`；文档里的命令路径必须真实存在（P58）；脚本 `$var` 写 `${var}`（bash 3.2，P50）。
- 多人/多会话共用机器加 `-derivedDataPath` 隔离（否则 `database is locked`）。
- **合并/同步后必查冲突标记残留**（P59）：全仓 grep `<<<<<<<` / `=======` / `>>>>>>>`。注意 `tests/golden/*.py` 有 45 字符 `=====` 注释分隔线，不是冲突标记。
- **push 被拒第一反应**：`(fetch first)` ≠ 权限问题。先 `git fetch` + `git rev-list --left-right --count origin/main...main` 看真值 —— 本会话若未 fetch 过，本地 `origin/*` 是过期快照（2026-10-07 深夜踩过）。确认实际分歧后用 `git pull --rebase`（先看两边改集是否相交），再 `--dry-run` 验证后才真推。

## 15. 播放器域边界（UIA-015 / ADR-0022）
- **AVFoundation/AVKit 只许出现在 `SharedUI/Sources/SharedUI/Player/` 五个文件**（PlayerEngine / AVPlayerEngine / PlayerSurfaceView / VideoThumbnailLoader / PlayerPipCoordinator）；控制层、PlayerViewModel、App target 一律不 import。跨文件传 `AVPlayer`/`AVPlayerLayer` 用「不点名的不透明值」。控制层只依赖 `PlayerEngine` 协议 —— 换 C++ 播放 session 时不改 UI。
- **SharedUI 新代码按 Swift 5.5 可解析风格写**（显式 `guard let x = x`、不用 `any P`）—— 本机 swiftc 5.5 是唯一静态验证手段。
- ~~P78 Player 域不可编译~~ **已解决 2026-10-07**：全量修复编译 38 处 + 行为 5 处 + 补写从未入库的 `PlayerZoomMath`；SharedUI 128 用例全绿、iOS App BUILD SUCCEEDED 且 0 告警。

## 16. 智能成片（ADR-0020）
- **原始素材默认不出设备**：上云只有 FeatureReport（聚合统计），人脸只报 count/area_ratio；可选帧上传须显式授权。
- LLM 输出 = EditPlan（`cq.editplan/1`，≤8 动词），非时间线；时间一律 `{value,timescale}`（120000），浮点秒非法；未知 schema 拒绝降级不发猜。C++ 校验器唯一权威。
- AI 产物全走 Command（同一撤销栈，一次应用 = 一个可撤销批次），禁止直改 ModelSnapshot。
- 离线降级是产品能力（本地规则引擎出同 schema，UI 明示）。语音走系统 STT，音频不上传；上线前过法务。

## 17. 构建环境
| 机器 | 系统 / 工具链 |
|---|---|
| A（早期全部"本机实测"） | macOS 15.4 / AppleClang 17（Intel i7 + AMD GPU，**无 ANE、无 ProRes 硬编**） |
| B | macOS 13.7 / Xcode 15.2（Swift 5.9.2）。`swift-tools-version:6.1` 解析不了 → swift-bindings 门禁 FAIL 属**环境上限非回归** |
| C（当前） | macOS 26.7.1 / Xcode 26.6（iPhoneSimulator 26.5 SDK） |

- B 机：`pip3 install --user cmake` 后 `export CMAKE_BIN=$(ls ~/Library/Python/*/bin/cmake | head -1)`。
- 跨工具链兼容：用 `::va_list` + `<cstdarg>`；不对 volatile 复合赋值/自增。Apple 端没有 brew：xcodegen 取 GitHub Release 二进制放 `/usr/local/bin`。

## 18. 编号纪律（ADR-0019 §4）
- **任务 ID / ADR / pitfalls P 号取号前先 `git fetch` 核对远端已用号**（双机曾撞 UIA-011、ADR-0013/0014、P36-P39、UIA-015/016、CAM-015/016）。处理原则：**改动面小的一侧让位**。
- 引用清扫按**主题上下文**精确替换，禁止全局 sed。三线并行起：**集成机是唯一发号器**，每线一次领 5 个号，登记即占号。
- 已裁定撞号：UIA-015/016（编辑器线让位 → UIA-032/033，BACKLOG §12 的 UIA-021~024 → 034~037，ADR-0022 → 0024，RESEARCH-006 → 008）；CAM-015/016（本机美颜线让位 → **CAM-018/019**，P62/P63 → **P80/P81**）。

## 19. 悬而未决（需传哲拍板，AI 不得代决）
1. **FFmpeg LGPL v2.1+ 链接处置**（目标文件归档 / 商业授权 / 动态链接 / 不接入改平台原生）—— 需法务，**已确认延后不阻塞**。
2. 性能基线未建立（PERF-001 未做），文档性能数字仍是估算；本机 Intel Mac 无 ANE、无 ProRes 硬编，**不得采样本机数字**。
3. 上述两项 + `tools/perf/` 处置待办，交另一 agent：[`docs/tasks/TODO-2026-10-07-播放器域收尾待他人接手.md`](../../docs/tasks/TODO-2026-10-07-播放器域收尾待他人接手.md)（已在 `docs/tasks/README.md` 登记）。
