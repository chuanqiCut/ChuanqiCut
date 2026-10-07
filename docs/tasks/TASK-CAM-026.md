# TASK-CAM-026：美妆——关键点区域着色（C 期）

```yaml
id:          TASK-CAM-026
layer:       UI(iOSApp)
goal:        唇色/腮红/眼影/眉毛/美瞳五类区域美妆：CAM-011 关键点（outerLips/innerLips/
             左右眉/左右眼区域）→ 区域蒙版 → 着色混合（multiply/soft-light 光照语义），
             强度滑杆；妆容资产包（色板+区域组合）清单化
input:       [传哲 2026-10-07 定则（人像能力算法驱动，拒绝滤镜式全画面）,
             SPEC-CAM-001 §3 C 期, TASK-CAM-011(区域关键点已就绪), ADR-0014]
output:      [ChuanqiCutCamera/MakeupParams.swift(参数纯函数 + 区域蒙版构建),
             ChuanqiCutCameraImpl/Effects/MakeupRenderer.swift(着色混合),
             妆容资产清单 + UI 面板]
write_set:   apps/apple/packages/ChuanqiCutCamera/Sources/ChuanqiCutCamera/MakeupParams.swift,
             apps/apple/packages/ChuanqiCutCamera/Sources/ChuanqiCutCameraImpl/Effects/MakeupRenderer.swift
read_set:    Detection/FaceObservation.swift(区域契约), FaceMask.swift(蒙版惯例),
             RESEARCH-009(对标), TASK-CAM-027(分割底座——精修依赖)
deps:        [TASK-CAM-011]
acceptance:
  - 无脸直通（算法驱动定则）；区域蒙版由关键点生成（ Lips 多边形/眼窝椭圆+羽化）
  - 唇色混合保护牙齿/口腔高光（色域排除）；妆容随表情/头动跟随无漂移
  - 妆容参数纯函数单测（蒙版几何/混合模式单调，统一测试轮）
verification:  swift test（契约层）+ iOS 构建；真机妆容观感归传哲
risk:        76 点唇部精度对唇线贴合有限（升级依赖 CAM-028 网格）；腮红需要脸颊
             皮肤分割精修（依赖 CAM-027），v1 用关键点几何近似
parallel:    false
```

## 实现要点

- 区域蒙版：唇 = outerLips 多边形填充（含 innerLips 挖洞保护口腔）；眉/眼影 =
  区域点集凸包 + 羽化；美瞳 = 瞳孔圆域。全部归一化坐标 → CI 蒙版（复用 FaceMask 惯例）。
- 混合：multiply（唇色/眼影）与 soft-light（腮红）两语义；强度 = 原图/着色插值。
- 处理链插位：磨皮/美型之后、滤镜之前（妆容贴皮肤，滤镜再统一调色）。
