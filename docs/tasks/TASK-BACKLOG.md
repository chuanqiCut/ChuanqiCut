# TASK-BACKLOG：ChuanqiCut 任务分解（DAG）

> 版本：v1.0（待 Review）
> 日期：2026-09-23
> 上游：`ARCH-001`~`ARCH-005`、`ADR-0001`~`ADR-0007`
> 配套：`docs/ai/AI-COLLAB-001`（上下文与 Skill）

---

## 0. 任务字段规范

每个任务进入实现前必须补齐以下字段，缺任一项不得进入编码：

```yaml
id:          MEDIA-021
layer:       SDK            # SDK | 跨平台 | UI | 基建
goal:        实现 FrameProvider 的 FFmpeg demux 后端
input:       [ARCH-002 §3, ADR-0003, 已冻结的 FrameProvider 接口]
output:      [代码, 单测, golden 测试样本, 模块文档更新]
write_set:   core/src/media/ffmpeg_impl/*, core/include/cq/media/frame_provider.h
read_set:    pal/apple/*, core/src/media/*
deps:        [MEDIA-010, DEPS-012]
acceptance:
  - 与 SystemFrameProvider 在相同 seek 请求下返回同一帧（PSNR ≥ 45dB）
  - 倒放与速度曲线场景可逐帧取帧，无重建开销
  - 体积增量 < 3MB（arm64）
verification:
  - ctest -R media_ffmpeg
  - tools/perf/frame_provider_bench --cases=seek,reverse,ramp
risk:        FFmpeg 构建链三平台不一致
parallel:    false          # 是否与同批次其他任务并行
```

**写集（write_set）铁律**：一个任务一个写集，两个任务的 write_set 不得相交。共享文件（CMakeLists、cq_sdk.h、pbxproj）由 Integrator 单独处理。

---

## 1. 分层总览

| 层 | 前缀 | 内容 | 任务数 |
|---|---|---|---|
| **跨平台层（SDK 内核）** | `CORE` `MODEL` `GFX` `SHADER` `RENDER` `MEDIA` `AUDIO` `AI` `COLOR` `PROJ` `EXPORT` | C++20 共享内核，与平台无关 | 51 |
| **跨平台层（PAL 实现）** | `PALA` `PALD` `OHOS` | Apple / Android / 鸿蒙 的平台适配 | 24 |
| **SDK 绑定层** | `BIND` | C ABI → Swift / Kotlin / ArkTS | 6 |
| **UI 层** | `UIA` `UID` `UIO` | SwiftUI / Compose / ArkUI | 16 |
| **基建** | `DEPS` `INFRA` `PERF` `QA` | 依赖治理、CI、性能、测试 | 21 |
| **合计** | | | **118** |

> **执行顺序原则**：架构按三端设计，但**人力与优化优先保障 iOS/macOS**（重点支持平台）。
> 标了 `[Apple 优先]` 的任务先做；Android 端排期在 Phase 3。

---

## 2. Phase 0 — 地基（内核骨架 / PAL 契约 / 构建 / 治理 / 基线）

目标：三平台能编译出内核，Apple 空壳 App 能跑，性能基线数据入库，依赖治理跑通。

### 2.1 依赖治理与构建（基建）

| ID | 层 | 任务 | 依赖 | 写集 | 验收 |
|---|---|---|---|---|---|
| DEPS-001 | 基建 | `third_party/manifest.toml` 格式与解析器 | — | `third_party/manifest.toml`, `tools/deps/*` | 解析器能校验 SPDX 表达式合法性 |
| DEPS-002 | 基建 | `deps.lock` 生成与校验 | DEPS-001 | `tools/deps/*` | manifest 与 lock 不一致时构建失败 |
| DEPS-003 | 基建 | 协议分级门禁（ALLOW/REVIEW/RESTRICTED） | DEPS-001 | `tools/compliance/*`, CI | 构造 RESTRICTED 依赖时 CI 失败 |
| DEPS-004 | 基建 | 公共头文件第三方符号扫描 | DEPS-001 | `tools/compliance/*`, CI | 引入第三方类型到公共头时失败 |
| DEPS-005 | 基建 | SBOM 生成（CycloneDX + SPDX） | DEPS-002 | `tools/compliance/*` | 每次构建产出 SBOM 并归档 |
| DEPS-010 | 基建 | FFmpeg `demux` 档位构建脚本（Apple universal） | DEPS-001 | `tools/build/build_ffmpeg.sh` | 产物 < 3MB，无 GPL 符号 |
| DEPS-011 | 基建 | FFmpeg `demux` 档位构建脚本（Android NDK） | DEPS-010 | 同上 | 同上，arm64-v8a |
| DEPS-012 | 基建 | FFmpeg 源码集成与二进制集成双路径打通 | DEPS-010 | `third_party/CMakeLists.txt` | 两种集成暴露同一 target，切换不改上层 |
| DEPS-013 | 基建 | 实测并记录 FFmpeg 体积/符号基线 | DEPS-010 | `.ai/memory/baselines.md` | 数据入库 |
| DEPS-020 | 基建 | signalsmith-stretch 接入与构建配置 | DEPS-001 | `third_party/signalsmith-stretch` | 规避 `-ffast-math` + AppleClang16 组合；该模块单独开优化 |
| DEPS-030 | 基建 | glslang + SPIRV-Cross 构建期工具链 | DEPS-001 | `tools/shaders/*` | 构建机能生成 SPIR-V 与 MSL |
| DEPS-031 | 基建 | 模型资产清单 `third_party/models/manifest.toml` | DEPS-001 | `third_party/models/` | 模型登记来源/许可/校验和/张量规格 |
| INFRA-001 | 基建 | monorepo 目录骨架与 CMake 顶层 | — | 仓库根 | 三平台入口存在 |
| INFRA-002 | 基建 | 内核 CMake 构建 + CTest（桌面） | INFRA-001 | `core/CMakeLists.txt` | macOS 上能编译并跑单测 |
| INFRA-003 | 基建 | Apple 构建脚本产出 XCFramework | INFRA-002 | `tools/build/build_core_apple.sh` | 产出含 iOS device/sim/macOS 三切片 |
| INFRA-004 | 基建 | Android Gradle + externalNativeBuild 打通 | INFRA-002 | `apps/android/` | 产出 `.so` |
| INFRA-005 | 基建 | Apple Xcode workspace 与双 target（iOS/Mac） | INFRA-003 | `apps/apple/` | 两个 target 均可编译运行 |
| INFRA-006 | 基建 | CI：编译 + 单测 + 门禁（三平台） | INFRA-002/3/4 | `.github/workflows/` | PR 触发全门禁 |
| INFRA-007 | 基建 | 警告即错误（-Werror）与静态检查接入 | INFRA-002 | CI | 新代码零警告 |
| INFRA-008 | 基建 | `pal/ohos/` 接口编译检查 target（ADR-0007） | CORE-006 | `pal/ohos/` | 接口签名变更时该 target 失败 |
| INFRA-009 | 基建 | Apple 双工程拆分 + CocoaPods 源码集成（owner 决策 2026-10-02，替代 INFRA-005 的单工程形态） | UIA-002 | `apps/apple/**`, `ChuanqiCut.podspec` | 双工程 `pod install` 成功且 macOS/iOS 均编译通过 |
| INFRA-010 | 基建 | 本机总门禁脚本 `tools/ci/run_gate.sh`（多机守门入口，cq-code-review 流程 A 依赖）✅ 2026-10-05 | INFRA-002 | `tools/ci/run_gate.sh` | 一条命令跑完 deps 校验/头纯净性/Debug+Release 全量单测/XCFramework+Swift/golden，一票否决，日志落 `build/gate-logs/` |
| INFRA-011 | 基建 | DEPS-004 落地：静态库符号泄漏扫描（nm 全局符号 + `cq_/CQ_` 前缀白名单） | INFRA-010 | `tools/compliance/*`, `tools/ci/run_gate.sh` | 公共符号含非 `cq_/CQ_` 前缀时门禁失败 |
| INFRA-012 | 基建 | `.clang-format`/`.clang-tidy` 固化 CODESTYLE §1~2 并接入门禁 | INFRA-010 | `.clang-format`, `.clang-tidy`, `tools/ci/run_gate.sh` | 现有代码零 diff（或一次性整形提交单独走） |

### 2.1.1 代码风格统一（CODE-001，2026-10-05 全库巡检产出）

> 风格判定唯一标准 = `docs/CODESTYLE.md`；审查流程 = `.agents/skills/cq-code-review`。
> 巡检明细（每条带 file:line 证据）见 `docs/reviews/REVIEW-2026-10-05-全库风格巡检.md`。

| ID | 层 | 任务 | 依赖 | 写集 | 验收 |
|---|---|---|---|---|---|
| STYLE-001 | 基建 | C++ 测试辅助收敛：新建 `tests/unit/test_util.h` 收编 32 份 `Check()` 复制体（已漂移：test_cache 打印 ok、test_time 不打印） | INFRA-002 | `tests/unit/*` | 全部测试用共享头，失败输出格式唯一 |
| STYLE-002 | 基建 | Swift 测试辅助收敛：`waitForVersion`×6 复制体、TestPaths/RepoPath 命名统一 | — | `bindings/swift/Tests/*`, `apps/apple/packages/SharedUI/Tests/*` | 每包一份共享 helper；测试文件内禁止私有复制 |
| STYLE-003 | UI | `PickerTheme` 并入 `Theme`（消除调色常量双真源与 AlbumPickerScreen.swift:107 混用） | — | `SharedUI/Sources/SharedUI/MediaPicker/*` | Theme 常量单一来源，双端渲染不变 |
| STYLE-004 | 基建 | 「等待内核落地」原语收口（RunLoop 版 / async 版各一），替换三处生产忙等与多处测试手写轮询 | STYLE-002 | `bindings/swift/Sources/*`, `SharedUI/Sources/*` | 等待判据统一为「目标效果」型（P33），超时显式 |
| STYLE-005 | UI | 相机模块风格收敛（**相机线执行**）：FaceObservation 去无意义 `public`、CameraViewModel 去 `ciContext!`、`NSError(domain:"cq.camera")` 收敛为枚举 | — | `apps/apple/ios/iOSApp/Camera/*` | App target 内零 public、零 force unwrap |

### 2.2 内核基础（跨平台层）

| ID | 层 | 任务 | 依赖 | 写集 | 验收 |
|---|---|---|---|---|---|
| CORE-001 | 跨平台 | `base`：RationalTime 与运算 | INFRA-002 | `core/src/base/time.*` | 29.97fps 累计 10000 次步进零漂移 |
| CORE-002 | 跨平台 | `base`：Status/错误码体系 | INFRA-002 | `core/src/base/status.*` | 错误码稳定，跨端一致 |
| CORE-003 | 跨平台 | `base`：日志与帧级 trace | INFRA-002 | `core/src/base/log.*` | 分级日志，可落盘，媒体管线可追溯 |
| CORE-004 | 跨平台 | `base`：内存池 / Arena / 纹理预算记账 | INFRA-002 | `core/src/base/alloc.*` | 可查询当前分配量 |
| CORE-005 | 跨平台 | `base`：并发原语、有界队列、CancelToken | INFRA-002 | `core/src/base/concurrency.*` | 取消语义可测 |
| CORE-006 | 跨平台 | **PAL 接口定义冻结**（GFX/Media/Audio/Inference/FS/Clock/Log/Capabilities） | CORE-001~005 | `core/include/cq/pal/*.h` | 头文件零平台类型；评审通过 |
| CORE-007 | 跨平台 | 能力查询 `ICapabilities` 与枚举 | CORE-006 | `core/src/pal/capabilities.*` | 运行时可查询各项能力 |
| CORE-008 | 跨平台 | 线程模型与队列骨架（ARCH-001 §6） | CORE-005 | `core/src/session/*` | 主线程零阻塞可测 |
| CORE-009 | 跨平台 | `EditorSession` 门面与快照机制 | CORE-006/008 | `core/src/session/*` | 快照版本号递增，UI 可 diff |

### 2.3 性能与测试基线（基建）

| ID | 层 | 任务 | 依赖 | 写集 | 验收 |
|---|---|---|---|---|---|
| PERF-001 | 基建 | **性能基准套件**：解码/渲染/推理逐环节实测 | CORE-006 | `tools/perf/*` | 产出实测数据，替换 RESEARCH-001 中所有 [E] 数字 |
| PERF-002 | 基建 | 设备矩阵与**支持档位门禁**（高端/中端/低端门槛） | PERF-001 | `.ai/memory/device-matrix.md` | 档位门槛确定；**低端机明确不支持**，需有启动检测与提示 |
| PERF-003 | 基建 | 性能门禁（帧时间/内存峰值/导出耗时），以**中端机为下限** | PERF-001 | CI | 超阈值阻断 |
| QA-001 | 基建 | golden frame 样本库（10 段覆盖素材） | — | `tests/golden/` | 素材齐备且有说明 |
| QA-002 | 基建 | PSNR/SSIM 对比工具与容差标准 | QA-001 | `tools/qa/*` | 输出可机读报告 |
| QA-003 | 基建 | 端到端用例：导入→编辑→导出 | MEDIA-020 | `tests/e2e/` | 1080p/4K 各一 |

### 2.4 Phase 0 出口标准

- [ ] 三平台均能编译内核；Apple 空壳 App 在 iPhone/Mac 上启动
- [ ] `PERF-001` 实测数据入库，原调研中所有估算数字被替换或标注为待实测
- [ ] 依赖治理 CI 全绿（协议门禁、符号门禁、SBOM）
- [ ] FFmpeg `demux` 档位产物 < 3MB 且无 GPL 符号
- [ ] PAL 接口冻结并通过评审

---

## 3. Phase 1 — Apple MVP（解码→渲染→预览→导出）

### 3.1 GFX 与 Shader（跨平台层 + Apple PAL）

| ID | 层 | 任务 | 依赖 | 写集 | 验收 |
|---|---|---|---|---|---|
| GFX-001 | 跨平台 | GFX 抽象接口（概念映射表 12 项） | CORE-006 | `core/include/cq/gfx/*.h` | 头文件零平台类型 |
| GFX-002 | 跨平台 | TexturePool 与内存预算控制 | GFX-001, CORE-004 | `core/src/gfx/pool.*` | 超预算时按 LRU 回收 |
| GFX-003 | 跨平台 | 外部图像导入抽象 `INativeImageImporter` | GFX-001 | `core/src/gfx/import.*` | 导入失败可退化为 CPU 拷贝 |
| PALA-001 | 跨平台 | **Metal 后端实现** | GFX-001 | `pal/apple/gfx_metal.*` | 清屏 + 纹理绘制可跑 |
| PALA-002 | 跨平台 | `CVPixelBuffer → CVMetalTexture` 零拷贝 | PALA-001 | `pal/apple/` | 实测零拷贝生效（无 memcpy） |
| SHADER-001 | 跨平台 | shader 编译链：GLSL → SPIR-V → MSL | DEPS-030 | `tools/shaders/` | 生成可读 MSL 并落盘 |
| SHADER-002 | 跨平台 | 反射信息 → 绑定号代码生成 | SHADER-001 | `tools/shaders/` | 绑定号由工具生成 |
| SHADER-003 | 跨平台 | shader 规范检查（禁用扩展/显式精度等） | SHADER-001 | `tools/shaders/lint.*` | 违规 shader 构建失败 |
| SHADER-004 | 跨平台 | **Platform-Native 层机制**：`RenderNode.specialize()` + 运行时选择 + fallback | SHADER-001, RENDER-001 | `core/src/graph/*` | 有特化用特化，无特化 fallback portable |
| SHADER-005 | 跨平台 | 特化 vs portable 一致性对比工具 | SHADER-004 | `tools/qa/*` | 输出 PSNR/SSIM 对比报告 |
| SHADER-010 | 跨平台 | 基础变换 shader（平移/旋转/缩放/裁剪） | SHADER-001 | `shaders/src/transform.glsl` | 三端一致性测试通过 |
| SHADER-110 | 跨平台 | **[Apple 优先] Metal 特化：变换/合成** | SHADER-004, PALA-001 | `pal/apple/shaders/` | 收益 ≥ 20%，与 portable 一致性达标 |
| SHADER-111 | 跨平台 | **[Apple 优先] Metal 特化：LUT/调色** | SHADER-004, COLOR-002 | `pal/apple/shaders/` | 同上 |
| SHADER-112 | 跨平台 | **[Apple 优先] Metal 特化：美颜磨皮** | SHADER-004, AI-020 | `pal/apple/shaders/` | 同上 |

### 3.2 媒体管线（跨平台层）

| ID | 层 | 任务 | 依赖 | 写集 | 验收 |
|---|---|---|---|---|---|
| MEDIA-010 | 跨平台 | `FrameProvider` 接口与语义（精确 seek） | CORE-006 | `core/include/cq/media/frame_provider.h` | 接口评审通过 |
| MEDIA-011 | 跨平台 | 帧缓存池与 LRU 策略 | MEDIA-010 | `core/src/media/cache.*` | 内存上界可控 |
| MEDIA-012 | 跨平台 | DecoderPool 调度与硬件路数限制处理 | MEDIA-010 | `core/src/media/decoder_pool.*` | 超路数时降级不崩溃 |
| MEDIA-013 | 跨平台 | `TimeMap` 抽象：恒速 / 曲线 / 倒放 | CORE-001 | `core/src/retime/*` | 三种实现同一接口 |
| MEDIA-020 | 跨平台 | SystemFrameProvider（抽象 + 通用逻辑） | MEDIA-010 | `core/src/media/` | 通过 mock 单测 |
| PALA-010 | 跨平台 | Apple 解封装后端（AVAssetReader） | MEDIA-020 | `pal/apple/media_demux.*` | 可读 MP4/MOV |
| PALA-011 | 跨平台 | Apple 硬解后端（VideoToolbox） | PALA-010 | `pal/apple/media_decode.*` | 硬解生效，功耗符合预期 |
| PALA-012 | 跨平台 | Apple 编码与封装（AVAssetWriter + PixelBufferAdaptor） | MEDIA-020 | `pal/apple/media_encode.*` | 能导出 H.264 MP4 |
| MEDIA-030 | 跨平台 | 音画同步与时钟（audio master clock） | MEDIA-020, CORE-008 | `core/src/media/sync.*` | A/V 偏差 ≤ 1 帧 |
| MEDIA-021 | 跨平台 | FFmpeg demux 后端（精确 seek / 倒放 / 曲线） | DEPS-012, MEDIA-010 | `core/src/media/ffmpeg_impl/*` | 与系统后端同 seek 同结果 |
| PALA-013 | 跨平台 | FFmpeg demux + VT 解码组合路径 | MEDIA-021, PALA-011 | `pal/apple/` | 倒放/速度曲线可逐帧取 |

### 3.3 渲染图与基础效果（跨平台层）

| ID | 层 | 任务 | 依赖 | 写集 | 验收 |
|---|---|---|---|---|---|
| RENDER-001 | 跨平台 | RenderGraph：节点 DAG 与拓扑排序 | GFX-001 | `core/src/graph/*` | 拓扑正确，环检测 |
| RENDER-002 | 跨平台 | Pass 合并与中间纹理别名分配 | RENDER-001 | `core/src/graph/*` | 4K 下中间纹理数显著少于朴素实现 |
| RENDER-003 | 跨平台 | LOD 机制（预览跳过昂贵节点） | RENDER-002 | `core/src/graph/*` | 预览/导出走同一图 |
| RENDER-010 | 跨平台 | TransformNode | SHADER-010, RENDER-001 | `core/src/effect/transform.*` | golden 测试通过 |
| RENDER-011 | 跨平台 | 多轨合成节点（Z-order blend） | RENDER-001 | `core/src/effect/composite.*` | 多轨结果正确 |
| RENDER-012 | 跨平台 | 转场节点（dissolve / wipe 起步） | RENDER-001 | `core/src/effect/transition.*` | golden 测试通过 |
| COLOR-001 | 跨平台 | 色彩管道定义（working space / 输入输出转换） | RENDER-001 | `core/src/color/*` | 预览与导出色彩一致 |
| COLOR-002 | 跨平台 | 3D LUT 节点（.cube 加载 + 强度混合） | COLOR-001, SHADER-001 | `core/src/effect/lut.*` | LUT 应用位置与顺序固定 |
| COLOR-003 | 跨平台 | 调色参数节点（曝光/对比/色温/曲线） | COLOR-001 | `core/src/effect/color_grade.*` | 与 LUT 顺序：先校正后风格化 |

### 3.4 模型与命令（跨平台层）

| ID | 层 | 任务 | 依赖 | 写集 | 验收 |
|---|---|---|---|---|---|
| MODEL-001 | 跨平台 | Timeline/Track/Clip/Transition 数据模型 | CORE-001 | `core/src/model/*` | 模型覆盖多轨/转场 |
| MODEL-002 | 跨平台 | Command 模式与 CommandHistory（Undo/Redo） | MODEL-001 | `core/src/command/*` | 100 次 undo 后回到初始态 |
| MODEL-003 | 跨平台 | EffectBinding 与参数系统 | MODEL-001 | `core/src/model/effect_binding.*` | 效果可挂载/卸载 |
| ANIM-001 | 跨平台 | Keyframe / AnimationChannel / 插值引擎 | CORE-001 | `core/src/anim/*` | Linear/Bezier/Hermite/Catmull-Rom 可测 |

### 3.5 绑定层与 UI（Apple）

| ID | 层 | 任务 | 依赖 | 写集 | 验收 |
|---|---|---|---|---|---|
| BIND-001 | SDK | `cq_sdk.h` 纯 C ABI 冻结 | CORE-009 | `core/include/cq/cq_sdk.h` | 零 C++/平台类型；评审通过 |
| BIND-002 | SDK | Swift 绑定层（SPM package） | BIND-001 | `bindings/swift/` | Swift 可调用全部门面接口 |
| UIA-001 | UI | 项目列表页 | BIND-002 | `apps/apple/packages/SharedUI` | 可创建/打开项目 |
| UIA-002 | UI | 编辑器主框架（预览 + 时间线 + 属性面板） | BIND-002 | SharedUI | 三区布局，Mac/iOS 自适应 |
| UIA-003 | UI | MTKView 预览视图嵌入 | UIA-002, PALA-002 | `apps/apple/` | 预览画面不经 UI 合成路径 |
| UIA-004 | UI | **时间线自绘视图**（自绘，非组件堆叠） | UIA-002 | SharedUI | 数百片段拖拽不掉帧 |
| UIA-005 | UI | 片段拖拽/裁剪交互（拖拽预览层 + 结束提交 Command） | UIA-004, MODEL-002 | SharedUI | 拖拽主线程 < 16ms |
| UIA-006 | UI | 属性面板（变换/调色/滤镜参数） | UIA-002, MODEL-003 | SharedUI | 参数变更走 Command |
| UIA-007 | UI | 导出界面与进度/取消 | EXPORT-001 | SharedUI | 可取消，进度准确 |
| UIA-008 | UI | Undo/Redo 入口（含 Mac 快捷键） | MODEL-002 | SharedUI | iOS 摇一摇 + Mac Cmd+Z |
| UIA-009 | UI | 素材导入流程（含 Session 级素材表收口：文件选择 → 入表 → Command 建片段 → 时间线/预览可见） | UIA-004, MODEL-002 ✅ | `SharedUI` + `cq_sdk.h` + `core/session` | 导入的片段重启前可见；素材表 Session 级共享 |
| UIA-011 | UI | 相册素材导入（PhotosPicker → 既有 importMedia 链路，不引第三方；Spec UIA-011） | UIA-009 ✅ | `SharedUI`（PropertyPanelZone + PhotoImportTests） | 相册选视频追加进时间线；与文件导入汇入同一入口；内核/绑定零改动 |
| UIA-012 | UI | 相册多选批量导入（PhotosPicker maxSelectionCount=20，逐条汇入 importMedia，部分失败不中断；Spec UIA-012 + ADR-0015） | UIA-011 | `SharedUI`（PropertyPanelZone + PhotoImportTests 追加） | 多选 N 条全部入表且顺序一致；部分失败汇总展示不中断；零权限零依赖；内核/绑定零改动 |
| UIA-013 | UI | 自研相册浏览器（网格/相簿/多选序号/时长过滤/iCloud/.limited，替换系统 sheet；Spec UIA-013 + ADR-0015，B 期伞任务） | UIA-012 | `SharedUI/MediaPicker`（新目录）+ `project.yml` info 段（高冲突，开工时协调） | 编译门禁 + AlbumPickerTests 全绿；真机项（权限/.limited/iCloud/帧率）随真机恢复决策执行；导入链路零改动 |
| UIA-014 | 跨平台 + UI | 预览宽高比适配（FitMode stretch/contain/cover，视口原语接缝）✅ 2026-10-04 | UIA-010 | `preview_renderer.*` + GFX/PAL 编码器 + `cq_sdk.h` + `Previewer.swift` + SharedUI AppEntry | 非同比例素材按模式适配；默认 stretch 行为不变；像素断言见 TASK-UIA-014（编号两次让位：011→012→014，撞相册导入/相册多选） |

### 3.6 导出

| ID | 层 | 任务 | 依赖 | 写集 | 验收 |
|---|---|---|---|---|---|
| EXPORT-001 | 跨平台 | 导出控制器：状态机 / 进度 / 取消 / 错误码 | MEDIA-012, CORE-005 | `core/src/export/*` | 取消后资源全释放、临时文件清理 |
| EXPORT-002 | 跨平台 | 导出与预览共用 RenderGraph（ARCH-001 §7） | RENDER-003, EXPORT-001 | `core/src/export/*` | 预览与导出结果 PSNR ≥ 40dB |
| EXPORT-003 | 基建 | 导出端到端测试（1080p/4K/长片/失败恢复） | EXPORT-001, QA-003 | `tests/e2e/` | 全通过 |

### 3.7 Phase 1 出口标准

- [ ] 导入 3 段素材 → 裁剪 → 拼接 → 恒速变速 → 调色 → 转场 → 导出 MP4
- [ ] 1080p 三轨预览稳定 ≥ 55fps（高端机）
- [ ] 预览与导出结果 PSNR ≥ 40dB
- [ ] Undo/Redo 覆盖全部用户可见操作
- [ ] 导出可取消、可恢复、失败有稳定错误码

---

## 4. Phase 2 — 效果与编辑能力

### 4.1 AI 与美颜美型（跨平台层）

| ID | 层 | 任务 | 依赖 | 写集 | 验收 |
|---|---|---|---|---|---|
| **AI-013** | 基建 | **[spike] `.tflite → .mlpackage` 转换链可行性验证**（ADR-0005 §0.1，Apple 端路径 A 的生死判定） | DEPS-031 | `tools/models/spike/`, `.ai/memory/baselines.md` | ① 两个模型都能转出 `.mlpackage`；② 与 LiteRT 原始输出数值比对在阈值内；③ 目标设备能跑通。**任一不通过 → 切路径 B（LiteRT + CoreML delegate），不写业务代码** |
| AI-001 | 跨平台 | `IInferenceBackend` 抽象 | CORE-006 | `core/include/cq/infer/*.h` | 零平台类型 |
| PALA-020 | 跨平台 | CoreML 后端 | AI-001, **AI-013** | `pal/apple/infer_coreml.*` | 可加载模型并推理 |
| AI-002 | 基建 | **实测 CoreML 是否落在 ANE**（RESEARCH-001 F8） | PALA-020 | `.ai/memory/baselines.md` | 给出实测结论，不成立则记录回退方案 |
| AI-010 | 跨平台 | 人脸检测（Apple 端先做） | PALA-020 | `core/src/ai/face_detect.*` | 检出率与耗时入库 |
| AI-011 | 跨平台 | **landmark 后处理在 C++ 实现并共享**（ADR-0005） | AI-010 | `core/src/ai/landmark_post.*` | 三端同一份代码 |
| AI-012 | 基建 | 模型转换脚本化并纳入 CI（.tflite → .mlpackage） | DEPS-031, **AI-013（必须先过）** | `tools/models/` | 转换失败构建失败；coremltools 版本登记进 manifest |
| AI-020 | 跨平台 | 美颜：频率分解磨皮 | RENDER-001, SHADER-001 | `core/src/effect/beauty.*` | compute + fragment 双路径 |
| AI-021 | 跨平台 | 美型：MeshWarp（FaceWarpNode 实现一） | AI-011 | `core/src/effect/face_warp_mesh.*` | golden 测试通过 |
| AI-022 | 跨平台 | 美型：UV Offset Map（实现二，可切换） | AI-021 | `core/src/effect/face_warp_uv.*` | 与实现一同一接口 |
| AI-023 | 跨平台 | 抠像：Chroma Key | RENDER-001 | `core/src/effect/chroma_key.*` | 边缘质量达标 |
| AI-024 | 跨平台 | 抠像：AI 分割 mask | AI-010 | `core/src/effect/matting.*` | 发丝区域指标 |
| AI-025 | 跨平台 | 帧间平滑（landmark 抖动抑制） | AI-011 | `core/src/ai/smooth.*` | 抖动指标下降 |

### 4.2 音频（跨平台层）

| ID | 层 | 任务 | 依赖 | 写集 | 验收 |
|---|---|---|---|---|---|
| AUDIO-001 | 跨平台 | 音频图与 PCM 缓冲管理 | CORE-006 | `core/src/audio/*` | 音频线程无锁无分配 |
| AUDIO-002 | 跨平台 | 时间拉伸节点（signalsmith-stretch 集成） | DEPS-020 | `core/src/audio/stretch.*` | **变速后时长误差 ≤ 1 帧** |
| AUDIO-003 | 跨平台 | 变声节点（pitch + formant） | AUDIO-002 | `core/src/audio/pitch.*` | formant 可独立控制 |
| AUDIO-004 | 跨平台 | 多轨混音 | AUDIO-001 | `core/src/audio/mix.*` | 电平正确，无溢出 |
| PALA-030 | 跨平台 | AVAudioEngine 后端（播放/渲染） | AUDIO-001 | `pal/apple/audio.*` | 低延迟播放 |
| AUDIO-010 | 跨平台 | EQ/压缩/混响基础效果 | AUDIO-001 | `core/src/audio/fx.*` | 参数可测 |

### 4.3 编辑能力

| ID | 层 | 任务 | 依赖 | 写集 | 验收 |
|---|---|---|---|---|---|
| EDIT-001 | 跨平台 | 速度曲线（TimeMap 曲线实现 + UI 编辑） | MEDIA-013 | `core/src/retime/*` | 曲线渲染结果正确 |
| EDIT-002 | 跨平台 | 倒放 | MEDIA-013, MEDIA-021 | `core/src/retime/*` | 倒放导出正确 |
| EDIT-003 | 跨平台 | 关键帧动画引擎接入渲染管线 | ANIM-001, RENDER-001 | `core/src/anim/*` | 属性随时间变化生效 |
| EDIT-004 | 跨平台 | 文字/字幕渲染（排版 → 纹理 atlas → 叠加） | RENDER-001 | `core/src/effect/text.*` | 中英混排、换行正确 |
| EDIT-005 | 跨平台 | 贴纸/图片叠加层 | RENDER-011 | `core/src/effect/sticker.*` | PNG/APNG/WebP |
| EDIT-006 | 跨平台 | 代理媒体工作流 | MEDIA-010 | `core/src/media/proxy.*` | 后台转码 + 导出切回原片 |
| PROJ-001 | 跨平台 | 项目序列化（schema v1） | MODEL-001, CORE-001 | `core/src/project/*` | 往返序列化一致 |
| PROJ-002 | 跨平台 | schema 版本迁移器链 | PROJ-001 | `core/src/project/migrate/*` | 每个迁移器有样本测试 |
| PROJ-003 | 跨平台 | 自动保存（临时文件 + 原子替换） | PROJ-001 | `core/src/project/autosave.*` | 写入中断不损坏 |
| PROJ-004 | 跨平台 | 跨端兼容（相对路径 + 资产 ID） | PROJ-001 | `core/src/project/*` | iOS 创建的项目 Android 可打开 |

### 4.4 HDR 与色彩进阶

| ID | 层 | 任务 | 依赖 | 写集 | 验收 |
|---|---|---|---|---|---|
| COLOR-010 | 跨平台 | HDR 预览管道（EDR） | COLOR-001 | `core/src/color/hdr.*` | HDR 素材不发灰 |
| COLOR-011 | 跨平台 | Tone Mapping（HDR→SDR 导出） | COLOR-010 | `core/src/color/tonemap.*` | 导出 SDR 颜色正确 |
| COLOR-012 | 跨平台 | 10-bit 管道支持 | COLOR-001 | `core/src/color/*` | 能力查询受控 |

### 4.5 Phase 2 出口标准

- [ ] 人像视频：美颜 + 瘦脸 + 磨皮，实时预览 ≥ 55fps → 导出
- [ ] 速度曲线与倒放可用
- [ ] 完整 Undo/Redo；项目文件跨端可打开
- [ ] 三端渲染一致性测试（iOS vs 后续 Android）通过

---

## 5. Phase 3 — Android

原则：**先做 PAL + 空壳 App 跑通内核，再点亮功能**。内核已由 Apple 端验证，风险集中在 PAL 与设备适配。

| ID | 层 | 任务 | 依赖 | 写集 | 验收 |
|---|---|---|---|---|---|
| PALD-001 | 跨平台 | GLES 3.1 后端（基线） | GFX-001 | `pal/android/gfx_gles.*` | 清屏 + 纹理绘制 |
| PALD-002 | 跨平台 | Vulkan 后端（旗舰可选） | GFX-001 | `pal/android/gfx_vulkan.*` | 能力查询受控切换 |
| PALD-003 | 跨平台 | `AHardwareBuffer → EGLImage / VkImage` 零拷贝 | PALD-001 | `pal/android/import.*` | 实测无 memcpy；失败可退化 |
| PALD-004 | 基建 | Android 设备黑名单与降级策略 | PERF-002 | `pal/android/caps.*` | 命中机型走降级路径 |
| PALD-010 | 跨平台 | MediaExtractor/MediaCodec 解封装与硬解 | MEDIA-020 | `pal/android/media.*` | 异步模式，关键帧 seek 语义统一 |
| PALD-011 | 跨平台 | MediaCodec 硬编 + MediaMuxer 封装 | MEDIA-020 | `pal/android/media_enc.*` | 导出 H.264 MP4 |
| PALD-012 | 跨平台 | YUV stride 对齐差异处理 | PALD-010 | `pal/android/media.*` | 上层无感 |
| PALD-020 | 跨平台 | TFLite 推理后端（NNAPI/GPU/XNNPACK 回退） | AI-001 | `pal/android/infer_tflite.*` | 三档回退可用 |
| PALD-030 | 跨平台 | Oboe 音频后端（AAudio→OpenSL） | AUDIO-001 | `pal/android/audio.*` | 低延迟，自动回退 |
| PALD-040 | 跨平台 | Scoped Storage / MediaStore 文件访问 | CORE-006 | `pal/android/fs.*` | 权限最小化 |
| BIND-003 | SDK | JNI 绑定层 + Kotlin 封装 | BIND-001 | `bindings/kotlin/` | Kotlin 可调用门面 |
| UID-001 | UI | Compose 编辑器主框架 | BIND-003 | `apps/android/app/` | 布局与 iOS 对齐 |
| UID-002 | UI | SurfaceView/TextureView 预览嵌入 | UID-001, PALD-003 | `apps/android/` | 不经 UI 合成 |
| UID-003 | UI | 时间线自绘（Compose Canvas） | UID-001 | `apps/android/` | 拖拽不掉帧 |
| UID-004 | UI | 属性面板 / 导出界面 / Undo | UID-001 | `apps/android/` | 功能对齐 iOS |
| UID-005 | 基建 | Android 端到端与设备矩阵测试 | UID-001~004, PERF-002 | `tests/e2e/android/` | 高/中/低端通过 |

**Phase 3 出口标准**：Android 端具备 Phase 1 + Phase 2 同等能力；设备矩阵（含低端降级路径）全部通过。

---

## 6. Phase 4 — HarmonyOS（可选，未排期）

按 ADR-0007，本期只做 `OHOS-001`。

| ID | 层 | 任务 | 状态 |
|---|---|---|---|
| OHOS-001 | 跨平台 | `pal/ohos/` 接口编译检查 | **本期做**（INFRA-008） |
| OHOS-002 | 基建 | DevEco + NDK + Vulkan 环境验证 | 未排期（启动后第一步） |
| OHOS-003 | 跨平台 | GFX Vulkan 后端 | 未排期 |
| OHOS-004 | 跨平台 | AVCodecKit 解封装/硬解/硬编/封装 | 未排期 |
| OHOS-005 | 跨平台 | OHAudio 后端 | 未排期 |
| OHOS-006 | 跨平台 | MindSpore Lite 推理后端 | 未排期 |
| OHOS-007 | SDK | NAPI 绑定 | 未排期 |
| OHOS-008 | UI | ArkUI 编辑器壳 | 未排期 |

---

## 7. 并行批次建议

可以并行（写集不相交）：
- **批次 A**：`DEPS-*` 与 `INFRA-*` 与 `QA-001/002` 可高度并行
- **批次 B**：`CORE-001~005` 五个 base 模块互不干扰，可并行
- **批次 C**：`SHADER-001` 与 `PALA-001` 可并行（工具链与后端正交）
- **批次 D**：`UIA-*` 各页面在 `BIND-002` 完成后可并行

**禁止并行**：
- `CORE-006`（PAL 接口冻结）之前，任何 PAL 实现不得开始 —— 接口不稳定会导致大规模返工
- `BIND-001`（C ABI 冻结）之前，任何绑定层不得开始
- `GFX-001` 之前，任何后端不得开始
- 同一写集的两个任务
- `CMakeLists.txt`、`cq_sdk.h`、`*.pbxproj`、`build.gradle.kts` 的修改一律串行

**关键路径**（决定最早交付时间）：
```
INFRA-001/002 → CORE-001~005 → CORE-006(PAL冻结) → PALA-001/010
  → MEDIA-010/020 → RENDER-001 → EXPORT-001/002 → QA-003
```
任何在关键路径上的延迟会直接推迟 Phase 1 出口，应优先保障人力。

---

## 8. 任务状态管理

- 任务事实源：`docs/tasks/TASK-BACKLOG.md`（本文件）+ 每个实施任务单独建 `docs/tasks/TASK-<ID>.md`
- 进展追踪用项目管理系统（Issue/PR），**不要用聊天记录**
- 任务完成判定由门禁决定，不由执行者自述（见 ARCH-001 §10）
- 每次任务结束必须回写：架构事实变更 → ADR/模块文档；失败教训 → `.ai/memory/pitfalls.md`

---

## 9. 相机与首页（CAM，2026-10-04 新增；**同日架构转向 iOS 原生，ADR-0014**）

> 用户需求：首页两入口 + 相机采集 + 实时特效（美颜/美型/美体/宠物/贴纸/滤镜/头部道具）+ 前后同开。
> **ADR-0014**：相机域为 iOS 原生功能域（AVFoundation + Vision/ARKit + Core Image/Metal），
> 不经 PAL/C ABI；编辑器内核维持 C++ 跨端。CAM-001 曾冻结的 PAL 契约当日回退。
> 分 A/B/C 三期（SPEC-CAM-001 **v1.2** §3；v1.2 拍板：双摄提前至 B 期 + 横竖屏全支持 + UI 栈 SwiftUI+MTKView 混合）。

| ID | 层 | 任务 | 依赖 | 写集 | 验收 |
|---|---|---|---|---|---|
| CAM-001 | SDK | ~~PAL 契约冻结~~ **已回退留档** | — | — | 39/39 门禁（回退后） |
| CAM-002 | UI | 相机采集管理器（AVCaptureSession 前后摄/权限） | — | `iOSApp/Camera/CameraManager.swift` | 授权状态机单测；iOS 构建 |
| CAM-003 | UI | 预览渲染链（MTKView + Core Image）+ 滤镜预设 | CAM-002 | `CameraVideoView/Renderer.swift`、SharedUI `CameraFilter.swift` | 滤镜单测；真机 ≥30fps |
| CAM-004 | UI | 首页两入口 + 相机页 + EditorViewModel 惰性化 | CAM-002/003 | `HomeView.swift`、`CameraView.swift`、SharedUI `EditorScreen.swift` | SharedUI 全量；iOS 构建+权限 |
| CAM-005 | UI | 录制（AVAssetWriter H.264+AAC）+ 存相册/进编辑器 | CAM-002~004 | `CameraRecorder.swift`、EditorScreen initialMedia | 产物校验 ≤2 帧偏差 |
| CAM-011 | B 期 | Vision 检测桥(人脸关键点/人体/动物)+ 帧间平滑 | CAM-002~004 | `Camera/Detection/`、SharedUI 平滑纯函数 | 观测/平滑单测;检测耗时真机入库 |
| CAM-012 | B 期 | 磨皮升级 Metal kernel(替换 A 期高斯近似) | CAM-003 | `Camera/Effects/`、CameraBeauty 封装层 | 单调/off 恒等口径不变;≤8ms [E] |
| CAM-013 | B 期 | 美型 MeshWarp(瘦脸/大眼/下巴,关键点驱动) | CAM-011 | `Camera/Effects/`、CameraReshapeParams | 无脸直通;真机无接缝/抖动 |
| CAM-014 | B 期 | 贴纸 + 头部道具锚定(处理链最后一段) | CAM-011 | `Camera/Effects/`、StickerAnchor、资产 | 锚定纯函数锁定;资产许可干净 |
| CAM-015 | B 期 | ~~预览 CI→drawable 渲染修复 + 帧计数去伪绿~~（中间纹理+blit 落地，门禁过；真机出画已经传哲确认颠倒有画） | CAM-003 | `Camera/CameraRenderer/VideoView.swift` | BUILD SUCCEEDED 0W；失败计数口径 |
| CAM-016 | B 期 | **预览方向修复（颠倒 + 横竖屏跟踪 + aspect-fill，SPEC v1.2 A7）** | CAM-015 | `Camera/{Manager,Renderer,ViewModel,View}.swift` | 三方向预览正立铺满；拍照/录像方向一致 |
| CAM-021 | B 期 | **双摄提前（MultiCamSession 画中画 + 独立开关 + 录合成流，SPEC v1.2 A8）** | CAM-016 | `Camera/{Manager,Renderer,ViewModel,View}.swift` | 双摄同画可录；不支持机型降级明示；实测入库 |
| CAM-022~024 | C 期 | MetalFX / 景深人像 / 宠物 / 美体（双摄已提前） | CAM-011~ | 待 C 期任务卡 | 待细化 |

**关键路径**：`CAM-002 → CAM-003 → CAM-004 → CAM-005`。
**注意**：相机特效与编辑器特效是两套实现（ADR-0014 代价）——时间线滤镜仍等
RENDER-001/红线 #6 路线，勿把相机滤镜直接当 SDK 能力引用。

---

## 10. 智能成片（AIEDIT，2026-10-04 新增；ADR-0020 + SPEC AIEDIT-001）

> 用户需求：首页「智能成片」入口 —— 本地特征提取 → 大模型决策 → SDK 执行 →
> 导出/二次编辑 + 对话框（文字/语音）多轮调整；扩展单列「AI 脚本成片」入口
> （脚本→分镜）。调研：RESEARCH-003。伞卡：TASK-AIEDIT-000（含 DAG/批次/并行声明）。

| ID | 层 | 任务 | 依赖 | 写集要点 | 验收 |
|---|---|---|---|---|---|
| AIEDIT-001 | SDK | **契约冻结**：FeatureReport/EditPlan schema + ILlmClient/INetTransport + 校验器 | — | `core/include/cq/ai/*`(新)、`core/include/cq/pal/net.h`(新)、校验器+golden ≥40 例 | ctest edit_plan 全绿；浮点秒全拒 |
| AIEDIT-002 | SDK | 视觉特征（镜头边界/运动/质量，零模型 P0） | 001 | `core/src/ai/analysis/*`(新) | golden 边界 ±1；内存 <200MB [E] |
| AIEDIT-003 | SDK | 音频解码扩档(FFmpeg decode) + 音频特征（静音/LUFS/包络） | 001 | `core/src/media/audio_decode/*`(新)、`third_party/manifest.toml`(高冲突) | 过 dependency-governance；边界 ≤50ms |
| AIEDIT-004 | SDK | PAL 网络（URLSession/SSE）+ OpenAI-compatible 客户端 | 001 | `pal/apple/net/*`(新)、`core/src/ai/llm/*`(新) | 假服务器四异常路径；零三方依赖 |
| AIEDIT-005 | SDK | Prompt 管线与决策解析/修复/降级编排 | 001/004/011 | `core/src/ai/plan/plan_pipeline 等`(新) | 四路径全过；增量 rev 校验 |
| AIEDIT-006 | SDK | EditPlan→Command 执行器 + RemoveRange/SetTransition 新命令 | 001 | `core/include/cq/command/command.h`(高冲突)、`core/src/command/*` | undo 逐字段还原；批次原子 |
| AIEDIT-007 | SDK | C ABI 扩展（cq_ai_*）+ Swift 绑定（Integrator） | 002/004/005/006 | `cq_sdk.h`(高冲突)、bindings | c_abi_ai 全绿；observer 无泄漏 |
| AIEDIT-008 | UI | 智能成片向导 UI（首页入口 + 三步 + 双出口） | 007 | `HomeView.swift`(高冲突)、SharedUI `SmartCut/Wizard+Result`(新) | 状态机单测；双端编译 |
| AIEDIT-009 | UI | 对话式调整（文字 + 语音 STT + 逐条接受） | 008 | SharedUI `SmartCut/Chat+Voice`(新)、project.yml info(高冲突) | 撤销本轮还原；权限三路径 |
| AIEDIT-010 | P1 | AI 脚本成片（脚本→分镜→素材匹配，单列入口） | 009 | 启动时冻结 | 伞占位，启动时拆 |
| AIEDIT-011 | SDK | 本地规则引擎降级（离线成片，同 schema 输出） | 001 | `core/src/ai/fallback/*`(新) | 确定性输出；断网出合法 plan |

**批次**：1=001（串行先行）→ 2=002/003/004/006/011（五路并行）→ 3=005 → 4=007 → 5=008 → 6=009。
**关键路径**：`001 → 005 → 007 → 008 → 009`（002/003/006/011 赶在 007 前完成即可）。
**P0 出口**：闭环可用（导出按钮置灰待 EXPORT-001）；**P0.5**：BGM 卡点命令 + 导出对接；**P1**：010 + 转写剪辑 + Android 端。

---

## 11. 编辑页重构（UIA-015/016/020，2026-10-05 新增；SPEC-UIA-015）

> 用户命题：编辑页丑（与剪映范式错位）+ 导入后预览无画面 + 播放入口不可用。调研：RESEARCH-004（§3.4/§6.2）。
> 号段：线 A 预占 UIA-015~018 内取用（本机 = 集成机，登记即占号）；UIA-020 为新领号（相邻线 A 域）。

| ID | 层 | 任务 | 依赖 | 写集要点 | 验收 |
|---|---|---|---|---|---|
| UIA-020 | UI | 预览活性修复（模型推进 → 同 pts 重渲染，seq 追帧） | — | `AppEntry.swift`、`MetalPreviewView.swift`、SharedUITests | 泵 requested 单测；全量零回归 |
| UIA-016 | UI | Theme 令牌扩展（增量，全量清扫待批） | — | `Common/Theme.swift` | Editor 新文件无裸 RGB；编译绿 |
| UIA-015 | UI | iOS 编辑页剪映式重构（预览最大化/播放条/底部工具栏/媒体抽屉） | 020、016 | `Editor/*`（七文件）+ `ChuanqiCutApp.swift` DEBUG 钩子 | 走查截图 + 全量测试 + 双平台编译 |
| MEDIA-022 | SDK | HEVC 解码支持 + 探测失败诚实透传 ✅ 2026-10-05 | — | `pal/apple/media_decode.mm`、绑定 probe 透传、AppEntry 文案 | HEVC golden probe=0 + 像素断言；门禁全绿（诊断见任务卡 §背景） |

**批次**：020 ∥ 016 → 015。**关键路径**：020 → 015。
**登记未开工**：UIA-017（macOS 惯例化）、UIA-018（时间线视觉/缩略图）、Theme 2.0 全量清扫（RESEARCH-004 §6.0，待批）、UIA-019 面板框架立项、MEDIA-022（HEVC，2026-10-05 立项）。
