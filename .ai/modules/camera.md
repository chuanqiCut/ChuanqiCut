# 模块：相机（iOS 原生域，ADR-0014）

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
      CVPixelBuffer → CIImage → 处理链 → CI 渲进中间纹理 → blit 进 drawable → present
录制  CameraRecorder（videoQueue 内 AVAssetWriter + PixelBufferAdaptor）
拍照  CameraManager.capturePhoto → CameraViewModel 走同一条 process 链 → 存相册
```

## 2. 预览渲染形状（2026-10-05 改，TASK-CAM-015 / pitfalls P60）

**CI 不能直写 MTKView 的 drawable**：`framebufferOnly`（默认 true）时 drawable 纹理
只有 `renderTarget` usage，而 CI 内部构造 `CIRenderDestination` 要求 usage 含
`ShaderWrite`，缺 → init 返回 nil → 每帧静默空转（黑屏）。

```
旧：CI ──直接──> drawable.texture          ✗ usage 不含 ShaderWrite → destination nil
新：CI ──> 自建中间纹理(ShaderWrite|ShaderRead, private) ──blit──> drawable   ✓
          尺寸 = 帧尺寸；pixelFormat = drawable 同款；尺寸/格式变就重建
```

- drawable `framebufferOnly = false`（2026-10-05 翻案，pitfalls P65）：Metal 规范**禁止
  对 framebufferOnly 纹理 blit**（源/目标都禁，只允许当 colorAttachment）。此前记的
  「blit 不受限（本机实测无 error）」是**无校验层**运行下的假象 —— 校验层（DEBUG scheme
  Metal API Validation / GPU 抓帧）开启时每帧硬断言 SIGABRT。
- blit 尺寸按 drawable 截断 —— 保持「1:1 不缩放」的既有视觉语义；**铺满 / letterbox 属 UI 需求，未做**。
- framebufferOnly=false 的代价 = 失去 CoreAnimation 显示优化（Apple 明写 "at a cost to
  performance"），登记在案。**真机帧率不达标时的替代方案 = blit 换 render pass
  （全屏 quad 采样中间纹理），不是改回 true —— 那条路已被规范封死。**

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
