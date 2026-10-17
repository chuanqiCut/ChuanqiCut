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
read_set:    platform/apple/*, core/src/media/*
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
| **跨平台层（Platform 实现）** | `PALA` `PALD` `OHOS` | Apple / Android / 鸿蒙 的平台适配 | 24 |

> **前缀说明（2026-10-11）**：`PALA` / `PALD` 是「Platform 层 · Apple / Android」的**历史任务前缀**
> （`PAL` 是 2026-10-10 前的旧名，当日随 INFRA-022 统一改名为 `Platform`，见 RESEARCH-011 §5.2）。
> 前缀**保持 `PALA` / `PALD` 不变** —— 已建的几百张卡与 BACKLOG 行都挂在它下面，
> 改前缀会让历史引用全部断链，收益远小于代价。阅读时按「Platform·Apple / Platform·Android」理解即可。
| **SDK 绑定层** | `BIND` | C ABI → Swift / Kotlin / ArkTS | 6 |
| **UI 层** | `UIA` `UID` `UIO` | SwiftUI / Compose / ArkUI | 16 |
| **基建** | `DEPS` `INFRA` `PERF` `QA` | 依赖治理、CI、性能、测试 | 21 |
| **合计** | | | **118** |

> **执行顺序原则**：架构按三端设计，但**人力与优化优先保障 iOS/macOS**（重点支持平台）。
> 标了 `[Apple 优先]` 的任务先做；Android 端排期在 Phase 3。

---

## 2. Phase 0 — 地基（内核骨架 / Platform 契约 / 构建 / 治理 / 基线）

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
| INFRA-008 | 基建 | `platform/ohos/` 接口编译检查 target（ADR-0007） | CORE-006 | `platform/ohos/` | 接口签名变更时该 target 失败 |
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
| CORE-006 | 跨平台 | **Platform 接口定义冻结**（GFX/Media/Audio/Inference/FS/Clock/Log/Capabilities） | CORE-001~005 | `core/include/cq/platform/*.h` | 头文件零平台类型；评审通过 |
| CORE-007 | 跨平台 | 能力查询 `ICapabilities` 与枚举 | CORE-006 | `core/src/platform/capabilities.*` | 运行时可查询各项能力 |
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
- [ ] Platform 接口冻结并通过评审

---

## 3. Phase 1 — Apple MVP（解码→渲染→预览→导出）

### 3.1 GFX 与 Shader（跨平台层 + Apple Platform）

| ID | 层 | 任务 | 依赖 | 写集 | 验收 |
|---|---|---|---|---|---|
| GFX-001 | 跨平台 | GFX 抽象接口（概念映射表 12 项） | CORE-006 | `core/include/cq/gfx/*.h` | 头文件零平台类型 |
| GFX-002 | 跨平台 | TexturePool 与内存预算控制 | GFX-001, CORE-004 | `core/src/gfx/pool.*` | 超预算时按 LRU 回收 |
| GFX-003 | 跨平台 | 外部图像导入抽象 `INativeImageImporter` | GFX-001 | `core/src/gfx/import.*` | 导入失败可退化为 CPU 拷贝 |
| PALA-001 | 跨平台 | **Metal 后端实现** | GFX-001 | `platform/apple/gfx_metal.*` | 清屏 + 纹理绘制可跑 |
| PALA-002 | 跨平台 | `CVPixelBuffer → CVMetalTexture` 零拷贝 | PALA-001 | `platform/apple/` | 实测零拷贝生效（无 memcpy） |
| SHADER-001 | 跨平台 | shader 编译链：GLSL → SPIR-V → MSL | DEPS-030 | `tools/shaders/` | 生成可读 MSL 并落盘 |
| SHADER-002 | 跨平台 | 反射信息 → 绑定号代码生成 | SHADER-001 | `tools/shaders/` | 绑定号由工具生成 |
| SHADER-003 | 跨平台 | shader 规范检查（禁用扩展/显式精度等） | SHADER-001 | `tools/shaders/lint.*` | 违规 shader 构建失败 |
| SHADER-004 | 跨平台 | **Platform-Native 层机制**：`RenderNode.specialize()` + 运行时选择 + fallback | SHADER-001, RENDER-001 | `core/src/graph/*` | 有特化用特化，无特化 fallback portable |
| SHADER-005 | 跨平台 | 特化 vs portable 一致性对比工具 | SHADER-004 | `tools/qa/*` | 输出 PSNR/SSIM 对比报告 |
| SHADER-010 | 跨平台 | 基础变换 shader（平移/旋转/缩放/裁剪） | SHADER-001 | `shaders/src/transform.glsl` | 三端一致性测试通过 |
| SHADER-110 | 跨平台 | **[Apple 优先] Metal 特化：变换/合成** | SHADER-004, PALA-001 | `platform/apple/shaders/` | 收益 ≥ 20%，与 portable 一致性达标 |
| SHADER-111 | 跨平台 | **[Apple 优先] Metal 特化：LUT/调色** | SHADER-004, COLOR-002 | `platform/apple/shaders/` | 同上 |
| SHADER-112 | 跨平台 | **[Apple 优先] Metal 特化：美颜磨皮** | SHADER-004, AI-020 | `platform/apple/shaders/` | 同上 |

### 3.2 媒体管线（跨平台层）

| ID | 层 | 任务 | 依赖 | 写集 | 验收 |
|---|---|---|---|---|---|
| MEDIA-010 | 跨平台 | `FrameProvider` 接口与语义（精确 seek） | CORE-006 | `core/include/cq/media/frame_provider.h` | 接口评审通过 |
| MEDIA-011 | 跨平台 | 帧缓存池与 LRU 策略 | MEDIA-010 | `core/src/media/cache.*` | 内存上界可控 |
| MEDIA-012 | 跨平台 | DecoderPool 调度与硬件路数限制处理 | MEDIA-010 | `core/src/media/decoder_pool.*` | 超路数时降级不崩溃 |
| MEDIA-013 | 跨平台 | `TimeMap` 抽象：恒速 / 曲线 / 倒放 | CORE-001 | `core/src/retime/*` | 三种实现同一接口 |
| MEDIA-020 | 跨平台 | SystemFrameProvider（抽象 + 通用逻辑） | MEDIA-010 | `core/src/media/` | 通过 mock 单测 |
| PALA-010 | 跨平台 | Apple 解封装后端（AVAssetReader） | MEDIA-020 | `platform/apple/media_demux.*` | 可读 MP4/MOV |
| PALA-011 | 跨平台 | Apple 硬解后端（VideoToolbox） | PALA-010 | `platform/apple/media_decode.*` | 硬解生效，功耗符合预期 |
| PALA-012 | 跨平台 | Apple 编码与封装（AVAssetWriter + PixelBufferAdaptor） | MEDIA-020 | `platform/apple/media_encode.*` | 能导出 H.264 MP4 |
| MEDIA-030 | 跨平台 | 音画同步与时钟（audio master clock） | MEDIA-020, CORE-008 | `core/src/media/sync.*` | A/V 偏差 ≤ 1 帧 |
| MEDIA-021 | 跨平台 | FFmpeg demux 后端（精确 seek / 倒放 / 曲线） | DEPS-012, MEDIA-010 | `core/src/media/ffmpeg_impl/*` | 与系统后端同 seek 同结果 |
| PALA-013 | 跨平台 | FFmpeg demux + VT 解码组合路径 | MEDIA-021, PALA-011 | `platform/apple/` | 倒放/速度曲线可逐帧取 |

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
| UIA-014 | 跨平台 + UI | 预览宽高比适配（FitMode stretch/contain/cover，视口原语接缝）✅ 2026-10-04 | UIA-010 | `preview_renderer.*` + GFX/Platform 编码器 + `cq_sdk.h` + `Previewer.swift` + SharedUI AppEntry | 非同比例素材按模式适配；默认 stretch 行为不变；像素断言见 TASK-UIA-014（编号两次让位：011→012→014，撞相册导入/相册多选） |
| UIA-015 | UI | 独立视频播放器 MVP（AVPlayer 过渡 + PlayerEngine 接缝；Spec UIA-020 + ADR-0022，2026-10-05 当日交付）✅ + 第二/三轮 V1 | 无（UIA-014 收口后立项） | `SharedUI/Player/`（新目录）+ HomeView + MacApp + `ios/project.yml` info 段 | PlayerTests 全绿 + 构建机 0 警告 + SPEC §6.4 行为清单；内核/绑定零改动；C++ session 演进见 ADR-0022 反转条件 |
| UIA-016 | UI | 播放器系统级播控补完（章节标记 + PiP 占位态 + AirPlay 路由；进阶版 P1，PLAN-播放器进阶） | UIA-015 门禁 PASS | `SharedUI/Player/**` + PlayerTests | 章节刻度/跳转；PiP 占位态；AirPlay 呼出；章节 API 形状构建机首验 |
| UIA-017 | UI | 播放器画面捏合缩放与拖移（1x–3x + 双击复位；进阶版 P1） | UIA-015 门禁 PASS | PlayerControlsView/Screen/VM + PlayerTests | 缩放钳制 + 回弹；与上下滑/长按消歧真机验证；映射纯函数可测 |
| UIA-018 | UI | 播放器外挂字幕 v1（SRT/WebVTT；进阶版 P1） | UIA-015 门禁 PASS；**开工前补 ADR-0023（解析层归属）** | Player/SubtitleParser + Overlay + VM/Screen + PlayerTests + ADR-0023 | 解析容错 + 1MB 上界；字幕随时间轴显隐；换片清除 |
| UIA-021 | UI | 播放器最近播放（bookmark 持久化 + 列表；进阶版 P1；编号跳 019/020 见 PLAN §5） | UIA-015 门禁 PASS | PlayerRecentStore + Launcher + PlayerTests | 重启重播；去重置顶 ≤20；失效自动剔除 |
| UIA-022 | UI | 播放器播放列表与连续播放（进阶版 P1） | UIA-015 门禁 PASS, UIA-021 | PlayerViewModel/Screen/Queue + PlayerTests | 连播不断流（<1s [E]）；AB > 循环 > 队列优先级；失败跳片 |
| UIA-023 | UI | 播放器设置页 + macOS PiP + 快捷键扩充（进阶版 P1） | UIA-015 门禁 PASS, UIA-018 | PlayerSettingsView + Controls/Screen/PipCoordinator + PlayerTests | 设置聚合既有持久化项；macOS PiP 可用性显隐；快捷键无冲突 |
| UIA-024 | UI | 播放器网络流播放（URL/HLS 点播；源类型策略 + 缓冲态 + URL 入口；拍板项 2026-10-05"均需要"） | UIA-015 门禁 PASS | AVPlayerEngine/VM/Screen + PlayerTests | 源类型判定纯函数；远程禁预热；buffering 态；直播流拒绝；HLS 真机样本 |
| UIA-025 | UI | 播放器外挂字幕 v2（ASS/SSA 样式子集：颜色/粗斜下/对齐/\pos；拍板项） | UIA-015 门禁 PASS, UIA-018 | SubtitleParser/OverlayView + PlayerTests | 子集 tag 生效且未知 tag 容错；还原度声明为子集；libass 引入另评 |
| UIA-026 | UI | 编辑器素材库 → 播放器联动（单条预览/批量入队；值拷贝过接缝；跨域卡） | UIA-015 门禁 PASS, UIA-022 | PlayerScreen + Editor/PropertyPanelZone（热点，开工前协调）+ PlayerTests | 失效素材置灰；播放器零 Session 依赖；push/sheet 呈现 |
| UIA-027 | UI | macOS mini player（MenuBarExtra + PlayerController 门面 + 关窗续播；拍板项） | UIA-015 门禁 PASS, UIA-022 | PlayerController（新）+ PlayerScreen + MacApp + PlayerTests | 既有 init 兼容回归；关窗续播；MiniBar 只读进度 |

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
| PALA-020 | 跨平台 | CoreML 后端 | AI-001, **AI-013** | `platform/apple/infer_coreml.*` | 可加载模型并推理 |
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
| AUDIO-001 | 跨平台 | [音频图与 PCM 缓冲管理](TASK-AUDIO-001.md)（预分配池/SPSC 环/AudioGraph 骨架）✅ 2026-10-05 | CORE-006 ✅ | `core/src/audio/*` | 音频线程无锁无分配（operator new 计数实测增量 0） |
| AUDIO-002 | 跨平台 | 时间拉伸节点（signalsmith-stretch 集成） | DEPS-020 | `core/src/audio/stretch.*` | **变速后时长误差 ≤ 1 帧** |
| AUDIO-003 | 跨平台 | 变声节点（pitch + formant） | AUDIO-002 | `core/src/audio/pitch.*` | formant 可独立控制 |
| AUDIO-004 | 跨平台 | 多轨混音 | AUDIO-001 | `core/src/audio/mix.*` | 电平正确，无溢出 |
| PALA-030 | 跨平台 | AVAudioEngine 后端（播放/渲染） | AUDIO-001 | `platform/apple/audio.*` | 低延迟播放 |
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
| EDIT-007 | SDK | 片段分割与删除 C ABI（B1 模型层命令；RESEARCH-010 §5.2 新号） | MODEL-002 ✅ | `engine/core/cq/{model,command,session}/*`、`engine/core/cq/cq_sdk.*` | Split/RemoveClip/RemoveTrack 经 C ABI 可用且有单测 | ✅ 2026-10-11（TASK-EDIT-007，48/48） |
| EDIT-008 | SDK | 左缘裁剪 trim-clip-in C ABI（RESEARCH-010 §5.2 新号） | EDIT-007 | 同上（共用写集） | start/source_in/duration 联动、右缘不动、越界拒绝，经 C ABI 可用且有单测 | ✅ 2026-10-11（TASK-EDIT-008，48/48） |
| EDIT-009 | SDK | 跨轨移动命令 + C ABI（UIA-040 多轨操作内核面） | EDIT-007 | `engine/core/cq/{model,command,session}`、`cq_sdk.*` | id 不变上目标轨；类型/重叠校验；可撤销 | ✅ 2026-10-12（TASK-UIA-040，48/48） |
| EDIT-010 | SDK | 画布项目属性 + 比例 C ABI/UI（UIA-040） | MODEL-001 | 同上 + Editor Pod | set_canvas 可撤销、指纹纳入；预览目标随画布 resize | ✅ 2026-10-12（TASK-UIA-040，65/65） |
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

原则：**先做 Platform + 空壳 App 跑通内核，再点亮功能**。内核已由 Apple 端验证，风险集中在 Platform 与设备适配。

| ID | 层 | 任务 | 依赖 | 写集 | 验收 |
|---|---|---|---|---|---|
| PALD-001 | 跨平台 | GLES 3.1 后端（基线） | GFX-001 | `platform/android/gfx_gles.*` | 清屏 + 纹理绘制 |
| PALD-002 | 跨平台 | Vulkan 后端（旗舰可选） | GFX-001 | `platform/android/gfx_vulkan.*` | 能力查询受控切换 |
| PALD-003 | 跨平台 | `AHardwareBuffer → EGLImage / VkImage` 零拷贝 | PALD-001 | `platform/android/import.*` | 实测无 memcpy；失败可退化 |
| PALD-004 | 基建 | Android 设备黑名单与降级策略 | PERF-002 | `platform/android/caps.*` | 命中机型走降级路径 |
| PALD-010 | 跨平台 | MediaExtractor/MediaCodec 解封装与硬解 | MEDIA-020 | `platform/android/media.*` | 异步模式，关键帧 seek 语义统一 |
| PALD-011 | 跨平台 | MediaCodec 硬编 + MediaMuxer 封装 | MEDIA-020 | `platform/android/media_enc.*` | 导出 H.264 MP4 |
| PALD-012 | 跨平台 | YUV stride 对齐差异处理 | PALD-010 | `platform/android/media.*` | 上层无感 |
| PALD-020 | 跨平台 | TFLite 推理后端（NNAPI/GPU/XNNPACK 回退） | AI-001 | `platform/android/infer_tflite.*` | 三档回退可用 |
| PALD-030 | 跨平台 | Oboe 音频后端（AAudio→OpenSL） | AUDIO-001 | `platform/android/audio.*` | 低延迟，自动回退 |
| PALD-040 | 跨平台 | Scoped Storage / MediaStore 文件访问 | CORE-006 | `platform/android/fs.*` | 权限最小化 |
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
| OHOS-001 | 跨平台 | `platform/ohos/` 接口编译检查 | **本期做**（INFRA-008） |
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
- `CORE-006`（Platform 接口冻结）之前，任何 Platform 实现不得开始 —— 接口不稳定会导致大规模返工
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
> 不经 Platform/C ABI；编辑器内核维持 C++ 跨端。CAM-001 曾冻结的 Platform 契约当日回退。
> 分 A/B/C 三期（SPEC-CAM-001 **v1.2** §3；v1.2 拍板：双摄提前至 B 期 + 横竖屏全支持 + UI 栈 SwiftUI+MTKView 混合）。

| ID | 层 | 任务 | 依赖 | 写集 | 验收 |
|---|---|---|---|---|---|
| CAM-001 | SDK | ~~Platform 契约冻结~~ **已回退留档** | — | — | 39/39 门禁（回退后） |
| CAM-002 | UI | 相机采集管理器（AVCaptureSession 前后摄/权限） | — | `iOSApp/Camera/CameraManager.swift` | 授权状态机单测；iOS 构建 |
| CAM-003 | UI | 预览渲染链（MTKView + Core Image）+ 滤镜预设 | CAM-002 | `CameraVideoView/Renderer.swift`、SharedUI `CameraFilter.swift` | 滤镜单测；真机 ≥30fps |
| CAM-004 | UI | 首页两入口 + 相机页 + EditorViewModel 惰性化 | CAM-002/003 | `HomeView.swift`、`CameraView.swift`、SharedUI `EditorScreen.swift` | SharedUI 全量；iOS 构建+权限 |
| CAM-005 | UI | 录制（AVAssetWriter H.264+AAC）+ 存相册/进编辑器 | CAM-002~004 | `CameraRecorder.swift`、EditorScreen initialMedia | 产物校验 ≤2 帧偏差 |
| CAM-011 | B 期 | Vision 检测桥(人脸关键点/人体/动物)+ 帧间平滑 | CAM-002~004 | `Camera/Detection/`、SharedUI 平滑纯函数 | 观测/平滑单测;检测耗时真机入库 |
| CAM-012 | B 期 | 磨皮升级 Metal kernel(替换 A 期高斯近似) | CAM-003 | `Camera/Effects/`、CameraBeauty 封装层 | 单调/off 恒等口径不变;≤8ms [E] |
| CAM-013 | B 期 | 美型 MeshWarp(瘦脸/大眼/下巴,关键点驱动) | CAM-011 | `Camera/Effects/`、CameraReshapeParams | 无脸直通;真机无接缝/抖动 |
| CAM-014 | B 期 | 贴纸 + 头部道具锚定(处理链最后一段) | CAM-011 | `Camera/Effects/`、StickerAnchor、资产 | 锚定纯函数锁定;资产许可干净 |
| CAM-015 | B 期 | ~~预览 CI→drawable 渲染修复 + 帧计数去伪绿~~✅（中间纹理+渲染 pass 落地，门禁过） | CAM-003 | `Camera/CameraRenderer/VideoView.swift` | BUILD SUCCEEDED 0W；失败计数口径 |
| CAM-016 | B 期 | **预览方向修复（颠倒 + 横竖屏跟踪 + aspect-fill，SPEC v1.2 A7）**✅ | CAM-015 | `Camera/{Manager,Renderer,ViewModel,View}.swift` | 三方向预览正立铺满；拍照/录像方向一致 |
| CAM-018 | B 期 | ~~美颜色彩空间修正(workingColorSpace 对齐 harness gamma 域)+录制色彩对齐+引擎状态日志~~✅ **曾号 CAM-015**（2026-10-07 撞号让位） | CAM-012 | `CameraViewModel/Recorder/Renderer/BeautyKernel.swift` | 代码 grep+typecheck;真机不闪(人工);SPEC-CAM-018-019 |
| CAM-019 | B 期 | ~~美白/磨皮人脸区域化(接 CAM-011 检测桥,羽化蒙版混合,nil/[]/非空三态)~~✅ **曾号 CAM-016**（同批让位） | CAM-018 | SharedUI `Camera/{FaceMask,CameraBeauty}.swift`、三消费方、SharedUITests | 坐标/三态纯函数单测;无脸直通;真机人工;SPEC-CAM-018-019 |
| CAM-021 | B 期 | **双摄提前（MultiCamSession 画中画 + 独立开关 + 录合成流，SPEC v1.2 A8）** | CAM-016 | `Camera/{Manager,Renderer,ViewModel,View}.swift` | 双摄同画可录；不支持机型降级明示；实测入库 |
| CAM-022~024 | C 期 | MetalFX / 景深人像 / 宠物 / 美体（双摄已提前） | CAM-011~ | 待 C 期任务卡 | 待细化 |

> 📌 **CAM-015/016 撞号已裁定**（2026-10-07，沿 UIA-032/033 同日裁定先例）：远端渲染线（先入库 +
> 活线）保留原号；本机美颜线（已完结）让位 → **CAM-018/019**。卡片：`TASK-CAM-015/016.md`（渲染线）、
> `TASK-CAM-018/019.md`（美颜线，曾号 015/016）。同批：pitfalls 本机条目 P62/P63 → P80/P81。

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
| AIEDIT-001 | SDK | **契约冻结**：FeatureReport/EditPlan schema + ILlmClient/INetTransport + 校验器 | — | `core/include/cq/ai/*`(新)、`core/include/cq/platform/net.h`(新)、校验器+golden ≥40 例 | ctest edit_plan 全绿；浮点秒全拒 |
| AIEDIT-002 | SDK | 视觉特征（镜头边界/运动/质量，零模型 P0） | 001 | `core/src/ai/analysis/*`(新) | golden 边界 ±1；内存 <200MB [E] |
| AIEDIT-003 | SDK | 音频解码扩档(FFmpeg decode) + 音频特征（静音/LUFS/包络） | 001 | `core/src/media/audio_decode/*`(新)、`third_party/manifest.toml`(高冲突) | 过 dependency-governance；边界 ≤50ms |
| AIEDIT-004 | SDK | Platform 网络（URLSession/SSE）+ OpenAI-compatible 客户端 | 001 | `platform/apple/net/*`(新)、`core/src/ai/llm/*`(新) | 假服务器四异常路径；零三方依赖 |
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

## 11. 编辑页重构（UIA-032/033/020，2026-10-05 新增；SPEC-UIA-032）

> 用户命题：编辑页丑（与对标 App 范式错位）+ 导入后预览无画面 + 播放入口不可用。调研：RESEARCH-004（§3.4/§6.2）。
> 号段：原取 UIA-015/016，与播放器线撞号，2026-10-07 裁定编辑器线让位改 **UIA-032/033**（登记即占号）；UIA-020 为新领号（相邻线 A 域）。

| ID | 层 | 任务 | 依赖 | 写集要点 | 验收 |
|---|---|---|---|---|---|
| UIA-020 | UI | 预览活性修复（模型推进 → 同 pts 重渲染，seq 追帧） | — | `AppEntry.swift`、`MetalPreviewView.swift`、SharedUITests | 泵 requested 单测；全量零回归 |
| UIA-033 | UI | Theme 令牌扩展（增量，全量清扫待批；原 UIA-016 让位改号） | — | `Common/Theme.swift` | Editor 新文件无裸 RGB；编译绿 |
| UIA-032 | UI | iOS 编辑页对标 App 式重构（预览最大化/播放条/底部工具栏/媒体抽屉；原 UIA-015 让位改号） | 020、033 | `Editor/*`（七文件）+ `ChuanqiCutApp.swift` DEBUG 钩子 | 走查截图 + 全量测试 + 双平台编译 |
| MEDIA-022 | SDK | HEVC 解码支持 + 探测失败诚实透传 ✅ 2026-10-05 | — | `platform/apple/media_decode.mm`、绑定 probe 透传、AppEntry 文案 | HEVC golden probe=0 + 像素断言；门禁全绿（诊断见任务卡 §背景） |

**批次**：020 ∥ 033 → 032。**关键路径**：020 → 032。
| MEDIA-024 | SDK | 顺序快路径对真实 4K60 失效修复 + 泵帧外秒级尖刺定位（播放卡顿定案修复） | — | `system_frame_provider.cpp`、`preview_renderer.cpp`、单测 | 真机 rendered/s ≥ 55 且无秒级尖刺（数据见 baselines） |

**登记未开工**：macOS 惯例化（原 UIA-017 建议位已让位播放器线，重开时取新号）、时间线视觉（原 UIA-018 建议位——被 RESEARCH-008/§12 时间线缩略图吸收时标注让位）、Theme 2.0 全量清扫（RESEARCH-004 §6.0，待批）、UIA-019 面板框架立项、MEDIA-024（2026-10-06 立项，数据已定案）。

## 12. 编辑页 UIKit 重建（UIA-034~037，2026-10-05 新增；RESEARCH-008 + ADR-0024）

> 用户命题：播放卡顿 + 界面丑 → 复刻对标 App 移动端范式；SwiftUI 难实现就改 UIKit。
> 决策：ADR-0024（编辑页核心三件套 UIKit，外层 SwiftUI 壳，Command 链路零改动）。
> **让位说明**：本节任务原取 UIA-021~024，与播放器线进阶卡撞号，2026-10-07 裁定编辑器线让位改 **UIA-034~037**。

| ID | 层 | 任务 | 依赖 | 写集要点 | 验收 |
|---|---|---|---|---|---|
| UIA-034 | UI | EditorViewController 骨架（三区 UIKit 容器 + SwiftUI 装配）✅ 2026-10-07 | — | SharedUI `Editor/UIKit/**`(新)、EditorScreen 装配 | 双平台编译；既有测试零回归 |
| UIA-035 | UI | 时间线 UIKit 自绘 + 手势 + CADisplayLink 播放头（卡顿修复主体）✅ 2026-10-07（播放头独立层每帧只动 path；真机 <16ms 走查 = 池 [3]） | 034 | SharedUI `Editor/UIKit/Timeline*` | 播放头移动仅重绘播放头层；主线程单帧 <16ms（真机走查） |
| UIA-036 | UI | 预览浮层/传输条 + 底部工具栏/二级条 ✅ 2026-10-07（一级条落地；二级条随各能力实装引入） | 034 | SharedUI `Editor/UIKit/{Preview,Toolbar}*` | 对标 App 形状走查清单（RESEARCH-008 §2） |
| UIA-037 | UI | 时间线缩略图（异步抽帧，吸收时间线视觉建议位） | 035 | 同上 + 抽帧缓存 | 主线程不解码；缩略图随片段可见 |

**批次**：阶段 0（真机性能剖面，回填 baselines，UIA-034 前半天）→ 034 → 035 ∥ 036 → 037。
**关键路径**：034 → 035。

## 13. 素材库·草稿·混排·多轨（LIB 新前缀，2026-10-07 新增；[PLAN-素材库草稿混排多轨](PLAN-素材库草稿混排多轨.md)）

> 传哲 2026-10-07 四需求：本地素材库 / 草稿管理 / 多类型混排+GIF·LivePhoto 产出 / 多轨叠加。
> 号段已由集成机在本 PLAN §4 占号（EXPORT-004~007 被 AI-ENG-001 预留，新卡从 010 起；
> UIA-028~031 已预占——UIA-015/016 撞号已于 2026-10-07 裁定落地，可按依赖建卡）。
> RENDER-001/011/012、PROJ-001~004、EXPORT-001/002、AUDIO-004 为既有号，见上文各节。
> **ADR 让位注记**：本节原预留 ADR-0024~0027，因编辑器线让位占用 0024（编辑页 UIKit），
> 全部顺延为 **ADR-0025~0028**。
> **Pod 域归属（ADR-0031，2026-10-07）**：LIB-*、UIA-028 → `ChuanqiCutAssets` Pod；
> PROJ-005、UIA-029 → `ChuanqiCutDraft` Pod；UIA-030/031 → `ChuanqiCutEditor` Pod；
> MEDIA-028/029、EXPORT-010/011 → C 线内核支撑（core/platform，不进 UI Pod）。

| ID | 层 | 任务 | 依赖 | 写集要点 | 验收 |
|---|---|---|---|---|---|
| LIB-001 | 跨平台 | 素材库契约冻结（资产类型 video/still/animated/livephoto、存储布局、元数据 schema、与 Session AssetRegistry 关系） | 定稿 ADR-0025 | `core/include/cq/library/*.h` | 契约评审通过；零平台类型 |
| LIB-002 | 跨平台 | 素材库存储与索引（入库/扫描/检索/失效标记） | LIB-001 | `core/src/library/*` | 往返一致；跨会话可重建索引 |
| LIB-003 | 跨平台+PALA | 缩略图与元数据（probe 复用；缩略图生成/缓存） | LIB-002 | `core/src/library/thumbs*`、`platform/apple/media_thumb*` | 缩略图命中率；主线程不解码 |
| LIB-004 | 跨平台+UI | 入库链路改造：拍摄/导出/相册/文件→落库，替换 importMedia tmp 链（UIA-009/011/012 欠账收口；C/A 拆两卡） | LIB-002 | core `library/ingest*` + SharedUI 导入链 | 全部产出有库内资产 ID；tmp 链退役 |
| LIB-005 | 跨平台 | 素材管理：删除/重命名/去重/引用保护（被草稿引用→缺失标记） | LIB-002, PROJ-001 | `core/src/library/manage*` | 引用保护语义单测；无静默连删 |
| PROJ-005 | 跨平台 | 草稿箱索引与生命周期（建/开/存/复制/删/封面） | PROJ-001 | `core/src/project/drafts*` | 崩溃后草稿可恢复（自动保存接线） |
| MEDIA-028 | 跨平台+PALA | 静图/动图帧源：FrameProvider 扩展 still（单帧+声明时长）/ animated（帧序列，GIF 帧延迟→120000 网格） | MEDIA-020, 定稿 ADR-0026/0027 | `core/src/media/`、`platform/apple/media_gif*` | GIF 逐帧时间与解码器一致（golden） |
| MEDIA-029 | 跨平台+PALA | LivePhoto 探测与解码（photo+video 配对识别；Apple-only，其他端降级普通素材） | MEDIA-028 | `platform/apple/media_livephoto*` + core 探测接缝 | 配对识别真机验证；缺失降级不崩溃 |
| EXPORT-010 | 跨平台+PALA | GIF 导出（逐帧量化编码器；尺寸/帧率/循环参数） | EXPORT-002, RENDER-011, 定稿 ADR-0028 | `core/src/export/`、`platform/apple/media_enc*` | golden 对比；导出走同一 RenderGraph |
| EXPORT-011 | 跨平台+PALA | LivePhoto 导出（视频+封面配对写入相册 / 文件对；入相册=显式授权） | EXPORT-002, 定稿 ADR-0028 | `platform/apple/media_livephoto*` | 相册成对写入真机验证；文件对可打开 |
| UIA-028 | UI | 素材库页面（浏览/搜索/多选/管理；联动编辑与播放器复用 UIA-026 接缝） | LIB-002/005, UIA-026 | SharedUI（预占，依赖就绪后建卡） | 管理操作走库 ABI；失效素材置灰 |
| UIA-029 | UI | 草稿箱页面（列表/封面/时长/体积；开/编/删/复制） | PROJ-005 | SharedUI（预占，依赖就绪后建卡） | 冷启动进草稿箱；崩溃恢复入口 |
| UIA-030 | UI | 多轨时间线 UI（轨道增删/排序/静音锁定；Z 序=轨序） | UIA-035, RENDER-011 | SharedUI（预占，依赖就绪后建卡） | 多轨真机走查 <16ms/帧 |
| UIA-031 | UI | 导出面板 v1（格式含 GIF/LivePhoto；入相册/文件显式授权流；进度/取消） | EXPORT-001/010/011 | SharedUI（预占，裁定后建卡） | 取消可中断；授权文案过审口径 |

**批次**：期 1 = RENDER-001 ∥ PROJ-001~003 ∥ EXPORT-001 ∥ LIB-001~003；期 2 = MEDIA-028/029 ∥ RENDER-011 ∥ EXPORT-010/011 ∥ LIB-004/005 + PROJ-004/005 ∥ AUDIO-004；期 3 = UIA-028~031。
**关键路径**：RENDER-001 → RENDER-011 → EXPORT-010；PROJ-001 → PROJ-005 → UIA-029。

---

## 14. 壳工程与功能 Pod 拆分（INFRA-013~020，2026-10-07 新增；[ADR-0031](../decisions/ADR-0031-主工程壳化与功能Pod分治.md) + [PLAN-壳工程与功能Pod](PLAN-壳工程与功能Pod.md)）

> 传哲 2026-10-07 拍板：主工程壳化，草稿/素材管理/播放器/拍摄/素材导入各自独立 podspec。
> 八张卡全部**集成机执行**（热点文件：podspec×8 / Podfile×2 / project.yml×2 / run_gate.sh）；
> 每阶段收尾 = 一个阶段批门禁点（ADR-0030）。

| ID | 层 | 任务 | 依赖 | 写集要点 | 验收 |
|---|---|---|---|---|---|
| INFRA-013 | 基建 | 壳工程改造：`apps/apple/packages/` 骨架 + 双 Podfile/project.yml 适配 + `run_gate.sh` 逐 Pod 测试段 ✅ 2026-10-07（双 Podfile+门禁段+基座注入点；project.yml 零改动） | ADR-0031 | 双 Podfile、双 project.yml、`tools/ci/run_gate.sh` | 双壳 xcodegen+pod install+构建冒烟过；门禁绿 |
| INFRA-014 | 基建 | SharedUI 瘦身为 UI 基座（功能子域迁出即删源，仅留 Common/Theme） | INFRA-013 | `SharedUI.podspec`、`Sources/SharedUI/Common/**` | 测试套仍绿；全仓 grep 零悬空 import |
| INFRA-015 | 基建 | `ChuanqiCutPlayer` Pod 迁移（Player 全域 + 测试）✅ 2026-10-07（52 用例随迁零丢失；SharedUI 88+Player 52=140 对齐 HEAD；MediaSheet 经 PlayerPreviewInjector 解耦） | INFRA-014 | `packages/ChuanqiCutPlayer/**` | Player 测试数字对齐迁移前不掉用例 |
| INFRA-016 | 基建 | `ChuanqiCutImport` Pod 迁移（MediaPicker 7 文件 + AlbumPickerTests）✅ 2026-10-07（16 用例；AlbumPickerScreen 公开化经 MediaLibraryInjector 注入） | INFRA-014 | `packages/ChuanqiCutImport/**` | 导入链单测过；双壳构建过 |
| INFRA-017 | 基建 | `ChuanqiCutAssets` Pod 建域（素材表/素材库收敛；LIB-* UI 配套）**改挂 LIB 依赖（2026-10-07 实测定案）**：素材逻辑与 EditorViewModel 不可分，硬拆即假工程——随 LIB-001 契约冻结建域，先随 Editor Pod | LIB-001 | `packages/ChuanqiCutAssets/**` | 素材表回归测试过 |
| INFRA-018 | 基建 | `ChuanqiCutCamera` Pod 迁移（iOSApp/Camera + 契约层；iOS 专属）✅ 2026-10-07 提前（传哲指定；metallib 管线留壳工程 SRC 指向 Pod 源——script_phase 产物到不了 App bundle 实测假绿，见 P85；EditorEntryInjector 解耦） | INFRA-013 | `packages/ChuanqiCutCamera/**` | metallib 非空壳 ✅ 8431B+kernelNames；真机一趟（池攒单）相机检查点全过 ⏳ |
| INFRA-019 | 基建 | `ChuanqiCutEditor` Pod 迁移（Editor+Timeline+AppEntry/EditorViewModel；UIA-032 在新 Pod 内重构）✅ 2026-10-07（36 用例；Theme 公开化入基座；MediaSheet 随 Editor 待 LIB 拆 Assets） | INFRA-013 | `packages/ChuanqiCutEditor/**` | 编辑器测试过；双壳构建过 |
| INFRA-022 | 基建 | 引擎源码收拢 engine/（pod 根=engine，docs 天然脱离文档探测；CMake/SPM/工程引用重定基）✅ 2026-10-07（[TASK-INFRA-022](TASK-INFRA-022.md)） | INFRA-021 | `engine/**` | core 45/45；bindings 26/26；双壳构建绿 |
| INFRA-021 | 基建 | ChuanqiCutEngine pod 正常化（头文件可见/docs 移除/Binary 移除/重名头改名）✅ 2026-10-07（[TASK-INFRA-021](TASK-INFRA-021.md)；pods_post_install 钩子） | INFRA-013 | podspec/pods_post_install.rb | Pods 工程 docs=0/头 42；core 45/45 |
| INFRA-020 | 基建 | `ChuanqiCutDraft` Pod 骨架（PROJ-001 落地后填肉）✅ 2026-10-07（占位域符号；暂不进 Podfile，首功能落地时接线） | INFRA-013 | `packages/ChuanqiCutDraft/**` | 骨架编译过；随 PROJ-005/UIA-029 填功能 |

**待拍板（INFRA-023，2026-10-07 登记）**：Swift 绑定与五个 UI 包的 SPM 包现在**只承担
`swift test` 测试宿主**（App 依赖链 100% 走 pod，源码同一份）。若要彻底移除 SPM，需把
五包测试迁到 pod `test_spec`（xcodebuild test），牵动门禁跑法——**待传哲拍板是否值得**。

**批次（= ADR-0031 六阶段）**：阶段 0 = 013+014；阶段 1 = 015；阶段 2 = 016；阶段 3 = 017；
阶段 4 = 018；阶段 5 = 019+020。同域业务任务与该域迁移**不并行**（串行让路）。

---

## 15. 仓库布局整改（INFRA-026~035，2026-10-16 新增；[ADR-0044](../decisions/ADR-0044-顶层布局按层分目录与门面外提.md) + [RESEARCH-018](../research/RESEARCH-018-仓库布局复勘与整改执行方案.md)）

> 传哲 2026-10-16 命题：「可读性太差，文件夹中还夹杂着测试 case 留下的垃圾」。
> RESEARCH-011（10-10）的 P3 + 本轮 14 项新决策，**全量一次做完**。
> 十张卡全部**集成机执行**（热点文件：双 Podfile / pbxproj×2 / run_gate.sh / AGENTS 真源 / CI）。
> 纪律两条：**UI 搬家与路径改名不得同批**（031 ∥ 032 禁止）；每批收尾 = 窄检 + 双壳构建 + 具体数字。

| ID | 层 | 任务 | 依赖 | 写集要点 | 验收（要点） | 状态 |
|---|---|---|---|---|---|---|
| INFRA-026 | 基建 | 布局契约冻结：ADR-0044 + RESEARCH-018 + 十卡 + 本 §15 + ARCH-005 目录树 | — | docs/{decisions,research,tasks,specs} | 十卡字段齐全、并行卡写集不相交 | ✅ 2026-10-16 |
| INFRA-027 | 基建 | 忽略规则一次性收口（锚定 + 新旧路径同覆盖） | 026 | `.gitignore`、`.zcodeignore` **独占** | check-ignore 8 条探针符合预期；`git ls-files` 差值 0 | ✅ 2026-10-16（8/8 探针符合预期，含新旧 `api/swift/.build`、`ui/*/.build`、`engine/bindings/swift/.build` 三写；`git ls-files`=857 不变） |
| INFRA-028 | 基建 | 孤儿产物清理 + build/ 分区 + 构建脚本去机器绝对路径 | 027 | `tools/build/*.sh`、`docs/BUILD.md`、AGENTS 真源「验证」段 | 4 处孤儿目录不存在；`grep /Users/zhuning tools/build` 零命中；ctest 数不掉 | ✅ 2026-10-16（5 项孤儿 mv 至仓库外隔离目录 533M + `Editor/.build` 223M 删除；`grep /Users/zhuning tools/build`=0 复测；`build/output`/`build/tmp` absent；ctest 52/52 不掉；双壳 pod install ios 14/mac 7 且 Podfile.lock 零 diff） |
| INFRA-029 | SDK | edit_plan golden 夹具出树（59 个入库文件 → `tests/golden/edit_plan/`） | 026 | `tests/golden/**`、`tests/CMakeLists.txt`、`engine/core/cq/ai/plan/edit_plan_golden`(删) | 计数 59/0；`ai_edit_plan` 用例名不变；`verify.py --json` 0 | ✅ 2026-10-16（`tests/golden/edit_plan` 59 / 旧目录 0；`ctest -N` 用例名集合 diff 为空、仍 52 例；Debug 52/52 155.97s、Release 52/52 197.04s；`verify.py --json` built_ok=21 built_fail=0 unbuilt=0 total_bytes=901784 exit 0；总 tracked 857 不变） |
| INFRA-030 | SDK | `tests/unit/` 51 平铺 → 按模块子目录（**用例名一律不动**） | 029 | `tests/unit/**`、`tests/CMakeLists.txt` | `ctest -N` 排序 diff 为空；文件数 51 | ✅ 2026-10-16（12 个模块目录 / 51 文件 / 根目录平铺残留 0；51 条全以 `R` 重命名入索引、内容 0 改动；`add_test` 52 条一字未动且 diff 里 0 行涉及；`ctest -N` before/after 各 **52** 且 **diff 为空**；`grep -rn /Users/zhuning tests/unit` = 0（3 处 ffprobe 改 env > `$HOME`(`access(X_OK)`) > PATH）。全量门禁 **PASS=15 / FAIL=0 / SKIP=0**：Debug 52/52 133.05s、Release 52/52 226.96s、headers 43/0 违规、layer-hygiene 119 文件、golden 21/0/0 901784B、包段 bindings 26 + player 52 + camera 77 + import 16 + editor 81；**双壳构建 4 步 exit 0**——ios pod install 14/14、mac 7/7 且 `Podfile.lock` 零 diff，ios ChuanqiCutApp + mac ChuanqiCutMacApp 均 **BUILD SUCCEEDED**（error 0） |
| INFRA-031 | UI | `apps/apple/packages/` → 扁平顶层 `ui/`（六包，保留 ChuanqiCut 前缀） | 026 | `ui/**`、双 Podfile、双 pbxproj、`run_gate.sh`、beauty_harness | `git ls-files ui`=124；apple-* 五段用例数不掉；双壳 xcodebuild 过 | ✅ 2026-10-16（一次 `git mv` = **124 files / 0 insertions / 0 deletions**，旧路径 tracked 0；六包 `swift package resolve` 全过，`Package.swift` engine 深度 4→2，`RepoPath` 上溯 7→5 层且 probe 实证命中 golden mp4；图层卫生两趟 **4 + 115 = 119** 与迁移前逐字相等；全量门禁 **PASS=15 / FAIL=0 / SKIP=0**：Debug 52/52 165.11s、Release 52/52 145.14s、headers 43/0、golden 21/0/0 901784B、包段 bindings 26 + player 52 + camera 77 + import 16 + editor 81 = **252**；双壳 pod install ios 14/14 + mac 7/7、两端 BUILD SUCCEEDED、lock 路径全指 `../../../ui/…`；pbxproj run-script 3 处 `../packages` 手改 1 行、三个 metallib 9215/5792/8118B 重生成 → P149） |
| INFRA-032 | SDK | `engine/bindings/swift` → `api/swift/` + `ChuanqiCutEngine.podspec` pod 根随之迁 | 031 | `api/**`、Engine podspec、双 Podfile、`run_gate.sh`、`gen_api_reference.py` | `git ls-files api`=25；engine 下无 bindings；**链接**通过非仅 pod install | ✅ 2026-10-16（`git ls-files api`=**25** / `engine/bindings`=**0** / `engine` **149→124**（差恰 25；卡面原估 23 系数错，bindings 实测 24 个入库文件）、总 tracked **857** 不变；移动集 = 15 `R100` + 9 `R0xx` + 1 相对符号链接重写（`D`+`A` 非 `R`，`test -f` 实证解析 → P151）。pod 根改判：`source_files = 'Sources/ChuanqiCut/**/*.swift'`（**pod 根相对**，脚本机械替换会静默丢源码 → P150）。**链接级取证三层**：Local Podspecs JSON 两端一致、Pods 工程各 **8** 条 `path = Sources/ChuanqiCut/*.swift`、`libChuanqiCutEngine.a` 507616B/511248B、App 二进制 `nm -c ChuanqiCutEngine` ios **1838**/mac **1842**。全量门禁 **PASS=15 / FAIL=0 / SKIP=0**（18m58s）：Debug 52/52 149.75s、Release 52/52 144.73s、headers 43/0、layer-hygiene 119、golden 21/0/0 901784B、包段 bindings 26 + player 52 + camera 77 + import 16 + editor 81 = **252**；双壳 pod install 14/14 + 7/7、两端 BUILD SUCCEEDED（error 0，warning 24/6）。run1 曾红于 `apple-import`（SPM 增量缓存钉死旧绝对路径），清 `build/spm` 1.2G 后 run2 全绿 → **P152**。顺带修 `gen_api_reference.py` 长期过期：符号 **76→103**、文档 406→516 行，已把 `--check` 登记给 034 入门禁） |
| INFRA-033 | SDK | shader 并入 `engine/shaders/{portable,native}/` + 红线 #6 措辞修订 | 032 | `engine/shaders/**`、`engine/platform/apple/CMakeLists.txt`、`tools/shaders/`、AGENTS 真源+5 生成物（实测扩张 +`chq_gfx.h` 注释 2 处、`blit.vert:8`、`.ai/modules/shader.md`、2 个 skill） | `build/generated/shaders/` 非空且由新路径重生成；sync_context 后零 diff | ✅ 2026-10-16（**只跑模块级窄检**，全量门禁归 034 末批）。tracked：`engine/shaders` **0→3**、`shaders` **0**（目录已不在磁盘）、`engine` **124→127**、总 tracked **857** 守恒。防静默假绿：`rm -rf build/generated` 后 `build_core.sh --platform=apple --test` → exit 0、日志 `[27%] SHADER-001` 真实执行、ctest **52/52** real **135.17s**、`error:` **0**。产物逐字节核对：spv **960/548B**、msl **418/410B** 与搬家前**相等**；`blit_msl.h` **1665→1689B**，+24B 由 `git show HEAD` 的 `HEADER_BANNER` 两行路径字面各 +12B **精确对上** → banner 变了、转译结果没变。GLSL 代码等价：剥离注释后 md5 与 `HEAD:shaders/src/*` 相同（vert `568b8102…`/frag `687a4761…`）→ 未顺手加平台扩展。headers `scanned 43 … 0 violation`（与 032 基线相同，扫描根未误改）；`sync_context.py --check` 一致。另修：CMakeLists 脱敏残留 `其编辑器组件)` → `VERBATIM)`（原词不可考，靠重生成+编译证明行为不变，`git log -S` 追到 `6ccf29b B0`）；两个 skill 里的**不存在脚本**与「tools/shaders/ 是占位」假陈述换成真实命令。残留登记 034：README **3 行**、ARCH-003 **2 行**、死忽略规则 `.gitignore:44`/`.zcodeignore:48` 的 `shaders/generated/`（引擎侧两条保留作防御）。 |
| INFRA-034 | 基建 | 治理补齐（CI workflow / `.clang-format` / `.editorconfig`）+ `tools/probe`→`tools/qa` + 活文档路径收口 | 028,029,030,031,032,033,035 | `.github/workflows/*`、两个新配置文件、`tools/qa/probe/**`、活文档（根 README/BUILD/skills/modules） | 本机 `CMAKE_BIN=$(command -v cmake)` 复现过；活文档旧路径零命中（append-only 不改） | ✅ 2026-10-16/17（**17 步全量门禁 PASS=17 / FAIL=0 / SKIP=0**，墙钟 10m57s 暖缓存：Debug 52/52、Release 52/52、headers 43/0、layer-hygiene 119/0、包段 252、golden 21/0/0 901784B；步数 15→**17** = 新增 `api-doc`+`ios-compile`、`artifacts` 并入 `hygiene`）。新增四条判据全绿：`check_repo_hygiene.sh` **4/4**（tracked **856** 产物 **0**、旧路径非豁免 **0**、editorconfig 四条件 **0**、clang-format INFO **79/115**）、`gen_api_reference.py --check` 全文比对（516→**538 行/103 符号**）、`check_ios_compile.sh`（P146 收口，`nm` 取证 **4/3/0**，暖 2~6s）、`linkcheck_docs.py` **10→0**。P145 负向：`PYTHON_BIN=/bin/ls` 强制首步红 → exit **1**、摘要仅 1 行。`tools/probe`→`tools/qa/probe`：tracked **0 → 3**。双壳 ios **14/14** + mac **7/7** 均 BUILD SUCCEEDED（error 0），壳内 metallib **9215/5792/8118B**、`blit_msl.h` **1689B**。**CI core 段干净复现四遍**（`rm -rf build` 逐遍重装）：toolchain/build/ctest 全 rc=0、**51/51**，四遍都打印排除名单 `Test #45: platform_apple_decode`，run2/run4 hygiene rc=0 → 判据"连续 2 次绿"由 run3+run4 满足。**复现本身抓到 P160**（构建期第三方工具只在本机暖缓存、仓库无产出脚本 → 首遍 `build rc=2`、`ctest rc=8`、50/51 `Could not find executable`），修复主体 = 新增 `tools/build/build_shader_toolchain.sh` + `ci.yml` 装配步；负向测试又抓到该脚本两处自身缺陷并修（**P162**：`--check-only` 名义只读却删、`SPVC_PATCH_FP:STRING=` grep 恒不命中 → 暖跑每遍误重编）。⚠️ **未做**：`CODEOWNERS`（待传哲给用户名）、远端 workflow 首跑、CI 的 FFmpeg 装配步本机未复现、clang-format 全库重排（另开卡）；池 **[22]**（90 个 tracked 文件仍用 `core/include/cq/**`，hygiene 射程外）、池 **[23]**（本机 SPIRV-Cross 不入库本地补丁，待判定）。详见 `TASK-INFRA-034.md` §实测 |
| INFRA-035 | 基建 | `docs/handoff` 归档：在位留最近 5 份，重号补注不删 | 026 | `docs/handoff/**`→`docs/archive/handoff/**`、`docs/archive/README.md` | 在位 5 / 归档 22 / 合计 27；linkcheck 无新增死链 | ✅ 2026-10-16（5 / 22 / 27 三个计数齐；重号 004×2、006×3 全随迁未合并；`linkcheck_docs.py` 断链 9 → **6**，剩余 6 条全是存量：指向已改名的 `docs/specs/PAL-接口契约.md` 3 条（ADR-0035 1、LEDGER-W42 2）、LEDGER-W42 另 2 条（RESEARCH-011 全名已变、ADR-0011 已变）、HANDOFF-021 指向从未存在的 `TASK-EDIT-007/008.md` 1 条；本批零新增死链；`docs/archive/README.md` 建） |
| INFRA-036 | 基建 | 活文档三代死路径适配（池 [22]）+ hygiene 判据扩射程与新增第 5 条 | 034 | `.ai/modules/*.md`、`docs/specs/*.md`、`docs/{BUILD,COCOAPODS,CODESTYLE}.md`、源码注释（api/engine/tests/ui）、`tools/ci/check_repo_hygiene.sh` | 非豁免命中 0 行；PAT 含三条死根；判据 5 反证能判红 | ✅ 2026-10-17（50 文件 / +217 −158。`check_repo_hygiene.sh` **5/5 PASS**：legacy 非豁免 **0**、豁免 33 → **64**、tracked **878** 不变、clang-format INFO 仍 **79/115**。唯一残留活债 `tests/unit/gfx/gfx_headers_compile.cpp:44` static_assert 文本 `core/src/gfx` → `engine/core/cq/gfx`（实测实现文件确在 `engine/core/cq/gfx/chq_gfx_device.cpp`）。历史行一律"保留原文 + 旧路径标注"，不做字符串替换（P156）。**已接受噪声**：`docs/specs/UIA-011/012/013/019/032/043` 内 17 处"将要新建"的文件名不改（设计期意图，非磁盘承诺）。池 [22] 原写的验收"grep 归零"与红线 5 互斥，关闭回填里订正为"非豁免 0"。详见 `TASK-INFRA-036.md`） |
| INFRA-037 | 基建 | 双 App 壳构建进总门禁（池 [18]） | 034,036 | `tools/ci/check_apple_shells.sh`（新）、`tools/ci/run_gate.sh` 第 6 步 | 两端 rc=0 且 BUILD SUCCEEDED 且 error 行 0；产物只落仓库根 `build/`；`--fast/--skip-apple` 一并跳过 | ✅ 2026-10-17（用 **App 自己的 workspace**，未另立判据工程。冷 **280s** / 暖 **39s**（两端合计），两端 error **0**，iOS derivedData 993MB / mac 514MB，`pod install` 两端 rc=0 **14 pods**。**测量趟抓到 P164**：`-derivedDataPath ../../build/…` 在 `cd apps/apple/ios` 的子 shell 里语义变 `apps/build/` → 源码树里 **1.5G** derivedData（第三次失守，同 P84/P152 族）；修法=绝对路径 + 前缀断言 + 跑完自查 + hygiene 新增判据 5。**未覆盖**：iOS **模拟器**壳（池 [16]，2026-10-17 传哲定「模拟器没必要支持」→ 拟改为明确不支持并取消 sim 切片，另开卡）。步数 **17→18 已实跑证实**：`run_gate.sh` 全量 **PASS=18 / FAIL=0 / SKIP=0**，墙钟 ≈20m40s，本步 44.5s（暖）。每步耗时分布见 `.ai/memory/baselines.md`「18 步全量门禁实测」——结论是 `core-dbg+core-rel` 占 66%，优化立项 INFRA-038（并行度）/INFRA-039（取消模拟器切片）。详见 `TASK-INFRA-037.md`） |
| INFRA-038 | 基建 | 门禁 C++ 段并行化（`cmake --build` 补 `--parallel`） | 037 | `tools/build/build_core.sh`、`tools/build/build_core_apple.sh`（高冲突构建脚本，需传哲点头） | 同脏集 A/B：73 TU 串行 **254s** vs `--parallel 12` **70s** = **3.6×**；~~预期 `core-dbg+core-rel` 从 817s 降到 ~230s，全量从 20m40s 降到 ~10min~~ **预期作废（12:4x 实测）**：并行只压构建段，ctest 段没动 → 两步实到 **198s + 213s**，全量 **9m28s** | ✅ **2026-10-17 完成（本机全量门禁 PASS=18 / FAIL=0 / SKIP=0，墙钟 568s = 9m28s，串行基线 20m40s → 2.18×）**。三个调用点全带 `--parallel`，核数走 `CQ_JOBS`；`-Werror` 仍生效，Debug/Release 各 **52/52**；六包用例数 **26/52/77/16/81** 与前批逐字相等（digest 未因输出交错失配，未放宽任何正则）。附带待办**同批做掉**：`run_gate.sh` 每步时长入账（摘要行末 `[Ns]` + 末行墙钟/合计对账，本趟差 **0s**）。Apple 三切片冷构建 **8m20s → 151s**（`check_ios_compile.sh:19` 已换数，旧数留在 `TASK-INFRA-034` 不改写）。**两个数量级候选未做**（不扩写集）：池 [25] Debug/Release 共用一棵 `build/`、池 [26] `media_sequential_real` 占 ctest 一半。**过程中记下 P167（"暖=no-op" 是猜的）与 P168（后台任务完成通知早于实际完成）**。详见 `TASK-INFRA-038-门禁并行化.md` |
| INFRA-039 | 基建 | iOS **模拟器切片**是否下线（三切片→两切片） | 038 | `tools/build/build_core_apple.sh:199`、`tools/ci/check_ios_compile.sh`（`--slice` 有 simulator 死选项要一并清；**默认是 `ios-device`，不吃 sim 树** —— 本行初稿写反，池 [24] 已更正）、`build_core_apple.sh` 产出的 xcframework | — | ⏸ **2026-10-17 传哲改判「先不动」**。要点留档（**同轮更正**：初稿那句「窄检正靠 sim 树、须先改指 `ios-device`」写反了，脚本第 37 行默认就是 `ios-device`，故该前置作废——见池 [24] 内的更正段）：真实前置只剩两件 —— ① `build_core_apple.sh:199` 停产 `arm64;x86_64` 的 sim 切片（这切片每个 TU 编两遍，`build/apple/ios-sim` 32M > device 27M；**冷态收益无实测**，测量跑一半被叫停）；② 产物面：xcframework 无 iphonesimulator slice ⇒ App 模拟器上链接不了 ⇒ 池 [16] 改判「明确不支持」。外加清掉 `--slice` 里那条永远配不出来的 simulator 死选项。登记为池 [24] |
| INFRA-042 | 治理 | commit message 立规：标题一行 + 正文 ≤5 行，**数字与表格不进提交** | 034 | `.ai/source/AGENTS.root.md` §提交、`AGENTS.md`（生成物） | 真源有条目且 `sync_context.py --check` 绿；后续 commit 正文 ≤5 行 | ✅ 2026-10-17（传哲指出「又在里边写作文」。查下来**规则原本不存在** → 不是违规是无规；案底与取证见 **P169**。本条自身即按新规写成，不单独开卡） |
| INFRA-040 | 基建 | `core-dbg`/`core-rel` **共用一棵 `build/`** → 每趟全量门禁白做一遍全量重编（拆 `build/dbg` + `build/rel`） | 038 | `tools/build/build_core.sh`（`BUILD_DIR`）、CI workflow、hygiene 判据 5 的 scratch 根清单 | 拆树后连跑两趟全量：第二趟 `core-rel` 应降到增量级；两步通过数仍 52/52 | ⏳ **候选，未立项**（2026-10-17 INFRA-038 实测副产品，见池 [25]）。收益是**推算**（459s → 100~200s），未实测；属构建脚本 + CI 高冲突面，须传哲点头 。**INFRA-043 之后仍未做**，且新增一条相关证据：本批实测 Debug 档 `--skip-label=heavy` 后 ctest **15.17s**（0 TU 暖态），而 `core-dbg` 整步仍 **86s** —— 因为两档共用一棵树，切配置必然重编 **95 TU**。**现在的成本重心从 ctest 段移到了"切配置重编"这一段。** **2026-10-17 16:2x 判定：📌 挂起、不立项**（集成机判定，传哲本轮答 *No preference*，**非其裁定**，可推翻）：v0.1.0 L3 实测 `core-rel` 整步 **199s** = ctest **141.99s** + 构建段 **≈57s** ⇒ 拆树能省的只剩这 ≈57s/版本批；而 `--test-dir build` 实测 **96 处 / 64 文件**（`docs/BUILD.md` 原写 43 处已失效）里绝大多数是历史行、按红线 5 不得改写，且 `BUILD.md:51-52` 本身是**有意决定**，反转要走 ADR。数字与账见池 [25] 追加段、`docs/BUILD.md` 的订正块。 |
| INFRA-041 | 基建 | `media_sequential_real` **一个用例占 ctest 一半**（113.88s / 195.5s），要不要缩样或单独档位 | 038 | `tests/unit/media/**`、`run_gate.sh`（若走"单独档"则是门禁语义变更） | 三条路任一：现状 / 缩样并写明判据射程变小 / 加一档触发频率 | ⏳ **候选，未立项**（见池 [26]）。**需传哲判**——它测实时序播放/解码，缩样=削弱判据，不由集成机自行决定 。**INFRA-043 部分缓解**：它已进 `LABELS "heavy"` 名单 → Debug 档不再跑它（省 58.23s/趟），但 Release 档全跑不变，**缩样与否仍待传哲判**。 **2026-10-17 16:2x 状态改「📌 维持现状」**（集成机判定，传哲答 *No preference* = 不反对，**不是裁定**）：v0.1.0 L3 里 Release ctest **141.99s**、占全趟 513s 的 **28%**，Debug 档已完全不跑它（该档 ctest 共 **15.04s**）。取选项 1（时间换判据强度）。见池 [26] 追加段。 |
| INFRA-043 | 基建 | 版本批门禁节奏：`VERSION` 单源 + 分层窄检（L0~L3）+ ctest `heavy` 分档 + `gate_scope.sh` 路由 | 038 | `VERSION`（新）、`docs/reports/VERSIONS.md`（新）、根 `CMakeLists.txt`、`tools/ci/run_gate.sh`、`tools/ci/gate_scope.sh`（新）、`tools/build/build_core.sh`、`tests/CMakeLists.txt`、`.github/workflows/ci.yml` | 见 `TASK-INFRA-043` 的 8 条机检验收（含**本卡全程不跑 18 步全量**这条自证） | ✅ **2026-10-17 编码完成、窄检绿**（**传哲 2026-10-17 拍板**：「门禁要搞成一个小版本统一跑，别写个小功能就在那跑门禁浪费时间」；批次口径选**引入显式小版本号 v0.x.y**；真机节奏本轮不动）。 **实测**：heavy **14** 例 / 非 heavy **38** / 总 **52**；Debug 档 ctest **107.55s → 15.17s**（暖态 0 TU），`--fast` 全档 **239s → 100s**（PASS=8/FAIL=0/SKIP=3）；Release 档仍全 **52/52**（ctest **151.55s**，切配置重编 **95 TU**，整步 211s）。tsv 加 `version`/`batch` 列并**就地迁移**（9→11 列，历史行补 `-`）。 **过程中抓到 P172**：`if(TEST _t)` 恒假（要写 `${_t}`）→ 一个标签都打不上，而 `-LE heavy` 会"成功地"跑完 52 例，**分档看起来生效其实没生效**；暴露它的正是本卡坚持的"跳过名单必须打印"。**同批声明式订正 2 处**：ADR-0046 初稿把 CMake 记为「不带版本」（实为 `VERSION 0.1.0`）与 CI「与本机同口径」（改判为 CI 保全 52 例，当 Debug 档 heavy 覆盖点）。详见 `TASK-INFRA-043-版本批节奏与门禁分档.md` |
| INFRA-045 | 基建 | `ui/ChuanqiCutDraft` 进门禁（收池 [21]）：新增 `apple-draft` 步，用 `swift build` 不用 `swift test` | 043 | `tools/ci/run_gate.sh`、`tools/ci/gate_scope.sh`（R4 build-only 名单）、`.ai/source/AGENTS.root.md` + 5 份生成物、`TASK-INFRA-045-Draft包进门禁.md`（新） | 该步存在于包段且命令是 `swift build`；`gate_scope.sh` 对 `ui/ChuanqiCutDraft/*` 吐 build 不吐 test；`--fast`/`--skip-apple` 一并跳过；`bash -n` rc=0；`sync_context.py --check` 一致 | ✅ **2026-10-17（v0.1.0 L3 第 19 步 `apple-draft` PASS [3s]，全趟 PASS=19/FAIL=0/SKIP=0）**。实测：首编 `swift build` **Build complete! (1.54s)** rc=0、暖跑 0.29s；`swift test` **rc=1**（`error: no tests found; create a target in the 'Tests' directory`）→ 无 `Tests/` 目标的包只能 build（**P177**）。六包磁盘实测：SharedUI/Draft 无 `Tests`、Player/Camera/Import/Editor 有 ⇒ `CQ_BUILD_ONLY_PKGS` 按目录判定不按包名猜。真源 L3 行的「全量 18 步」改为「**步数以脚本为准**」（再加一步不必再改 6 个文件）。⚠️ **只证明"能编"**：该包至今**零 XCTest 用例**，功能证据要另开测试卡；池里那条"在 `ui-apple.md` 补归属行"**本批未做**。详见 `TASK-INFRA-045-Draft包进门禁.md` |
| INFRA-046 | 基建 | 全库 clang-format 重排，把 `.clang-format` 的存量违规清到 0（INFRA-034 有意留下的那批） | 034,043 | `engine/**`+`tests/**` 的 `.h/.c/.cpp/.mm`、`.clang-format` 头部、`tools/ci/check_repo_hygiene.sh`（INFO 文案 **+ 统计射程**）、`tools/ci/gate_scope.sh`（R12，与 045 共写整文件随 045 落库）、`TASK-INFRA-046-全库clang-format重排.md`（新） | `--dry-run --Werror` 对全部入库 C/C++/mm（排除 vendor）命中 **0**；hygiene **5/5**；Debug 重编 + `-Werror` + ctest 不掉例；`gen_api_reference.py --check` 一致；**`git diff --summary` 不含 mode change** | ✅ **2026-10-17**。基数 **168** 文件（vendor 的 C/C++ 源**根本不入库**，不是被豁免）；实排 **113 files / +1684 −1211**（engine/core 65 + engine/platform 14 + tests/unit 34），违规 **79/115 + 34/45 → 0/168**；重排后 Debug 重编 **92 TU**、ctest **38/38**（L3 里该段 **15.04s**）、`gen_api_reference.py --check` 与 `sync_context.py --check` 均一致。**两个新坑**：**P176** `clang-format -i` 把仓库**唯一**的符号链接 `api/swift/Sources/ChuanqiCutCore/include/cq_sdk.h` 换成 38624 字节普通副本（`mode change 120000 => 100644`），**内容逐字节相同 ⇒ 所有门禁照绿**，只有 `git diff --summary` 看得见（已恢复）；**P175** 我的违规统计连报两趟 0（`--dry-run` 不带 `-Werror` 时违规也 rc=0），而负向反证打在**二进制**而非**我的循环**上 → 反证"通过"毫无意义。**P178** 给 `gate_scope.sh` 补 **R12**（`.clang-format`/`.editorconfig` → hygiene + 全量，**升档不降级**：射程本来就是全库 C/C++）之后，`UNCLASSIFIED` 第一次为空 → bash 3.2 `set -u` 下数组展开直接 `unbound variable`，且末段**无条件**喊"把路径加进规则里"（刚归类好的文件也被叫去修一个已经正确的路由）→ 拆 `NEED_FULL`（要不要全量）/`UNCLASSIFIED_FULL`（为什么）两位，档位标题随之分叉；R12 位置必须在 R11 **之后**（`linkcheck_docs.py` 不在 `run_gate.sh` 的 19 步里，只在 CI，放前面会把"文档+风格配置"同批 diff 的链接判据挤掉）。**同批订正门禁射程**：hygiene 的 clang-format 计数原先只扫 `engine/**`（115），而重排的 113 个文件里 **34 个在 `tests/**`** —— 那 34 个进门禁不在射程内，"非零即新代码"当场是假话；扩到五根 pathspec 后基数 **168**（与本卡口径同一行字），反证打在**完整路径**上：注入违规 → **1/168**，还原 → **0/168**，`cmp` 确认探针没污染工作树。`.clang-format` 头部从"描述存量"改口径为"基线 = 0，非零即新代码未按格式"，仍只报不判。**"只是空白"用字符级证据立住**：抽掉全部空白比校验和，113 个文件 **112 个逐字符相同**；唯一不同的 `chq_logging.h` 按字符频次对撞，差别只有反斜杠 18→32（宏体拆续行）。详见 `TASK-INFRA-046-全库clang-format重排.md` |

**并行批次**（写集不相交才可同批；高冲突登记文件 `.gitignore`/`run_gate.sh`/双 Podfile/AGENTS 真源
按 ADR-0030 归集成机串行，不算相交）：

- 批 1 = 026 ✅ → 批 2 = 027 → 批 3 = 028
- 批 4 = **029 ∥ 031 ∥ 035**（夹具 / UI 上提 / 文档归档，三者写集互不相交）
- 批 5 = 030（同写 `tests/CMakeLists.txt`，必须让在 029 之后）
- 批 6 = 032（同写双 Podfile + `run_gate.sh`，必须让在 031 之后；**传哲纪律：UI 与路径改名不同批**）
- 批 7 = 033 → 批 8 = 034（末批收口，依赖全部前序）
- **禁止并行**：029×030、031×032、027×任意（`.gitignore` 独占期）、034×任意（回填需最终路径稳定）

**关键路径**（决定最早交付）：026 → 027 → 028 → 031 → 032 → 033 → 034（7 批串行）。
029/030/035 三条支线均可挂进关键路径的空档批并行，不延长交付。

**明确不做**（传哲决策 9/10/11 + ADR-0044 §5）：C++/Swift 混进单一 `modules/`、
合并 `.ai`/`.workbuddy`/`.agents`/`.zcode`、AI 生成物改 ignored、本轮收编 TimelineKit（落待办池）。

---

## 16. 编辑页轨道区接入与回归（UIA-044/045 结卡 + 三条裁定转出，2026-10-17 新增；[ADR-0042](../decisions/ADR-0042-轨道区接入TimelineKit与内核真源方向.md) + [ADR-0034](../decisions/ADR-0034-分批推进与禁临时方案及署名台账.md)）

> **本节的号原本欠登记**：UIA-041~045 只有任务卡没有 BACKLOG 行（模块册有记录），
> 2026-10-17 回收时一次补齐。号段：**UIA-046**、**CORE-011** 为本轮新领（现取现核，无撞号）。

| ID | 层 | 任务 | 依赖 | 写集要点 | 验收（要点） | 状态 |
|---|---|---|---|---|---|---|
| UIA-044 | UI | 轨道区接入 TimelineKit（本地 Pod）+ `TimelineKitAdapter` / `EditorTimelineKitView` + 删除旧自绘 | UIA-034/039/040/041/043 | `ui/ChuanqiCutEditor/**`、双 Podfile、podspec 拆子 spec | 双壳 BUILD SUCCEEDED；内核唯一真源、翻译不了的命令一律回滚；不改调试页冒充 | ✅ 2026-10-17（合并版问卷整卷通过；回收口径=**传哲整体判定，未逐项勾选/无截图**） |
| UIA-045 | UI | 接入后四项回归：返回键分层 / 播放中编辑先暂停 / 拖轨道同步 seek / iPad 与 iPhone 统一 | UIA-044 | `ui/ChuanqiCutEditor/**`（AppEntry/TrackInteraction/EditorLayout/UIKit）+ 组件侧 3 处 | 底栏逐层退出；播放中编辑先停；iOS 只有一条轨道区实现 | ✅ 2026-10-17（同上回收趟；卡内「`.selectClip` 不暂停」一条**被 D5 裁定推翻**，转 UIA-046） |
| UIA-046 | UI | 播放中**点选片段也暂停**（D5 裁定的行为变更） | UIA-044/045 | `TrackInteraction.swift`、`EditorViewController.swift:585`、`TimelineInteractionTests.swift` | 点选后 `!isPlaying`；谓词改名 `isEditing`→`pausesPlayback`；81 例零回归 + 双壳 | ⏳ **待开工**（等传哲指令；一行级改动但要重命名语义 + 发一张小问卷收手感） |
| CORE-011 | SDK | 轨道静音写路径：`ChqTimeline::SetTrackMuted` + `ChqSetTrackMutedCommand` + `cq_session_set_track_muted` + Swift 穿透 + 适配层去回滚（E1 裁定） | 池 [19] | `cq_sdk.{h,cpp}`（**高冲突，集成机独占**）、`model/chq_timeline.*`、`command/chq_command.*`、`session/chq_editor_session.*`、`tests/unit/{command,session,abi}`、`api/swift/**`、`EditorTimelineKitView.swift`、`docs/api/engine-api.md` | 未知轨 `kInvalidArgument`；可撤销可重做；`--check` 符号 103→104；全量 18 步 + 双壳；**零改仓库外 TimelineKit** | ⏳ **待编码**（关池 [19] 的"待决策"态；`enabled` 是否同批由传哲定） |

**批次**：044 → 045（同域同批交付）→ 046 ∥ 011 之外**不得并行**（011 动 `cq_sdk.h`，
且其 Swift/UI 段与 046 同写 `EditorViewController.swift` 邻域——**046 先、011 后**，或反过来，串行）。
**关键路径**：CORE-011 → 轨道头恢复显示 →（B4 导出不含静音轨 / B5 混音 UI）。
**明确不做**（本节）：收编 TimelineKit（池 [20]）、iPad 常驻右栏（F3 已裁"接受现状"）、
锁定与轨道排序的写 ABI（内核仍无，UI 仍隐藏轨道头）。
