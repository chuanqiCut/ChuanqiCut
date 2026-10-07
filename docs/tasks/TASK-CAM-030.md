# TASK-CAM-030：真机反馈批——录制修复 + 采集设置 + 变焦（B 期收官批）

```yaml
id:          TASK-CAM-030
layer:       UI(iOSApp)
goal:        传哲 2026-10-07 真机反馈七项：①录制 AVAssetWriter 报错修复；②录制计时显示；
             ③采集分辨率档位（720p/1080p/4K，预览/录制共用）；④帧率档位（30/60）；
             ⑤高清拍照（全分辨率）；⑥变焦（捏合）；⑦曝光补偿/手动对焦；拍照入相册路径核验
input:       [传哲 2026-10-07 反馈清单, SPEC-CAM-001 A4/A5, pitfalls P69/P83, RESEARCH-009]
output:      [CameraRecorder.swift(会话起点守卫+append 结果检查+双源),
             CameraManager.swift(CaptureQuality/帧率/变焦/曝光/对焦/高清拍照),
             CameraViewModel.swift(设置状态+录制计时起点),
             CameraView.swift(设置面板+计时 UI+捏合手势)]
write_set:   apps/apple/packages/ChuanqiCutCamera/Sources/ChuanqiCutCameraImpl/{CameraRecorder,
             CameraManager,CameraViewModel,CameraView}.swift,
             apps/apple/ios/project.yml(face_warp 编译段)
read_set:    .ai/modules/camera.md, baselines.md, AVFoundation 文档
deps:        [CAM-005, CAM-017]
acceptance:
  - 录制成功率：音频先到场景不炸 writer（会话起点守卫），失败帧不入进度计数
  - 分辨率/帧率档位：canSetSessionPreset/activeFormat 校验，不支持如实拒绝并明示
  - 高清拍照走 maxPhotoDimensions 全分辨率 + .quality；产物入相册（addOnly 路径核验）
  - 变焦 [1, videoMaxZoomFactor] 精确夹取，切摄重置 1.0
verification:  iOS 构建（构建机）+ 真机归传哲
risk:        曝光/对焦滑杆实时生效（每 tick 一次配置锁），真机卡顿则改拖动结束生效（一行）
parallel:    false
```

## 实现记录（2026-10-07 当日完成）

- **录制报错根因**：`appendAudio` 无会话起点守卫——音频先于 `startSession`（首视频帧）到达
  或 PTS 早于会话起点即令 writer 进入 `.failed`（不可恢复）。修复：appendAudio 强制
  「已起会话 + PTS ≥ startPTS + writer.status == .writing」；视频/音频 append 返回值全部
  检查，失败帧不计入进度（旧实现无条件计数 = 失败伪装成进度）。
- 检测提频 15→30Hz（VisionDetector，传哲「贴纸/美型慢半拍」对策；与预览帧率解耦，
  功耗真机对账后可回 24Hz）。
