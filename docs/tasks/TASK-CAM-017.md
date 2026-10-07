# TASK-CAM-017：真机首验问题集中修复（录制死锁 / 前摄方向 / 磨皮闪屏 / 拍照遥测）

```yaml
id:          TASK-CAM-017
layer:       UI(iOSApp)
goal:        修 CAM-016 后真机首验暴露的四问题：①录制无效（死锁根因已实证）
             ②前摄竖屏横躺 ③磨皮闪屏 ④拍照无效（根因待遥测定案）
input:       [传哲 2026-10-06 真机报告, TASK-CAM-005/012/016, pitfalls P69(本卡登记)]
output:      [CameraManager.swift, CameraRecorder.swift, CameraViewModel.swift,
             BeautyKernel.swift]
write_set:   apps/apple/ios/iOSApp/Camera/{CameraManager,CameraRecorder,CameraViewModel,Effects/BeautyKernel}.swift
read_set:    docs/tasks/TASK-CAM-016.md, .ai/modules/camera.md, ADR-0021
deps:        [TASK-CAM-016]
acceptance:
  - 编译 0 error / 改动文件 0 warning（iphonesimulator，ChuanqiCutApp scheme）
  - 模拟器安装冷启动无崩
  - 真机（传哲）：①录制产物系统播放器可播、有画面 ②前摄竖屏正立（镜像为自拍惯例）
    ③磨皮开启无闪屏 ④拍照产物入相册（或错误文案指向确切失败点）
  - 遥测：录制 append 计数 / finish status、拍照 capture→deliver→save 各步、
    磨皮引擎 nil 计数 —— 全部落 os_log（camera.recorder / camera.photo / camera.preview）
verification:
  - xcodebuild -workspace … -scheme ChuanqiCutApp -sdk iphonesimulator build
  - pool 实证：macOS 探针（startWriting 前 pool=nil、后=有）已跑，登记 P69
  - 磨皮 kernel 离屏确定性：20 帧同输入输出指纹唯一（已跑，排除算法层非确定）
risk:        ①前摄标定依赖 RotationCoordinator 的 horizon 角度在设备位姿=界面方向时
             采样，系统旋转锁开启时沿用静态表+既有偏移；②拍照根因未定，遥测先行；
             ③磨皮若为 CI 渲染静默失败（P60 族）则闪屏遥测不可见，需真机复看。
parallel:    false
```

## 背景

CAM-016 落地后传哲真机首验四问题。本卡三修一诊：

1. **录制无效 = 状态机死锁（已实证）**：`CameraRecorder.setupIfNeeded` 在
   `startWriting` **之前**抓 `adaptor.pixelBufferPool`，而该池此时为 **nil**
   （macOS 探针实证，P69）；`appendVideo` 的池守卫又排在 `startSessionIfNeeded`
   之前 ⇒ 每帧必丢 ⇒ writer 永不启动 ⇒ `markAsFinished`（未知态）+ 空产物。
2. **前摄竖屏横躺**：前后摄传感器原生朝向不同，静态角度表按背摄推导
   （P67 同源）；iOS 17+ 官方解法 = `AVCaptureDevice.RotationCoordinator`
   逐传感器标定偏移。
3. **磨皮闪屏**：kernel 离屏 20 帧完全确定（同输入输出指纹唯一）⇒ 排除算法层；
   最可能 = 设备上引擎间歇 nil → 逐帧在「双边/高斯兜底」两种视觉间翻转。
   修法 = **黏性回落**（连续 3 次 nil 本会话停用引擎）+ nil 计数进遥测。
4. **拍照无效**：代码路径静态审查无定论（权限齐、preset 兼容性文档不可达），
   capture→deliver→save 全链 os_log 遥测，错误必上 UI，真机一次定位。

## 实现要点

- Recorder：`startSessionIfNeeded`（含 startWriting）**前置到取池之前**；池懒取
  + 缓存 + 取不到直配 CVPixelBufferCreate 兜底；`markAsFinished` 仅 `.writing` 态；
  finish 时 0 帧 → 显式失败（不产空文件假成功）。
- Manager：iOS 17+ 用 RotationCoordinator 在「设备位姿=界面方向」时标定
  `sensorAngleOffset`（换 position 即重标）；applyOrientation = 静态表 + 偏移后
  snap 到 90° 栅格。设备位姿无效/旋转锁时沿用静态表。
- BeautyKernel：引擎闭包加连续失败黏性停用 + Logger。
- 遥测 logger：camera.session / camera.recorder / camera.photo。

## 验证状态

- [x] `xcodebuild -workspace … -scheme ChuanqiCutApp -sdk iphonesimulator build`
      → **BUILD SUCCEEDED，0 error，改动文件 0 warning**（2026-10-06 12:45；全日志
      仅 2 条环境级警告与改动无关）。
- [x] 模拟器（iPhone 16 Pro, iOS 18.4）安装 + 冷启动无崩。
- [x] 录制根因实证：macOS 探针证明 pool 在 startWriting 前为 nil（pitfalls P69）。
- [x] 磨皮 kernel 离屏确定性：20 帧同输入输出指纹唯一（排除算法层非确定）。
- [ ] **真机（传哲）**：①录制产物可播有画面 ②前摄竖屏正立 ③磨皮无闪屏
      ④拍照入相册或错误文案指向确切失败点；仍闪屏则抓 `camera.beauty`/
      `camera.preview` 日志（引擎 nil 计数已内置）。
- [ ] 真机数据回填 baselines（录制帧率/磨皮引擎失败率）。

## 二修（2026-10-06 下午，真机三轮反馈：后摄方向回归 / 拍照录制仍无效）

三根因（pitfalls P72/P73/P74）：
1. **后摄回归（P72）**：RotationCoordinator 新建即读拿到未初始化 0，后摄 90° 被
   偏到 0°。砍掉 coordinator → 静态表 + 前摄安装差 270° 常量（该常数由事故反推
   实证：前摄 0° 正确 / 后摄 0° 横躺）。
2. **拍照（P73）**：`AVCapturePhotoSettings()` 默认 HEIF 管线，`photo.pixelBuffer`
   恒 nil。改显式 BGRA pixel-buffer format。
3. **录制残余（P74）**：finish 主线程脏读 appendedFrames=0 → 成功落盘被判
   .nothingWritten 删文件。计数自增/读取全收锁内，帧数改回调内取。

验证：BUILD SUCCEEDED 0 error / 0 warning；模拟器冷启动无崩。真机复验归传哲。

## 回写

pitfalls P69（pool 时序）+ baselines（真机数据回传后）+ camera.md 装配形状 + 日志。
