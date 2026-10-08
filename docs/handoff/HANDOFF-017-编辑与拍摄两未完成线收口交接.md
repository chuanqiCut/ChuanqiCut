# HANDOFF-017：编辑（AIEDIT-001）× 拍摄（CAM-026/027/029）两条未完成任务收口交接（2026-10-08）

> 接手人开第一步前**必读本文件**；配套：`.ai/modules/ai.md`「AIEDIT-001 落地形状」、
> `.ai/modules/camera.md` 模块册、`docs/tasks/TODO-POOL-门禁真机待办池.md` [8][9]。
>
> ⚠️ **要去构建机/真机上把数字跑出来的，执行入口是池 [10]**（2026-10-08 立）：
> 命令清单（7 条）+ 必须记录的参数表 + 回填位置逐项勾。池 [8][9] 只列待办，
> 池 [10] 负责「怎么跑、记什么、写回哪儿」。
>
> 本轮定位：扫出上一会话（另一工具在本机同一工作区）在**编辑**与**拍摄**两条线上留下的
> **未提交、未验证**的两堆工作，做可核查的收口：**一处会让整个相机 Pod 编不过的半成品
> 接线已回退**，其余改动原样保留，差额全部登记进池。未经传哲点头，本轮**没有**跑门禁、
> 没有跑全量测试、没有提交/push。

## 0. 本交接要交接什么

| 线 | 卡 | 编码 | 本机可做的验证 | 卡住的地方 |
|---|---|---|---|---|
| **A 编辑** | AIEDIT-001 智能成片契约冻结 | ✅ 完成 | clang 直编最小组合实跑 **117 检查 0 失败** | 缺 cmake/ninja，ctest 通道与 `build_core.sh -Werror` 没跑（池 [8]） |
| **B 拍摄** | CAM-026 美妆 + CAM-027 人像分割 + CAM-029 磨皮升级 | 026/027 编码收口，**029 待拍板** | 026/027 单测已补（本机跑不了） | **一处引用不存在符号的 CAM-027 接线已回退**；Impl 层本机编不了（Xcode 13.1）；本机**未跑任何构建/测试**，全部数字为空 |

## 1. 硬性环境事实（接手人先认，别按旧记录假设）

实测（`sw_vers` / `xcodebuild -version`）：

- macOS **12.7.6**、Xcode **13.1**、Apple Swift **5.5.1**、iPhoneSimulator SDK **15.0**
- **无** `cmake`、无 `ninja`、无 `brew`
- 后果：① iOS Pod（部署目标 iOS 16、代码已用 `if let x {` Swift 5.7 简写）**在本机编不了**；
  ② SPM 包 `swift-tools-version:6.1` **swiftpm 5.5 解析不了** → `swift test` 也跑不了；
  ③ `build_core.sh` / `ctest` 跑不了。
- ⚠️ `.workbuddy/memory/MEMORY.md` §17 旧表把本机写成「macOS 26.7.1 / Xcode 26.6」，与实际
  不符（P90）。**引用 baselines 里任何"本机实测"数字前，先确认它出自哪台机器**。

## 2. A 线：AIEDIT-001（编辑 / 智能成片契约冻结）——编码完成，只差构建机门禁

### 2.1 状态与交付物

全部**未提交**（`git status` 可见），路径与分工见 `docs/tasks/TASK-AIEDIT-001.md`「进度」表
（2026-10-08 已回写，本轮未改代码）。

| 文件 | 内容 |
|---|---|
| `engine/core/include/cq/ai/{feature_report.h, edit_plan.h, llm_client.h}` | 新契约头：`cq.featurereport/1`、`cq.editplan/1`（动词集 9）、ILlmClient |
| `engine/core/include/cq/pal/net.h` | INetTransport（PostJson / PostSse），SSE 拆帧边界 |
| `engine/core/include/cq/base/status.h` + `src/base/status.cpp` | 追加 `kAiPlan*` 段 **9500~9513** + 分类 11（只追加，不动既有段） |
| `engine/core/src/ai/plan/edit_plan_validator.{h,cpp}` | 三层校验：手写 JSON → 结构 → 语义（私有头） |
| `engine/core/src/ai/plan/edit_plan_golden/` | 58 JSON 夹具 + `manifest.txt`（**append-only 真源**，生成脚本用后即删） |
| `tests/unit/test_edit_plan_validator.cpp` | manifest 驱动 + 码值 static_assert + 名往返 |
| `engine/core/CMakeLists.txt`、`tests/CMakeLists.txt` | 源登记 + 测试目标 `ai_edit_plan`（测试需 `-I engine/core/src` 拿私有头，已写） |

### 2.2 已有验证证据

上一会话测得；本轮**未重跑**（用户要求不跑）所述的 clang 直编结论：

```
clang++ -std=c++20 -Wall -Wextra -Wconversion -Wshadow -Wold-style-cast \
  -I engine/core/include -I engine/core/src \
  -DCQ_EDIT_PLAN_GOLDEN_DIR='"engine/core/src/ai/plan/edit_plan_golden"' \
  tests/unit/test_edit_plan_validator.cpp \
  engine/core/src/ai/plan/edit_plan_validator.cpp engine/core/src/base/status.cpp
→ 合法通过: 18  非法精确匹配: 40 / 总 58；117 项检查，0 项失败
```

### 2.3 下一步（按序）

1. **池 [8]（第一优先，换机做）**：有 cmake/ninja 的机器上 `build_core.sh --platform=apple`
   （-Werror）+ `ctest -R ai_edit_plan`。风险面只在 CMake 注册（本机已经有一条等价的直编证据）。
2. 真机无涉（纯 C++ 契约层）。
3. 解锁后并行排的下批卡：`AIEDIT-002`（视觉特征，产出 feature_report）、`AIEDIT-004`
   （ILlmClient 实现 + `pal/apple/net`）、`AIEDIT-011`（本地规则引擎，同 schema，
   `generator="local_rules"`）；`AIEDIT-005` 依赖 004+011，`AIEDIT-006` 依赖 001 可先行。

### 2.4 冻结裁定（下游卡开工前必读）

- 动词集 = **9** 个（SPEC §6.1 行文"八个"系笔误，枚举清单为准）。
- 浮点秒**双形态**都要拦成 `kAiPlanFloatTime`：`0.5` 与 `{"value": 0.5}`，且在形状检查**之前**。
- 未知**字段**忽略；未知 **op / 转场 / schema 版本**拒绝。扩展走版本号，不走私加字段。
- 校验器**没有时间线上下文**：`trim_clip` / `remove_range` / `set_transition` 的落点校验归 AIEDIT-006。
- `EditPlanAction` 字段存在性用 `has_asset` / `has_shot` 标志判，别用空串/缺省值判。
- op 名映射实现必须在 `namespace cq` 直层（曾放 `cq::ai` 导致歧义调用）。
- 任务卡写 `core/`，仓库实际是 `engine/core/`（全仓简写约定，不是漂移）。

## 3. B 线：拍摄侧 CAM-026/027/029 —— 本轮已排雷，仍有明确缺口

### 3.1 本轮做了什么（唯一代码改动）

`CameraRenderer.process(...)` 里有一段**引用未实现符号**的接线，会让 **ChuanqiCutCamera
Pod 整包编译失败**：

```swift
// 原（不可编译）
result = beauty.apply(to: image, faces: faces,
                      skinMask: PortraitSemantics.skinMask(for: image))
```

- `PortraitSemantics` 全仓只有 `TASK-CAM-027.md` 的 write_set 里有，**没有任何实现**；
- `CameraBeautyParams` 也只有 `apply(to:faces:)`，**没有 `skinMask:` 重载**（唯一签名见
  `Sources/ChuanqiCutCamera/CameraBeauty.swift:91`）。

已回退为 `var result = currentBeauty().apply(to: image, faces: faces)`，并留注释说明为什么退、
正确形态是什么。全仓再无 `PortraitSemantics` / `skinMask` 引用。

⚠️ 顺带一条**作业面检查结论**：这段接线同时违反了 CAM-027 卡自己的约束——卡里写明
「API 形状保持 `apply(to:faces:)` 不变、调用方零改动」，正确做法是改 `CameraBeauty` **内部**
取语义蒙版，而不是给调用方加参数。接手人写 CAM-027 时按卡的口径来。

### 3.2 保留下来未提交的改动（原样，未验证）

| 文件 | 内容 | 缺什么 |
|---|---|---|
| `Sources/ChuanqiCutCamera/MakeupParams.swift`（新） | CAM-026 契约层：`MakeupParams` + `MakeupAnchors` + `enum MakeupMask`（唇/腮红/眼影/眉/美瞳纯函数蒙版） | **零单测**（纯函数、可测，理应 `swift test`）——本机 swiftpm 跑不了，池 [9] |
| `Sources/ChuanqiCutCameraImpl/Effects/MakeupRenderer.swift`（新） | CAM-026 着色混合（唇/眼影 multiply、腮红 soft-light、眉/美瞳 over） | 同上；依赖 Impl 编译 |
| `CameraRenderer.swift` | FaceBoxStore 增 `updateMakeupAnchors/currentMakeupAnchors`；renderer 增 `setMakeup`；`process` 增 `makeupAnchors` 参数；reset 清理 | Impl 编译未验 |
| `CameraRecorder.swift` | 录制路径增 `makeup` 参数（开始录制锁定）+ 处理链插位（磨皮/美型之后、滤镜之前） | Impl 编译未验；录制 WYSIWYG 真机未验 |
| `CameraViewModel.swift` | `@Published var makeup` + detection 回调产出锚点 + 录制传参 | Impl 编译未验 |
| `CameraView.swift` | 美妆面板（自然/元气/浓颜/无）+ 图标/重置联动 | Impl 编译未验（依赖 SharedUI） |
| `Effects/beauty_bilateral.metal` | CAM-029 部分项：新增 `cq_beauty_protect`（唇齿/眉眼色域保护）与 `cq_beauty_sigma_local`（亮度分档自适应 σ），**只在 pass1 `cq_beauty_down_h` 用了** | 见 3.3 |

「CameraRecorder 构造点唯一（`CameraViewModel.swift:376`）」已同步传参 —— 构造点唯一，无漏改。
podspec `source_files` 用通配 `Sources/ChuanqiCutCamera/**/*.swift`，新文件自动纳入，无需登记。

### 3.3 CAM-029（磨皮算法升级）接手人必看的三点

1. **不对称**：保护与自适应 σ 只在 **pass1（下采样水平双边）** 生效，pass2 `cq_beauty_up_v_mix`
   仍用原始 `sigma_range`。是"有意保留 pass2 干净"还是"漏改"，上一会话没留下结论 ——
   **开工第一条就是找传哲定这一点**，别自己猜。
2. **参数面没动**：卡的 write_set 里有 `BeautyKernel.swift`，但本轮没有改它 → kernel 参数面
   （protect 强度 0.85、σ 分档 0.6×~1.4×）现在是**写死常量**。要不要开出来、怎么曝给你们两边都留道题。
3. **验收项远没完成**：卡片要的三件事里「①细节回注」**完全没做**，「②唇齿/眉眼保护」只做了
   **色域兜底**（卡里写明语义保护应由 026 唇蒙版 / 027 语义供给）。缺 `beauty_harness` 剖面
   实测（保边保持率 ≥60%、高频能量恢复 ≥80%、全脸 ≤8ms）。

### 3.4 CAM-027（人像理解底座）—— 仍然未开工

卡、意图都在（`TASK-CAM-027.md`），**一行实现都没有**。要做的事：皮肤/头发/人像分割
（`PortraitSemantics.swift`），消费端把美颜蒙版从「框椭圆」换成「语义 ∩ 框」，且 **API 形状不变**。
卡里的降级口径必须守住：Vision API 不可用（<15 / <17）逐项降为关键点几何蒙版，**不伪造**。

### 3.5 后续编码轮（2026-10-08 晚）：CAM-026 单测补齐 + CAM-027 v1 落地

> 接手人被要求「继续做下去」时看的正是这一节。约束不变：**没有跑任何编译/测试/门禁**
> （传哲指令），所以以下代码全部处于**未验证**状态，验证清单统一在池 [9]。

1. **CAM-026：单测缺口填平** —— 新增 `Tests/ChuanqiCutCameraTests/MakeupMaskTests.swift`（10 用例）：
   凸包剔除内部点、点数不足的处理、`ciPoint` y 翻转、extent 恒等于画面（P81 那条坑的机器防线）、
   **唇内挖空的渲染采样断言**（牙齿保护）、参数越界夹取、预设键名锁定。
2. **CAM-027：v1 落地（几何级精修）**，形状如下 —— 关键点是**没动任何调用方签名**：

   | 文件 | 角色 |
   |---|---|
   | `Sources/ChuanqiCutCamera/PortraitSkinMask.swift`（新） | 契约层纯函数：脸框椭圆 ∩ 「非眼/眉/唇区」 |
   | `Sources/ChuanqiCutCamera/CameraBeauty.swift`（改） | 加 `CameraBeautyEngine.semanticMask` 注入点；`apply` 内 `semanticMask?(image, faces) ?? FaceMask.mask(...)`；注入点为 nil = **老行为逐位等价** |
   | `Sources/ChuanqiCutCameraImpl/Detection/PortraitSemantics.swift`（新） | Impl 薄壳：安装/摘除注入点，算法一行不放 |
   | `Sources/ChuanqiCutCameraImpl/CameraViewModel.swift`（改 1 处） | 装配期安装（`if let faceBoxes = renderer?.faceBoxes`） |
   | `CameraRenderer.FaceBoxStore`（extension） | 补 `@unchecked Sendable`（它本来就是带 NSLock 的跨线程盒子）→ **并发契约变更，门禁要确认** |
   | `Tests/.../PortraitSkinMaskTests.swift`（新） | 7 用例：nil/退化回落、五官挖除（渲染采样）、注入点零回归（注入全黑 → 美颜整图不动） |

3. **本期明确不做**（已写进文件注释，不是只在文档里说）：
   - **头发分割**（`VNGenerateHairMaskRequest`，iOS 17+）：本机 SDK 15.0 **查不到该符号**（已核验），
     写了必然编不过 → 等 iOS 17+ SDK 工具链 + `@available` 门控。
   - **YCbCr 肤色聚类**：CI 侧没有廉价 branchless 门函数（`CIColorPolynomial` 三次多项式近似
     smoothstep 精度不可自证）→ 真语义分割归 **CAM-028 模型路线**。
   - **模型路线**（`VNGeneratePersonSegmentationRequest` 在本机 SDK 15.0 头文件里存在，已核验）：
     v1 坚持纯几何，不上模型 —— 模型带来的精度收益与帧预算要真机实测才有数字。
4. **CAM-029 没动**：等传哲给一句话——pass2 要不要跟着改（详见 §3.3）。这句没给之前，
   改 pass2 就是把「不确定」写成「确定」。

## 4. 待办落账（本轮新登记）

- **池 [9]**（新，见 `docs/tasks/TODO-POOL-门禁真机待办池.md`）：相机侧三条 —— Impl 编译验证 /
  CAM-026 契约单测补齐 / CAM-029 三个未决问题。
- **pitfalls P89**：跨会话半成品接线引用未实现符号（整包编不过）+ 改动违反本卡明文约束。
- **pitfalls P90**：交接必须写明本机工具链能力；旧记录（MEMORY §17「macOS 26.7.1 / Xcode 26.6」）
  与实际（12.7.6 / 13.1）漂移，会让人误以为本机可以跑 cmake 与 iOS 编译。
- 顺手修号：池 [7] 里待落账的坑原写 P86/P87，**P86 已被「同机双会话」占用** → 改成 P87/P88。

## 5. 工作区当前状态（未提交，接手人接手前先看 `git status`）

- 修改：上述相机 6 文件 + AIEDIT 的 `status.h/cpp` + 两个 CMakeLists + `docs/tasks/TASK-AIEDIT-001.md`
  + TODO-POOL + `.ai/modules/ai.md` + `.ai/memory/baselines.md`
- 新增：`MakeupParams.swift`、`MakeupRenderer.swift`、`engine/core/include/cq/ai/`、
  `engine/core/include/cq/pal/net.h`、`engine/core/src/ai/`、`tests/unit/test_edit_plan_validator.cpp`、
  本文档、`docs/` 其他回写
- **未 commit、未 push** —— 是否提交由传哲定。若要提交，建议按 P86 规约拆成两个提交
  （AIEDIT-001 一条 / 相机 C 期一条），别让一个提交混两条线。

## 6. 记录索引

- 任务卡：`TASK-AIEDIT-001.md`（进度表齐全）、`TASK-CAM-026.md` / `TASK-CAM-027.md` / `TASK-CAM-029.md`（本轮补了进度段）
- 池：`TODO-POOL-门禁真机待办池.md` [8]（AIEDIT 门禁）、[9]（相机，新）
- 模块册：`.ai/modules/ai.md`、`.ai/modules/camera.md`（本轮补记录行）
- 坑：`.ai/memory/pitfalls.md` P89 / P90
- Spec / ADR：`docs/specs/AIEDIT-001-智能成片.md` §4-§7、ADR-0020
- 既有参照：HANDOFF-016（AIEDIT-001 契约冻结编码轮）
