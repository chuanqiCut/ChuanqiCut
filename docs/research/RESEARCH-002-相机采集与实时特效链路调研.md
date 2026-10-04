# RESEARCH-002：相机采集与实时特效链路调研

- 日期：2026-10-04
- 状态：**提案**（决策点见 §9，确认后转 Spec）
- 上游：用户需求（2026-10-04 会话）、ADR-0005、ADR-0010、RESEARCH-001、`技术调研_MediaPipe加速与系统API对比.md`
- 参考设备：iPhone 17 Pro（iOS 26 / A19 Pro），部署基线 iOS 16（ADR-0010）

---

## 0. 结论速览

| 问题 | 结论 |
|---|---|
| 相机代码现状 | **全仓为零**。`core/pal/apps/bindings` 均无 camera/capture 代码，Info.plist 无相机权限 |
| 渲染链路可复用度 | **约 80%**。相机帧(CVPixelBuffer)与解码帧同构，PALA-002 零拷贝导入链路原样可用；缺的是"外部帧入口 + 特效多 pass" |
| 录制复用 | **IMediaMuxer 已具备完整能力**（AVAssetWriter + 视频 CVPixelBuffer + PCM→AAC），相机录制几乎零新增 |
| 前后同开 | `AVCaptureMultiCamSession`（iOS 13+，A12+），iPhone 17 Pro 支持；**运行时 `isMultiCamSupported` 判定**（红线 #3）；双流分辨率上限预计 ≤1080p/流 [E，待真机实测] |
| 人脸/宠物检测 | iOS 系统能力齐备：人脸框/关键点(76点)、人体姿态(17关节)、人像分割、动物检测(猫狗)、动物姿态(25关节，iOS 17+)；精细美型按 ADR-0005 走 MediaPipe 468 点模型(CoreML) |
| 特效算法 | 磨皮=频率分解/双边滤波(Metal)，美型=MeshWarp(Delaunay+顶点偏移)，美体=人体姿态+分割+区域形变，贴纸/道具=关键点锚定的纹理叠加，滤镜=3D LUT |
| 主要缺口 | ① PAL 无相机契约；② ICommandEncoder **无 compute dispatch**、**无"把纹理当渲染目标"** 的 API（特效链必需）；③ Portable shader 层为零(SHADER-001 未启动)；④ 无 home/导航 |

---

## 1. 需求拆解（用户原话 → 能力项）

用户需求（2026-10-04）：

1. iOS 现有编辑器基础上加**首页**：两个入口——「进入编辑」「进入相机」。
2. **相机模块全新**；渲染链路尽量复用编辑已有的。
3. 支持 iOS 16+，发挥 iOS 优势；设备 iPhone 17 Pro。
4. 特效能力：**人脸识别、美颜、美型、美体**；**宠物识别 + 宠物美化/美型**；**贴纸、滤镜、头部道具**。
5. 「最好也要支持」**前后摄像头同时采集**。

映射到分层：

| 能力项 | 所在层 | 说明 |
|---|---|---|
| 采集(单/双摄)、会话管理 | PAL(apple) | AVFoundation 是平台 HAL，天然归 PAL |
| 检测(人脸/人体/宠物) | PAL(apple) + core 后处理 | Apple 端 Vision / CoreML 推理在 PAL；坐标后处理、平滑下沉 core（ADR-0005 §1.3） |
| 美颜/美型/美体算法与 mesh 生成 | core | 跨平台共享（红线 #1、ADR-0005） |
| 特效 shader | shaders/src(Portable) / pal/apple/shaders(Native) | 策略冲突见 §9 决策点 D4 |
| 录制封装 | core（复用 IMediaMuxer） | PAL 实现 AppleMediaMuxer 已存在 |
| 首页/相机页 UI | apps/apple（iOS 端） | 相机先不做 macOS；首页壳放 iOSApp target |
| 能力降级判定 | core `cq_query_capability` | 新增枚举：双摄、动物姿态等 |

---

## 2. 现状盘点

### 2.1 可直接复用（已验证）

| 既有件 | 位置 | 对相机的意义 |
|---|---|---|
| 零拷贝导入 | `pal/apple/gfx_metal.mm:390-504` `CqNativeImageImporter` | 相机输出 CVPixelBuffer(32BGRA+MetalCompat) → MTLTexture，与解码帧**完全同构**，IOSurface 共享已实测（1500× 代差） |
| blit 管线范本 | `pal/apple/blit_pass.mm:41-101` | MSL→ShaderModule→Pipeline→绘制的完整装配模式，特效 pass 直接克隆 |
| Metal 设备/GFX 门面 | `core/src/gfx/gfx_device.cpp`（GFX-001 已完成） | `RenderFrame(ctx,target,client)` 帧编排已存在 |
| 视频录制封装 | `pal/apple/media_encode.{h,mm}`（PALA-012） | `IMediaMuxer`：视频 CVPixelBuffer 按源格式写 H.264 + PCM(kFloat32/kInt16)→AAC，PTS 用 RationalTime 网格无漂移 |
| 能力查询 | `core/include/cq/pal/capabilities.h:20-38` | 已有 kGpuMetal/kComputeShader/kNpuInference 等，按需新增枚举 |
| 预览上屏 | SharedUI `MetalPreviewView`/`PreviewFrameRenderer` | MTKView + 恒等 blit 的上屏模式可被相机预览借用 |
| Swift 绑定惯例 | `bindings/swift/Sources/ChuanqiCut/` | 一类型一文件；新 ABI 组按 Session.swift 模式包装 |

### 2.2 缺口（必须新做）

1. **PAL 相机契约 + Apple 实现**：`core/include/cq/pal/camera.h`（冻结契约，零平台类型）+ `pal/apple/camera_capture.{h,mm}`。
2. **外部帧渲染入口**：`PreviewRenderer` 只吃时间线快照（`preview_renderer.cpp:186-210`），无外部帧入口；需要 `cq_preview_render_external_frame` 之类的直通路径或独立 CameraRenderer。
3. **特效链的 PAL 扩展（两处硬缺口）**：
   - `IRenderTarget` 只能自建纹理，**无法把已有 ITexture 包装成渲染目标** → 磨皮→LUT→贴纸的多 pass ping-pong 走不通；
   - `ICommandEncoder` **无 compute dispatch API**（`pal/gfx.h:159`）→ 频率分解磨皮需要 compute（或 fragment 双 pass 替代）。
4. **检测契约**：core 无 `ai/observation.h` 之类的中性观测结构（人脸框/关键点/姿态/宠物）。
5. **Portable shader 层为零**：`shaders/src/` 空目录，SPIR-V 路径在 Metal 上直接返回 `kInternal`（`gfx_metal.mm:581-583`），SHADER-001 未启动。
6. **首页/导航**：root 直接是 EditorView（`iOSApp/ChuanqiCutApp.swift:32-38`），且 `EditorViewModel`（含内核 Session）在 App.init 就创建——首页形态下要改为**进编辑器时惰性创建**。
7. **权限声明**：无 NSCameraUsageDescription / NSMicrophoneUsageDescription / NSPhotoLibraryAddUsageDescription。

---

## 3. 相机采集调研（Apple 端）

### 3.1 会话选型

| 方案 | 说明 | 结论 |
|---|---|---|
| `AVCaptureSession` | 单输入单输出，经典相机 App | 单摄路径用 |
| `AVCaptureMultiCamSession` | iOS 13+ 多输入同开，ISP 级硬件时间戳同步 | 前后同开用；**运行时 `isMultiCamSupported` 判定**，不支持则降级单摄 |
| 两个独立 Session | 无硬件同步，功耗高、易抢资源 | 否决 |

要点（WWDC19 Session 249 + Apple 文档）：
- 配置变更必须**在 session 停止时**进行（与普通 Session 不同）；
- 前后同开 = 恰好 2 个 video data output；帧率/分辨率受 ISP 带宽约束，**双流通常 ≤1080p/流** [E，WWDC 时代 XS 数据；iPhone 17 Pro 上限待真机 `activeFormat` 实测，不写死]；
- 帧输出格式选 `32BGRA`（与现有零拷贝导入的 32BGRA 路径严格一致）+ `kCVPixelBufferMetalCompatibilityKey`（PALA-002 硬约束 #1）。

### 3.2 与架构红线的对照

- 红线 #2（PAL 头零平台类型）：相机帧以 `NativeImageHandle`（opaque，内含 CVPixelBuffer）过契约，与 media.h 的既有做法一致；
- 红线 #3（能力运行时查询）：双摄、动物姿态、ANE 等全部走 `cq_query_capability` 新增枚举；
- 红线 #4（有理数时间）：采集时间戳 CMTime → `RationalTime`（timescale 沿 ADR-0009 的 120000 网格）；
- 红线 #8（主线程零阻塞）：采集回调在专用串行队列；检测降频（人脸类每帧或 15Hz [E]）在独立队列；渲染在 MTKView 渲染线程。

### 3.3 权限与 Info.plist

`NSCameraUsageDescription`、`NSMicrophoneUsageDescription`（录视频带音）、`NSPhotoLibraryAddUsageDescription`（存相册）；由 `project.yml` 的 `info:` 段生成（仓库不存手工 plist）。

---

## 4. 检测能力调研（人脸 / 人体 / 宠物）

### 4.1 iOS 系统能力（Vision 框架，零第三方依赖）

| 能力 | API | 可用性 | 精度边界 |
|---|---|---|---|
| 人脸框 | DetectFaceRectanglesRequest | iOS 11+ | — |
| 人脸关键点 | DetectFaceLandmarksRequest | iOS 11+ | **76 点**（含轮廓/眉/眼/鼻/唇/瞳）；既有调研记 65 点，结论不变：**够基础美颜，不够精细美型** |
| 人脸姿态 | FaceObservation yaw/pitch/roll | 同上 | 头部道具锚定够用 |
| 人体姿态 | DetectHumanBodyPoseRequest | iOS 14+ | 17-19 关节 |
| 人像分割 | GeneratePersonSegmentationRequest | iOS 14+ | qualityLevel 三档 |
| 动物检测 | DetectAnimalsRequest | iOS 13+ | **仅猫/狗**，输出框+置信度 |
| 动物姿态 | DetectAnimalBodyPoseRequest | **iOS 17+**（部署目标 16 → 运行时门控+能力查询） | 猫/狗 25 关节（含耳、尾） |

### 4.2 精细美型的模型路径（ADR-0005 既有决策，不重复决策）

- Vision 76 点 → 磨皮/调色/简单贴纸锚定 OK；瘦脸/大眼/鼻翼等精细美型**必须 468 点级**；
- 按 ADR-0005：引入 MediaPipe **模型资产**（face_landmark.tflite，Apache-2.0），不引入 SDK；
- Apple 端推理：`.tflite → .mlpackage`（coremltools，**AI-013 spike 是生死门**，未过切 LiteRT+CoreML delegate）；
- 加速结构：Vision 快速检测人脸框 → 裁剪小图 → 468 点模型推理 → 映射回原图（既有调研估 ~1ms 总耗时 [E，待实测]）；
- landmark 后处理、帧间平滑（AI-025）在 C++ core 共享。

**MVP 取舍建议**：相机 MVP 用 Vision 76 点先打通全链（贴纸/道具/基础美颜美型可用），精细美型排 MediaPipe 模型路径之后——检测器做成可替换接口，切换不改上层。

---

## 5. 特效渲染调研

| 特效 | 算法 | GPU 形态 | 备注 |
|---|---|---|---|
| 磨皮 | 频率分解（低频保边+高频保留）或引导/双边滤波 | **compute 优先**（需 PAL 补 dispatch API）；fragment 双 pass 为替代路径 | 既有决策书已定频率分解+Metal compute |
| 美白/红润/滤镜 | 3D LUT（.cube 或 baked 条带）+ 强度混合 | fragment 单 pass | COLOR-002 既有规划 |
| 美型(瘦脸/大眼等) | 局部平移形变/TPS → 三角剖分 mesh 或 UV offset map | 顶点偏移（Delaunay 索引一次性上传，逐帧仅插值参数） | AI-021/022 既有规划（MeshWarp 与 UV Map 同接口） |
| 美体(瘦腰/长腿) | 人体姿态关节定位 → 区域分段垂直/水平形变 + 人像分割保背景 | fragment/compute + mesh | **复杂度高，建议 Phase C**；先做 2-3 个基础形变 |
| 宠物美化/美型 | 动物框+25 关节锚定贴纸/道具；简单形变（如放大眼睛） | 同美型基础设施复用 | Vision 动物姿态 iOS 17+；宠物美型精度天然低于人脸，期望要对齐 |
| 贴纸/头部道具 | 关键点锚定（双眼连线定位置/尺度/旋转 + yaw/pitch/roll） | 纹理 quad 叠加 pass | 资源格式 PNG 序列帧/静态；EDIT-005 既有规划可前移 |
| 头发/背景类 | 人像分割 mask | fragment | 可选，非 MVP |

**管线形态**（所有特效共用）：

```
相机帧纹理 → [磨皮 compute/fragment] → [LUT/调色] → [美型 warp] → [贴纸/道具叠加] → 上屏/录制
             └────────── ping-pong 中间纹理链（需要 PAL 扩展②）──────────┘
```

特效参数全部由 core 下发（C++ 生成 mesh/参数，shader 只执行），保证三端一致（红线 #1）。

---

## 6. 录制与产出

- **录制 = 复用 `IMediaMuxer`**：视频轨吃特效后输出的 CVPixelBuffer（32BGRA），音频轨吃 `AVCaptureAudioDataOutput` 的 PCM（kFloat32，48kHz）→ AAC。PTS 沿 120000 网格。
  - 即：**所见即所得录制**（录的是特效后画面），这是美颜相机的标准形态；
  - 双摄录制的建议形态：渲染链合成后**录一路合成流**（画中画/分屏由参数决定）；`IMediaMuxer` 当前单视频轨，双轨录制不做（需求本身罕见）。
- 产出去向：存相册（PhotoKit）+ 一键进编辑器（复用 `importMedia` 流程）。此为默认方案，如需调整在 Spec 定。

---

## 7. 架构方案（提案）

### 7.1 分层与数据流

```
[UI] iOSApp: HomeView（编辑/相机两入口）
      └─ CameraView(SharedUI 复用 MTKView 上屏模式) ── 参数面板（滤镜/美颜/贴纸）
[ABI] cq_camera_* / cq_gfx_import_* / cq_preview_render_external_frame（新增 ABI 组）
[core] EffectChain（磨皮/LUT/warp/叠加 参数与 mesh 生成，C++20）
       ai/observation.h（中性观测结构）+ 平滑后处理
[pal ] camera_capture.mm（AVCapture Session/MultiCam → NativeImageHandle + RationalTime）
       vision_detector.mm（Vision/CoreML → 中性观测）        ← 检测在 PAL，后处理在 core
```

- 采集 → 渲染：`AVCaptureVideoDataOutput` 回调（专用队列）→ `INativeImageImporter::Import`（既有零拷贝）→ 特效链 → 纹理句柄 → MTKView 上屏；
- 帧策略：**latest-wins**（采集回调无背压堆积，检测降频独立队列）；
- 相机预览是**连续渲染**（MTKView isPaused=false），与编辑器"按需单帧"不同，不复用 PreviewMTKView，复用的是 `PreviewFrameRenderer` 的恒等 blit 模式。

### 7.2 新增 ABI（初稿清单，Spec 细化）

| ABI 组 | 职责 |
|---|---|
| `cq_camera_create/destroy/configure/start/stop` | 会话管理（单/前/后/双，运行时能力查询） |
| `cq_camera_set_observer` | 帧回调（NativeImageHandle + RationalTime）与观测回调（人脸/宠物/姿态） |
| `cq_gfx_import_native_image / release_texture` | 外部帧→纹理（复用既有 importer 实现） |
| `cq_camera_renderer_*` | 特效链渲染：set_effect_params / render_frame(native_image, out_texture) |
| `cq_camera_record_start/stop` | 走 IMediaMuxer 的录制控制 |
| `cq_query_capability` 新枚举 | kMultiCamCapture / kAnimalBodyPose / kVisionFramework 等 |

### 7.3 UI 落点

| 内容 | 位置 | 理由 |
|---|---|---|
| HomeView | `apps/apple/ios/iOSApp/` | 平台壳（探索结论：首页无先例，放 App target 与 Mac 互不干扰） |
| 相机参数面板/视图逻辑 | SharedUI 暂缓，先放 iOSApp `Camera/` | 相机本期 iOS 专属，避免 Mac 构建负担；沉淀稳定后再下沉 SharedUI |
| EditorViewModel 惰性化 | `ChuanqiCutApp.swift` 重构 | 进编辑器才建 Session（现状 App.init 即建，与首页冲突，唯一存量耦合点） |

---

## 8. 分期计划（提案）

| 期 | 内容 | 验收口径 |
|---|---|---|
| **A：首页 + 相机 MVP** | HomeView 两入口；单摄预览（零拷贝+上屏）；录制（复用 IMediaMuxer，存相册+进编辑器）；基础滤镜（3-5 个 LUT）；权限/能力查询/降级 | iPhone 17 Pro 真机：预览 ≥30fps（实测入库）；录制 mp4 可 ffprobe 且像素正确 |
| **B：人脸与贴纸** | Vision 检测桥（人脸框/76点/姿态）+ core 观测结构与平滑；美颜磨皮（fragment 双 pass 先行）；基础美型（大眼/瘦脸 2-3 项）；贴纸 + 头部道具锚定 | 人脸跟随稳定无明显抖动（帧间平滑指标）；道具锚定正确随头动 |
| **C：双摄 + 进阶** | MultiCam 前后同开（合成预览+录合成流）；compute 磨皮升级；美体（瘦腰/长腿基础款）；宠物识别+宠物贴纸/道具；MediaPipe 468 精细美型（依赖 AI-013 spike） | 双摄真机实测（分辨率/帧率/温控入库）；宠物检测猫狗可用 |

依赖关系：A 无前置（不动既有编辑器行为）；B 的检测器接口预留 MediaPipe 切换点；C 的精细美型受 AI-013 门控，**spike 可与 A 并行启动**（不同写集）。

## 9. 决策点（需拍板）

| # | 决策 | 选项 | 建议倾向 |
|---|---|---|---|
| D1 | 特效算法来源 | ① 自研（Vision/MediaPipe模型 + Metal，零授权费，效果靠迭代）② 商业 SDK（火山引擎/FaceUnity/商汤，开箱即用但授权费+依赖治理+适配层） | ① 自研打底；商业 SDK 若引入也走 PAL 适配层（红线 #7/#10） |
| D2 | 检测器 MVP 路线 | ① Vision 76 点先行，MediaPipe 468 后续切换 ② 等 AI-013 spike 直接上 468 | ① 先通链路；检测器做可替换接口 |
| D3 | 双摄产品形态 | ① 画中画合成（过渲染链，可录合成流）② 左右分屏 ③ 仅预览合成、录制只录主摄 | ① 画中画（美颜相机主流形态） |
| D4 | 特效 shader 落层 | ① 先 Platform-Native MSL（快，记 ADR"例外/欠账"，Portable 层在 Android 阶段前补）② 先建 SHADER-001 Portable 工具链再写特效（守红线 #6 但显著拉长） | ① Native 先行 + ADR 记账（先例：blit_fullscreen_msl.h）；**此为红线例外，须用户确认** |
| D5 | 录制产出 | 存相册 + 一键进编辑器（默认） | 已按默认写入 §6，无异议不改 |

## 10. 风险清单

| 风险 | 等级 | 缓解 |
|---|---|---|
| 双摄分辨率/帧率上限未知（1080p/流 为 [E]） | 中 | 真机 activeFormat 实测入库（baselines）；能力查询动态适配 |
| PAL 契约扩展（compute dispatch / 纹理当 RT）触碰冻结契约 | 中 | CORE-006 变更走独立 ADR；fragment 替代路径兜底 |
| Vision 76 点做美型效果不达预期 | 中 | 检测器可替换；468 模型路径已规划（ADR-0005） |
| 宠物美化期望差（Vision 仅猫狗、姿态 25 关节、iOS 17+） | 低 | 需求侧对齐：宠物以贴纸/道具为主，形变为辅 |
| 实时特效与 30fps 预览的功耗/温控 | 中 | 特效逐项开关+降级；真机温控实测（ADR-0010 §6 埋点先行） |
| EditorViewModel 惰性化重构触碰编辑器回归 | 低 | 既有 SharedUI 测试全量跑；重构不改 Session 语义 |

## 11. 参考

- Apple：AVCaptureMultiCamSession（developer.apple.com/documentation/avfoundation/avcapturemulticamsession）、WWDC19-249（Introducing Multi-Camera Capture）、WWDC23-10045（Detect animal poses in Vision）、Detecting animal body poses with Vision（documentation/vision）
- 仓内：ADR-0005（推理策略）、ADR-0009（timescale）、ADR-0010（基线）、RESEARCH-001、`技术调研_MediaPipe加速与系统API对比.md`、`技术方案决策书.md` §Phase3、TASK-BACKLOG AI-0xx/EDIT-005/COLOR-002
