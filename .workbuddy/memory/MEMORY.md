# ChuanqiCut 项目长期约定

## 用户与协作偏好（传哲）
- 称呼：传哲。直接、少废话，不要「好的/很高兴为您」这类填充语。
- 要求**批判性审视**：发现事实错误、未验证假设、矛盾点要直接指出并给出依据。
- 交付判定 = 门禁通过，**不接受「已完成」的自述**。必须报告：执行了什么命令、通过/失败、跳过什么、剩余风险。
- 数字可追溯：估算标 `[E]`，推测标 `hypothesis`，实测才能作为验收阈值。
- 他不介意我推翻自己上一轮的结论——只要给出理由（已发生两次：Shader 单层→双层、低端机降级→明确不支持）。

## 项目定性与基线
- 跨平台视频编辑 SDK + 各端原生 App：`core/`=C++20 内核（纯 C ABI）、`pal/`=平台适配、`apps/`=原生 UI。
- 优先级：**iOS/macOS (P0)** → Android (P1，必须给方案) → HarmonyOS (P2，仅 `pal/ohos/` 接口编译检查)。
- 性能基线 = 高端满足、**中端可用**、**明确不适配低端机**（不写降级路径）；保留「能力缺失降级」（无硬解→软解、无 compute→fragment）。
- Shader 双层：`shaders/src/`=Portable（禁平台扩展，经 SPIR-V）；`pal/<platform>/shaders/`=Platform-Native（永远可选，收益 < 20% 不合并）。
- 最低系统版本 iOS 16 / macOS 15.4；容器格式常用子集（17 demuxer，mxf/dnxhd/r3d 不支持）；当前单人开发。
- 真机参考 iPhone 17 Pro，由传哲实测 → **日志与埋点必须先行做扎实**。

## AI 协作机制
- 单一真源 `.ai/source/AGENTS.root.md` → `tools/ai/sync_context.py` 生成 AGENTS.md / CLAUDE.md / .cursorrules / .windsurfrules / copilot-instructions.md。**改规则改真源再跑脚本**，禁手改生成物。
- 编码阶段：一个任务一个新会话，开场读真源 + `.ai/modules/<模块>.md` + 任务单卡。

## 收工同步清单（真源「任务结束必须同步上下文」，8 项逐项落盘）
`.ai/modules/` → ADR（**改了既有惯例就必须新增**）→ TASK 卡 → HANDOFF → pitfalls → baselines → 当日日志 → 本文件（新硬规则写这里）。
- 门禁状态写具体数字（如 `Debug 44/44、Release 44/44`），不写"全绿"；剩余风险与"本期不支持"写进头文件/文档，不要只在对话里说；HANDOFF 任务状态要**对着 commit 历史核**。
- ⚠️ 这条曾只有 4 行泛泛描述，导致连续两轮漏 `.ai/modules/` 与 ADR —— 模糊的"要回写"等于没写。

## 产物打包与链接（2026-09-29/30 定）
- **分发的静态库不开 LTO**（`build_core_apple.sh` 默认 `--lto=off`）：Release+LTO 产出 bitcode-only `.o`，`-create-xcframework` 直接拒绝。主构建仍开 LTO，开关是 `CQ_ENABLE_LTO_RELEASE`——**不能**用 `-DCMAKE_INTERPROCEDURAL_OPTIMIZATION_RELEASE=OFF`（该变量带 `FORCE`，命令行 `-D` 静默失效）。
- **交付外部工具链的静态库一律命名 `lib<Name>.a`**（`-lNAME` 只匹配 `libNAME.a`）。
- **打包后必须做消费者侧链接冒烟**（`tools/build/smoke_link.cpp`）。Swift 绑定验收两条路径：`swift test`（SPM）与 `run_smoke.sh`（swiftc 直编）。
- `.gitignore` 目录规则必须写成 `/dir/` 锚定根（裸 `build/` 曾把 `tools/build/` 一并忽略）。

## 分层与链接硬规则
- **core 不调 PAL 工厂**（调用只发生在 tests/ 与 pal/）。确需调时**必须隔离在独立 TU**（按 archive member 拉符号）：现存 `media/pal_frame_provider.cpp`、`preview/cq_sdk_preview.cpp`。回归验证：`cq_tests_c_abi` 只链 `cq_core` 必须保持通过。
- **抽象放哪层，看实现必然落在哪**：只能平台原生实现的（shader 源码 / 平台 SDK）抽象放 PAL（如 `IBlitPass`）；上层要用走逃生口 `IGfxDevice::PalDevice()` / `IGfxEncoder::PalEncoder()`。
- **契约写了「reinterpret 为平台对象」的句柄，必须有跨层测试真的 reinterpret 并消费它**（P20）。导出用（裸原生纹理）与 SetTexture 用（CqTexture* 包装）两种语义已在 `pal/gfx.h` 写清。
- **内核静态库系统框架依赖清单单一真源 = `ChuanqiCut.podspec` 的 ss.frameworks**；`Package.swift` linkerSettings 与 `run_smoke.sh` 必须同步（P23）。
- Intel Mac + AMD GPU：`MTLTexture.getBytes` 读不到 GPU 写入内容，读回一律 blit→Shared Buffer→contents（P21）。

## 模型变更硬规则（MODEL-002）
- **Timeline 只能经 CommandHistory 变更**（红线 #5），绕过直改会让历史 id 悬空、Undo/Redo 静默失效。
- **Add/Insert 的 Redo 必须走 `RestoreTrack/RestoreClip` 恢复原 id**（重放会分配新 id）。
- 编辑类命令只存增量（id + old/new）；结构类只允许持有单个实体；模型级快照禁止。
- **新 ABI 返回值语义单一**：错误码 XOR 数据（P26），条数类走 out 参数。
- **mv/rm 源文件后立即 grep 文件名引用并重跑受影响脚本**（P27）。

## 时间线交互硬规则（UIA-005 / ADR-0012）
- **拖拽期间不提交命令**：松手提交**一条** Move/Trim，**不引入 coalescing**（每帧提交污染 Undo 栈）。
- **提交后必须 `refreshFromKernel()`**：内核拒绝（同轨重叠 / duration ≤ 0）**不触发 observer 回流**，不回查会留"幽灵片段"。
- Undo/Redo 是 session 线程操作，异步入队；**撤销栈能力走 `atomic<bool> can_undo_/can_redo_`**，不得直读 CommandHistory。`cq_session_can_undo/redo` 返回 **0/1 数据**不是状态码。
- **裁剪只改 duration 不动 source_in**；左边缘裁剪是另一条命令，本期不做，UI 左边缘归移动。
- **异步提交测试同步点 = 哨兵法**（P31）：基准版本号提交前读，目标 = base + 预期成功条数 + 1。
- **测试 `#filePath` 上溯链不得手写**（P30）：用共享 helper（bindings→`TestPaths.root`、SharedUI→`RepoPath.root`）。

## 依赖治理（ADR-0008）
FFmpeg upstream = `https://github.com/FFmpeg/FFmpeg.git`（官方镜像），本地 git 管理。**源码集成的 git 依赖一律 `pin="commit"` + 40 位 hash，禁 `pin="tag"`**；「定期拉最新」= 人工 bump `pin_ref` + 完整 CI，禁止 CI 跟随分支/HEAD。`version` 字段必须 `git ls-remote` 核对（已发生 6 处编造版本号，E6）。

## FFmpeg 授权档位（传哲 2026-09-25 明确）
不用 GPL、保持 LGPL（`LGPL-2.1-or-later`、`CONFIG_GPL=0`、`CONFIG_LGPLV3=0`、`profile=demux`）。
**LGPL ≠ 无义务**（静态链接要求接收者可替换库版本重链接），但当前产物未接入任何构建目标 → 义务未触发。
架构约束：PAL Media 接口**不得依赖任何 FFmpeg 类型**（禁 `AVFormatContext`/`AVPacket`），否则将来切平台原生方案会跨层返工。

## 预览取帧线程归属（ADR-0016）
- 取帧/渲染**只在内核 `PreviewPump` 泵线程**；主线程只做 `Request` 与 `Lock→blit→Unlock`。
- 挂上泵后**禁止任何线程再调 `cq_preview_render_frame` / `cq_preview_resize`**（必然竞争），改尺寸走 `cq_preview_pump_request_resize`。
- 消费端持锁期间不调 `Request`（同锁死锁，P36）、不用 `waitUntilCompleted`（堵泵）；UI blit 必须用 `cq_preview_shared_queue`（跨队列无顺序保证）。
- 请求合并是合并"画面"不是"命令"——丢帧无副作用，丢编辑有。

## 数字纪律
引用性能数字前先查 `.ai/memory/baselines.md`，没有的就是估算。**修性能前先分段埋点**（曾因没埋点误判"渲染太慢"，实测取帧占 94%）。挪线程 ≠ 提帧率。

## 解码接缝硬规则（MEDIA-021 / ADR-0017）
1. 取帧循环一律「先 Feed 一包，再连续 PopFrame」——B 帧未喂入时重排判据无信息（P39）。
2. 平台解码器回调序 = **完成序（≈dts）不是显示序**，凡按"弹出即显示序"写的都要逐帧 pts 验证。
3. 区间归属依赖 duration 报准，首帧兜底用 dts 差（P40）。
4. 异步解码器 Flush = 先等在途落地、再清（P41）。
5. seek 目标被消费后重复同目标请求必须重新 seek（consumed_ 语义）。
6. 测试请求网格用整数 ticks 构造（浮点 ms*timescale 截断污染断言）。

## flaky 排障硬规则（P33 两层根因）
1. 「N 次全绿」只是概率证据；flaky 消除 = 根因机制闭环 + 失败签名可解释。
2. 异步命令"等落地"**不能拿版本号差值当判据**（任何在途命令都推版本）——等**目标效果本身**（如 `queryTracks` 出现视频轨）。
3. **框架回调"被触发"≠"成功"**；对平台回调的 `DISPATCH_TIME_FOREVER` 无限等是挂死隐患，一律有限超时 + 诚实错误码。
4. 手法：给可疑分支加「分支名 + 内核原始状态码 + 计时」诊断，全量复跑抓现行。

## 构建环境（多机事实，引用 baselines 必须连同环境）
- **A**（早期"本机实测"）：macOS 15.4 / AppleClang 17（Intel i7 + AMD GPU，无 ANE、无 ProRes 硬编）
- **B**：macOS 13.7 / Xcode 15.2（AppleClang 15，Swift 5.9.2）→ BIND-002 声明 `swift-tools-version:6.1`，本机解析不了 → swift-bindings 门禁 FAIL 属**环境上限非回归**
- **C（当前）**：macOS 26.7.1 / Xcode 26.6（iPhoneSimulator 26.5 SDK）
- B 机 `CMAKE_BIN=$(ls ~/Library/Python/*/bin/cmake | head -1)`；跨工具链不用 `std::va_list`、不对 volatile 复合赋值；Apple 端无 brew，xcodegen 取 GitHub Release 二进制放 `/usr/local/bin`。

## 编号纪律（ADR-0019 §4，以 ADR 为准）
- **任务 ID / ADR / pitfalls P 编号取号前必须先 `git fetch` 核对远端已用号**（双机并行曾撞号 UIA-011、ADR-0013/14、P36-P39）。让位原则：**改动面小的一侧让位**。
- 引用清扫按**主题上下文**精确替换，禁止全局 sed。
- 三线并行起（CODE-001）：**集成机是唯一发号器**，每线一次领 5 个号，登记即占号。

## 相机模块（B 期起）
- **观测坐标契约**：归一化坐标、origin 左上、两轴 0...1。Vision 左下原点翻转**只在检测器转换层做一次**（`visionPointToImageNormalized`），消费方不得再翻。
- 采集/渲染/检测三队列互不阻塞；检测 latest-wins；`onResult` 交付的观测已平滑。
- iOS 17+ 才有的 Vision 类型，其**类型引用也必须收进 `@available` 分支或用基类**持有。

## 相机特效分层（CAM-012 / ADR-0014 §3）
- **相机特效 = App 层资产**（`iOSApp/Camera/Effects/`：.metal + Swift 壳），不进 SDK shader 清单；SharedUI 只持契约层。**引擎放弃/加载失败必须回落默认实现**——引擎永不制造黑帧。CAM-013/014 照此分层。
- **CIKernel 纪律**（P47）：`metal -fcikernel` 一步编（两步 air→metallib 出 96 字节空壳、退出码 0）；运行时只走 `CIKernel(functionName:fromMetalLibraryData:)`，失败静默降级。验收：`strings` 查 kernel 名 + 大小（正常 ~8.4KB）。
- 相机 Swift 文件合入前必过 **iphonesimulator SDK 全量 `-typecheck` 且带 `-swift-version 6`**（P46/P48/P49：`-parse` 两次放行真错误）。

## 相机 CI 色彩域与蒙版契约（CAM-015/016，2026-10-06 定）
- **CIContext 一律显式 `workingColorSpace`（gamma sRGB）**，禁止依赖默认线性域（P62）：凡 harness 定标的 CI 参数，真机运行域必须与定标域一致；新增 CI 消费方先核域再调参。
- **美颜区域化三态契约**：`apply(to:faces:)` —— nil=全画面兜底、[]=**直通**（与美型"无脸直通"同口径）、非空=归一化框（左上）→ FaceMask 蒙版。引擎注入签名 `(CIImage, Double) -> CIImage?` 不加 mask 参数，蒙版在 SharedUI apply 内 `CIBlendWithMask` 施加。
- **CIImage DAG 宿主脚本先行**（P63）：自定义几何/渐变/合成先跑宿主实渲染采样再落正式测试；`CIRadialGradient` extent 有限、`cropped` 只做交集、`CGPoint+CGVector` 不存在——三个已实锤的 API 语义陷阱。

## 智能成片（ADR-0020）
- **原始素材默认不出设备**：上云只有 FeatureReport + 用户消息；人脸只报 count/area_ratio；帧上传须显式授权、默认关闭。
- **LLM 输出 = EditPlan（`cq.editplan/1`）action 列表**（8 动词封顶），不是时间线；时间字段 `{value, timescale}` 且 timescale==120000，**浮点秒非法**；未知 schema 拒绝并降级，C++ 校验器是唯一权威。
- **AI 产物全走 Command**（同人手撤销栈，一次应用 = 一个可撤销批次），禁直接改 ModelSnapshot。
- **离线降级是产品能力**：三连失败 → 本地规则引擎出同 schema plan（`generator: local_rules`），UI 明示"离线模式"。供应商收敛 OpenAI-compatible；语音走系统 STT；合规备案上线前过法务（HANDOFF-005 §6）。

## Apple 端工程与构建（P54-P56 / ADR-0021）
- **「cannot find X in scope」先查工程引用，不要先怀疑没提交**。xcodeproj 是 xcodegen 生成物、不入库，极易陈旧（曾只剩 1/12 源文件引用）。核对：`git ls-files <dir>` vs `find` vs `grep .swift project.pbxproj`。
- 改工程：改 `project.yml` 真源 → `xcodegen generate` → `bundle exec pod install`（**顺序不能反**）。
- xcodegen 2.46 三坑：不写 `PRODUCT_NAME`、`excludes` 必须用 glob、Metal 编译 flag 塞不进去。
- 多会话共用机器加 `-derivedDataPath` 隔离。传哲指示：**bitcode 不要开**，也不用 `-fno-embed-bitcode` 绕过。

## 门禁与守门（CODE-001）
- **门禁 = `tools/ci/run_gate.sh`**（deps + PAL 头纯净性 + Debug/Release 全量单测 + XCFramework + Swift 绑定 + SharedUI + golden，一票否决）。
- 远端"已验证"一律按未验证处理；合并后跑 gate + cq-code-review 流程 A（写集越界 + typecheck）。
- **风格唯一标准 = `docs/CODESTYLE.md`**；巡检记录落 `docs/reviews/`。
- 文档/skill 里的命令路径必须真实存在（P58）；脚本 `$var` 一律写 `${var}`（bash 3.2，P50）。
- **合并后必查冲突标记残留**（P59）：全仓 grep `<<<<<<<` / `=======` / `>>>>>>>`。注意 `tests/golden/*.py` 有 45 字符 `=====` 注释分隔线，非冲突。

## 悬而未决（需传哲拍板，AI 不得代决）
1. **FFmpeg LGPL v2.1+ 的链接处置**（目标文件归档 / 商业授权 / 动态链接，或改走平台原生）—— 需 + 法务，已确认延后，不阻塞。
2. 性能基线尚未建立（PERF-001 未做），文档中性能数字仍是估算；本机 A 机**无 ANE、无 ProRes 硬编**，数字不得取自本机。
3. ADR-0020 状态仍为"提案（待批准）"；发布签名构建下 postBuildScripts 时序（ADR-0021 已记）未实测。

## 播放器域边界（UIA-015 / ADR-0022，2026-10-05 确立）

- **AVFoundation/AVKit 只许出现在 `SharedUI/Sources/SharedUI/Player/` 域的
  五个文件**（PlayerEngine/AVPlayerEngine/PlayerSurfaceView/
  VideoThumbnailLoader/PlayerPipCoordinator）；控制层、PlayerViewModel、
  App target 一律不 import。跨文件传 `AVPlayer`/`AVPlayerLayer` 用
  "不点名的不透明值"（不写出类型名即可传值）。控制层只依赖
  `PlayerEngine` 协议——换 C++ 播放 session 时不改 UI。
- **SharedUI 新代码按 Swift 5.5 可解析风格写**（显式 `guard let x = x`、
  不用 `any P`）——本机 swiftc 5.5 是唯一静态验证手段，5.7 简写会把
  语法检查变成噪音（P45/P46 环境约束的推论）。