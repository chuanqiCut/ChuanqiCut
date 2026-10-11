# TASK-CAM-033：P1 检测裁剪 + 链路合并（美颜重构一期）

> SPEC：SPEC-CAM-033-035 §3.P1；RESEARCH-015 决策 1/4；状态：**编码中（2026-10-11 起）**

| 字段 | 内容 |
|---|---|
| layer | Implementation + 契约层纯函数 |
| goal | 美颜全关=零 Vision；磨皮脸框来自采集栈 metadataOutput（零 Vision 成本）；磨皮+美白单次混合 |
| input | RESEARCH-015、SPEC-CAM-033-035、VisionDetector/CameraManager/CameraBeauty 现状 |
| output | 契约层 `BeautyDetectionPlan`（开关→请求集合 + metadata→契约坐标转换纯函数）+ Impl 接线 |
| write_set | 契约层：`BeautyDetectionPlan.swift`(新)/`CameraBeauty.swift`；Impl：`VisionDetector.swift`/`CameraManager.swift`/`CameraViewModel.swift`；测试：`BeautyDetectionPlanTests.swift`(新)/`CameraBeautyTests.swift` |
| read_set | FaceMask.swift、FaceBoxStore（renderer 持有）、FaceObservation、baselines |
| deps | 无前置（RESEARCH-015 已拍板） |
| acceptance | 开关矩阵单测 / 混合等价 / Camera 62/62 不回归 / 壳构建绿 / 真机日志项挂池 [15] |
| verification | `swift test`（ChuanqiCutCamera）；iOS 壳 xcodebuild；真机项登记池 |
| risk | metadata 脸框坐标/方向一致性（真机标定，SPEC 开放问题 1）；detector 开关竞态（沿用 configLock） |
| parallel | 与 CAM-034 写集不相交（理论可并行），同模块串行执行；**CAM-035 依赖本卡**（CameraBeauty.swift 写集相交，禁止并行） |

## 子步骤

1. [x] 契约层 `BeautyDetectionPlan`：功能开关 → Vision 请求集合（纯函数，可单测）
2. [x] 契约层 metadata→契约坐标转换纯函数（归一化/y 翻转/镜像补偿，标定常数集中）
3. [x] CameraBeauty.apply 合并单次 Blend（数值等价：同 mask 两次嵌套线性插值 ≡ 一次）
4. [x] VisionDetector 请求开关化（configLock 内读 plan；全关且 metadata 可用 → 不 perform）
5. [x] CameraManager metadataOutput 接入（metadataQueue + rect 转换 + 前摄镜像）
6. [x] CameraViewModel 开关传递（美型/贴纸/美体参数变化 → detector plan）
7. [x] 单测：开关矩阵 + 合并 Blend 等价 + 坐标转换
8. [ ] 真机：metadata 脸框位置标定（前后摄×转屏）+ 全关零 Vision 日志核验 → 池 [15]

## 实现记录（2026-10-11）

- 提交 7082df3；Camera swift test **73/73**（62+11：开关矩阵 8/坐标 2/合并等价 1）；
  iOS 壳 BUILD SUCCEEDED（新文件 BeautyDetectionPlan.swift 走 pod install，P107 同族）。
- 实现要点与 SPEC 偏差：无（plan 增加 faceRectNeeded 参数 = 磨皮关时不跑兜底框，
  比 SPEC 初稿更省）；宠物贴纸判定用「任一贴纸选中」而非资产动物标记
  （StickerAsset 无类别字段，贴纸锚定本就有无脸落宠物兜底，语义保持）。
- 开放问题 1（metadata 脸框坐标/镜像语义）保持，真机标定后修正常数只动
  MetadataFaceGeometry 调用方。
