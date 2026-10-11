# 真机远程验证 SOP（CAM-033 批沉淀，2026-10-11）

> 目标：**真机验证不依赖传哲在场**——构建→安装→启动探针→日志/产物 WiFi 回传→
> 本地分析→回填。只有需要"人对镜头/人手点 UI"的场景（如脸框标定的受控数据、
> 录制人工复现）才需要传哲。

## 前置

- 设备：iPhone 17 Pro（UDID `0FA3CFBB-50FB-541F-971B-7FF65F5ED9A7`），解锁亮屏
  （P64：锁屏 = 一切远程操作被拒；连接报错先解锁/查开发者模式，再 `killall remoted`）。
- 同一 WiFi：手机回传目标 = 本机局域网 IP（`ipconfig getifaddr en0`）。

## 一键流程

```bash
# 1) 构建（增量）
cd apps/apple/ios && xcodebuild -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutApp \
  -destination 'generic/platform=iphoneos' -derivedDataPath "$PWD/../../../build/shell-ios" build

# 2) 启动回传服务（落 /tmp/probe_upload/）
python3 tools/probe/upload_server.py &     # :8931

# 3) 安装
xcrun devicectl device install app --device <UDID> \
  build/shell-ios/Build/Products/Debug-iphoneos/ChuanqiCutApp.app

# 4) 启动 + console 抓取（macOS 无 timeout：后台 + sleep + pkill）
(xcrun devicectl device process launch --device <UDID> --console --terminate-existing \
  -e '{"CQ_AUTO_ROUTE":"camera","CQ_CAM_FACE_CALIB":"1","CQ_LOG_UPLOAD":"<本机IP>:8931"}' \
  com.chuanqi.cut > /tmp/probe_scene.log 2>&1 &)
sleep 30; pkill -f "devicectl device process launch"

# 5) 分析 /tmp/probe_scene.log（stderr 探针行）+ /tmp/probe_upload/（照片/录像）
```

## stderr 探针行速查（stderr 全量进 devicectl --console）

| 标签 | 含义 | 开关 |
|---|---|---|
| `[cam-stats] cap= draw= ms=last/max mem= rec= front=` | 2Hz 性能快照（与 DEBUG 浮层同源）：采集/渲染 fps、处理耗时、内存足迹 | `CQ_CAM_FACE_CALIB=1` 或 `CQ_DEBUG_PROFILE=1` |
| `[face-calib] meta n= mirrored= raw=[…] conv=[…]` | metadata 人脸框：raw = sensor 原始 bounds（0...1），conv = outputRectConverted 输出（**语义未定标，勿消费**） | `CQ_CAM_FACE_CALIB=1` |
| `[face-calib] vision box=(…)` | Vision 脸框（标定模式下强制 faceRectangles）——标定对照基准 | 同上 |
| `[face-calib] plan forced …` / `gate closed` / `.face unavailable` | 检测计划/闸门状态 | 同上 |
| `[cam-lifecycle] stop/configureAndStart` | 会话生命周期取证 | 同上 |
| `[cam-probe] frames flowing N=` | 60 帧心跳（采集链活着的证据） | `CQ_CAM_PROBE` |
| `cq.debug: face detect lastMs=…` | Vision 单次耗时/计数 | `CQ_DEBUG_PROFILE=1` |

## 环境变量（相机域全表见 HANDOFF-020 §6）

`CQ_AUTO_ROUTE=camera`（直进相机）/ `CQ_CAM_FACE_CALIB=1`（脸框标定+取证全集）/
`CQ_DEBUG_PROFILE=1`（检测耗时+cam-stats）/ `CQ_CAM_PROBE=front|back|manual`（探针）/
`CQ_LOG_UPLOAD=ip:port`（产物回传）/ `CQ_SMOKE_VARIANT=A|C|D`。

## 已沉淀的实证结论（CAM-033 真机批，2026-10-11）

1. **metadataOutput 装配顺序**：`setMetadataObjectTypes` 必须在 `addOutput` **之后**
   （此前直接 NSInvalidArgumentException 崩溃）；`availableMetadataObjectTypes`
   在 **startRunning 之前为空**（types 设置须在 running 后，见
   `activateMetadataFacesIfNeededLocked`）。
2. **`outputRectConverted(fromMetadataOutputRect:)` 语义与文档不符**：实测输出
   像素级 + 旋转错位（height≈1248 / 归一化应为 1）。**映射未定标前闸门关**
   （`CameraManager.metadataFacesCalibrated=false`），plan 回退 Vision
   faceRectangles 兜底（坐标已验证正确）。
3. **性能稳态（iPhone 17 Pro，1080p）**：美颜全关处理耗时 0.5-2ms / 渲染 60fps /
   采集 30fps / 内存 ~177MB 稳态（P1 优化后，泄漏修复后的健康基线）。
4. **标定待办**：metadata↔vision 映射反解需要"人脸对相机、居中静止 30s"受控数据
   （远程采到的样本脸贴边/出画，对照失真）→ 传哲手跑一次
   `CQ_CAM_FACE_CALIB=1`，日志回传后解出映射常数、修 MetadataFaceGeometry、
   闸门翻 true（零成本启用 metadata 路）。

## 输出稳定性量化（磨皮脉动取证）

```bash
# 探针自动录像回传后，抽帧算脸区域高频能量时序：
#   磨皮强度脉动 → 高频能量大幅振荡；固定强度 → 残余变化仅运动/AE/编码噪声量级
swift tools/probe/analyze_frames.swift /tmp/probe_upload/cq_rec_xxx.mp4 > /tmp/a.csv
# 判读：变异系数（CV）与帧间变化率——本轮实测 CV 9.3% / 帧间 5.7% = 稳定
```

## 局限（需要传哲的场景）

- 脸框标定受控数据（人脸对镜头）
- 人工复现类（录制手点三次、浮层目检、绿点观察）
- 需要导航驱动的 UI 路径（退出拍摄页 onDisappear → 绿点灭；探针暂无往返场景）
