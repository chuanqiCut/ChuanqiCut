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



## 进度（2026-10-08 回写，HANDOFF-017 收口轮）

**状态：未开工（一行实现都没有）+ 本轮退掉了一处越权接线 —— 池 [9]**

- 上一会话在 `CameraRenderer.process` 里加过一段「语义蒙版」接线：
  `beauty.apply(to: image, faces: faces, skinMask: PortraitSemantics.skinMask(for: image))`。
  `PortraitSemantics` **从未实现**，且 `CameraBeautyParams` 没有 `skinMask:` 重载 → Pod 编不过。
  **2026-10-08 已回退**为 `currentBeauty().apply(to: image, faces: faces)`（原地留注释说清因果）。
- ⚠️ **开工口径以本卡为准**：卡里写明「API 形状保持 `apply(to:faces:)` 不变、调用方零改动」，
  所以正式实现应当是 **CameraBeauty 内部去取语义蒙版**，不是在调用方加参数（再犯就是 P89）。
- 卡的降级口径要守住：Vision API 不可用（<15 / <17）逐项降为关键点几何蒙版，**不伪造**；
  分割在检测队列跑（复用 latest-wins + 降频），蒙版半分辨率生成，采集/渲染零阻塞。
- 依赖面：CAM-029 的「唇齿/眉眼语义保护」等这张卡的供给；CAM-026 的腮红也排队等它做精修
  （v1 现用关键点几何近似）。


## 进度 2（2026-10-08 晚，接 HANDOFF-017 后继续）

**状态：v1（几何级精修）编码完成 —— 构建机门禁与真机未跑，仍挂池 [9]**

### 落地形状（**没有动 `apply(to:faces:)` 签名，卡约束守住了**）

| 文件 | 角色 | 可验证性 |
|---|---|---|
| `Sources/ChuanqiCutCamera/PortraitSkinMask.swift`（新） | 契约层纯函数：脸框椭圆 ∩ 「非眼/眉/唇区」 | macOS 可 typecheck、**已配单测** |
| `Sources/ChuanqiCutCamera/CameraBeauty.swift`（改） | 新增 `CameraBeautyEngine.semanticMask` 注入点（`CameraBeautySemanticMaskEngine`），`apply` 内 `semanticMask?(image, faces) ?? FaceMask.mask(...)`；`reset()` 一并清 | 注入点为 nil 时 **= 老行为逐位等价** |
| `Sources/ChuanqiCutCameraImpl/Detection/PortraitSemantics.swift`（新） | Impl 薄壳：`installSkinMask(faceBoxStore:)` 安装注入点 + `uninstallSkinMask()` | iOS 编译待构建机 |
| `Sources/ChuanqiCutCameraImpl/CameraViewModel.swift`（改 1 处） | 装配期（`if let faceBoxes = renderer?.faceBoxes`）安装注入点 | iOS 编译待构建机 |
| `Sources/ChuanqiCutCameraImpl/Detection/FaceBoxStore`（extension） | 补 `@unchecked Sendable`（它本来就是带 NSLock 的跨线程盒子，补宣告只为能进 `@Sendable` 闭包） | **并发契约变更**，门禁需确认 |
| `Tests/.../PortraitSkinMaskTests.swift`（新） | 7 用例：nil/退化回落、五官挖除（渲染采样）、注入点零回归 | `swift test` 待构建机 |

### 本期**明确不做**（写在文件注释里了，不是只在对话里说）

- **YCbCr 肤色聚类**：CI 侧没有廉价 branchless 门函数，`CIColorPolynomial` 三次多项式近似
  smoothstep 的精度无法自证 → 真语义分割归 **CAM-028 模型路线**。
- **头发分割**（`VNGenerateHairMaskRequest`，iOS 17+）：本机 iPhoneSimulator SDK 15.0
  **没有该符号**（已核验），写下必然编不过 → 等带 iOS 17+ SDK 的工具链，且要配 `@available` 门控。
- **人像分割**（`VNGeneratePersonSegmentationRequest`）：本机 SDK 15.0 里有头文件（已核验），
  但坚持 v1 先几何、不上模型——模型路线的精度与帧预算，要真机实测才有数字。
