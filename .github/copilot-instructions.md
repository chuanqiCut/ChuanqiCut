<!-- GENERATED from .ai/source/AGENTS.root.md — DO NOT EDIT -->
完整规则见 [`.ai/source/AGENTS.root.md`](../../.ai/source/AGENTS.root.md)。

## 项目
跨平台视频编辑 SDK + 原生 App。`core/`=C++20 内核，`pal/`=平台适配，`apps/`=原生 UI。
iOS/macOS(P0) → Android(P1) → HarmonyOS(P2 仅预留)。

## 生成代码时遵守
- 业务逻辑放 `core/`（C++20），不要生成把业务逻辑写进 Swift/Kotlin 的代码。
- 时间用 `RationalTime{value, timescale}`，不要用浮点秒或 `Double` 表示时间。
- 不要在 `core/` 的头文件中引用任何平台原生类型。
- 特性可用性用 `cq_query_capability()` 判断，不要用编译期宏推断。
- Shader 分两层：`shaders/src/*.glsl` 是 Portable 层（禁平台扩展，由构建链生成各端代码，不要手写目标代码）；平台特化 shader 只放 `pal/<platform>/shaders/`。
- 平台特化必须是可选加速：先有 Portable 实现，且性能收益 ≥ 20% 才值得加。
- 公共头 `core/include/cq/cq_sdk.h` 只用 C 类型与 opaque 句柄。
- 音频路径不要加锁、不要动态分配。
- 引用第三方库前先确认已在 `third_party/manifest.toml` 登记。

## 提交前
运行：编译 + 相关单测 + golden 对比（渲染/导出相关）。附上命令与结果。
