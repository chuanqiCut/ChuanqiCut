# TASK-CAM-001：相机契约冻结（PAL camera.h + 能力枚举 + C ABI）

> **状态：已回退（2026-10-04 当日）——被 ADR-0014 取代**
>
> 本卡曾按跨端契约路线完成（`pal/camera.h` + 3 个能力枚举 + `cq_sdk.h` 相机 ABI 段，
> 门禁 40/40）。同日传哲指示相机模块"发挥 iOS 优势、不强套跨端逻辑"，契约整体
> 回退（`git checkout` 7 个文件 + 删 2 个新文件，复跑门禁 **39/39**）。
>
> **留档价值**：契约设计中的语义决策（latest-wins 帧策略、lease 模型、
> 120000 网格 pts、状态码映射）被 ADR-0014 的原生实现继承；
> `AVCaptureMultiCamSession` 仅 iOS 等事实记入 pitfalls P44 与 pal.md。
> 详见 `docs/decisions/ADR-0014-相机模块采用iOS原生栈.md`。
