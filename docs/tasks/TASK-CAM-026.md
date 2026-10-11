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



## 进度（2026-10-08 回写，HANDOFF-017 收口轮）

**状态：编码完成（未提交），构建机门禁未跑；契约层单测 0 用例 —— 池 [9]**

| 子步骤 | 状态 | 证据 / 缺口 |
|---|---|---|
| 契约层 `MakeupParams.swift`（参数 + `MakeupAnchors` + `enum MakeupMask` 五区域蒙版） | ✅ 已落盘 | 本机 `swiftc -typecheck`（macOS SDK，Swift 5.5）通过；**注意这不是完整验证** |
| 实现层 `Effects/MakeupRenderer.swift`（multiply / soft-light / over 三语义） | ✅ 已落盘 | Impl 层本机编不了（Xcode 13.1 + iOS 16 目标 + Swift 5.7 简写） |
| 五路接线（ViewModel 状态 / 渲染链插位 / 录制锁定 / FaceBoxStore 锚点 / UI 面板） | ✅ 已落盘 | 同 Impl；`CameraRecorder` 构造点唯一（`CameraViewModel.swift:376`）已同步 |
| **契约层纯函数单测** | ❌ **零用例** | 卡的 acceptance 明写「妆容参数纯函数单测（蒙版几何/混合模式单调）」——最大缺口 |
| iOS 双壳构建 + Camera 契约 `swift test` | ❌ 未跑 | 池 [9] |
| 真机观感（五区域跟随 / 口腔保护 / 强度单调 / 预览=录制） | ❌ 未跑 | 池 [9]，归传哲一体趟 |

备注：本轮 **顺带退掉了一处会让整包编不过的 CAM-027 半成品接线**
（`PortraitSemantics.skinMask` 无实现），与 CAM-026 无关但同批改动 —— 详见 HANDOFF-017 §3.1 / P89。


## 进度 2（2026-10-08 晚）

**单测缺口已补**：新增 `Tests/ChuanqiCutCameraTests/MakeupMaskTests.swift`（**13 用例** ——
三份文档曾误记 10，2026-10-08 构建机按源码数核对后订正）：

| 用例组 | 断言什么 |
|---|---|
| 纯几何 | 凸包剔除内部点 / <3 点原样返回 / `ciPoint` y 翻转（0.25 → CI y = 75） |
| 蒙版契约 | 点数不足 → nil；**extent 恒等于画面**（P81：CIGaussianBlur / CIRadialGradient 后必须 cropped 回） |
| 渲染采样 | 多边形内白外黑；**唇内挖空**：给 innerLips 后唇中心必须显著变暗（牙齿保护的机器防线） |
| 参数契约 | 强度越界夹取到 0...1；`off` 恒等；预设键名 `["自然","元气","浓颜"]`（UI 写死，改名要同步 CameraView） |

仍 unverified（本机 swiftpm 5.5 解析不了 tools-version 6.1）= 池 [9]。

## 进度 3（2026-10-08 深夜·构建机实测，机器 macOS 26.7.1 / Xcode 26.6 / Swift 6.3.3）

**状态：Camera 包 `swift test` 全绿 57/57；本卡 13 用例全过；真机观感仍待传哲一趟**

| 子步骤 | 状态 | 证据 / 缺口 |
|---|---|---|
| 契约层 `MakeupParams.swift` | ✅ | `swift test`（SPM 宿主）通过 |
| 实现层 `Effects/MakeupRenderer.swift` | ✅ 编过 | App target 首次真编译通过（`-scheme ChuanqiCutApp`，device SDK） |
| 五路接线 | ✅ 编过 | 同上；`FaceBoxStore` 的 `@unchecked Sendable` 扩充**无新告警** |
| 契约层单测 13 例 | ✅ | 首跑 2 例失败（真 bug，见下）；修完 13/13 |
| iOS 双壳构建 | ✅ 见下 | 先 `pod install`（P92），再用 device SDK（simulator SDK 无 MetalFX） |

**首跑抓出的两个真 bug（都已修，附根因）**：
1. `irisMask` extent = (43,43,14,14) 不是画面 —— `CIImage.cropped` 是**交集**不是外扩，
   有限大小的 `CIRadialGradient` 裁回画面拿不到画面 extent；改 `composited(over:)` 黑底画布再裁（**P91**）。
2. 三角蒙版内部采样 195 < 阈值 200 —— 羽化 `0.02 × 画布高` 在 100px 小画布 = 2px，足够把
   20px 小三角的形心压暗；羽化加 1px 下限，断言改取真正内部点。

**真机待办（池 [9]，归传哲）**：五区域跟随无漂移 / 口腔（牙齿）不染色 / 强度滑杆单调 / 预览=录制色。
