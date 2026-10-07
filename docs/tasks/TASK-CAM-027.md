# TASK-CAM-027：人像理解底座——皮肤/头发/人像分割（C 期，效果追平的前置）

```yaml
id:          TASK-CAM-027
layer:       UI(iOSApp)
goal:        把美颜的「脸框椭圆蒙版」升级为「语义蒙版」：皮肤分割（肤色域 + 关键点联合）
             / 头发分割（iOS 17+ VNGenerateHairMaskRequest）/ 人像分割（iOS 15+
             VNGeneratePersonSegmentationRequest，qualityLevel=.balanced），供磨皮/美白/
             美妆/背景虚化(CAM-023) 精修消费
input:       [传哲 2026-10-07 定则, RESEARCH-009 §差距1（人像理解底座是主流差距的第一根因）,
             ADR-0005(推理策略), ADR-0014]
output:      [ChuanqiCutCameraImpl/Detection/PortraitSemantics.swift(分割调度+蒙版融合),
             消费方接线（CameraBeauty 蒙版升级为 语义∩脸框）]
write_set:   apps/apple/packages/ChuanqiCutCamera/Sources/ChuanqiCutCameraImpl/Detection/PortraitSemantics.swift,
             ChuanqiCutCamera/CameraBeauty.swift(蒙版消费升级)
read_set:    .ai/modules/camera.md, Apple Vision 文档, pitfalls P49 族（Sendable）, RESEARCH-009
deps:        [TASK-CAM-011(检测桥结构复用)]
acceptance:
  - 磨皮/美白蒙版 = 皮肤语义 ∩ 脸框：发际/眉毛/眼睛/唇不再被波及（对比 019 框级蒙版）
  - 分割降频运行（复用检测桥 latest-wins + 降频纪律），采集/渲染零阻塞
  - Vision API 不可用（<15/<17）逐项降级为关键点几何蒙版，不伪造
  - 真机：发丝边缘无磨皮波及（对比验收）
verification:  iOS 构建 + 真机对比归传哲
risk:        肤色域分割无系统 API——v1 用 YCbCr 肤色聚类 ∩ 脸框 [E]；漂发/深肤色
             泛化依赖 CAM-028 的模型路线补齐
parallel:    false
```

## 实现要点

- 分割在检测队列跑（与关键点同队列/同降频闸门），蒙版降采样半分辨率生成、全分辨率采样。
- 消费：CameraBeauty 的 mask 来源从「框椭圆」换成「语义蒙版 ∩ 框」；API 形状保持
  `apply(to:faces:)` 契约不变（内部升级），调用方零改动。
- 性能：VNGeneratePersonSegmentationRequest balanced 档 1080p ≈ 3~6ms [E]，15Hz 降频
  占帧预算 ~5-9% [E]，真机实测入库后定频。
