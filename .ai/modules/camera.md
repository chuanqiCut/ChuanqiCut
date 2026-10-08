# 模块：相机（iOS 原生域，ADR-0014）

> **归属**：B 线（相机/特效；pal/apple 相机与检测子域随 B） —— 归属表见 docs/tasks/PLAN-三线并行.md §1a / ADR-0029（双机分工与门禁跑批，2026-10-07）

> 建立：2026-10-05（此前只散落在 TASK-CAM-* 与 HANDOFF-004，无模块文档）
> 位置：`apps/apple/ios/iOSApp/Camera/`
> 边界：相机是 **App 层资产域**，不经 PAL / C ABI（ADR-0014）。SharedUI 只持
> 相机相关的**契约层**（`CameraFilterPreset` / `CameraBeautyParams` /
> `CameraBeautyEngine` 注入点 + 默认 CI 兜底），不放特效资产。

## 1. 三段分工

```
采集  CameraManager     AVCaptureSession（会话配置/启停全在 sessionQueue）
  ├─ videoQueue 视频帧 → CameraFrameSlot.push（latest-wins，不排队）
  └─ audioQueue 音频包 → CameraRecorder.appendAudio
渲染  CameraPreviewRenderer（MTKViewDelegate，连续绘制）
      CVPixelBuffer → CIImage → 处理链 → CI 渲进中间纹理 → 显式UV渲染pass 进 drawable → present
录制  CameraRecorder（videoQueue 内 AVAssetWriter + PixelBufferAdaptor）
拍照  CameraManager.capturePhoto → CameraViewModel 走同一条 process 链 → 存相册
```

## 2. 预览渲染形状（2026-10-06 终态，TASK-CAM-015/016 / pitfalls P60/P65/P68）

**CI 不能直写 MTKView 的 drawable**（P60）：framebufferOnly drawable 只有 renderTarget
usage，而 CI 的 CIRenderDestination 要求 ShaderWrite → destination nil → 每帧**静默**
黑屏（render 非 throws，失败不进 commandBuffer.error，帧计数假绿）。
**blit 也被规范封死**（P65）：Metal 禁止对 framebufferOnly 纹理 blit（源/目标都禁），
无校验层时未定义行为放行、DEBUG 校验层下每帧 SIGABRT ——「实测无 error」不算证据。

```
旧：CI ──直接──> drawable             ✗ P60（usage 缺 ShaderWrite → 静默黑屏）
旧：CI ──> 中间纹理 ──blit──> drawable ✗ P65（framebufferOnly 禁 blit，校验层必炸）
新：CI ──> 自建中间纹理(ShaderWrite|ShaderRead, private, 帧尺寸)
        ──显式UV渲染pass──> drawable   ✓ colorAttachment 是 framebufferOnly 唯一合法写法
```

- drawable 恢复 `framebufferOnly = true`（CoreAnimation 显示优化失而复得）；编辑器
  PreviewFrameRenderer 同形态，真机已验证。CAM-015 二段的 `= false` 是 blit 存续期的
  续命方案，随 blit 移除而退场。
- 渲染 pass 全屏大三角形 + 逐帧 uniforms（`uScale` / **带符号 vScale**，几何与 uv
  约定与 PreviewFrameRenderer 对齐）：v 符号 = CI 行序补偿（`ciWritesBottomUp=true`
  由真机颠倒现象**反推**；macOS 探针判不了 iOS 行序 —— P68；真机反向则改 false）；
  u/v 比例 = aspect-fill（SPEC v1.2 目标5，铺满取代旧「1:1 截断」语义）。

## 3. 埋点口径（红线：真机验收归传哲，日志先行）

`os.Logger(subsystem: "com.chuanqi.cut", category: "camera.preview")`：

| 事件 | 级别 | 节流 |
|---|---|---|
| 每 120 帧「成功=… 失败=…」摘要 | info | 每 120 次累加触发 |
| 单帧渲染失败（commandBuffer.error 非 nil） | error | 每 30 次打一条 |

**计数语义**：`renderedFrameCount` 只认「完成且无错」，配套 `renderFailureCount`。
两者都由 command buffer 完成回调按成功/失败分流 —— 旧实现在 draw 末尾无条件 ++，
导致 CI 静默失败时也能报满帧率（P60 的伪绿教训）。

## 4. 处理链次序（WYSIWYG 三路一致）

预览 / 拍照 / 录制都走同一条：**美颜 → 滤镜**。录制在开始时锁定 preset+beauty。
录制路径渲染到 `CVPixelBufferPool` 的像素缓冲（不是 MTL 纹理），故不受 P60 影响。

## 4.5 录制器时序（CAM-017，pitfalls P69）

`pixelBufferPool` 在 `startWriting()` **之前是 nil**（探针实证）⇒ 取池必须排在
`startSession`（首帧，内含 startWriting）之后：**setup → startSession → 懒取池+
缓存（取不到直配兜底）→ 渲染 → append**。收尾：`markAsFinished` 仅 `.writing` 态；
0 帧落盘 = 显式 `.nothingWritten` 失败（不产空文件假成功）。遥测
`camera.recorder`：开始尺寸 / 每 240 帧计数 / 收尾 status+frames+error。

## 4.6 磨皮引擎回落纪律（CAM-017）

引擎闭包带**黏性回落**：连续 3 次 nil 本会话停用引擎、只走默认 CI 实现——
否则间歇失败会让画面逐帧在两种视觉间翻转（真机「磨皮闪屏」主嫌）。nil 计数
走 `camera.beauty` 遥测；kernel 离屏 20 帧同输入指纹唯一（算法层确定，排除）。

## 5. 方向（CAM-016，SPEC v1.2 目标5：竖 + 左右横屏全支持）

- **采集**：`connection.videoRotationAngle` 按 UIInterfaceOrientation 映射
  {portrait:90, landscapeLeft:0, landscapeRight:180}（landscapeLeft=home 在右=传感器
  原生位）；iOS 16 fallback 走旧 API 且 **landscape 名互换**
  （UI.landscapeLeft → AVCapture.landscapeRight，UIOrientation.h 原文依据，pitfalls P67）。
  入口 `CameraManager.setInterfaceOrientation`（sessionQueue 串行；configure 前只存值）。
- **触发**：CameraView 监听 `UIDevice.orientationDidChangeNotification`（scene 级通知
  不存在，P67）→ `CameraViewModel.refreshInterfaceOrientation()` 分 0/200/500ms 三次
  采样 `scene.interfaceOrientation`（通知早于 scene 提交转场的竞态）；
  **录制中锁定**（`!isRecording` 门控，Spec v1.2 非目标）。
- **渲染**：aspect-fill 采样窗逐帧按帧/drawable 尺寸重算，转屏零重建成本。
- **前摄安装差（CAM-017 二修，P72）**：videoRotationAngle 的 0° = 传感器 native
  （iPhone 横装，前后摄轴向相反）。**常量补偿：`静态表 + (front ? 270 : 0)`**
  （后摄 90° / 前摄 0° 由真机两代现象反推定案；RotationCoordinator 新建即读拿到
  未初始化 0 曾致后摄回归，已砍掉）。iOS 16 旧 API 是语义方向，不加偏移。
- 前摄镜像在各方向保持（旋转后应用，Apple 语义）。
- 待真机一验：行序常数（`ciWritesBottomUp`）与标定偏移的定案口径见 TASK-CAM-016/017。

---

## 模块册（ADR-0030：任务/进度/测试门禁记录按模块归口）

> 本节由归属线更新（一机一线，天然单写者）；BACKLOG / pitfalls / baselines 等
> 全局册零直写（集成机阶段批落账）。新调研/规格/审查落 docs/ 原位，但必须在此登记指针。

### 任务与进度（在飞 + 近期；全量 DAG 见 TASK-BACKLOG）

| Task ID | 标题 | 状态 |
|---|---|---|
| INFRA-018 | ChuanqiCutCamera Pod 迁移（ADR-0031 阶段 4 提前，传哲指定） | ✅ 2026-10-07：契约 4 文件+实现 6 文件+Detection/Effects+4 测试文件入独立 iOS 专属 Pod；EditorScreen 经 EditorEntryInjector 解耦；metallib 管线留壳工程（SRC 指向 Pod 源）；坑案底 P85 |
| CAM-001~005 | 契约（回退留档）/采集/预览/首页/录制 | ✅ |
| CAM-015/016 | 预览 CI→drawable 渲染修复 + 方向（渲染线先入库） | ✅ |
| CAM-018/019 | 美颜色彩空间 + 人脸区域化（曾号 015/016） | ✅ 代码落地；真机 = 池 [2]；**修复轮 2026-10-07**：预览 FaceBoxStore 断线（P86 候选） |
| CAM-013/014 | 美型 MeshWarp / 贴纸锚定 | ✅ 代码落地（2026-10-07 功能批：契约纯函数 + face_warp.metal + 引擎 + 三路接线 + 美型滑杆/贴纸条 UI）；单测统一轮；真机待验 |
| 用户反馈批 | 录制报错修复（音频会话起点守卫）/录制计时/采集档位与帧率/高清拍照/曝光对焦 | ✅ 代码落地 2026-10-07，待构建机 |
| CAM-021 | 双摄（MultiCamSession） | ✅ 代码落地 2026-10-07：双输入双输出 + 前/后独立检测桥（PiP 过完整链 WYSIWYG）+ PiP 右上白描边可互换 + 录制合成流（Renderer composer）+ 不支持机型置灰明示；真机 A8 验收待传哲 |
| CAM-023 | 景深人像 | ✅ 代码落地 2026-10-07：深度能力设备切换（DualWide/Dual/LiDAR/TrueDepth）+ DepthDataOutput 同步 connection + 拍照内嵌深度交付 + PortraitBlur CI 管线（视差归一/羽化/f 值单调）；深度仅服务拍照；无深度机型置灰明示；与双摄互斥 v1；**AVCapturePhoto.depthData / isDepthDataDeliveryEnabled 命名待构建机核对** |
| CAM-022~025 | C 期四卡（MetalFX/景深/宠物美化/美体），2026-10-07 立项（美体自原 022~024 拆出） | 024/025 本轮全链落地；022 MetalFX 本轮落地（SDK 命名待构建机对表）；023 待接续 |
| CAM-026 | 美妆（唇/腮红/眼影/眉/美瞳五区域） | ⚠️ 2026-10-08：契约 `MakeupParams.swift` + 实现 `Effects/MakeupRenderer.swift` + 五路接线（VM/渲染/录制/FaceBoxStore/UI 面板）已落盘**未提交**；单测 ✅ 已补 10 用例（`MakeupMaskTests.swift`，待构建机实证）；iOS 构建与 swift test 本机跑不了（Xcode 13.1 / swiftpm 5.5）= 池 [9] |
| CAM-027 | 人像理解底座（皮肤/头发/人像分割） | ⚠️ **v1 已落地 2026-10-08 晚**（几何级精修）：契约层 `PortraitSkinMask`（脸框 ∩ 非眼/眉/唇区）+ `CameraBeautyEngine.semanticMask` **注入点**（`apply(to:faces:)` 签名零改动，nil=老行为）+ Impl 薄壳 `Detection/PortraitSemantics.swift` + ViewModel 装配 1 处 + 7 用例；`FaceBoxStore` 补 `@unchecked Sendable`（并发契约变更，门禁需确认）。**本期不做**头发分割（SDK 15 无符号）与肤色聚类（归 CAM-028）——均已写进文件注释。构建机验证/真机 = 池 [9] |
| CAM-029 | 磨皮/美白算法升级 | ⚠️ 2026-10-08：只落地「②色域兜底（`cq_beauty_protect`）」+「③自适应 σ（`cq_beauty_sigma_local`）」，且**只在 pass1 `cq_beauty_down_h`**；①细节回注与④美白唇保护未做；`BeautyKernel` 参数面未动（常量写死）；无 harness 剖面实测 = 池 [9] |
| **算法定则（传哲 2026-10-07）** | 美颜/美型/美体/美妆/道具/人脸跟踪/AR 一切人像能力必须算法驱动，无算法即无效果，**不得退化为滤镜式全画面修改** | 已落实：CameraBeauty.apply nil 语义 全画面兜底→**直通**（旧契约用例同步改） |

### 测试与门禁记录（阶段批）

| 日期 | 阶段/范围 | 结论（数字） |
|---|---|---|
| 2026-10-07 | 壳工程双壳构建（首次 App target 真编 CAM-018 代码） | 抓出 P0：`kCVPixelBufferColorSpaceKey` 不存在于 SDK（P83）→ 已修 `kCVImageBufferCGColorSpaceKey`；iOS/mac BUILD SUCCEEDED。池 [2] 真机项不变 |
| 2026-10-07 | 相机 Pod 迁移阶段批 | Camera 契约 swift test **36/36**；metallib **8431B** + kernelNames（cq_beauty_down_h/up_v_mix）齐全；iOS 模拟器 + macOS BUILD SUCCEEDED；全量门禁见当日日志。真机验收（磨皮/区域化/录制色）仍 = 池 [2] |
| 2026-10-07 | 修复轮+功能批（本机，未提交） | 本机仅新契约文件 typecheck PASS（CameraReshape/StickerAnchor，工具链 5.5 限制无法编 Impl/iOS）；真机「还是滤镜效果」根因 = 预览 FaceBoxStore 断线（两线同病非合并回归）；录制报错根因 = 音频 append 无会话起点守卫。**iOS 构建/单测/真机全部待构建机与传哲** |
| 2026-10-08 | HANDOFF-017 收口轮（本机，**按传哲规则未跑门禁/未提交**） | 核环境：本机 **macOS 12.7.6 / Xcode 13.1 / Swift 5.5.1 / 无 cmake·ninja·brew** → iOS Pod 与 SPM `swift test`、`build_core.sh` 全跑不了（§17 旧记录的 Xcode 26.6 与实际不符，P90）。退掉一处不可编译接线（P89）；契约层 `MakeupParams.swift` 仅过 `swiftc -typecheck`（macOS SDK, Swift 5.5）——**弱证据，不作为完成依据**。真机/构建全部 = 池 [9] |
| 2026-10-08 晚 | CAM-026/027 编码轮（本机，**未跑任何门禁/测试/构建**） | 交付：契约层 `PortraitSkinMask.swift`（新）+ `CameraBeauty` 注入点 + Impl `PortraitSemantics.swift` + ViewModel 装配 + 两份单测（`MakeupMaskTests` 10 例 / `PortraitSkinMaskTests` 7 例）。**未执行任何验证**（按传哲指令不编译）——所有数字仍为空，构建机 `swift test` 与 iOS 双壳构建 = 池 [9]。新增关注点：`FaceBoxStore` 的 `@unchecked Sendable` 扩充 |

### 调研 · 决策 · 池指针

- ADR-0013/0014/0021 · RESEARCH-002/007 · HANDOFF-004/007
- pitfalls P60/P65/P68（渲染终态）/P72~74（方向/拍照/录制）/**P89（半成品接线·引用未实现符号）**/**P90（交接须写本机工具链能力）**
- HANDOFF-017（2026-10-08 编辑×拍摄两未完成线收口）：AIEDIT-001 待构建机门禁（池 [8]）；相机 C 期三条待办（池 [9]）
