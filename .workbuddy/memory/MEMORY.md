# ChuanqiCut 项目长期约定

## 用户与协作偏好（传哲）
- 称呼：传哲。直接、少废话，不要「好的/很高兴为您」这类填充语。
- 要求**批判性审视**：发现事实错误、未验证假设、矛盾点直接指出并给依据。
- 交付判定 = 门禁通过，**不接受「已完成」自述**。必须报：执行了什么命令、通过/失败、剩余风险。
- 数字可追溯：估算标 `[E]`，推测标 `hypothesis`，实测才能作验收阈值。
- 他不介意我推翻自己上一轮的结论——给理由即可（已发生过两次）。

## 项目定性
- 跨平台视频编辑 SDK + 各端原生 App。`core/`=C++20 内核，`pal/`=平台适配，`apps/`=原生 UI。
- **iOS / macOS 是 P0** → Android(P1，必须给方案) → HarmonyOS(P2，仅接口编译检查，本期不动)。

## 不可协商的基线
- 性能基线 = 高端满足、**中端可用**、**明确不适配低端机**（不为低端机写专用降级路径）。
- 保留「能力缺失降级」（无硬解→软解、无 compute→fragment）——中端机也可能缺某项能力。
- Shader 双层：Portable（`shaders/src/`，禁平台扩展）+ Platform-Native（`pal/<platform>/shaders/`，永远可选、收益 < 20% 不合并）。
- **修性能前先分段埋点**（曾因没埋点误判"渲染慢"，实测取帧占 94%）。挪线程 ≠ 提帧率。
- 最低系统版本 **iOS 16 / macOS 15.4**（ADR-0010）；容器只支持常用子集（17 demuxer）。

## AI 协作机制
- 单一真源 `.ai/source/AGENTS.root.md` → `tools/ai/sync_context.py` 生成五份入口文件。**改规则改真源再跑脚本**，禁止手改生成物。
- 编码阶段：**一个任务一个新会话**，开场读真源 + 模块文档 + 任务单卡。

## 上下文同步（收工前必须逐项落盘）
清单真源见 `AGENTS.root.md`「任务结束必须同步上下文」一节。8 项：
`.ai/modules/` → ADR（**改了既有惯例就必须新增**）→ TASK 卡 → HANDOFF → pitfalls →
baselines → 当日日志 → MEMORY.md（新硬规则写这里，不留在日志里）。
⚠️ 这条原本只有 4 行泛泛描述，导致连续两轮漏 `.ai/modules/` 和 ADR —— **模糊的"要回写"等于没写**。

## 编号纪律（2026-10-04 定）
- **任务 ID / ADR / pitfalls P 号取号前必须 `git fetch` 核对远端**（已多次双机撞号）。
  冲突时**改动面小的一侧让位**；引用清扫按主题上下文精确替换，禁止全局 sed。
- 三线并行起（CODE-001）：**集成机是唯一发号器**，每线一次领 5 个号，登记即占号。

## 产物打包约定（2026-09-29/30 定）
- **分发的静态库一律不开 LTO**（`build_core_apple.sh` 默认 `--lto=off`）：Release+LTO 产出
  bitcode-only `.o`，`xcodebuild -create-xcframework` 直接拒绝。日常/CI/单测仍开 LTO，
  项目开关 `CQ_ENABLE_LTO_RELEASE`（不能 `-DCMAKE_INTERPROCEDURAL_OPTIMIZATION_RELEASE=OFF`，
  它是 `FORCE` 写的，命令行 `-D` 会静默失效）。
- **打包后必须做消费者侧链接冒烟**（`tools/build/smoke_link.cpp`）：xcodebuild 成功 ≠ 能链接运行。
- **静态库一律命名 `lib<Name>.a`**：曾用名 `ChuanqiCut.a` 使所有 `-lNAME` 失效，且
  `swift build` 只编译不链接会全绿，直到 `swift test` 才炸。
- Swift 绑定验收两条路径：`swift test`（SPM）+ `run_smoke.sh`（swiftc 直编，不依赖 binaryTarget）。
- `.gitignore` 目录规则必须写成 `/dir/` 锚定根（裸 `build/` 曾把 `tools/build/` 一并忽略）。

## 分层与链接硬规则（2026-10-02 定）
- **core 不调 PAL 工厂**（全库 grep 可核）。cq_core 若引 PAL 符号，无后端的平台会链接失败。
- 确需调时**隔离在独立 TU**（静态库按 archive member 拉符号）：现有
  `pal_frame_provider.cpp`、`cq_sdk_preview.cpp`。回归：`cq_tests_c_abi` 只链 `cq_core` 必须通过。
- **抽象放哪层看实现必然落在哪**。只能平台原生实现的放 PAL；上层要用走逃生口
  （`IGfxDevice::PalDevice()` / `IGfxEncoder::PalEncoder()`）。

## 跨层句柄与链接硬规则（2026-10-03 定，UIA-003）
- **契约写了「reinterpret 为平台对象」的句柄，必须有跨层测试真的 reinterpret 并消费**（P20）。
  导出用（裸原生纹理）与 SetTexture 用（CqTexture* 包装）两种语义已在 `pal/gfx.h` 写清，不得混用。
- **系统框架依赖清单单一真源 = `ChuanqiCut.podspec` 的 `ss.frameworks`**；
  `bindings/swift/Package.swift` linkerSettings 与 `run_smoke.sh` 必须同步（P23）。
- Intel Mac + AMD GPU / macOS 15.4 上 `MTLTexture.getBytes` 读不到 GPU 写入内容：
  读回一律 blit→Shared Buffer→contents（P21）。

## 模型变更硬规则（2026-10-03 定，MODEL-002）
- **Timeline 只能经 CommandHistory 变更**（红线 #5 执行点），绕过直改会让 Undo/Redo 静默失效。
- Add/Insert 的 Redo 必须走 `RestoreTrack/RestoreClip` 恢复原 id（回放不能重新分配 id）。
- 编辑类命令只存增量；结构类只允许持有单个实体；**模型级快照一律禁止**。
- **新 ABI 返回值语义必须单一**：错误码 XOR 数据（P26），条数走 out 参数。
- **mv/rm 源文件后立即 grep 引用并重跑受影响脚本**（P27）。

## 时间线交互硬规则（2026-10-03 定，UIA-005 / ADR-0012）
- **拖拽期间不提交命令**，松手提交一条 Move/Trim。**不引入 coalescing**（会污染 Undo 栈）。
- **提交后必须主动回内核真值**（`refreshFromKernel()`）：内核拒绝不触发 observer 回流，
  不回查会留"幽灵片段"。代价是成功时旧值回弹一次——正确性优先。
- Undo/Redo 也是 session 线程操作，走异步入队；空历史在 session 线程失败。
- **撤销栈能力走原子量**（`can_undo_/can_redo_`），不得直读 CommandHistory。
  `cq_session_can_undo/redo` 返回 0/1 数据不是状态码。
- **裁剪只改 duration 不动 source_in**；左边缘裁剪是另一条命令，本期不做。
- **异步测试同步点 = 哨兵法**（P31）：基准版本提交前读，目标 = base + 预期成功数 + 1。
- **测试里 #filePath 上溯链不得手写**（P30）：用 TestPaths.root / RepoPath.root。

## 依赖治理硬规则（ADR-0008）
- FFmpeg upstream 用 GitHub 官方镜像；**git 依赖一律 `pin="commit"` + 40 位 hash，禁 `pin="tag"`**。
- 「定期拉最新」= 人工 bump `pin_ref` + 完整 CI，**绝不允许 CI 自动跟随分支/HEAD**。
- `version` 字段必须 `git ls-remote` 核对（已发生 6 处编造版本号，E6）。

## FFmpeg 授权档位（传哲 2026-09-25 明确）
- **不用 GPL、保持 LGPL**：`LGPL-2.1-or-later`、`CONFIG_GPL=0`、`CONFIG_LGPLV3=0`、`profile=demux`。
- ⚠️ **LGPL ≠ 无义务**：静态链接要求接收者能替换库版本并重新链接。当前产物未接入任何
  构建目标 → 义务未触发；将来分发需选 relink / 目标文件归档 / 商业授权 / 动态链接之一。
- **架构约束**：PAL Media 接口不得依赖任何 FFmpeg 类型（禁 `AVFormatContext`/`AVPacket`），
  否则"接入 FFmpeg"与"走平台原生"之间的切换会变成跨层返工。

## 悬而未决（需传哲拍板，AI 不得代决）
1. FFmpeg LGPL v2.1+ 的链接处置（+法务）。已确认延后，不阻塞开发。
2. 性能基线未建立（PERF-001 未做），文档中所有性能数字仍是估算。

## 预览取帧与共享命令队列（2026-10-04 定，UIA-010 子步骤 5）
- **取帧/渲染只在 `PreviewPump` 泵线程**，主线程只做 Request 与 Lock→blit→Unlock。泵由内核拥有。
- **挂泵后禁止再调 `cq_preview_render_frame`/`cq_preview_resize`**（解码会话与
  CVMetalTextureCache 不可并发访问）；改尺寸走 `cq_preview_pump_request_resize`。
- **消费端持锁期间不要调 Request**（同锁死锁，P36 实踩），也不要 `waitUntilCompleted`。
- **UI 侧 blit 必须用内核共享队列**（`cq_preview_shared_queue`）：Metal 只保证同队列顺序。
- 请求合并是合并"画面"不是"命令"（后者会丢一次编辑）。

## 解码接缝硬规则（2026-10-04 定，MEDIA-021）
1. 取帧循环一律**先 Feed 一包再连续 PopFrame**（B 帧未喂入时重排判据无信息，P39）。
2. **平台解码器回调序 = 完成序（≈dts 序），不是显示序**（P39）。
3. 区间归属依赖 duration 报准；首帧兜底用 dts 差（P40）。
4. **异步解码器 Flush = 先等在途落地、再清**（P41）。
5. seek 目标被消费后重复同目标请求必须重新 seek。
6. 测试请求网格用整数 ticks 构造（浮点截断会污染断言）。

## flaky 排障硬规则（2026-10-04 定，P33）
1. **「N 次全绿」只是概率证据**，必须配合失败签名闭环。flaky 消除的判定 = 根因机制闭环。
2. **异步命令"等待落地"不能拿版本号差值当判据**（任何在途命令都可能推版本）——
   等目标效果本身（如 `queryTracks` 出现视频轨）。
3. **框架回调"被触发"≠"成功"**；对平台回调的无限等是挂死隐患，一律有限超时 + 诚实错误码。
4. 排障手法：给可疑分支加「分支名 + 内核状态码 + 计时」临时诊断，全量复跑抓现行。

## 相机模块（B 期，2026-10-04 定）
- **观测坐标契约**：归一化坐标、origin 左上、两轴 0...1。Vision 的左下原点翻转**只在
  检测器转换层做一次**（`visionPointToImageNormalized`），消费方不得再翻。
- 采集/渲染/检测三队列互不阻塞，检测 latest-wins；`onResult` 交付的观测已平滑。
- iOS 17+ 才有的 Vision 类型，其**类型引用也必须收进 `@available` 分支**或用基类持有。
- **相机特效 = App 层资产**（`iOSApp/Camera/Effects/`，ADR-0014 §3）：不进 SDK shader 清单；
  SharedUI 只持契约层 + 默认 CI 兜底。引擎放弃/加载失败**必须回落默认实现**，永不制造黑帧。
- 相机 Swift 合入前必须过 **iphonesimulator SDK 全量 -typecheck**（P46/P48：-parse 两次放过真错误）。

## 智能成片硬规则（2026-10-04 定，ADR-0019）
- **原始素材默认不出设备**：上云只有 FeatureReport（KB 级聚合）+ 用户消息；人脸只报
  count/area_ratio，不做识别。可选帧上传须显式授权，默认关闭。
- **LLM 输出 = EditPlan action 列表**（8 动词封顶），不是时间线；时间一律
  `{value, timescale}` 且 timescale==120000，**浮点秒非法**；未知 schema 拒绝并降级。
- **AI 产物全走 Command**，同一撤销栈，一次应用 = 一个可撤销批次。
- **离线降级是产品能力**：三连失败 → 本地规则引擎出同 schema plan，UI 明示"离线模式"。

## 构建环境约定（多机事实，2026-10-05 更新）
开发机至少三台，**引用 baselines 数字必须连同环境**：
| 机器 | 系统 / 工具链 |
|---|---|
| A（早期全部"本机实测"） | macOS 15.4 / AppleClang 17（Intel i7 + AMD GPU，无 ANE、无 ProRes 硬编） |
| B | macOS 13.7 / Xcode 15.2（AppleClang 15） |
| C（当前） | macOS 26.7.1 / Xcode 26.6（iPhoneSimulator 26.5 SDK） |
- B 机构建：`pip3 install --user cmake` 后 `export CMAKE_BIN=$(ls ~/Library/Python/*/bin/cmake | head -1)`。
- 跨工具链兼容：不用 `std::va_list`（用 `::va_list` + `<cstdarg>`）；不对 volatile 复合赋值/自增。
- **Apple 端没有 brew**：xcodegen 取 GitHub Release 二进制放 `/usr/local/bin`（见下节）。

## Apple 端工程与构建硬规则（2026-10-05 定，P54-P56 / ADR-0021）
- **"cannot find X in scope"先查工程引用，不要先怀疑没提交**。xcodeproj 是 xcodegen 生成产物、
  不入库，极易陈旧（曾只剩 1/12 源文件引用，11 个文件从未编译）。
  核对法：`git ls-files <dir>` vs `find` vs `grep .swift project.pbxproj`。
- 改工程一律改 `project.yml` 真源 → `xcodegen generate` → `bundle exec pod install`
  （**顺序不能反，generate 会清掉 Pods 注入**）。
- **xcodegen 2.46 三坑**：不写 `PRODUCT_NAME`（→ `Multiple commands produce .../.app`）；
  `excludes` 必须用 glob（`**/x.metal`，相对路径不生效）；Metal 编译 flag 塞不进去
  （`MTL_OTHER_FLAGS` / source 级 `compilerFlags` 都不落地）。
- **CoreImage CIKernel 不走 Xcode 内建 Metal 阶段**：编译和链接**都要** `-fcikernel` 且都用
  `metal`（不是 `metallib`）。只给编译加 + 用 `xcrun metallib` 链接会产出 96 字节**空壳**
  （退出码 0、编译全绿，运行时查不到 kernel → 静默降级）。
  验收：`strings` 查 kernel 名 + 看大小（正常 ~8.4KB）。已实测签名构建下产物被纳入 `CodeResources`。
- 多人/多会话共用机器时加 `-derivedDataPath` 隔离，否则撞 `database is locked`。

## 门禁与守门（2026-10-05 定，CODE-001）
- **门禁 = `tools/ci/run_gate.sh`**（INFRA-010：deps + PAL 头纯净性 + Debug/Release 全量单测
  + XCFramework + Swift 绑定 + SharedUI + golden，一票否决）。
- 远端"已验证"一律按未验证处理；合并后跑 gate + cq-code-review 流程 A（写集越界 + typecheck）。
- **风格唯一标准 = `docs/CODESTYLE.md`**；巡检记录落 `docs/reviews/`。
- **文档/skill 里的命令路径必须真实存在**（P49）；仓库脚本 `$var` 一律写 `${var}`（bash 3.2 坑，P50）。
