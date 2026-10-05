# ChuanqiCut 项目长期约定

## 用户与协作偏好（传哲）
- 称呼：传哲。直接、少废话，不要「好的/很高兴为您」这类填充语。
- 要求**批判性审视**：不要附和他的方案，发现事实错误、未验证假设、矛盾点要直接指出并给出依据。
- 交付判定 = 门禁通过，**不接受「已完成」的自述**。必须给出执行了什么命令、通过/失败、剩余风险。
- 数字必须可追溯：估算标 `[E]`，推测标 `hypothesis`，实测才能作为验收阈值。
- 他不介意我推翻自己上一轮的结论——只要给出理由。已发生过两次（Shader 单层→双层、低端机降级→明确不支持）。

## 项目定性
- 跨平台视频编辑 SDK + 各端原生 App。`core/`=C++20 内核，`pal/`=平台适配，`apps/`=原生 UI。
- **iOS / macOS 是重点支持平台**（P0）→ Android(P1，必须给方案) → HarmonyOS(P2，仅预留)。
- 鸿蒙本期**不动**，只做 `pal/ohos/` 接口编译检查。

## 不可协商的基线
- 性能基线 = 高端满足、**中端可用**、**明确不适配低端机**（不为低端机写专用降级路径）。
- 保留的是「能力缺失降级」（无硬解→软解、无 compute→fragment），因为中端机也可能缺某项能力。
- Shader 双层：Portable（`shaders/src/`，禁平台扩展）+ Platform-Native（`pal/<platform>/shaders/`，可用满平台特性，但永远可选、收益 < 20% 不合并）。

## AI 协作机制
- 单一真源 `.ai/source/AGENTS.root.md` → `tools/ai/sync_context.py` 生成 AGENTS.md / CLAUDE.md / .cursorrules / .windsurfrules / copilot-instructions.md。**改规则改真源，再跑脚本**，禁止手改生成物。
- 编码阶段：**一个任务一个新会话**，会话开场读真源 + 模块文档 + 任务单卡。见 `docs/ai/HANDOFF-001`。
- 任务结束必须回写 `.ai/modules/`、`.ai/memory/pitfalls.md`、`.ai/memory/baselines.md`。

## 产物打包约定（2026-09-29 定）
- **分发的静态库一律不开 LTO**（`tools/build/build_core_apple.sh` 默认 `--lto=off`）。
  Release + LTO 产出 bitcode-only `.o`，`xcodebuild -create-xcframework` 直接拒绝；
  且带 LTO bitcode 的分发库会强制消费者 linker 版本匹配。Release 的 `-O3` 保留。
- 主构建（日常开发 / CI / 单测）**仍开 LTO**，项目开关是 `CQ_ENABLE_LTO_RELEASE`。
  不能直接 `-DCMAKE_INTERPROCEDURAL_OPTIMIZATION_RELEASE=OFF` —— 那个变量是
  `set(... CACHE BOOL ... FORCE)` 写的，`FORCE` 会让命令行 `-D` **静默失效**。
- **打包后必须做消费者侧链接冒烟**（`tools/build/smoke_link.cpp`）。
  理由：`xcodebuild` 成功只说明是合法 Mach-O，"能被 App 链接并运行"是另一件事。
- `.gitignore` 的目录规则必须写成 `/dir/` 锚定根。裸 `build/` 曾把 `tools/build/`
  一并忽略，导致三个构建脚本建库以来从未入库，且 `git status` 完全看不出来。

- **交付给外部工具链的静态库一律命名 `lib<Name>.a`**（2026-09-30 定）。
  曾用名 `ChuanqiCut.a` 导致所有 `-lNAME` 失效（`-lNAME` 只匹配 `libNAME.a`），
  表现为 `ld: library 'ChuanqiCut' not found`，且 `swift build` 因只编译不链接而全绿，
  直到 `swift test` 链接可执行宿主才炸。
- Swift 绑定验收有两条路径：`swift test`（SPM 集成）与 `run_smoke.sh`（swiftc 直编）。
  后者不依赖 binaryTarget，SPM 出问题时仍能证明"Swift 能调内核"。

## 分层与链接硬规则（2026-10-02 定）

- **core 不调 PAL 工厂**（既有惯例，全库 grep 可核：调用只发生在 tests/ 与 pal/）。
  理由：cq_core 若引用 PAL 符号，没有 PAL 后端的平台（Android / ohos）会链接失败。
- **确需调时，必须隔离在独立 TU**。静态库按 archive member 粒度拉符号，
  独立 TU 才能保证「不用该能力的目标」不被牵出 PAL 依赖。
  现有两个：`core/src/media/pal_frame_provider.cpp`、`core/src/preview/cq_sdk_preview.cpp`。
  回归验证：`cq_tests_c_abi` 只链 `cq_core`、不链 `cq_pal_apple`，必须保持通过。
- **抽象放哪层，看实现必然落在哪**。只能用平台原生能力实现的（shader 源码 /
  平台 SDK），抽象放 PAL（如 `IBlitPass` 在 `pal/gfx.h`）；放上层会导致 PAL
  反向依赖上层。上层要用时走逃生口（`IGfxDevice::PalDevice()` /
  `IGfxEncoder::PalEncoder()`）。

## 跨层句柄与链接硬规则（2026-10-03 定，UIA-003）

- **凡契约里写了「reinterpret 为平台对象」的句柄，必须有跨层测试真的
  reinterpret 并消费它**（pitfalls P20）。`GetColorTexture` 曾返回 CqTexture*
  包装却承诺可 reinterpret 为 id<MTLTexture>，绑定测试只查非空是绿的，
  Swift 首用即崩。导出用（裸原生纹理）与 SetTexture 用（CqTexture* 包装）
  两种句柄语义已在 `pal/gfx.h` 写清，不得混用。
- **内核静态库的系统框架依赖清单单一真源 = `ChuanqiCut.podspec` 的
  ss.frameworks**；`bindings/swift/Package.swift` linkerSettings 与
  `run_smoke.sh` 链接清单必须与之同步（pitfalls P23）。静态库新拉入 TU
  （如预览/媒体）会引入新的系统框架依赖，三处清单一起改。
- 本机（Intel Mac + AMD GPU / macOS 15.4）`MTLTexture.getBytes` 读不到 GPU
  写入内容：读回一律 blit→Shared Buffer→contents（pitfalls P21）。

## 模型变更硬规则（2026-10-03 定，MODEL-002）

- **Timeline 只能经 CommandHistory 变更**（红线 #5 的执行点）。绕过直改会让
  历史里的 id 引用悬空，Undo/Redo 静默失效。
- **Add/Insert 类命令的 Redo 必须走 `RestoreTrack/RestoreClip` 恢复原 id**；
  重放 Add/Insert 会分配新 id（pitfalls 同类：「id 是单调查分配的，回放不能重分配」）。
- 编辑类命令只存增量（id + old/new），结构类命令只允许持有**单个实体**内容；
  模型级快照一律禁止。

- **新 ABI 的返回值语义必须单一**：错误码 XOR 数据，绝不混用（P26）。
  条数类结果一律走 out 参数；新函数统一「状态码 + out_count」。
- **mv/rm 源文件后立即 grep 文件名引用并重跑受影响脚本**（P27，E10 同族）。

## 时间线交互硬规则（2026-10-03 定，UIA-005 / ADR-0012）

- **拖拽期间不提交命令**：UI 本地几何覆盖（ClipDrag / ClipPreviewOverride）
  只影响绘制，松手提交**一条** Move/Trim Command。**不引入 coalescing** ——
  它的需求来自"每帧提交"，而每帧提交会污染 Undo 栈（按一次 Cmd+Z 只回退几像素）。
- **提交后必须主动回到内核真值**（`refreshFromKernel()`）：内核拒绝
  （同轨重叠 / duration ≤ 0）**不触发 observer 回流**，不回查就留下"幽灵片段"。
  代价：成功时有一次旧值回弹 —— 正确性优先于动画平滑。
- **Undo/Redo 也是 session 线程操作**，走异步入队（CommandHistory 与 Timeline
  都是 session 线程状态）；空历史在 session 线程失败（版本不推进）。
- **撤销栈能力走原子量**：`EditorModelState` 内 `atomic<bool> can_undo_/can_redo_`，
  由 Execute/Undo/Redo 成功后刷新。**不得直读 CommandHistory**。
  `cq_session_can_undo/redo` 返回 **0/1 数据**，不是状态码（P26，别比 cq_status_is_ok）。
- **裁剪只改 duration，不动 source_in**（TrimClipCommand 语义）。左边缘裁剪
  需同时改 start+source_in+duration，是另一条命令，**本期不做**，UI 左边缘归移动。
- **异步提交的测试同步点 = 哨兵法**（P31）：基准版本号必须在**提交前**读，
  目标 = base + 预期成功条数 + 1。不要 sleep 赌时长，也不要无参数地"等一次推进"。
- **测试里的 #filePath 上溯链不得手写**（P30）：一律用共享 helper
  （bindings→TestPaths.root、SharedUI→RepoPath.root）；新建 helper 时层数
  必须打印实际结果验证后写死并逐层注释。

## 依赖治理硬规则（ADR-0008）
- FFmpeg upstream 用 **GitHub 官方镜像** `https://github.com/FFmpeg/FFmpeg.git`（ffmpeg.org 登记为官方 mirror），本地 git 管理。
- **源码集成的 git 依赖一律 `pin="commit"` + 40 位 hash。禁止 `pin="tag"`。**
- 「定期拉最新」= **人工 bump `pin_ref` + 完整 CI**，绝不允许 CI 自动跟随任何分支/HEAD。理由：跟随变动引用会摧毁可复现构建，让 golden/PSNR 随机失败，且 LGPL 审计无法指认具体源码。
- **`version` 字段必须 `git ls-remote` 核对，不得凭印象写。** 已发生过 6 处编造版本号（ pitfalls E6）。

## 上下文同步（2026-10-02 传哲要求：每次搞完都同步）

**收工前必须逐项落盘**，清单在 `.ai/source/AGENTS.root.md`「任务结束必须同步上下文」
一节（真源，跑 `tools/ai/sync_context.py` 生成五份入口文件 —— 改规则改真源，别手改产物）。
8 项：`.ai/modules/` → ADR（**改了既有惯例就必须新增**）→ TASK 卡 → HANDOFF →
pitfalls → baselines → 当日日志 → MEMORY.md（新确立的硬规则写这里，不留在日志里）。

⚠️ 这条原本在真源里只有 4 行泛泛描述，导致连续两轮（BIND-003 子步骤 4/5）
都漏了 `.ai/modules/` 和 ADR —— **模糊的"要回写"等于没写**，故改成逐项清单。

## 已拍板的基线（2026-09-25，见 ADR-0010）

- **最低系统版本：iOS 16 / macOS 15.4**（此前未写进任何文档，已固化）
- **容器格式**：沿用常用子集档位（17 demuxer），专业格式（mxf/dnxhd/r3d）本期不支持
- **Android**：接受排 Phase 3；鸿蒙维持仅接口编译检查
- **团队**：当前**单人**开发，不做并行 write_set 划分；有新人后再拆分
- **真机**：参考 iPhone 17 Pro，等 iOS 能跑由传哲本人实测
  → **日志与埋点必须先行做扎实**（他明确要求），到时直接看结果，不临时补埋点

## FFmpeg 的授权档位（传哲 2026-09-25 明确）

**要求：不使用 GPL 相关代码，保持 LGPL。** 这与已构建产物完全一致，无需改动：
`license=LGPL-2.1-or-later`、`CONFIG_GPL=0`（无 GPL 代码）、`CONFIG_LGPLV3=0`、`profile=demux`。

⚠️ **LGPL ≠ 无义务**（别因为"只是 LGPL"就忽略）：
LGPL v2.1 对**静态链接**的核心要求是 **接收者能用修改过的库版本替换并重新链接**。
所以「技术能用」与「可以分发」是两件事：现在未接入构建 → 义务未触发；将来要分发 → 需选
relink 能力 / 目标文件归档 / 商业授权 / 动态链接 之一。

（2026-09-25 我一度把"不用 GPL、保持 LGPL"误读成"规避 LGPL"，已更正。传哲的判断无误。）

**当前不阻塞**：产物**未接入任何构建目标**（core/ 与根 CMakeLists.txt 均未引用 ffmpeg），
未链接未分发 → LGPL 附加义务暂未触发。

**因此产生的架构约束**：CORE-006 的 PAL Media 接口**不得依赖任何 FFmpeg 类型**
（禁止 `AVFormatContext` / `AVPacket` 等）。接口必须抽象，否则将来
「接入 FFmpeg（承担 LGPL）」与「走平台原生 AVFoundation/MediaExtractor（零 LGPL）」
之间的切换会变成跨层返工。

## 悬而未决（需传哲拍板，AI 不得代决）
1. **FFmpeg LGPL v2.1+ 的链接处置**（目标文件归档 / 商业授权 / 动态链接；或干脆不接入 FFmpeg
   改走平台原生）—— 需 + 法务。**已确认延后，不阻塞当前开发**（见上）。
2. 性能基线尚未建立（PERF-001 未做），文档中所有性能数字仍是估算。
   注意：本机 Intel Mac **无 ANE、无 ProRes 硬编**，性能数字不得取自本机。

## 预览取帧的线程归属与共享命令队列（2026-10-04 定，UIA-010 子步骤 5；ADR-0016）

- **取帧/渲染只在 `PreviewPump` 的泵线程发生**；主线程只做 `Request` 与
  `Lock → blit → Unlock`。泵由**内核**拥有（非 UI 层 GCD）：非 UI 逻辑（红线 #1）、
  三端不重写、可被注入假帧源的 C++ 单测覆盖。
- **挂上泵后禁止任何线程再调 `cq_preview_render_frame` / `cq_preview_resize`**：
  解码会话与 CVMetalTextureCache 不可并发访问（不是"可能出错"，是必然竞争）。
  改尺寸只能走 `cq_preview_pump_request_resize`（RT 只能由持有它的线程销毁）。
- **消费端持锁期间不要调 `Request`**（同一把锁 → 死锁，P36 实踩），也不要
  `waitUntilCompleted`（会把泵一起堵住）。
- **UI 侧 blit 必须用内核共享的那条命令队列**（`cq_preview_shared_queue`）：
  Metal 只保证**同一条队列内**按 commit 顺序执行，跨队列需显式同步。
  GFX 设备因此由「每帧新建队列」改为按设备复用。
- **请求合并是合并"画面"不是合并"命令"**：画面是时间的函数、重算即得，丢帧无副作用；
  命令合并会丢一次编辑（撤销栈必须有）—— UIA-005 拒绝的是后者，两者别混淆。

## 数字纪律补充（2026-10-04）

- **修性能之前先分段埋点**。本次若没加 `cq_preview_last_timings`，会误判"渲染太慢"
  去做 GPU 优化 —— 实测取帧占 94%，方向会全错。
- 挪线程 ≠ 提帧率。前者换来主线程不被堵，帧率上限仍是 1/单帧取帧耗时。

## 交接（2026-09-28）：完整上下文已写入 docs/HANDOFF-002-编码阶段会话交接.md

新会话接手前**先读 HANDOFF-002 + `.ai/source/AGENTS.root.md`**。
其中包含：已完成清单（26 commit）、能力链路、未完成项（XCFramework 合并）、
iOS 平台差异五处修复、门禁命令、红线摘录、下一步优先级、本轮教训。

**传哲指示：bitcode 不要开** —— 不为打包便利开启 bitcode，也不用 `-fno-embed-bitcode`
之类选项绕过（该 Xcode 的 clang 不识别，已撤销）。XCFramework 合并这最后一步待新会话处理，
且接手时**先确认 .a 是否真的含 bitcode 段**——若未开 bitcode 却仍报 `Unknown header: 0xb17c0de`，
说明根因不是 bitcode，需重新定位，不要沿用旧推测。

## 解码接缝硬规则（2026-10-04 定，MEDIA-021；ADR-0017）

1. **编排层取帧循环一律「先 Feed 一包，再连续 PopFrame」**——B 帧未喂入时任何
   显示序重排判据都无信息可用，旧「弹不出才喂」必错帧（P39）。
2. **平台解码器回调序 = 完成序（≈dts 序），不是显示序**——凡按「弹出即显示序」
   写的代码都要用逐帧 pts 断言验证（P39）。
3. **区间归属的正确性完全依赖 duration 报准**——首帧兜底必须用 dts 差
   （B 帧文件前两包 pts 差 = (bframes+1) 帧，P40）。
4. **异步解码器 Flush = 先等在途落地、再清**（P41）；只清缓冲等于没清。
5. **seek 目标被消费后重复同目标请求必须重新 seek**（consumed_ 语义），
   否则越过兜底返回下一帧。
6. **测试请求网格用整数 ticks 构造**，浮点 ms*timescale 截断会污染逐帧断言
   与性能均值。

## flaky 排障硬规则（2026-10-04 定，P33 两层根因）

1. **「N 次全绿」只是概率证据，必须配合失败签名闭环**。P33 内核修复后 SharedUI
   ×3 全绿被写进 pitfalls 当作「flaky 消除」，下一会话复跑即 6/3/0 失败 ——
   同一 7000 签名背后有第二个独立根因（importMedia 版本差值竞态）。flaky 消除
   的判定 = 根因机制闭环 + 失败签名可解释，不是连绿次数。
2. **异步命令的「等待落地」不能拿版本号差值当判据**——任何在途命令都可能推
   版本（registerAsset 也 Publish）。等**目标效果本身**（如 `queryTracks` 出现
   视频轨；快照读纳秒级，10ms 轮询安全便宜），不要等版本号越过某个基线。
3. **框架回调的「被触发」≠「成功」**（AVFoundation loadValuesAsynchronouslyForKeys
   的 completion 对 Failed/Cancelled 终态也触发）；同理 **任何对平台回调的
   DISPATCH_TIME_FOREVER 无限等都是挂死隐患**——回调可能永不触发，一律有限
   超时 + 诚实错误码。
4. **flaky 排障手法**：先给可疑分支加「分支名 + 内核原始状态码 + 计时」的
   临时诊断，全量复跑抓现行，一轮定位（本轮 10μs 内退出却查空的打印直接
   揭示了竞态）；比对着日志猜测快一个数量级。

## 构建环境约定（2026-10-04 起，多机事实）
- **开发机不止一台**：此前所有"本机实测"来自 macOS 15.4 / AppleClang 17 的机器；
  2026-10-04 起新机为 macOS 13.7 / Xcode 15.2（AppleClang 15）。引用 baselines
  数字必须连同环境一起引用；跨机兼容写法见 pitfalls P42。
- 新机构建：`pip3 install --user cmake` 后
  `export CMAKE_BIN=$(ls ~/Library/Python/*/bin/cmake | head -1)` 再跑 build_core.sh。
- 代码跨工具链兼容规则：不用 `std::va_list`（用全局 `::va_list` + `<cstdarg>`）；
  不对 volatile 做复合赋值/自增（C++20 已弃用）。

## 编号纪律（2026-10-04 深夜定，双机并行撞号；**2026-10-05 升格为 ADR-0019 §4，以 ADR 为准**）
- **任务 ID / ADR / pitfalls P 编号取号前必须先 `git fetch` 核对远端已用号**。
  2026-10-05 合并时发现双机独立取了 UIA-011（letterbox vs 相册导入）、
  ADR-0013/0014（预览线程+顺序取帧 vs 相机特效+相机原生栈）、pitfalls P36-P39
  双份。处理原则：**改动面小的一侧让位**——本地 letterbox 任务卡两次让位 011→012→014、
  本地 ADR-0013/0014/0015 改 0016/0017/0018、远端后取号的 pitfalls P36-P39 改
  P42-P45（远端条目仅被文档引用，本地条目被内核代码注释引用）。
- 引用清扫按**主题上下文**精确替换（取帧/线程/视口 = 编码侧；相机/原生/特效 =
  相机侧），禁止全局 sed。

## 相机模块（B 期起，2026-10-04 定）
- **观测坐标契约**：相机检测观测 = 图像归一化坐标、origin 左上、两轴 0...1，
  与像素尺寸/方向无关。Vision 的左下原点翻转**只在检测器转换层做一次**
  （SharedUI `visionPointToImageNormalized`），消费方（美型 warp/贴纸）不得再翻。
- **检测队列纪律**：采集/渲染/检测三队列互不阻塞；检测 latest-wins（busy 丢帧），
  平滑状态只在检测队列持有；`onResult` 交付的观测已平滑。
- iOS 17+ 才有的 Vision 类型（如动物姿态）其**类型引用也必须收进 `@available`
  分支或用基类**（VNRequest/VNObservation）持有——无门控作用域写类型名直接编译错。

## 相机特效分层与验证（2026-10-04 定，CAM-012）
- **相机特效 = App 层资产**（`iOSApp/Camera/Effects/`，ADR-0014 §3）：.metal +
  Swift 壳都放这里，不进 SDK shader 清单；SharedUI 只持有**契约层**（参数结构 +
  注入点 + 默认 CI 兜底实现）。原生引擎经 `CameraBeautyEngine.smoothing` 注入，
  引擎放弃/加载失败**必须回落默认实现**——引擎永不制造黑帧。后续特效卡
  （CAM-013 warp / CAM-014 贴纸）照此分层。
- **CI kernel 资产纪律**（P47）：.metal 用 `metal -fcikernel` 一步编（两步 air→
  metallib 在本机工具链出空库）；运行时只走 `CIKernel(functionName:
  fromMetalLibraryData:)`，加载失败静默降级，不抛错不崩。
- **相机模块 Swift 文件合入前必须过 iphonesimulator SDK 全量 -typecheck**
  （P46/P48：-parse 已两次证明会放行真错误；A 期 4 文件 7 处存量错误即证据）。

## 智能成片硬规则（2026-10-04 定，ADR-0016）

- **原始素材默认不出设备**：上云只有 FeatureReport（KB 级聚合统计）+ 用户消息；
  人脸只报 count/area_ratio，不做识别。可选帧上传须显式授权，默认关闭。
- **LLM 输出 = EditPlan（`cq.editplan/1`）action 列表**（8 动词封顶），不是时间线；
  时间字段一律 `{value, timescale}` 且 timescale==120000，**浮点秒一律非法**；
  未知 schema 版本拒绝并降级，不猜测解析。C++ 校验器是唯一权威。
- **AI 产物全走 Command**：与人手编辑同一撤销栈，一次应用 = 一个可撤销批次；
  AI 链路禁止直接改 ModelSnapshot。
- **离线降级是产品能力**：无网/无 key/解析三连失败 → 本地规则引擎出同 schema
  plan（`generator: local_rules`），UI 明示"离线模式"。
- 供应商协议收敛 OpenAI-compatible（可插拔）；语音输入走各端系统 STT（UI 层），
  音频不上传。合规备案问题上线前过法务（HANDOFF-005 §6）。
