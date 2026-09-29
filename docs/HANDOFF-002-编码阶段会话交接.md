# HANDOFF-002：编码阶段会话交接（2026-09-28 10:20）

> 上一轮会话上下文已到上限，本文件承载接手所需的全部关键上下文。
> 新会话**先读本文件 + `.ai/source/AGENTS.root.md`（根规则真源）**，再动手。

## 0. 一句话现状

ChuanqiCut（跨平台视频编辑 SDK）**在 macOS 上已打通完整编辑闭环**：
读 MP4 → 硬解 → 零拷贝渲染 → 导出 H.264+AAC MP4。
代码**在 iOS SDK（部署目标 iOS 16）下也能编译产出静态库**。
2026-09-29 更新：**三个切片已合并成可用的 `ChuanqiCut.xcframework`**（根因是 LTO，
不是当初推测的 bitcode，详见 §3）。**但 xcframework 暂无 C ABI，Swift App 接不上，
需先做 BIND-001（见 §3b）**。

仓库：`main`，26 个 commit，工作区干净，CTest **22/22** 全绿（Debug / Release 各跑通）。
最后 commit：`8c2f6d4`。（本轮 XCFramework 修复尚未提交）

## 1. 已完成清单

| 任务 | 内容 | 验收 |
|---|---|---|
| INFRA-001/002 | monorepo 骨架、CMake 顶层、C++20 内核可编译、CTest、`-Werror` | 10 个 target 可见；`-Werror` 经故意触发实验证明会失败 |
| DEPS-001/002 | 依赖清单 schema + 解析器 + `deps.lock` 生成/校验 | selfcheck 18/18；占位 sha256 被拦；防篡改双保险；输出确定性 |
| DEPS-010 | FFmpeg demux 常用档位（17 demuxer / 13 parser / 5 bsf） | 2.22 MiB；GPL 符号扫描 0；`CONFIG_GPL=0` |
| QA-001 | golden 样本库 21 段 | ffprobe 实测校验，21/21 |
| CORE-001~005 | base 层：时间 / 错误 / 日志 / 内存 / 并发 | 单测合计 200+ 项 |
| CORE-006 | **PAL 接口冻结**（8 领域 + 静态门禁） | 零平台类型门禁；评审通过 |
| GFX-001 / MEDIA-010 | 跨平台 GFX / FrameProvider 接口 | — |
| MEDIA-020 | SystemFrameProvider（精确 seek） | mock 验证 kExact 命中 B 帧 |
| PALA-001 | Metal 渲染后端 | 离屏渲染 + 读回像素断言（清屏红、四色纹理四角） |
| PALA-010 | Apple 解封装（AVAssetReader） | 150 帧 / pts 单调 / 关键帧与 ffprobe 5/5 逐帧吻合 |
| PALA-011 | VideoToolbox 硬解 | 端到端打通；解码像素 (0,190,0) ≈ 真值 (0,188,0) |
| PALA-002 | CVPixelBuffer→CVMetalTexture 零拷贝 | IOSurface 一致性 + 耗时 1407× |
| PALA-012 | AVAssetWriter 导出 H.264 MP4 | ffprobe：h264 / 1920×1080 / 帧数 60 / 2.0s |
| IMediaMuxer | 跨平台封装接口（补冻结接口缺口） | 平台无关调用证明（不 include 平台头） |
| 音频 AAC | `AddAudioTrack` / `WriteAudioFrame` | ffprobe：index=1 = `aac / 48000 / 2ch` |
| MEDIA-011/012 | 帧缓存 LRU + 解码器池 | 上界 800≤1000；超路数返回 `kResourceExhausted` |
| 性能埋点 | `core/src/base/perf` | Release 可用、可采样、挂到 AcquireFrame |
| docs/BUILD.md | 构建与门禁说明 | 含"产物不入库"关键前提 |

## 2. 能力链路

```
读 MP4 (PALA-010) → 硬解 (PALA-011) → 零拷贝导入 (PALA-002) → Metal 渲染 (PALA-001)
                                                              ↘ 导出 H.264+AAC (PALA-012)
                          帧缓存 (MEDIA-011) / 解码器池 (MEDIA-012)
```

**已知断点（诚实记录）**：
- **源音频环未打通**：PALA-010 是 passthrough demux，只读 AAC 压缩包、不做 AAC→PCM 解码。
  所以"从源视频取音频再写入"需 **AUDIO-001**（音频图）才能闭合。
  当前只能写**合成 PCM**（已验证）；不要把"合成 PCM 能写"说成"源音轨已打通"。

## 3. ✅ XCFramework 合并已修（2026-09-29 完成）

**旧推测是错的**：不是 bitcode 嵌入，是 **LTO**。

**真因**：`cmake/CompileOptions.cmake` 开了 `CMAKE_INTERPROCEDURAL_OPTIMIZATION_RELEASE=ON`。
Release + LTO 时 clang 产出 **bitcode-only 目标文件**（头部 magic `0x0b17c0de`，紧跟
`BC\xc0\xde` 的 LLVM IR），**不是 Mach-O**。`xcodebuild` 因此读不到架构信息。
与 ENABLE_BITCODE / `-fembed-bitcode` **无关**——所以当初加 `-fno-embed-bitcode` 方向就错了。

**踩到的第二个坑**：原写法是 `set(... CACHE BOOL ... FORCE)`，**`FORCE` 会让命令行
`-DCMAKE_INTERPROCEDURAL_OPTIMIZATION_RELEASE=OFF` 静默失效**（第一次修复传了 OFF，
cache 里仍是 ON，`.o` 还是 bitcode，且产物字节数与之前完全相同才被察觉）。
→ 已改为项目显式开关 `option(CQ_ENABLE_LTO_RELEASE ... ON)`，打包脚本传 OFF。

**验证（2026-09-29 实测）**：
- 三切片 `.o` 头部由 `dec0170b` 变为 `cffaedfe`；`file` 报 `Mach-O 64-bit object arm64`
- xcframework 三切片：`ios-arm64` / `ios-arm64_x86_64-simulator` / `macos-arm64_x86_64`
- 消费者侧真实链接并运行 macOS 切片：输出 `StatusToString(kOk) = OK`
- 主构建 Release **LTO 未退化**（`.o` 仍是 bitcode）；Debug/Release CTest 均 22/22

**新增两道门禁**（防复发）：
1. 合并前预检：`otool -l` 断言切片不含 bitcode，否则带明确根因退出（不再丢原始报错）
2. 合并后链接冒烟：`tools/build/smoke_link.cpp` 真链 macOS 切片并断言输出
   ——理由：xcodebuild 成功只说明是合法 Mach-O，"能被 App 消费"必须试一次

**当前状态**：`build/apple/ChuanqiCut.xcframework`（1.5MB，产物不入库，符合约定）。

## 3b. ⚠️ xcframework 不是给 Swift 用的

`core/include/cq/cq_sdk.h` 目前**只有注释里的示例函数名，没有任何真正的 C ABI 导出**。
`nm -g` 看到的全是 C++ mangled 符号（`__ZN2cq...`）和 ObjC++ 实现符号。
→ **Swift / Objective-C App 现在接不上**，必须先做 **BIND-001（C ABI 绑定层）**。
不要把"xcframework 打包成功"说成"App 可以集成了"。

## 3c. ✅ CORE-007 能力查询已实现（2026-09-29）

`capabilities.h` 在 CORE-006 里只冻结了接口，
`SetCapabilitiesBackend` / `QueryCapability` **长期只有声明无定义**——唯一引用是
`pal_headers_compile.cpp` 的 `static_assert`（编译期检查、**不链接**），所以 CTest 全绿
看不出来。这是 CORE-006「编译 7/7 全绿但接口是断的」的**同型复发**（记为 pitfalls P2）。

已补：`core/src/pal/capabilities.cpp`（内核注入/分发）+ `pal/apple/capabilities.mm`
（Apple 后端）。要点：
- 解码用 `VTIsHardwareDecodeSupported`（**iOS 11+/macOS 10.13+**，无需守卫）；
  比 PALA-011 的会话探针（iOS 17.0+ 常量）覆盖面更广，iOS 16 上也能如实上报
- 编码无等价直接 API，只能建一次性会话查 `kVTCompressionPropertyKey_...`（**iOS 17.4+**）；
  iOS 16/17.0~17.3 返回 `kDegraded`（**未知，非"没有"**），不抬高部署目标
- 查不到的一律 `kNo` / `kDegraded`，不猜机型、不猜芯片
- 实测结果与本机已知事实交叉吻合（`hw_{de,en}code_prores=no`，Intel Mac 确无 ProRes 硬编）

详细设计与逐项依据：`docs/tasks/TASK-CORE-007.md`；实测数据：`.ai/memory/baselines.md`。
CTest 22 → **24**。

## 3d. ✅ CORE-008 线程模型与队列骨架已完成（2026-09-29）

ARCH-001 §6 此前**只是一张 ASCII 图**：7 类线程角色定义好了，但 Session Thread
不存在，"主线程零阻塞"无从执行也无从验证。

已落地（详见 `.ai/modules/session.md` / `docs/tasks/TASK-CORE-008.md`）：
- `core/include/cq/session/thread_model.h`：`ThreadRole` 枚举 + 运行时角色标记
  （`thread_local`，默认 `kUnknown` —— 不把未标记线程猜成主线程）
- `core/include/cq/session/task_runner.h`：`TaskRunner` 串行执行器，
  `Post()` **非阻塞**（队列满返回 `kResourceExhausted`），复用 CORE-005 的
  `BoundedQueue` + `CancelToken`，不重复发明原语

验收「主线程零阻塞可测」：**实测 `Post()` 内含 100ms sleep 的任务，返回耗时 0.030ms**
（16ms 预算的 1/533）。另测：任务跑在 worker 线程、FIFO 保序、满队列立即失败、
Shutdown 保证 join。

⚠️ 宿主必须记得在主线程调 `SetCurrentThreadRole(ThreadRole::kMain)`，否则守卫失效
（SDK 无法自得知哪根是 UI 线程）——需在 BIND-002 Swift 侧兜住。

CTest 24 → **25**。

## 3e. ✅ CORE-009 EditorSession 门面已完成（2026-09-29）—— 依赖链打通

ARCH-001 §4.1 定义 `session` = 「串起各模块，**对外唯一门面**」。
它是 BIND-001 要冻结成 C ABI 的对象，此前完全不存在，
是整条 `BIND-001 → BIND-002 → 所有 UIA-*` 依赖链的最后缺口。

已落地（详见 `.ai/modules/session.md` / `docs/tasks/TASK-CORE-009.md`）：
- `core/include/cq/session/editor_session.h`：`EditorSession`
  —— `Submit()` 异步不阻塞、`CurrentSnapshot()`、变更日志 `ChangesSince()`、观察者
- `core/include/cq/session/snapshot.h`：`Snapshot{version,digest}` / `ChangeRecord` /
  `ISessionState`（模型层扩展点）

关键约定：
- 版本号**只在变更成功时递增**；失败与取消都不推进（否则 UI 会以为状态变了而错刷）
- 观察者在 **session 线程**回调 —— Swift 侧必须自行 dispatch 到主线程
- 变更在 CORE-008 的 session 线程**串行**执行（Undo/Redo 与三端一致性的前提，红线 #5）

**边界（未越界）**：不定义 `TimelineModel`（MODEL-001）、不定义
`Command`/`CommandHistory`/Undo-Redo（MODEL-002）。状态内容通过 `ISessionState` 注入，
本期用测试实现跑通机制 —— 避免门面变成第三个"断接口"。

CTest 25 → **26**。至此 **BIND-001 的前置全部就位**。

## 4. 当前 iOS 平台差异（已修，勿回退）

为让 iOS 切片可编，已按**平台条件编译 / 诚实降级**处理五处，
**没有删功能、没有用 `-Wno-*` 逃逸、没有抬高 iOS 部署目标（ADR-0010 定 iOS 16）**：

1. `IOSurface`（macOS 专有框架）→ `#if !TARGET_OS_IPHONE` 隔离；iOS 下验证辅助返回 0
2. `MTLStorageModeManaged`（iOS 无）→ `kCqCpuVisibleStorageMode`（macOS=Managed / iOS=Shared）
3. 硬解探针常量要求 iOS 17.0 → `@available` 守卫；iOS 16 不探针，不谎报"已硬解"
4. 硬编探针常量要求 iOS 17.4 → 同上
5. macOS 切片部署目标 `11.0 → 15.4`（ADR-0010）

配套：`pal/apple/CMakeLists.txt` 里 `IOSurface` 的 `find_library` 按
`CMAKE_SYSTEM_NAME STREQUAL "Darwin"` 条件化（iOS 下该框架不存在，`REQUIRED` 会 configure 失败）。

## 5. 门禁（新会话先跑一遍确认基线）

```bash
CMAKE_BIN=/Users/zhuning/.workbuddy/binaries/cmake/CMake.app/Contents/bin/cmake
CTEST_BIN=$(dirname $CMAKE_BIN)/ctest
PY=/Users/zhuning/.workbuddy/binaries/python/versions/3.13.12/bin/python3

$CMAKE_BIN --build build -j4 && $CTEST_BIN --test-dir build      # 期望 22/22
$PY tools/pal/check_pal_headers.py                                # 零平台/零 FFmpeg 类型
$PY tests/golden/verify.py                                        # golden 21 段
$PY tools/deps/deps.py validate third_party/manifest.toml
$PY tools/deps/selfcheck.py                                       # 期望 18/18
```

**Debug 与 Release 都要跑**：本项目出现过 Release-only 缺陷（日志宏 NDEBUG 下不引用参数
→ `-Wunused-variable` 打断构建；测试越界访问 → SEGFAULT）。日常开发在 Debug 下看不出来。

## 6. 不可违反的约定（红线摘录，详见 AGENTS.root.md）

- **内核不用异常**，错误一律 `Status` + `StatusCode`
- **时间一律 `RationalTime`**（timescale=120000，ADR-0009），禁 `operator double`
- **零平台类型 / 零 FFmpeg 类型**（ADR-0010）
- **`-Werror` 零警告，禁止 `-Wno-*` 逃逸**——告警必须改代码
- **注释不能比代码走得快**（发现"注释说有、代码没有"必须修实现或改注释，不许糊弄）
- **PAL 接口已冻结**：允许**新增**接口，**修改既有签名**需先提 ADR。发现冻结接口缺陷**先报告，不要自己改**
- **产物不入库**：clone 后须自行构建 FFmpeg（见 docs/BUILD.md）

## 7. 建议下一步（按优先级）

1. **BIND-001（`cq_sdk.h` 纯 C ABI 冻结）** ✅ **前置已全部就位**
   —— 依赖链 CORE-007 → CORE-008 → CORE-009 全部完成（2026-09-29）。
   现在冻结的 C ABI 终于有 **EditorSession 这个真实门面**做支撑，
   不会再是"接口冻结但实现是断的"（CORE-006 / CORE-007 两次教训）。
   冻结范围建议：`EditorSession` 生命周期 + `Submit` + 快照查询 + `ChangesSince`。
   ⚠️ 冻结前先确认：Swift 侧拿到的是 **session 线程**的观察者回调，
   必须自行 dispatch 到主线程（BIND-002 处理）。
2. **AUDIO-001**（音频图/PCM 缓冲）→ 闭合源音频环（当前只能写合成 PCM，源音轨未通）
3. EXPORT-001（导出控制器：状态机/进度/取消/错误码）
4. MEDIA-030（音画同步）
5. BIND-002 → UIA-002 → UIA-003（App 壳：依赖链未到，**UIA-003 现在不能开始**）
6. iPhone 17 Pro 真机实测（传哲要求：届时打开性能埋点直接看数据）

## 8. 本轮值得记住的教训

1. **绿灯 ≠ 可用**：CORE-006 编译验证 7/7 全绿，但接口其实是断的（RenderTarget 创建后
   无法传给 encoder）。接口冻结后要尽早让真实实现跑通端到端最小路径。
2. **mock 会掩盖平台缺陷**：B 帧 seek 的 mock 掩盖了 3 个平台后端问题，升级到真实文件才暴露。
3. **Release-only 缺陷危险**：日常 Debug 全绿，第一次打 Release 才炸。
4. **不要为编译通过抬高部署目标 / 放宽编译选项**——用 `@available` 守卫 + 诚实降级。
5. **worker 报告可能过时或不准**（曾把 Release 真实缺陷说成"cmake 重配置瞬态"），
   **必须自己独立复验**，不能照抄结论进交付。
6. **做完完整任务的 worker 上下文会撑到 100k 上限暴毙**——后续任务一律 spawn fresh。
