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

1. **BIND-001（C ABI 绑定层）**——最高优先级，xcframework 要能被 Swift App 消费必须先过这关（§3b）
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
