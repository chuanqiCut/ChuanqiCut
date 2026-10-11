# HANDOFF-020 — 真机探针批会话交接（相机录像四案 + 相机浮层 + 录制预热）

> 日期：2026-10-11（会话跨 13:00~19:00）；交接人：集成机（GLM-5.3-Flash）
> 状态：**核心修复已全部真机验证**；P115 预热 + 相机浮层【编码完、待真机验证】
> 下一步执行人：任意会话（先读本文，再按「续跑清单」顺序执行）

## 0. 推送记录

**已全部推送**（2026-10-11 19:3x，`aeceb02..30a3ebb`，快进推送 19 个提交）。
新会话直接 `git pull` 即得全部成果（含并行线 INFRA-025/DEPS-012 的提交）。
工作区残留：并行线未提交的档位/启动屏/研究文档改动（**勿动**，各线自行收口）。

## 1. 本会话交付（按提交序）

| 提交 | 内容 | 真机验证 |
|---|---|---|
| c42f083 | P110 录制死锁+崩溃修复（.writing 守卫在 startWriting 前） | ✅ 探针+人工 |
| 4ee6b8b | AUDIO-002 预览音频全链（core 编排+Apple 解码/引擎+ABI+Swift） | ✅ 48/48+真机音频绿 |
| 73f7d04 | ADR-0037 壳工程冻结入库退役 XcodeGen | ✅ 双壳构建 |
| 90a7963 | ADR-0037 台阶2 synchronized groups + edit_project.rb | ✅ 加文件冒烟 |
| de5b625 | DEPS-012 收口（FFmpeg vendored） | ✅ ctest 48/48 |
| f360257 | ADR-0038 ChuanqiCutCore 改名 + ChuanqiCutFFmpeg 独立 Pod | ✅ 真机安装启动 |
| 5abcc11 | P110/P111 + 探针钩子 | ✅ |
| 37e2833 | P112 色键毒化 startWriting 根因修复 + P113 切摄事务 | ✅ |
| 8e5016e | **P114** 完成回调析构竞态（强持有 self）+ 录制存相册 + 探针 manual | ✅ frames=90×2 |
| cc5818d | **P115 录制预热** + 相机 DEBUG 浮层 + 探针工具化 | ⏳ **待真机验证** |

## 2. P114 录制全案（终审结论）

录制在真机从未成功过（10-07 起），四层根因依次暴露：

1. **P110** `.writing` 守卫在 startWriting 前 → 0 帧 + 停止崩（守卫放行 .unknown）
2. **P112** adaptor 源属性色键 → startWriting 被 Fig -17281 拒收（色键移出，sRGB 走
   CVBufferSetAttachment buffer 附件）
3. **P113** 切摄无配置事务 → 横屏闪现（begin/commitConfiguration）
4. **P114** 完成回调 [weak self] + recorderBox 提前置空 → recorder 先析构 →
   成功录制被判 0 帧删除（回调 [self] 强持有）

**终验**：finish frames=90×2 段、两段 5.7MB mp4 回传核验（1080×1920/3.19s/含音轨）、
用户手点三次 frames=111/27/113 全成功（manual 模式取证）。

## 3. 当前未验证态（P115 + 相机浮层，cc5818d）

### 3.1 P115 录制预热（治「第一次录制画面卡住」）
- 根因：写码器装配（writer 创建/startWriting/编码器 XPC）原在**采集回调线程**
  的首帧上做 → 做不完帧堵 → 预览卡。
- 修：`setupIfNeeded` 尺寸参数化；`startRecording` 经 `recorder.warmup(1080,1920)`
  后台队列预热（竖屏预测尺寸，appendVideo 实际尺寸对账不符重建）。
- **待验**：首录预览不卡 + 录制产物正常。

### 3.2 相机 DEBUG 浮层（用户要求：采集/渲染帧率、处理耗时上屏）
- CameraDebug.swift（stats+snapshot+view）、Renderer.draw 打点、VM 2Hz 采样、
  CameraView 浮层+顶栏天线开关；CQ_DEBUG_OVERLAY=1 / CQ_CAM_PROBE 默认开。
- **待验**：浮层上屏、数值合理性（采集≈30/s、渲染≈60/s、处理 ms 个位数~几十）。
- ⚠️ **交接第一步必须是 pod install**：CameraDebug.swift 是新文件，Pods 工程
  还是旧快照（上次构建因它失败——P107 同族规则）。

## 4. 续跑清单（按序执行）

```bash
# 1) 刷新 Pods（CameraDebug.swift 进工程）
cd apps/apple/ios && bundle exec pod install
# 2) 双端构建
xcodebuild -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutApp \
  -destination 'generic/platform=iphoneos' -derivedDataPath $ROOT/build/shell-ios build
# 3) 安装 + 探针（设备解锁亮屏；WiFi 回传服务：python3 /tmp/upload_server.py）
xcrun devicectl device process launch --device <UDID> --console --terminate-existing \
  -e '{"CQ_AUTO_ROUTE":"camera","CQ_CAM_PROBE":"front","CQ_LOG_UPLOAD":"192.168.0.104:8931"}' com.chuanqi.cut
# 验证：录制预热日志「录制预热 1080x1920」；append 无 FAIL；首录预览不卡；
#       浮层上屏（绿字：采集/渲染 fps、处理 ms）；smoke PASS；mp4 回传核验
# 4) 传哲目检：浮层样式、首录卡顿是否消失、相册新录像效果
```

## 5. 已知未修（池 [15] 登记，非阻塞）

- warp kernel 签名错（CIWarpKernel 不允许显式 sampler）→ 美型诚实跳过；shader 纪律流程
- beauty_bilateral Pool width 越界告警（9/13）
- 横持拍照方向（P111 表只覆盖竖屏）；初始黑帧占位优化
- SPM 绑定 xcframework 重构建（bindings swift test 链接需要）
- EditorScreen 同款浮层已做（877cbdd）；相机浮层开关入口顶栏天线按钮

## 6. 坐标

- 探针环境变量：CQ_CAM_PROBE=front|back|manual / CQ_AUTO_ROUTE=camera|editor /
  CQ_DEMO_VIDEO+CQ_DEMO_AUTOPLAY / CQ_LOG_UPLOAD=host:port / CQ_DEBUG_OVERLAY=1 /
  CQ_SMOKE_VARIANT=A|C|D / CQ_CAM_FORCE_PLAIN / CQ_CAM_PROBE_NOAUDIO
- 上传服务：python3 /tmp/upload_server.py（:8931，落 /tmp/probe_upload/）
- pitfalls 新增：P106/P107/P110/P111/P112/P113/P114（P110/P111 已提交，余者随批提交）
- 设备：iPhone 17 Pro（UDID 0FA3CFBB-50FB-541F-971B-7FF65F5ED9A7）
- main 领先远端 25+ 提交（含并行线 INFRA-025/DEPS-012），**未推送**——推送前按
  多 agent 规则核对他人提交
