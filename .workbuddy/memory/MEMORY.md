# ChuanqiCut 项目长期约定

> 精简整理 2026-10-05（原文 23KB 过大导致注入被截断，规则全保留，只压叙事）

## 用户与协作偏好（传哲）
- 称呼「传哲」。直接、少废话，不要「好的/很高兴为您」这类填充语。
- 要求**批判性审视**：发现事实错误、未验证假设、矛盾点直接指出并给依据。
- 交付判定 = 门禁通过，**不接受「已完成」自述**：须报「执行了什么命令 / 通过失败 / 跳过什么 / 剩余风险」。门禁数字写具体（如 Debug 34/34），不写"全绿"。
- 数字可追溯：估算标 `[E]`，推测标 `hypothesis`，实测才能做验收阈值。
- 他不介意我推翻自己上一轮结论——只要给理由（已发生过两次）。

## 项目定性
- 跨平台视频编辑 SDK + 各端原生 App：`core/` C++20 内核，`pal/<platform>/` 适配，`apps/<platform>/` 原生 UI。
- **iOS / macOS P0** → Android P1（须给方案）→ HarmonyOS P2（本期只做 `pal/ohos/` 接口编译检查，不动）。
- 团队当前**单人**，不做并行 write_set 划分，有新人后再拆。
- 真机参考 iPhone 17 Pro，等 iOS 能跑由传哲本人实测 → **日志与埋点必须先行做扎实**。

## 不可协商的基线
- 性能基线 = 高端满足、**中端可用**、**明确不适配低端机**（不为低端机写专用降级路径）。
- 保留「能力缺失降级」（无硬解→软解、无 compute→fragment），因为中端机也可能缺某项能力。
- Shader 双层：Portable（`shaders/src/`，禁平台扩展）+ Platform-Native（`pal/<platform>/shaders/`，可用满平台特性，永远可选，收益 < 20% 不合并）。
- 最低系统版本：**iOS 16 / macOS 15.4**（ADR-0010）。容器格式沿用 17 demuxer 子集，专业格式本期不支持。

## AI 协作机制
- 单一真源 `.ai/source/AGENTS.root.md` → `tools/ai/sync_context.py` 生成 AGENTS.md / CLAUDE.md / .cursorrules / .windsurfrules / copilot-instructions.md。**改规则改真源再跑脚本**，禁手改产物。
- 编码阶段：**一个任务一个新会话**，开场读真源 + 模块文档 + 任务单卡。
- **收工逐项勾清单**（真源「任务结束必须同步上下文」）：`.ai/modules/` → ADR（改了既有惯例必须新增）→ TASK 卡 → HANDOFF → pitfalls → baselines → 当日日志 → MEMORY.md。模糊的"要回写"等于没写（连漏两轮的教训）。
- 门类补充：门禁状态写**具体数字**（如 `Debug 44/44、Release 44/44`），不写"全绿"；HANDOFF 里的任务状态要**对着 commit 历史核**，不能照抄上一版。
- 「本期明确不支持」要写进头文件/文档，不要只在对话里说。

## 产物打包与链接
- **分发的静态库不开 LTO**（`tools/build/build_core_apple.sh` 默认 `--lto=off`）：Release+LTO 产出 bitcode-only `.o`，`xcodebuild -create-xcframework` 拒绝；Release 的 `-O3` 保留。
- 主构建仍开 LTO，开关 `CQ_ENABLE_LTO_RELEASE`。不能 `-DCMAKE_INTERPROCEDURAL_OPTIMIZATION_RELEASE=OFF`（该变量 `FORCE` 写入，命令行 `-D` **静默失效**）。
- **打包后必须做消费者侧链接冒烟**（`tools/build/smoke_link.cpp`）：能打包 ≠ 能链接。
- 静态库命名一律 `lib<Name>.a`（`-lNAME` 只匹配此名；`swift build` 只编译不链接会假绿，到 `swift test` 才炸）。
- Swift 绑定两条验收路径：`swift test`（SPM）与 `run_smoke.sh`（swiftc 直编，不依赖 binaryTarget）。
- `.gitignore` 目录规则必须 `/dir/` 锚定根（裸 `build/` 曾吞掉 `tools/build/`）。
- **core 不调 PAL 工厂**；确需调时隔离独立 TU（`pal_frame_provider.cpp` / `cq_sdk_preview.cpp`）。回归：`cq_tests_c_abi` 只链 `cq_core` 必须保持通过。
- 抽象放哪层看实现必然落在哪：只能平台原生实现的放 PAL（如 `IBlitPass`），上层走逃生口 `PalDevice()/PalEncoder()`。
- 系统框架依赖清单单一真源 = `ChuanqiCut.podspec` 的 `ss.frameworks`；`Package.swift` linkerSettings 与 `run_smoke.sh` 三处同步（P23）。

## 跨层句柄
- 契约写了「reinterpret 为平台对象」的句柄，**必须有跨层测试真的 reinterpret 并消费它**（P20：GetColorTexture 曾假绿，Swift 首用即崩）。导出用（裸原生纹理）与 SetTexture 用（CqTexture* 包装）语义已在 `pal/gfx.h` 写清。
- 本机 Intel Mac + AMD GPU：`MTLTexture.getBytes` 读不到 GPU 写入内容 → 读回一律 blit→Shared Buffer→contents（P21）。

## 模型与时间线
- **Timeline 只能经 CommandHistory 变更**；Add/Insert 的 Redo 走 `RestoreTrack/RestoreClip` 恢复原 id（id 单调分配，回放不能重分配）。编辑类命令只存增量，结构类只允许持**单个实体**，禁止模型快照。
- **拖拽期间不提交命令**，松手提交**一条**；不引入 coalescing（会污染 Undo 栈）。
- **提交后必须 `refreshFromKernel()`**：内核拒绝不触发 observer 回流，不回查会留「幽灵片段」。正确性优先于动画平滑。
- Undo/Redo 也是 session 线程操作（异步入队）。撤销栈能力走 `EditorModelState` 原子量，不得直读 CommandHistory；`cq_session_can_undo/redo` 返回 **0/1 数据**不是状态码（P26）。
- 裁剪只改 duration 不动 source_in；左边缘裁剪本期不做。
- 新 ABI 返回值语义单一：错误码 XOR 数据（P26）；条数一律 out 参数。
- 测试同步点 = **哨兵法**（P31，基准版本在提交前读）；`#filePath` 上溯链不得手写（P30，用 TestPaths.root / RepoPath.root）。
- `mv/rm` 源文件后立即 grep 文件名引用并重跑受影响脚本（P27）。

## 依赖治理（ADR-0008）
- FFmpeg upstream = GitHub 官方镜像 `https://github.com/FFmpeg/FFmpeg.git`。
- **源码集成的 git 依赖一律 `pin="commit"` + 40 位 hash，禁 `pin="tag"`**；「定期拉最新」= 人工 bump + 完整 CI，CI 绝不跟随分支/HEAD。
- `version` 字段必须 `git ls-remote` 核对（曾 6 处编造版本号，E6）。
- LGPL：不用 GPL、保持 LGPL-2.1+。**LGPL ≠ 无义务**，静态链接需提供 relink 能力。当前产物**未接入任何构建目标**，义务未触发。CORE-006 PAL Media 接口**不得依赖 FFmpeg 类型**。
- **FFmpeg 授权档位（传哲 2026-09-25 明确）**：`LGPL-2.1-or-later`、`CONFIG_GPL=0`、`CONFIG_LGPLV3=0`、`profile=demux`。

## 预览 / 解码 / 取帧
- **取帧渲染只在 `PreviewPump` 泵线程**（内核拥有）；主线程只 Request + Lock→blit→Unlock。挂泵后任何线程禁调 `cq_preview_render_frame` / `cq_preview_resize`（改尺寸走 `cq_preview_pump_request_resize`）。
- 消费端持锁期间不要 Request（P36 死锁），不要 `waitUntilCompleted`（会把泵堵住）。UI blit 必须用内核共享队列 `cq_preview_shared_queue`（Metal 只保证同队列内顺序）。
- 请求合并合并的是"画面"不是"命令"（UIA-005 拒绝的是后者）。
- **修性能前先分段埋点**（没加 `cq_preview_last_timings` 会误判方向：实测取帧占 94%）。挪线程 ≠ 提帧率。
- 取帧循环一律「先 Feed 一包，再连续 PopFrame」（MEDIA-021/ADR-0017）：平台回调序 = 完成序不是显示序；区间归属依赖 duration 报准（首帧兜底用 dts 差）；异步 Flush = 先等在途落地再清（P41）；seek 目标被消费后重复同目标须重新 seek；测试请求网格用整数 ticks。

## 内存与异步等待纪律（MEDIA-027 血泪）
- **任何「等某个判据成立」的重排/同步循环，都必须配一条不依赖该判据的内存上界闸门**。
  反例（P75）：解码输出队列靠「显示序连续性」判据弹出，判据一失效就只进不出 →
  真机 8.3MB/帧 × 数百帧 = footprint 3375MB → jetsam signal 9，表现为「播放 5 秒后
  永久冻结」。判据正确性不可能零缺陷，闸门不能省。
- **判据失败分支必须区分「还没来」与「永远不会来」**，且后者的放行阈值按**连续次数**
  给（B 帧重排窗口的余量），**不能取 1** —— 取 1 会把 B 帧跳掉（实测 fast=128000 /
  slow=116000，提前 3 帧，media_sequential_real 直接挂）。
- **回调内「登记完成」必须在「交付数据」之后**：反过来的顺序让等待方的「完成」判据
  不蕴含数据可见，旧区间数据会漏进新区间（MEDIA-021 的「Seek 后首弹弹出旧 GOP」同形）。
- **等异步回调一律禁止无上界阻塞**（VTWait 系）：PopFrame 与 **Flush** 都要管 ——
  Flush 每次 Seek 都走，漏了它就是慢路径的永久阻塞入口。
- **泵线程是纯 C++ `std::thread`，没有 autorelease pool**：PAL 侧被它逐帧调用的函数
  （demux 的 RebuildReader/ReadPacket、decode 的 Feed）必须自带 `@autoreleasepool`，
  否则 AVFoundation 的自动释放对象攒到线程退出（实测 +13.8MB/60s → 加池后 +0.5MB/60s）。
- **真机「卡死 + signal 9」必须能区分 jetsam 与纯解码追赶失败** → DEBUG 剖面行恒带
  `footprint`（`task_vm_info.phys_footprint`，比 RSS 更贴近 jetsam 判定）与 `nonok/s`。
- 真机剖面用 `devicectl device process launch --console` + **stderr**（stdout 全缓冲）；
  设备锁定会直接报 `FBSOpenApplicationErrorDomain error 7`，测量窗口前先确认已解锁。

## 排障纪律
- **flaky 消除的判定 = 根因机制闭环 + 失败签名可解释**，不是连绿次数（P33 两层根因：同一签名背后有第二个根因）。
- 异步命令「等待落地」等**目标效果本身**（如 queryTracks 出现视频轨，10ms 轮询），不要等版本号越过基线。
- 框架回调「被触发」≠「成功」；对平台回调的 `DISPATCH_TIME_FOREVER` 无限等是挂死隐患，一律有限超时 + 诚实错误码。
- 手法：给可疑分支加「分支名 + 内核原始状态码 + 计时」临时诊断，全量复跑抓现行。
- **引用「实测无 error」必须注明校验层/断言层开关状态**（P65，P61 同族升级）：
  Metal API Validation（DEBUG scheme 默认开、GPU 抓帧强制开）等校验层**开与关改变
  运行时合法性** —— 关闭状态下放行可能是未定义行为。关键行为结论必须在**校验层
  开启**状态下复测过才成立。

## 相机模块（B 期，ADR-0014）
- 检测观测 = 图像归一化坐标、origin 左上、0...1；Vision 左下翻转**只在转换层做一次**（`visionPointToImageNormalized`）。
- 采集/渲染/检测三队列互不阻塞，检测 latest-wins，平滑状态只在检测队列持有。
- iOS 17+ 才有的 Vision 类型，引用也要收进 `@available` 分支或用基类持有。
- **相机特效 = App 层资产**（`iOSApp/Camera/Effects/`），SharedUI 只持契约层 + 默认 CI 兜底；原生引擎经 `CameraBeautyEngine.smoothing` 注入，**加载失败必须回落默认，引擎永不制造黑帧**。
- CIKernel：编译链接**都要** `-fcikernel` 且都用 `metal`（用 `xcrun metallib` 会产出 96 字节空壳，全绿但查不到 kernel）；验收 = `strings` 查 kernel 名 + 看大小（正常 ~8.4KB）。
- 相机 Swift 文件合入前必须过 **iphonesimulator SDK 全量 -typecheck 且带 `-swift-version 6`**（`-parse` 两次放过真错误，P46/P48/P49）。
- **drawable 走渲染 pass，不走 blit**（P65→CAM-016 终态）：Metal 禁止对 framebufferOnly
  纹理 blit（校验层下 SIGABRT，「实测无 error」须注明校验层状态）；终态 = 中间纹理 →
  显式 UV 渲染 pass（colorAttachment 是 framebufferOnly 唯一合法写法）→ drawable 保持
  `framebufferOnly = true`。v 轴符号 = CI 行序补偿（`ciWritesBottomUp`，真机一验定案）。
- **三套方向枚举 landscape 命名互换**（P67）：`UIInterfaceOrientationLandscapeLeft`（home 在右）
  ≡ `AVCaptureVideoOrientation.landscapeRight` —— 同名直映必错；映射只准落在
  `CameraManager.rotationAngle/videoOrientation` 一处，改前 grep SDK 头文件注释。
- **相机页 UI 栈（传哲 2026-10-05 拍板）**：SwiftUI + UIViewRepresentable(MTKView) 混合，
  **不引 SnapKit/RxSwift** 等 UIKit 生态库（SnapKit 只有 Auto Layout 语义、RxSwift 与
  SwiftUI 状态模型重复）；引任何 UI 三方必须走 manifest.toml + cq-dependency-governance。
  双摄（CAM-021）开关必须独立于前后翻转按钮。

## 数字纪律
- 估算标 `[E]`，推测标 `hypothesis`，实测才能做验收阈值。引用 baselines 必须带机器环境。
- **计数类埋点必须绑定「真的出了效果」，不能绑定「代码走到了这一步」**（P60）：
  `CIContext.render(_:to:commandBuffer:)` 非 throws 且失败不进 `commandBuffer.error`，
  黑屏也能让帧计数一路涨。UI 侧计数器一律加到「命令缓冲完成且无错」的回调里，
  并配套一个 `failureCount` 作为伪绿嗅探针。

## 日志：三维模型与 workflow 筛选（CORE-010，2026-10-06）

日志有**三维**，彼此正交，别混：
- **Level** —— 多详细（trace/debug/info/warn/error）
- **Stage** —— 帧走到哪一步（只用于带 pts 的帧级 trace）
- **Workflow** —— **我在排查哪条链路**（core/model/import/demux/decode/framecache/
  preview/render/export/camera/gfx/perf/mem/ai）

前两维答不出「只开 decode 链路」。输出前缀 `[wf:xxx]`，`grep '\[wf:decode\]'` 即可筛。
真机切换靠环境变量，**不改代码不重编译**（Xcode Scheme → Run → Arguments）：
`CQ_LOG_LEVEL` / `CQ_LOG_WORKFLOW`（白名单）/ `CQ_LOG_WF_LEVEL`（单链路提级）。
App 侧在 `EditorViewModel.init()` 最早处调 `ChuanqiCut.configureLogFromEnvironment()`。

**分级原则（判断某条日志该不该进 Release）**：问它报的是「系统正在偏离正轨」还是
「我想看细节」。前者 —— 降级发生、队列/追帧上界命中、慢调用、看门狗 —— 一律 **Warn
且 Release 可见**；后者才 Debug/Trace。

**硬规则**：
- 日志一律走 `CQ_LOG_*_WF(wf, ...)`，禁裸 `fprintf(stderr, ...)`。
- 慢调用告警统一 `CQ_SLOW_CALL_WF`（core/base/perf.h，阈值 500ms），
  **不许在 .cpp/.mm 里自抄 RAII**（旧版 4 个文件各抄一份，阈值还不一致）。
- **Debug-only 的诊断在 Release 包里等于不存在**（P76）。Release 才是真机常态。
- **改了任何依赖 NDEBUG 的代码，必须 Debug + Release 双向编译验证** ——
  解开一处 NDEBUG 后，它依赖的成员/计数器往往还在块里，Debug 绿、Release 炸（踩过 3 次）。

## 构建验证纪律（iOS 侧）
- **iOS App 编译验证必须 `-scheme ChuanqiCutApp`**：workspace 里 `ChuanqiCut` 是 Pods 生成的
  静态库 target，编不到 `iOSApp/` 源文件，却能 BUILD SUCCEEDED + 0 警告假绿（P61）。
  日志里 `Target dependency graph (1 target)` 就是线索。
- **不确定某个 Swift 文件是否被真编译 → 先塞一个必然报错的 canary（`1 + "x"`）跑一次，
  确认它真炸了再拿掉**（呼应 P46/P48：轻量检查多次放过真错误）。

## Apple 端工程与门禁（ADR-0021 / CODE-001）
- "cannot find X in scope" 先查工程引用：xcodeproj 是 xcodegen 生成产物、不入库、易陈旧。核对：`git ls-files` vs `find` vs grep `project.pbxproj`。
- 改工程：改 `project.yml` → `xcodegen generate` → `bundle exec pod install`（**顺序不能反**）。xcodegen 2.46 三坑：不写 `PRODUCT_NAME`（多命令冲突）、`excludes` 必须 glob、Metal flag 塞不进去。
- **门禁 = `tools/ci/run_gate.sh`**（deps + PAL 头纯净 + Debug/Release 全量单测 + XCFramework + Swift 绑定 + SharedUI + golden，一票否决）。远端"已验证"按未验证处理。
- 风格唯一标准 `docs/CODESTYLE.md`，巡检落 `docs/reviews/`；文档里的命令路径必须真实存在（P58）；脚本 `$var` 写 `${var}`（bash 3.2，P50）。
- 多人/多会话共用机器加 `-derivedDataPath` 隔离（否则 `database is locked`）。
- **合并/同步后必查冲突标记残留**（P59）：全仓 grep `<<<<<<<` / `=======` / `>>>>>>>`。注意 `tests/golden/*.py` 有 45 字符 `=====` 注释分隔线，不是冲突标记。

## 播放器域边界（UIA-015 / ADR-0022，2026-10-05 确立）
- **AVFoundation/AVKit 只许出现在 `SharedUI/Sources/SharedUI/Player/` 域的五个文件**（PlayerEngine / AVPlayerEngine / PlayerSurfaceView / VideoThumbnailLoader / PlayerPipCoordinator）；控制层、PlayerViewModel、App target 一律不 import。跨文件传 `AVPlayer`/`AVPlayerLayer` 用「不点名的不透明值」（不写出类型名即可传值）。控制层只依赖 `PlayerEngine` 协议 —— 换 C++ 播放 session 时不改 UI。
- **SharedUI 新代码按 Swift 5.5 可解析风格写**（显式 `guard let x = x`、不用 `any P`）—— 本机 swiftc 5.5 是唯一静态验证手段，5.7 简写会把语法检查变成噪音（P45/P46 环境约束的推论）。

## 智能成片（ADR-0020）
- **原始素材默认不出设备**：上云只有 FeatureReport（聚合统计），人脸只报 count/area_ratio；可选帧上传须显式授权。
- LLM 输出 = EditPlan（`cq.editplan/1`，≤8 动词），非时间线；时间一律 `{value,timescale}` 且 timescale==120000，浮点秒非法；未知 schema 拒绝降级不发猜。C++ 校验器唯一权威。
- AI 产物全走 Command（同一撤销栈，一次应用 = 一个可撤销批次），禁止直改 ModelSnapshot。
- 离线降级是产品能力（本地规则引擎出同 schema，UI 明示）。语音走系统 STT，音频不上传；上线前过法务。

## 构建环境（引用 baselines 必须连环境）
| 机器 | 系统 / 工具链 |
|---|---|
| A（早期全部"本机实测"） | macOS 15.4 / AppleClang 17（Intel i7 + AMD GPU，无 ANE、无 ProRes 硬编） |
| B | macOS 13.7 / Xcode 15.2（AppleClang 15，Swift 5.9.2）。SwiftPM 声明 `swift-tools-version:6.1` 本机解析不了 → swift-bindings 门禁 FAIL 属**环境上限，不是回归** |
| C（当前） | macOS 26.7.1 / Xcode 26.6（iPhoneSimulator 26.5 SDK） |
- B 机：`pip3 install --user cmake` 后 `export CMAKE_BIN=$(ls ~/Library/Python/*/bin/cmake | head -1)`。
- 跨工具链兼容：用 `::va_list` + `<cstdarg>`；不对 volatile 复合赋值/自增。
- Apple 端没有 brew：xcodegen 取 GitHub Release 二进制放 `/usr/local/bin`。

## 编号纪律（ADR-0019 §4）
- **任务 ID / ADR / pitfalls P 编号取号前先 `git fetch` 核对远端已用号**（双机曾撞 UIA-011、ADR-0013/0014、P36-P39）。处理原则：**改动面小的一侧让位**。
- 引用清扫按**主题上下文**精确替换，禁止全局 sed。
- 三线并行起：**集成机是唯一发号器**，每线一次领 5 个号，登记即占号。

## 悬而未决（需传哲拍板，AI 不得代决）
1. **FFmpeg LGPL v2.1+ 链接处置**（目标文件归档 / 商业授权 / 动态链接 / 不接入改平台原生）—— 需法务，**已确认延后不阻塞**。
2. 性能基线未建立（PERF-001 未做），文档性能数字仍是估算；本机 Intel Mac 无 ANE、无 ProRes 硬编，不得采样本机数字。
