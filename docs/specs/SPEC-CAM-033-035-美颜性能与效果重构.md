# SPEC-CAM-033-035：相机美颜性能与效果重构（三期）

> 日期：2026-10-11；来源：RESEARCH-015（传哲已拍板"OK 可以"，2026-10-11）
> 拆卡：TASK-CAM-033（P1 检测裁剪）/ TASK-CAM-034（P2 磨皮内核）/ TASK-CAM-035（P3 蒙版语义+美白重做）
> 顺序约束：P1 先行；P2/P3 互相独立，可换序（默认 P2 先）

## 1. 目标（用户价值）

1. **卡** → 美颜开/关都在 iPhone 17 Pro 上流畅：预览处理耗时 ≤5ms @1080p [E]，
   美颜全关时零 Vision 调用（检测成本≈0）。
2. **效果差** → 磨得净且有细节（纹理保留系数可调）、脸缘无断层、美白不塑料。
3. **发挥 iOS 系统优势**：采集栈原生人脸框（AVCaptureMetadataOutput）、
   GPU 人像分割（VNGeneratePersonSegmentation）、ANE 按需利用。

## 2. 非目标

- **不建自研渲染管线**（红线 #9：随 RENDER-001；本三期全部在现 CI 链内）。
- 不引入第三方美颜/推理 SDK（商 SDK 路线已否决）。
- 不做拍照路径降分辨率（成片质量不动）。
- 不做美型 warp 优化（warp kernel 签名修复是独立待办，池 [15]，不混入本三期写集）。
- 不做 MediaPipe 等第三方分割（v2 再议，依赖需走 manifest+门禁）。
- CI 链特效复杂度冻结：本三期之外不新增滤镜/蒙版层级。

## 3. 分期范围与验收

### P1 = TASK-CAM-033 检测裁剪 + 链路合并

范围：
1. `CameraManager` 新增 `AVCaptureMetadataOutput`（AVMetadataObjectTypeFace），
   脸框回调独立于视频帧（采集栈持续输出），经 EMA 平滑写 `FaceBoxStore`
   （坐标契约 = 图像归一化 0...1 origin 左上，与 CAM-011 同构；与视频帧方向一致性
   真机标定）。
2. `VisionDetector` 请求组合开关化：landmark 仅美型或贴纸开启；HumanBodyPose 仅美体；
   Animal 仅宠物贴纸；全关 = 不建 Vision handler（metadataOutput 供脸框）。
   兜底：metadata 输出不可用时脸框回落 Vision `VNDetectFaceRectanglesRequest`
   （单阶段，比 landmarks 便宜）。
3. `CameraBeautyParams.apply`：磨皮+美白合成后**单次** BlendWithMask。
4. 语义开关传递链：ViewModel 功能开关 → renderer/detector（锁保护，预览/录制同口径）。

验收（可机器判定）：
- [ ] 契约层单测：开关矩阵（全关/仅磨皮/仅美型/全开）下 Vision 请求集合正确
      （detector 输出 mock 注入，断言请求类型集合）。
- [ ] 磨皮+美白单次混合：契约测试断言 apply 输出 DAG 中 BlendWithMask 节点 ≤1
      （或以数值等价测试替代：输出像素与参考实现一致）。
- [ ] 现有 Camera 62/62 单测不回归。
- [ ] iOS 壳构建绿。
- [ ] 真机（挂池）：美颜全关时日志无 `handler.perform`（或计数为 0）；metadata
      脸框驱动磨皮蒙版位置正确（前后摄、转屏）。

### P2 = TASK-CAM-034 磨皮内核（引导滤波 + 纹理保留系数 k）

范围：
1. 新 kernel 文件（box filter 可分离 H/V 两 pass + 引导图 = 原图 + k 混合），
   契约不变：`(CIImage, strength) -> CIImage?`，extent 保持，origin=(0,0)。
2. 滑杆映射重定义：strength → (半径 r, eps, 保留系数 k)，单调不减，k 随强度
   单调**不增**（磨越狠留越少）。
3. beauty_harness 剖面真机定标（r/eps/k 三参数），替换全部 [E]。
4. 旧双边 kernel 保留为 harness 对照与降级路径（开关）。

验收：
- [ ] harness：平坦区方差压降 ≥50×、边缘保持率 ≥70%（10-90% 过渡宽度不劣化）、
      k 曲线单调——真机数字落 baselines「相机磨皮」段。
- [ ] 单测：extent 不变 / off 直通 / 强度单调（数值断言）。
- [ ] 处理耗时真机 ≤ 现实现（浮层 processing ms 对比留档）。

### P3 = TASK-CAM-035 蒙版语义 + 美白重做

范围：
1. `PortraitSegmentation`（新，Impl/Detection）：VNGeneratePersonSegmentationRequest
   （.balanced），15Hz 低频 + mask EMA；磨皮/美白开启时才跑。
2. 蒙版合成：分割 mask（上采样）∩ 脸框椭圆（P1 的 metadata 脸框），羽化带宽
   ≥ 框宽 20%。
3. 美白重做：亮度域曲线（高光保护）+ 肤色饱和度微降，并入磨皮同链半分辨率 [E]。
4. 美颜链半分辨率：540×960 跑完上采样混回原图（预览/录制分辨率不变；拍照不降）。

验收：
- [ ] 单测：mask 交集几何（合成 mask ∩ 框 = 预期区域）；半分辨率链 extent 不变。
- [ ] 真机：蒙版覆盖脸+额际+颈且背景不变（录像回传核验）；处理耗时 ≤5ms [E]
      落 baselines；传哲目检（断层消失/美白不塑料）为人工终验项。

## 4. 约束（红线对照）

- 时间契约不涉浮点秒（脸框 EMA 用 CMTime/PTS）✅
- 能力运行时查询：分割/metadata 可用性运行时判断，缺失回落老路径（诚实降级）✅
- UI 零改动（功能开关已有）；写集不跨模块（Camera Pod + 契约层）✅
- Shader：新 kernel 仅相机特效域（ADR-0014 §3 边界），不进 SDK shader 清单 ✅

## 5. 影响模块

`ChuanqiCutCamera`（契约层 CameraBeauty/FaceMask + Impl CameraManager/VisionDetector/
新 Detection 文件/Effects）、SharedUI 零改动（注入点签名不变）、baselines/pitfalls 登记。

## 6. 开放问题

1. metadataOutput 脸框与视频帧方向/坐标一致性 —— 真机标定项（P1 验收内）。
2. P2 的 r/eps/k 初始值 —— harness 真机定标，不预设。
3. 分割 mask 帧间闪烁超阈值时降 .fast 档还是回椭圆蒙版 —— 开关保留，真机定。

## 7. 工期估算 [E]

P1 ≈ 1 个工作会话（编码+单测+构建自查）；P2 ≈ 1 会话编码 + 真机定标半场；
P3 ≈ 1-2 会话。编码全量 3-5 会话（日历 2-4 天），真机验证/定标依赖设备配合另计。
