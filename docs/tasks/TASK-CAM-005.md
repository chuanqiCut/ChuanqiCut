# TASK-CAM-005：录制 + 产出（AVAssetWriter，iOS 原生）

```yaml
id:          TASK-CAM-005
layer:       UI(iOSApp)
goal:        所见即所得录制:Core Image 处理后帧 + 麦克风 → AVAssetWriter(H.264+AAC) → 存相册 + 一键进编辑器
input:       [TASK-CAM-002(帧源), TASK-CAM-003(滤镜链), ADR-0014]
output:      [apps/apple/ios/iOSApp/Camera/CameraRecorder.swift, CameraViewModel.swift(接线),
             apps/apple/packages/SharedUI/Sources/SharedUI/Editor/EditorScreen.swift(initialMedia 入口)]
write_set:   上述文件, SharedUI Tests 若加用例
read_set:    pal-apple.md(PALA-012 的 PTS 纪律参照——产物口径一致)
deps:        [TASK-CAM-002, TASK-CAM-003, TASK-CAM-004]
acceptance:
  - 录制产物:AVAsset 可加载,时长与录制时长偏差 ≤ 2 帧;video=h264 + audio=aac(track 校验)
  - 取消/停止后不留半成品(失败删除,成功原子落盘)
  - 存相册需 NSPhotoLibraryAddUsageDescription;进编辑器复用 importMedia 路径
verification:
  - SharedUI swift test(如有纯函数用例) + iOS 构建;真机录制冒烟归传哲(SPEC A4)
risk:        音视频 PTS 对齐(缓解:两轨都用各自 CMSampleBuffer 硬件时钟,起点对齐首个样本)
parallel:    false
```

## 实现要点

- `AVAssetWriter`（H.264, 32BGRA PixelBufferAdaptor）+ `AVAssetWriterInput`(AAC)；
  音频直接 append `AVCaptureAudioDataOutput` 的 CMSampleBuffer（AVFoundation 内部转 AAC）。
- 视频：采集帧 → CameraRenderer 的 CI 链 → `CIContext.render(_:to: pixelBuffer)` 写入
  自建 `CVPixelBufferPool`（预热的池,避免逐帧分配 8MB buffer）→ adaptor append。
- PTS：视频/音频各用自己 sampleBuffer 的硬件时钟时间戳，按首样本对齐（PALA-012 同纪律）。
- 停止 → `markAsFinished` → `finishWriting` 完成回调后产出 URL；失败删文件。
- 产出：`PHPhotoLibrary` 存相册 + 跳编辑器（EditorScreen(initialMedia:) → `importMedia`）。
