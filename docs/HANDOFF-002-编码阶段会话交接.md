# HANDOFF-002：编码阶段会话交接（2026-09-28 10:20）

> 上一轮会话上下文已到上限，本文件承载接手所需的全部关键上下文。
> 新会话**先读本文件 + `.ai/source/AGENTS.root.md`（根规则真源）**，再动手。

## 0. 一句话现状

ChuanqiCut（跨平台视频编辑 SDK）**在 macOS 上已打通完整编辑闭环**：
读 MP4 → 硬解 → 零拷贝渲染 → 导出 H.264+AAC MP4。
代码**在 iOS SDK（部署目标 iOS 16）下也能编译产出静态库**。
**未完成**：把三个切片合并成 `.xcframework` 的最后一步打包。

仓库：`main`，26 个 commit，工作区干净，CTest **22/22** 全绿。
最后 commit：`8c2f6d4`。

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

## 3. ⚠️ 未完成：XCFramework 合并（最后一步打包）

**现象**：`tools/build/build_core_apple.sh --config=Release` 能编出三个切片
（ios-device / ios-sim / macos 各自的 `ChuanqiCut.a`），但在
`xcodebuild -create-xcframework` 处失败：

```
error: unable to find any architecture information in the binary at
       '.../ios-device/ChuanqiCut.a': Unknown header: 0xb17c0de
```

`0xb17c0de` 是 bitcode 的 magic（非 Mach-O）。

**已试且已撤销**：加 `-fno-embed-bitcode` → 该 Xcode 的 clang 报
`unknown argument`，已撤销。**不为绕过打包问题而破坏编译。**

**传哲指示（2026-09-28）**：**bitcode 不要开**。
→ 因此接手时**先做一件事**：确认 `.a` 里到底有没有 bitcode 段
（`otool -l` 看有无 `__LLVM,__bitcode`，或 `ar -t` / `nm` 辅助判断）。
**若未开 bitcode 却仍报此错，说明根因不是 bitcode，需要重新定位**（不要沿用我的推测）。

**备选方向**（供新会话判断，不要盲从）：
1. 若确实含 bitcode：在 iOS 切片构建时用 `xcrun bitcode_strip ... -r -o` 剔除后再合并
2. 或者不合并，直接以「各平台 `.a` + `core/include` 头文件」交付（XCFramework 只是分发便利）
3. 或用 `-allow-internal-distribution` / 检查 `libtool` 是否应用 Apple 的 `libtool`（脚本已用 `xcrun libtool`）

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

1. **修 XCFramework 合并**（真机路径最后一步）——先按第 3 节确认根因是否为 bitcode
2. **AUDIO-001**（音频图/PCM 缓冲）→ 闭合源音频环
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
