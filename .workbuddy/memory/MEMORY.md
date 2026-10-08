# ChuanqiCut 项目长期约定

> 精简 2026-10-08（第 3 次）。规则全保留，只压叙事与已闭环历史。
> ⚠️ §17 机器表与实际工具链有漂移（见 P90）：引用前核 `sw_vers` / `xcodebuild -version`。

## 0. 用户协作偏好（传哲）
- **跑门禁与真机必须先询问**：全量门禁/合并快检/真机趟一律先问过再执行。ADR-0030 触发条件不变，触发后人点头；待验项照旧登记 TODO-POOL。
- 称呼「传哲」。直给、少废话，不要「好的/很高兴为您」类填充语。
- 要求**批判性审视**：事实错误、未验证假设、矛盾点直接指出并给依据；可以推翻自己上一轮结论，只要给理由。
- 交付判定 = 门禁通过，**不接受「已完成」自述**：须报「执行什么命令 / 通过失败 / 跳过什么 / 剩余风险」。门禁写具体数字（Debug 44/44），不写"全绿"。
- 数字可追溯：估算标 `[E]`，推测标 `hypothesis`，**只有实测能做验收阈值**；引用 baselines 必须带机器环境。
- **计数类埋点必须绑定「真的出了效果」而非「代码走到了这一步」**（P60）：CIContext.render 非 throws 且不进 commandBuffer.error，黑屏也算帧。UI 计数器加到「命令缓冲完成且无错」回调，配 `failureCount` 作伪绿探针。

## 1. 项目定性
- 跨平台视频编辑 SDK + 各端原生 App：`core/`（=仓库 `engine/core/`）C++20 内核（纯 C ABI）、`pal/<platform>/` 适配、`apps/<platform>/` 原生 UI。
- **iOS / macOS P0** → Android P1（须给方案）→ HarmonyOS P2（本期只做 `pal/ohos/` 接口编译检查）。
- **双机并行三线**（PLAN-三线并行）：本机 = 集成机（唯一真构建机 + 唯一发号器）。其他设备性能差、无真机、门禁不可信（P78）。
- 真机参考 iPhone 17 Pro，等 iOS 跑通由传哲本人实测 → **日志与埋点必须先行做扎实**。
- 最低系统版本 **iOS 16 / macOS 15.4**（ADR-0010）。

## 2. 不可协商的基线
- 性能基线 = 高端满足、**中端可用**、**明确不适配低端机**（不为低端机写专用降级路径）。
- 但**能力缺失降级要做**（无硬解→软解、无 compute→fragment）。
- Shader 双层：Portable（`shaders/src/`，禁平台扩展，经 SPIR-V）+ Platform-Native（`pal/<platform>/shaders/`，永远可选，**收益 < 20% 不合并**）。
- 「本期明确不支持」要写进头文件/文档，不要只在对话里说。

## 3. AI 协作机制（ADR-0029/0030/0031）
- 单一真源 `.ai/source/AGENTS.root.md` → `tools/ai/sync_context.py` 生成 AGENTS.md/CLAUDE.md/.cursorrules。**改规则改真源再跑脚本**，禁手改产物。
- 编码阶段：**一个任务一个新会话**，开场读真源 + 模块文档 + 任务单卡。
- **模块归属**（PLAN-三线并行 §1a，各 `.ai/modules/*.md` 头部有归属行）：A=编辑器/UI（ui-apple/ui-android/model/session/preview/project + AIEDIT）、B=相机（camera）、C=内核/媒体/渲染；集成机=core/pal/pal-android/deps/热点。**一机同一时间只待一条线**。
- **模块册分册制（ADR-0030）**：调研/任务/进度/测试及门禁记录写 `.ai/modules/<模块>.md`「模块册」，归归属线更新；新 RESEARCH/SPEC/REVIEW 落 `docs/` 并在模块册登记指针。
- **全局册单写者 = 集成机**：TASK-BACKLOG、两份 README、pitfalls、baselines、PLAN、ADR、workbuddy/MEMORY —— 开发机零直写，要改走池条目或提案。
- **开发机 = 简化档**：不等门禁；自查 = 编译 + 相关单测（Swift 必须 `-typecheck`）；不跑全量门禁、不碰真机；收工把待验项 append 进 TODO-POOL。
- **集成机 = 阶段批**：**合并快检必做**（core 编译 + SharedUI 测试窄检 + **双壳 App target 真编译**（P83）+ 冲突/旧号扫描，**远端"已验证"按未验证处理**）；**全量门禁 + 真机按阶段触发**（阶段收尾 / 一批卡闭环 / 真机单攒齐 / 周度兜底）。池 append-only 归开发机，清扫/关闭/编号只归集成机（P82）。
- **热点文件豁免排除**：`cq_sdk.h`、CMakeLists、podspec、Podfile、project.yml、构建脚本、真源、CI 及任何 ABI/依赖变更**不受简化档豁免**，须先提案给集成机。
- **收工逐项勾清单**：`.ai/modules/` → ADR → TASK 卡 → HANDOFF → pitfalls → baselines → 当日日志 → MEMORY.md。模糊的"要回写"等于没写。HANDOFF 任务状态**对着 commit 历史核**。
- **发号水位（2026-10-08）**：ADR 下一号 **0032**（0025~0028 预占素材库多轨）；pitfalls 下一号 **P91**（P89/P90 今日新占）。
- ①SDK pod 名 **ChuanqiCutEngine**（`s.module_name='ChuanqiCut'`）；②Pods 导航器里的 docs/*.md = CocoaPods 文档探测（无害，见 docs/COCOAPODS.md）；③core 头文件 preserve_paths 进导航器，**头文件永不进 source_files**；④周报 `docs/reports/WEEKLY-<年>-W<周>.md`。

### 3.1 壳工程与功能 Pod（ADR-0031）
- 主工程 = 壳；Pod = ChuanqiCut（SDK 不动）+ SharedUI（基座）+ Player/Import/Assets/Camera/Draft/Editor 七功能 Pod。**功能 Pod 横向零依赖**。Camera 仅 iOS。
- SharedUI 仅 `Common/` + 三注入器（PlayerPreview/EditorEntry/MediaLibrary）；测试守恒 140（Player 52 / Import 16 / Camera 36 / Editor 36）；INFRA-017 Assets 改挂 LIB 依赖。
- **域迁移开工前必须做全符号跨域引用分析**（grep 未限定标识符）。
- **P85 三假绿**：①.metal 不进 source_files；②静态 Pod script_phase 产物进不了 App bundle（管线留壳工程）；③scheme 必须在 project.yml 显式声明。依赖 SharedUI 的 Pod 自带 CChuanqiCut `SWIFT_INCLUDE_PATHS`。**门禁 PASS 基线 = 12 步**（含 artifacts + apple-camera）。
- **编辑页 UIKit 重建（UIA-034~036，ADR-0024）**：Editor Pod 内 `UIKit/` 域（全 `#if os(iOS)`）；CADisplayLink 直读 `vm.playhead` 驱动播放头层/时间码，SwiftUI 零参与、VM 零改动。macOS/横屏仍 SwiftUI。真机走查 = 池 [6]。

### 3.2 构建产物零入库（P84 硬规则）
①`.gitignore` 通配 `apps/apple/packages/*/.build/` 与根 `/.build/`；②`run_gate.sh` 有 **artifacts 步**（`.build/`、根 `build/`、`DerivedData`、`.xcuserstate`、`.DS_Store` 被跟踪 = 一票否决）；③**临时编译统一 `/build/`**（SPM 用 `--scratch-path "$ROOT/build/spm/<包>"`）；④`git add -A` 前必看 `git status`。`.gitignore` 目录规则必须 `/dir/` 锚定根。

## 4. 产物打包与链接
- **分发的静态库不开 LTO**（默认 `--lto=off`：Release+LTO 产出 bitcode-only `.o`，`create-xcframework` 拒绝）；Release `-O3` 保留；**不可**用 `-DCMAKE_INTERPROCEDURAL_OPTIMIZATION_RELEASE=OFF`（FORCE 变量，命令行静默失效）。
- **打包后必须做消费者侧链接冒烟**（`tools/build/smoke_link.cpp`）：能打包 ≠ 能链接。
- 静态库命名一律 `lib<Name>.a`；`swift build` 只编译不链接 → 假绿，到 `swift test` 才炸。
- Swift 绑定两条验收路径：`swift test`（SPM）+ `run_smoke.sh`（swiftc 直编）。
- **core 不调 PAL 工厂**；确需时隔离独立 TU。回归：`cq_tests_c_abi` 只链 `cq_core` 必须保持通过。
- 抽象放哪层看实现必然落在哪；上层逃生口 `PalDevice()/PalEncoder()`。
- 系统框架清单单一真源 = `ChuanqiCut.podspec` 的 `ss.frameworks`；`Package.swift` linkerSettings 与 `run_smoke.sh` **三处同步**（P23）。

## 5. 跨层句柄
- 契约写「reinterpret 为平台对象」的句柄，**必须有跨层测试真的 reinterpret 并消费它**（P20）。导出用（裸原生纹理）与 SetTexture 用（包装句柄）语义见 `pal/gfx.h`。
- 本机 Intel Mac + AMD GPU：`MTLTexture.getBytes` 读不到 GPU 写入 → 读回一律 blit→Shared Buffer→contents（P21）。

## 6. 模型与时间线
- 时间一律有理数 `RationalTime{value, timescale}`，禁浮点秒（timescale 见 ADR-0006/0009）。
- **Timeline 只能经 CommandHistory 变更**；Add/Insert 的 Redo 走 `RestoreTrack/RestoreClip` 恢复原 id。编辑类命令只存增量，禁止模型快照。
- **拖拽期间不提交命令**，松手提交**一条**；不引入 coalescing。
- **提交后必须 `refreshFromKernel()`**（内核拒绝不触发 observer → 幽灵片段）。
- Undo/Redo 也是 session 线程操作；能力走 `EditorModelState` 原子量，不得直读 CommandHistory；`cq_session_can_undo/redo` 返回 0/1 **数据**不是状态码（P26）。
- 裁剪只改 duration 不动 source_in；左边缘裁剪本期不做。
- 新 ABI 返回值语义单一：错误码 XOR 数据（P26）；条数一律 out 参数。
- 测试同步点 = **哨兵法**（P31）；`#filePath` 上溯链不得手写（P30）。
- `mv/rm` 源文件后立即 grep 文件名引用并重跑受影响脚本（P27）。

## 7. 依赖治理（ADR-0008）
- FFmpeg upstream = GitHub 官方镜像。**源码集成的 git 依赖一律 `pin="commit"` + 40 位 hash，禁 `pin="tag"`**。
- `version` 字段必须 `git ls-remote` 核对（曾 6 处编造版本号，E6）。
- LGPL-2.1+，不用 GPL。**LGPL ≠ 无义务**：静态链接需提供 relink 能力。CORE-006 PAL Media 接口**不得依赖 FFmpeg 类型**。授权档位：`CONFIG_GPL=0`、`CONFIG_LGPLV3=0`、`profile=demux`。

## 8. 预览 / 解码 / 取帧
- **取帧渲染只在 `PreviewPump` 泵线程**；主线程只 Request + Lock→blit→Unlock。挂泵后任何线程禁调 `cq_preview_render_frame` / `cq_preview_resize`。
- 消费端持锁期间不要 Request（P36 死锁），不要 `waitUntilCompleted`。UI blit 必须用 `cq_preview_shared_queue`。
- 请求合并合并的是"画面"不是"命令"。
- **修性能前先分段埋点**（`cq_preview_last_timings`）；挪线程 ≠ 提帧率。
- 取帧循环一律「先 Feed 一包，再连续 PopFrame」（MEDIA-021/ADR-0017）：回调序 = 完成序不是显示序；异步 Flush = 先等在途落地再清（P41）；seek 目标被消费后重复同目标须重新 seek。

## 9. 内存与异步等待纪律（MEDIA-027）
- **任何「等某判据成立」的循环，都必须配一条不依赖该判据的内存上界闸门**（反例 P75：footprint 3375MB → jetsam signal 9）。
- **判据失败分支必须区分「还没来」与「永远不会来」**，放行阈值按**连续次数**给，**不能取 1**（取 1 跳 B 帧）。
- **回调内「登记完成」必须在「交付数据」之后**。
- **等异步回调禁止无上界阻塞**（VTWait 系）：PopFrame 与 **Flush** 都要管。
- **泵线程是纯 C++ `std::thread`，无 autorelease pool**：PAL 侧逐帧调用的函数必须自带 `@autoreleasepool`（+13.8MB/60s → +0.5MB/60s）。
- 真机「卡死 + signal 9」要能区分 jetsam 与解码追赶失败 → DEBUG 剖面行恒带 `footprint` 与 `nonok/s`。
- 真机剖面用 `devicectl device process launch --console` + **stderr**；设备锁定报 error 7，测前先解锁。

## 10. 排障纪律
- **flaky 消除的判定 = 根因机制闭环 + 失败签名可解释**（P33）。
- **并发 bug 的验收一定是 A/B 单变量对照**（P77）：两个二进制交错跑，报「未修复 x/N 崩 vs 修复 y/N」+ 巧合概率。偶发 SIGSEGV 先看 `~/Library/Logs/DiagnosticReports/*.ips`：`std::map/std::deque` 树平衡/迭代器帧 = **并发写坏容器**。
- **跨线程共享容器：顺序对了 ≠ 互斥对了。** 注释出现「回调 / 另一线程 / 异步」就问「那把锁是谁」；不变量写在**头文件成员旁**。
- 异步命令「等待落地」等**目标效果本身**，不要等版本号越过基线。
- 框架回调「被触发」≠「成功」；一律有限超时 + 诚实错误码。
- **引用「实测无 error」必须注明校验层开关状态**（P65/P61）：Metal API Validation 开与关改变运行时合法性。
- 手法：给可疑分支加「分支名 + 内核状态码 + 计时」临时诊断，全量复跑抓现行。

## 11. 相机模块（B/C 期，ADR-0014）
- 检测观测 = 图像归一化坐标、origin 左上、0...1；Vision 左下翻转**只在转换层做一次**。
- 采集/渲染/检测三队列互不阻塞，检测 latest-wins；平滑状态只在检测队列持有。
- iOS 17+ 的 Vision 类型收进 `@available` 分支或用基类持有。
- **特效 = App 层资产**，SharedUI 只持契约 + 默认 CI 兜底；引擎注入 `CameraBeautyEngine.smoothing`，**加载失败回落默认，引擎永不制造黑帧**。
- CIKernel：编译链接**都要** `-fcikernel` 且用 `metal`（`xcrun metallib` 可能产出 96 字节空壳）；验收 = `strings` 查 kernel 名 + 看大小（正常 ~8.4KB）。
- **drawable 走渲染 pass，不走 blit**（CAM-016）：终态 = 中间纹理 → 显式 UV 渲染 pass → drawable 保持 `framebufferOnly = true`。
- **三套方向枚举 landscape 命名互换**（P67）：`UIInterfaceOrientationLandscapeLeft` ≡ `AVCaptureVideoOrientation.landscapeRight`；映射只准落在 `CameraManager.rotationAngle/videoOrientation` 一处。
- 相机页 UI 栈：SwiftUI + UIViewRepresentable(MTKView)，**不引 SnapKit/RxSwift**。双摄开关独立于前后翻转按钮。
- **人像能力算法驱动定则**（传哲 2026-10-07，ADR-0032 提案待落账）：无算法即无效果，nil → 直通，不退化为全画面滤镜。

### 11.1 CI 色彩域与蒙版契约（CAM-018/019）
- **CIContext 一律显式 `workingColorSpace`（gamma sRGB）**（P80）；新增 CI 消费方先核域再调参。
- **区域化三态契约**：`apply(to:faces:)` —— nil=全画面兜底、[]=**直通**、非空=归一化框（左上）→ 蒙版。
- **CIImage DAG 宿主脚本先行**（P81）：已实锤 `CIRadialGradient` extent 有限、`cropped` 只做交集、`CGPoint+CGVector` 不存在。
- **跨会话半成品接线**（P89）：引用未实现的符号会让整包编不过；收工时至少 grep 新引用符号的全部定义。

## 12. 日志：三维模型与 workflow 筛选（CORE-010）
- 三维正交：**Level** / **Stage**（帧级 trace）/ **Workflow**（core/model/import/demux/decode/framecache/preview/render/export/camera/gfx/perf/mem/ai）。
- 前缀 `[wf:xxx]`；真机切换靠环境变量（`CQ_LOG_LEVEL` / `CQ_LOG_WORKFLOW` / `CQ_LOG_WF_LEVEL`），**不改代码不重编译**。App 侧最早处调 `configureLogFromEnvironment()`。
- 分级：「系统正在偏离正轨」（降级、队列/追帧上界命中、慢调用、看门狗）一律 **Warn 且 Release 可见**；「我想看细节」才 Debug/Trace。
- 硬规则：走 `CQ_LOG_*_WF(wf, ...)`，禁裸 `fprintf`；慢调用统一 `CQ_SLOW_CALL_WF`（`core/base/perf.h`，500ms），**不许自抄 RAII**；**Debug-only 诊断在 Release 包里等于不存在**（P76）；**改了依赖 NDEBUG 的代码必须 Debug + Release 双向编译验证**。

## 13. 构建验证纪律（iOS 侧）
- **iOS App 编译验证必须 `-scheme ChuanqiCutApp`**：否则 Pods 静态库 target 单独 BUILD SUCCEEDED 是假绿（P61）；日志 `Target dependency graph (1 target)` 是线索。
- **不确定某 Swift 文件是否被真编译 → 塞 canary（`1 + "x"`）跑一次**。
- **`swiftc -parse` 绿不是绿**（P46/P48/P49/P78）：唯一合格形态 = **iphonesimulator SDK 全量 `-typecheck` 且带 `-swift-version 6`**；任务卡出现 `-parse` 应直接驳回。
- 外部/其他会话产物进主干前必须在合并侧跑完整门禁；归属不清用 `git diff --cached origin/main -- <dir>` + `git log --all -S <symbol>` 定位。

## 14. Apple 端工程与门禁（ADR-0021 / CODE-001）
- "cannot find X in scope" 先查工程引用（xcodeproj 是 xcodegen 产物、不入库、易陈旧）。
- 改工程顺序：**`project.yml` → `xcodegen generate` → `bundle exec pod install`**（顺序不能反）。xcodegen 2.46 三坑：不写 `PRODUCT_NAME`、`excludes` 必须 glob、Metal flag 塞不进去。
- **门禁 = `tools/ci/run_gate.sh`**（deps + PAL 头纯净 + Debug/Release 全量单测 + XCFramework + Swift 绑定 + SharedUI + golden，一票否决）。
- 风格唯一标准 `docs/CODESTYLE.md`；巡检落 `docs/reviews/`；文档命令路径必须真实存在（P58）；脚本写 `${var}`（bash 3.2，P50）。
- 多人共用机器加 `-derivedDataPath` 隔离。
- **合并/同步后必查冲突标记残留**（P59）：注意 `tests/golden/*.py` 有 45 字符 `=====` 注释分隔线。
- **push 被拒第一反应**：`(fetch first)` ≠ 权限问题，先 `git fetch` 再看真值（本地 `origin/*` 可能是过期快照）。

## 15. 播放器域边界（UIA-015 / ADR-0022）
- **AVFoundation/AVKit 只许出现在 `SharedUI/.../Player/` 五个文件**；控制层、PlayerViewModel、App target 一律不 import；跨文件传「不点名的不透明值」。
- **SharedUI 新代码按 Swift 5.5 可解析风格写**（显式 `guard let x = x`、不用 `any P`）—— 本机 swiftc 5.5 是唯一静态验证手段之一。

## 16. 智能成片（ADR-0020）
- **原始素材默认不出设备**：上云只有 FeatureReport，人脸只报 count/area_ratio；可选帧上传须显式授权。
- LLM 输出 = EditPlan（`cq.editplan/1`，**动词集 9**），非时间线；时间一律 `{value,timescale}`（120000）；未知 schema 拒绝降级不发猜；未知**字段**忽略、未知 **op/转场/schema** 拒绝。C++ 校验器唯一权威。
- AI 产物全走 Command（一次应用 = 一个可撤销批次），禁止直改 ModelSnapshot。
- 离线降级是产品能力；语音走系统 STT，音频不上传；上线前过法务。

## 17. 构建环境
| 机器 | 系统 / 工具链 |
|---|---|
| A（早期"本机实测"） | macOS 15.4 / AppleClang 17（Intel i7 + AMD GPU，**无 ANE、无 ProRes 硬编**） |
| B | macOS 13.7 / Xcode 15.2（Swift 5.9.2）；`swift-tools-version:6.1` 解析不了属环境上限 |
| C（claimed） | macOS 26.7.1 / Xcode 26.6 —— 与本机实测（2026-10-08：macOS **12.7.6** / Xcode **13.1** / Swift **5.5.1**，无 cmake/ninja/brew）**矛盾**，见 P90 |

- B 机 `pip3 install --user cmake` 后 `export CMAKE_BIN=$(ls ~/Library/Python/*/bin/cmake | head -1)`。
- 跨工具链兼容：`::va_list` + `<cstdarg>`；不对 volatile 复合赋值/自增。本机无 brew：xcodegen 取 GitHub Release 二进制放 `/usr/local/bin`。

## 18. 编号纪律（ADR-0019 §4）
- **任务 ID / ADR / pitfalls P 号取号前先 `git fetch` 核对远端已用号**；处理原则：**改动面小的一侧让位**。集成机是唯一发号器，每线一次领 5 个号。
- 引用清扫按**主题上下文**精确替换，禁止全局 sed。
- 已裁定撞号：UIA-015/016（编辑器线让位 → UIA-032/033，021~024 → 034~037，ADR-0022 → 0024，RESEARCH-006 → 008）；CAM-015/016（→ **CAM-018/019**，P62/P63 → **P80/P81**）。

## 19. 悬而未决（需传哲拍板，AI 不得代决）
1. **FFmpeg LGPL v2.1+ 链接处置**（目标文件归档 / 商业授权 / 动态链接 / 改平台原生）—— 需法务，已确认延后不阻塞。
2. 性能基线未建立（PERF-001 未做），文档性能数字仍是估算；本机 Intel Mac 无 ANE、无 ProRes 硬编，**不得采样本机数字**。
3. 上述两项 + `tools/perf/` 处置待办，交另一 agent：`docs/tasks/TODO-2026-10-07-播放器域收尾待他人接手.md`。
4. 本机工具链与 MEMORY §17「机器 C」不一致，谁把 C 机数字落到 baselines 需先澄清（P90）。
