# ADR-0013：相机特效 Shader 先行 Native 层与 Portable 欠账

- **状态**：**已作废（2026-10-04，被 ADR-0014 取代）** —— 同日 CAM-001 契约回退，
  相机特效改走 App 层（iOS 原生），本 ADR 的"落层欠账"对象不复存在。
  以下原文留档。
- **日期**：2026-10-04
- **相关**：AGENTS 架构红线 #6、ADR-0002（Shader 中间表示）、ADR-0010（Apple 优先基线）、SPEC-CAM-001 §4

## 背景

红线 #6 要求 Portable shader 层（`shaders/src/*.glsl` → SPIR-V）先于 Platform-Native。
但现状（RESEARCH-002 §2.2-5）：`shaders/src/` 为空，SHADER-001（GLSL→SPIR-V→MSL 工具链）
与 DEPS-030 未启动，Metal 后端的 SPIR-V 路径直接返回 `kInternal`（`gfx_metal.mm:581-583`）。
既有先例：预览 blit shader 就是 Platform-Native MSL（`pal/apple/shaders/blit_fullscreen_msl.h`），
当时无 Portable 层可先行。

相机实时特效（LUT/磨皮/美型 warp）若先建工具链，估算新增 1~2 周纯基建，
延迟"真机看到效果"（ADR-0010 §6 的真机验证导向）。

## 决策（提案）

1. **相机特效 shader 本期落 `pal/apple/shaders/`（Platform-Native MSL）**，与 blit 同层同装配模式；
2. **欠账显式登记**：Portable 基线（GLSL 版特效 shader + SHADER-001 工具链 + Metal SPIR-V 路径打通）
   作为 **Android 阶段（Phase 3）启动的硬前置**，登记进 TASK-BACKLOG（新条目 SHADER-001 优先级提升）；
3. 特效的**算法与参数生成在 core（C++）**，shader 只做执行 —— 保证将来 Portable 化只动 shader 文本与装配，
   不动算法层（三端一致性的实质保障）；
4. Android 端实现特效时**禁止**再写一套原生 GLSL 特效（届时 Portable 层必须已就位）。

## 备选方案

| 方案 | 否决/保留理由 |
|---|---|
| 先建 SHADER-001 工具链再写特效 | 守红线但显著延迟相机交付；工具链本身价值独立（COLOR-002/AI-020 都要），不因此任务绑架排期 |
| 特效算法放 Swift/App 层 | 违反红线 #1（除 UI 外一切下沉 C++） |

## 后果

- 正面：相机交付提前；Apple 端可用满 Metal 特性（发挥 iOS 优势的用户诉求）。
- 负面/成本：`pal/apple/shaders/` 特效 MSL 将来要重写为 Portable GLSL（文本级重写，装配层不变）；
  三端一致性暂时只有"算法层一致"没有"shader 层一致"，**golden 像素对比对 Android 期才生效**。
- 反转条件：Android 阶段启动而 SHADER-001 未完成 → 阻塞 Android 特效，必须先补欠账。

## 落地任务

TASK-CAM-003（首个落层者）；TASK-BACKLOG 新增 SHADER-001 提前条目（Android 前置）。
