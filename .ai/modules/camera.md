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
