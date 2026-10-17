# engine/shaders/native/ —— Platform-Native 层（**预留，本期为空**）

红线 #6 的 Shader 双层在目录上的落点：

| 层 | 位置 | 约束 |
|---|---|---|
| Portable | `engine/shaders/portable/*.glsl`（GLSL 4.50 Vulkan 方言） | **禁止平台扩展**；经 `tools/shaders/build_shaders.py`（glslang → SPIR-V → spirv-cross）转译成各端代码，是功能基线 |
| Platform-Native | `engine/shaders/native/<os>/*` | 可用满平台特性（如 Metal 专属），**永远可选** |

Platform-Native 的准入四条（与 `cq-shader-portability` 一致，逐条核过才允许合入）：

1. 必须先有 Portable 实现且能跑通 —— 本目录不得成为某功能的唯一实现路径。
2. 收益 ≥ 20%（实测数字，不是估算；查 `.ai/memory/baselines.md`）。
3. 只在 `engine/shaders/native/<os>/`，**不得**进 `portable/` 或 `engine/core/`。
4. 平台特化产物由该平台构建链消费，不进跨端共享的生成链。

## 为什么这里目前没有文件

- 本期唯一的 shader 是 blit（`portable/blit.{vert,frag}`），Portable→MSL 链已覆盖 iOS/macOS 需求，
  没有触发第 2 条的实测收益，故不建 Native 版本。
- 相机美颜的三个 `.metal`（`ui/ChuanqiCutCamera/Sources/**/Effects/*.metal`）**不归本目录**：
  它们在 UI Pod 内随 App bundle 编译、是相机效果实现而非引擎渲染资产，
  且 ADR-0031 阶段 4 实测 script_phase 产物到不了 App bundle（P85）。

产物落点与源码目录分开：生成物一律进 `build/generated/shaders/`（`CQ_GENERATED_SHADER_DIR`，
由 `engine/platform/apple/CMakeLists.txt` 承接），不入库。
