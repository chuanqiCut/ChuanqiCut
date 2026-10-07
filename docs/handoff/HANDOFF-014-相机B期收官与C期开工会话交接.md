# HANDOFF-014：相机 B 期收官 + C 期开工（大批落地）会话交接

> 2026-10-07 晚间。B 线开发机单会话大批：CAM-019 修复轮 + 013/014 全栈 + 021 双摄 +
> 022/024/025 + 真机反馈批（030）+ C 期立项 026~029 + RESEARCH-009。**代码全部落地、
> iOS 构建/真机全量未跑**（本机工具链 5.5 上限，见池[7]）——接手第一件事 = 构建机门禁。

## 本轮落了什么（对 commit 历史核）

| 块 | 内容 | 状态 |
|---|---|---|
| CAM-019 修复轮 | 预览 FaceBoxStore 断线（渲染器自持 store 无人写，两线同病非合并回归）→ ViewModel 改用 `renderer.faceBoxes` 单一真源；**算法定则落地**：`CameraBeauty.apply` nil 语义 全画面兜底→**直通**（契约用例同步改） | 代码落地；真机待验 |
| CAM-013/014 | 美型/贴纸全栈：`CameraReshape`/`StickerAnchor` 契约纯函数 + `face_warp.metal`（8 槽位移场 CIWarpKernel）+ FaceWarp 引擎（复用 BeautyKernel 扫描已泛化 `libraryDataInHostBundles(requiring:)`）+ 三路接线（链序锁定 美颜→美型→滤镜→贴纸）+ 美型三滑杆/贴纸选择条 UI | 代码落地；单测统一轮；真机待验 |
| CAM-021 双摄 | MultiCamSession 双输入双输出（A12 以下自动普通 Session）；**前/后独立检测桥**（PiP 过完整链 WYSIWYG）；方向/镜像按各 connection 摄位计算（前摄 270° 偏移不再依赖全局 currentPosition）；PiP 右上白描边可互换；录制 = Renderer `composeRecordingFrame` composer（时间轴由后摄 PTS 驱动）；`setDualCamEnabled` 失败自动回退单摄；翻转按钮双摄下禁用 | 代码落地；真机 A8 待验 |
| CAM-022 MetalFX | `MetalFXScaler`（MTLFXSpatialScaler，SDR）+ draw 集成（输出=帧宽比×屏幕级别尺寸，保取景一致；cover≤1.15 跳过）+ 设置开关；默认关=逐位等价 | ⚠️ SDK 命名（descriptor 属性/`newSpatialScaler`/`encode(to:)`）本机无 MetalFX 头无法对表，构建机首编译按头文件修（一行级） |
| CAM-024/025 | 宠物锚定（`StickerEyeAnchor` 人/宠同构 + AnimalObservation 提取，iOS 16 无姿态跳过）全链；美体 `BodyReshape` 纯函数层 + 接线（四关节齐全才生效） | 代码落地 |
| CAM-030 反馈批 | 录制报错根因修复（**appendAudio 无会话起点守卫**——音频先于 startSession/PTS 早于起点令 writer `.failed`；补守卫 + append 返回值检查 + 失败帧不入计数）；采集档位 720p/1080p/4K + 帧率 30/60（canSetSessionPreset/activeFormat 校验）；高清拍照（maxPhotoDimensions + .quality）；变焦捏合（videoMaxZoomFactor 夹取，切摄重置）；曝光补偿/手动对焦滑杆；录制计时 TimelineView；**检测提频 15→30Hz** | 代码落地 |
| C 期立项 | CAM-026 美妆 / 027 人像分割底座 / 028 ARKit 网格跟踪 / 029 磨皮算法升级；RESEARCH-009 对标抖音/剪映/INS（五根因+三阶段路线+三决策点待传哲拍板） | 卡就绪 |

**算法定则（传哲 2026-10-07，建议集成机落 ADR-0032）**：美颜/美型/美体/美妆/道具/跟踪/AR
一切人像能力必须**算法驱动，无算法即无效果**，不得退化为滤镜式全画面修改。已落实：nil→直通。

## 下一个会话怎么接手

1. **构建机门禁（第一优先）**：iOS 构建（双壳）+ Camera 契约 swift test（36+新增用例）
   + 阶段批。已知编译风险点：MetalFX SDK 命名（上表）；`CameraReshape.swift` 用了仓库
   惯用简写语法（6.1 正常）；face_warp.metallib 验收 = 大小 + kernelNames（cq_face_warp）。
2. **真机一趟多单（归传哲）**：池[7] 全清单——018/019 五项、021 双摄 A8（含帧率/分辨率
   实测入 baselines）、013/014/024/025 观感、zoom/曝光对焦/档位、录制成功率回归、
   30Hz 功耗对账。
3. **CAM-023 景深**：C 期唯一未动代码卡（DepthDataOutput + 帧同步 + 深度虚化）。
4. **发号水位**：CAM 下一号 **031**；pitfalls 下一号 **P86**（候选两条见下）；ADR 下一号
   **0032**（算法定则提案）；HANDOFF 下一号 **015**。
5. **pitfalls 候选（集成机落账）**：P86=契约单测全绿 ≠ 装配正确（预览 FaceBoxStore 断线，
   两线同病过全部门禁）；P87=AVAssetWriter 音频必须守会话起点（startSession 在首视频帧，
   音频先到即 .failed 不可恢复——注释声称的语义必须真实现）。
6. **baselines 待实测（真机）**：双摄帧率/分辨率上限、检测+分割 30Hz 开销、MetalFX 开关
   A/B 帧率、高清拍照耗时、变焦/曝光对焦手感。

## 验证（诚实口径）

- 本机：新契约文件 swiftc -typecheck **PASS**（CameraReshape/StickerAnchor/BodyReshape；
  工具链 5.5 上限，CameraBeauty 等含仓库惯用简写语法的文件本机不可检，构建机验证）。
- iOS 构建 / swift test 全量 / 阶段批 / 真机：**未跑**（池[7]）。
