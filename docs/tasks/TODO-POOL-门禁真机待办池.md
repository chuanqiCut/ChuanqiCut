# TODO-POOL：门禁 / 真机待办池（集成机阶段批消化）

> 立：2026-10-07（[ADR-0029](../decisions/ADR-0029-双机分工与门禁跑批节奏.md)，节奏经
> [ADR-0030](../decisions/ADR-0030-模块册分册制与阶段批门禁节奏.md) 修订为阶段批）。
> 这是「待集成机处理的门禁 / 真机待办」**唯一入口**——开发机把剩余验证记到这里，推送即收工。

## 规则（双机都读）

1. **开发机：只追加（append-only）**。收工时按 §格式 在「开放条目」末尾加条目；
   **不改、不关、不重排、不改号** —— 池的清扫 / 关闭 / 编号改动只归集成机
   （双机同改管理文档必分叉，P82 案底：CAM 撞号归一轮本机 4f0aa67 弃用重做）。
2. **集成机：阶段批（⚠️ 触发后先询问传哲再跑，2026-10-07 拍板）**：`git fetch` → **合并快检**（窄检：core 编译 + SharedUI 测试 +
   冲突/旧号扫描，每次拉远端必做）→ **阶段触发时**（PLAN 阶段收尾 / 一批任务卡闭环 /
   真机单攒齐 / 周度兜底）全量 `run_gate.sh` → 消化池条目 → **真机一趟多单**
   （iPhone 17 Pro，传哲操作，攒齐即跑，不定期空跑）→ 数字回填 → 关条目。
3. **关条目 = 标题行加 ✅ + 日期 + 门禁数字或真机观察结论**，原文保留，条目移入「已消化」。
4. 池条目**不占任务序列号**（ADR-0019 §4）；需要建卡时由集成机发号。
5. 真机项请写明**设备 + 可观察检查点**（模拟器测不出来的才进真机单）。

## 格式

```markdown
### [流水号] Task ID — 一句话标题（⏳ 待门禁 / ⏳ 待真机）
- 来源：机器 / 线 + 日期 + commit
- 改动面：模块 / 文件（对照 PLAN-三线并行 §1a 归属，越界即退回）
- 待办：[ ] 门禁范围（全量 / 指定 case）  [ ] 真机项（设备 + 检查点）
- 验收回填：baselines 段 / 任务卡 / HANDOFF
```

## 开放条目

### [1] 播放器域真机验证（⏳ 待真机，承 [TODO-2026-10-07-播放器域收尾](TODO-2026-10-07-播放器域收尾待他人接手.md) TODO-2）

- 来源：集成机 / 播放器线 + 2026-10-07 + 6d6190c..cb103af 一轮
- 改动面：A 线 · ui-apple（SharedUI/Player）
- 待办：[ ] 真机 iPhone 17 Pro，5 检查点：`AVPlayerEngine.currentTime` 起播前返回 0 非 NaN、
  章节 async API 真机仍取到标题、循环续播后控制条不卡暂停态、捏合缩放手感（1x–3x 钳制 /
  回弹 1.15）主观确认、最近播放 bookmark 分支 iOS 跨会话重开——清单全文见原 TODO 文件 TODO-2
- 验收回填：baselines「预览播放吞吐」段；关原 TODO 文件 TODO-2 标记

### [2] CAM-018/019 真机验收（⏳ 待真机，承 [TODO-2026-10-07-撞号归一轮收尾](TODO-2026-10-07-撞号归一轮收尾待接手.md) TODO-2）

- 来源：集成机 / 美颜线 + 2026-10-07 + 80f1d5a
- 改动面：B 线 · camera + platform-apple 相机子域
- 待办：[ ] 真机 iPhone 17 Pro，5 项：磨皮不闪 + 保边恢复（workingColorSpace = gamma sRGB）、
  滤镜观感基线复核（色彩域连带漂移人工定案）、美白/磨皮区域化行为（美白只在脸 / 无脸直通 /
  移动不抖）、预览 vs 录制颜色一致性（池缓冲色彩空间键接受度）、真机 log 确认
  `beauty engine INSTALLED`——清单全文见原 TODO 文件 TODO-2
- 验收回填：baselines「美颜色彩空间与人脸区域化」段；关 TASK-CAM-018/019 与 HANDOFF-007 待验标记

> 条目 [1] [2] [3] 可**同一趟真机执行**（合并执行减少解锁/装机来回）。

### [4] 阶段批全量门禁（⏳ 待门禁——⚠️ 按新规则待传哲确认后再跑）

- 来源：集成机 + 2026-10-07 深夜（本池规则更新后首批挂起项）
- 改动面：本批全部（UIKit 编辑页 + ChuanqiCutEngine 改名 + podspec 归位）
- 待办：[ ] `run_gate.sh` 全量 14 步（新基线）——**执行前询问传哲**
- 已自查（模块级）：bindings 26 + Player 52 + Camera 36 + Import 16 + Editor 36 全绿；
  iOS/mac 双壳 BUILD SUCCEEDED
- 验收回填：当日日志 + 门禁摘要

### [3] UIKit 编辑页真机走查（⏳ 待真机，UIA-034~036 验收）

- 来源：集成机 / 编辑器线 + 2026-10-07 深夜（UIKit 重建轮）
- 改动面：A 线 · ChuanqiCutEditor Pod（Editor/UIKit/** 新域）
- 待办：[ ] 真机 iPhone 17 Pro：①播放中播放头流畅度（CADisplayLink 直驱 vs 旧 30Hz
  整树重算，目标主线程单帧 <16ms——数字回填 baselines）；②片段拖拽/右缘裁剪手感
  （ADR-0012 语义：松手一条命令）；③时间码随播刷新；④空态引导「打开素材库」→
  MediaSheet 抽屉；⑤「媒体」工具位 → 抽屉；⑥预览点按播放/暂停
- 验收回填：baselines「编辑页主线程单帧」段（新段）；关 TASK-UIA-035 待验标记

### [5] 相册浏览器 MediaPicker 真机走查（⏳ 待真机，UIA-011/012/013 验收补登记）

- 来源：集成机 / 编辑器线 + 2026-10-07（历史漏登记：UIA-011~013 落地时真机项一直没进池，本轮巡检补挂）
- 改动面：A 线 · ChuanqiCutImport Pod（MediaPicker/**）+ ChuanqiCutEditor Pod（媒体抽屉挂载）
- 待办：[ ] 真机 iPhone 17 Pro：①权限弹窗 / 拒绝后引导（去设置）；②受限模式 .limited
  横幅（「管理可选照片」系统面板 UIKit 接线 = Spec UIA-013 §7 已知留白）；③iCloud
  云端项云徽标 + 确认导出联网拉取进度；④满选置灰 + 抖动提示；⑤单击即插入 loading
  闭环 + 多选批量「添加（N）」顺序衔接（sequencedImport 等片段可见）；⑥面板滚动帧率
  （PHFetchResult 增量刷新未做，MVP 整段 reload）
- 验收回填：baselines「相册浏览器」段（新段）；关 Spec UIA-013 §6.4 行为清单

### [6] UIA-037/038 缩略图 + 居中播放头/捏合缩放——自查与真机（⏳ 待自查 + 待真机）

- 来源：集成机 / 编辑器线 + 2026-10-07（UIA-037/038 编码轮）
- 改动面：A 线 · ChuanqiCutEditor Pod（TimelineThumbnails.swift 新域 + TimelineLayout /
  EditorTimelineView / UIKit/EditorTimelineUIView / UIKit/EditorViewController）
- 待办：[ ] **swift test（Editor 包，新增 22 用例）——编码后未执行（用户指示跳过验证），
  本条为第一优先**；[ ] iOS 模拟器构建（UIKit 路径 macOS 侧不可见，P49）；
  [ ] 真机 iPhone 17 Pro：①红条居中 + 拖动时间线 scrub 跟手（帧栅格取整，30fps [E]）；
  ②播放中跟滚不回弹、暂停/seek 后居中恢复；③捏合缩放界限（缩到全时长入视口 /
  放到一帧一槽）且缩放中时间不跳变；④标尺帧级刻度；⑤片段缩略图出现（≥3 帧）
  与拖拽/撤销后不闪不重请求风暴；⑥缩放中主线程不卡（500 片段布局 0.663ms [E] 待真机复核）
- 验收回填：baselines「编辑页主线程单帧」段 + 新「时间线缩略图」段；关 TASK-UIA-037/038 待验标记
- 备注：可并入 [1][2][3] 同一趟真机；[6] 未自查通过前不得视为完成

### [9] 相机 C 期三条（CAM-026 美妆 / CAM-027 人像分割 / CAM-029 磨皮升级）——构建机门禁 + 缺项（⏳ 待门禁 + 待真机）

- 来源：本机 / B 相机线 + 2026-10-08（上一工具会话产物，未提交；HANDOFF-017 收口轮）
- 改动面：B 线 · apps/apple/packages/ChuanqiCutCamera（契约 1 新：MakeupParams.swift；
  实现 1 新：Effects/MakeupRenderer.swift；改 5：CameraRenderer / CameraRecorder /
  CameraViewModel / CameraView / Effects/beauty_bilateral.metal）
- **本轮已做：回退一处让整包编不过的半成品接线** —— CameraRenderer.process 原引用
  `PortraitSemantics.skinMask(for:)`（该类型全仓无实现）与 `apply(to:faces:skinMask:)`
  （CameraBeauty 只有 `apply(to:faces:)` 单一签名，见 CameraBeauty.swift:91）→ 已改回
  `currentBeauty().apply(to: image, faces: faces)` 并留说明注释。全仓已无该两处引用。
- 待办（构建机，第一优先）：[ ] **iOS 双壳构建 -scheme ChuanqiCutApp**（本机 Xcode 13.1 /
  Swift 5.5.1 编不了：部署目标 iOS 16、代码已用 Swift 5.7 `if let x {` 简写）；
  [ ] Camera 契约 `swift test`（本机 swiftpm 5.5 解析不了 tools-version 6.1）；
  [ ] 冲突/旧号扫描（本轮只动 Impl 一处 + 文档）
- ~~CAM-026 契约单测~~ ✅ **2026-10-08 晚已交付**：`Tests/ChuanqiCutCameraTests/MakeupMaskTests.swift`
  10 用例（凸包 / 坐标翻转 / extent 恒等 / 唇内挖空渲染采样 / 参数夹取与预设键名）。
  **本机跑不了（swiftpm 5.5），需构建机 `swift test` 实证。**
- **CAM-027 v1 已交付（2026-10-08 晚）**：契约层 `PortraitSkinMask` + `CameraBeautyEngine.semanticMask`
  注入点（`apply(to:faces:)` 签名零改动）+ Impl 薄壳 `Detection/PortraitSemantics.swift` +
  ViewModel 装配 1 处 + `PortraitSkinMaskTests.swift` 7 用例。**新增门禁关注点**：
  `FaceBoxStore` 补了 `@unchecked Sendable` 一致性（并发契约变更，构建机需确认无误警）。
  本期**不做**头发分割（SDK 15 无该符号）与肤色聚类（归 CAM-028）——已写进文件注释。
- 待办（编码缺口，非验证）：
  [ ] **CAM-029 三个未决**（① 保护与自适应 σ 只落在 pass1 down_h、pass2 up_v_mix 未用——
  有意还是漏改需传哲定；② BeautyKernel 参数面未动，protect 0.85 / σ 0.6×~1.4× 现为写死常量；
  ③ 「细节回注」卡上的第 ① 项**完全没做**，缺 beauty_harness 剖面实测：保边保持率 ≥60%、
  高频能量恢复 ≥80% [E]、全脸 ≤8ms）；[ ] **CAM-027 仍然零实现**（PortraitSemantics.swift
  未建；卡要求「API 形状保持 apply(to:faces:) 不变、调用方零改动」——别再给调用方加参数）
- 待办（真机 iPhone 17 Pro，归传哲，可并 CAM 大批同一趟）：[ ] 美妆五区域跟随无漂移、
  口腔不染色、强度滑杆单调；[ ] 预览=录制色（WYSIWYG，含双摄 PiP 路）；
  [ ] 磨皮 A/B：唇齿/眉眼是否还被磨、暗部是否少磨亮部多磨、**回去对 CAM-012 版本比**；
  [ ] 全链路帧率与 ≤8ms 预算（GPU 剖面）
- 验收回填：baselines「磨皮」段（现 9.85ms 为旧值，升级后需重测）+ 关 TASK-CAM-026/027/029
- 备注：池 [8]（AIEDIT-001 编辑线）与本条同机同轮产物，换机会时可一并带走

### [10] 构建机门禁 + 真机参数回填清单（执行者的入门动作，2026-10-08 立）

> **这是给「下一台设备上的执行者 / AI」的入门文档**，聚合了池 [8]（AIEDIT-001）与
> 池 [9]（相机 CAM-026/027/029）要跑的命令与要回填的参数。**不占任务序列号**（ADR-0019 §4）。
> 背景与本机为什么跑不了：见 pitfalls P90 与 HANDOFF-017 §1。

#### 第 0 步：先把「机器」记下来（P90 的直接要求）

**不记机器环境的数据一律作废**（引用 baselines 必须带机器环境）。开工第一行先跑：

```bash
sw_vers; xcodebuild -version; xcrun swift --version; which cmake ninja brew
```

回填到：`.workbuddy/memory/MEMORY.md` §17 机器表 + `.ai/memory/baselines.md` 对应段的机器代号。
**跑不了的直接写「未实测（工具链上限：<版本>）」，不要写 `—`、不要留空、不要写"全绿"。**
参照：本机（本机记录了 Swift 5.5.1 / Xcode 13.1 / 无 cmake）所有 iOS 构建与 `swift test`、
`build_core.sh`、`ctest` **全部跑不了**——这一条已经坑过一次。

#### 第 1 步：命令清单（复制即跑，逐条记结果）

| # | 命令 | 记什么 | 期望 |
|---|---|---|---|
| 1 | `tools/build/build_core.sh --platform=apple` | PASS/FAIL 计数、**警告数** | AIEDIT-001 新增 TU 在 `-Werror` 下零警告 |
| 2 | `ctest -R ai_edit_plan` | **通过数 / 总数**（写具体数字） | 校验器 117 检查 0 失败（本机 clang13 直编已得此数，ctest 通道首次验证） |
| 3 | `ctest --test-dir build`（全量） | Debug x/y、Release x/y | 不写"全绿" |
| 4 | `xcodebuild -workspace ... -scheme ChuanqiCutApp build` | BUILD SUCCEEDED + **target 数与告警数** | ⚠️ 必须 `-scheme ChuanqiCutApp`：只编 Pods 静态库是假绿（P61，日志里 `Target dependency graph (1 target)` 就是线索） |
| 5 | ChuanqiCutCamera `swift test` | 通过数/总数 | 存量 36（CameraBeauty 7 + CameraFilter 4 + DetectionSmoothing 13 + FaceMask 12）+ MakeupMask **13** + PortraitSkinMask 7 = **56/56**（+1 直通防线用例后 = **57/57**）。⚠️ **订正 2026-10-08**：原文写「MakeupMask 10 → 53/53」，源码实为 13 例；`TASK-CAM-026.md` 与 `.ai/modules/camera.md` 同错，已三处同步 |
| 6 | ~~SharedUI `swift test`~~ → **改为 `swift build`** | 编译 PASS/FAIL | ⚠️ **订正 2026-10-08**：SharedUI 包**无 Tests 目录、Package.swift 无 testTarget**（podspec:15「无独立测试，由门禁 swift build + 双壳构建兜底」，`run_gate.sh:152` 也只跑 build）。「140」是全仓合计旧口径，不是单包数——**这条命令原样执行会直接失败** |
| 7 | metallib 核对 | 该厂商数 + `cq_beauty_down_h/up_v_mix` kernel 名均在 | 旧值 8431B；CAM-029 改过 `beauty_bilateral.metal`，要重新核大小 |

SPM 临时产物一律 `swift test --disable-sandbox --scratch-path "$ROOT/build/spm/<包名>"`（P84）。

> **2026-10-08 构建机首轮实测（机器：macOS 26.7.1 / Xcode 26.6 / Swift 6.3.3 /
> cmake 4.4.3）**：1 ✅（Debug+Release 双向，新增 TU 零警告）· 2 ✅（`ai_edit_plan` PASS）
> · 3 ✅（**Debug 46/46 · Release 46/46**）· 5 ❌→✅（首跑 **53/56** 三失败，已修 → **57/57**）
> · 6 ✅（按订正口径 build 通过）· 7 ✅（`beauty_bilateral.metallib` **9391B**，旧值 8431B；
> `cq_beauty_down_h` / `cq_beauty_up_v_mix` 均在）· golden ✅（built 21 / fail 0）。
> **补充经验（新坑 P92）**：#4 在跑之前必须先 `pod install` —— Pods.xcodeproj 是文件清单
> 快照，新增 Swift 文件不会自动进工程，直接构建会报几十条 `cannot find type in scope`。
> 另：iOS 侧 MetalFX 在 **iphonesimulator** SDK 下 `unable to resolve module dependency`，
> 用 `-sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO` 才编得过。

#### 第 2 步：必须记录的参数（缺一项就回填不全）

**A · AIEDIT-001（池 [8]）**

| 参数 | 取值方式 | 回填位置 |
|---|---|---|
| ctest 通过/总数 | 第 2 步 #2 | `TASK-AIEDIT-001.md` 进度表 + `ai.md` 门禁记录行 |
| Debug / Release 全量计数 | #3 | 同上；结论写具体数字 |
| **CMake 注册三件事**（私有头 include / `CQ_EDIT_PLAN_GOLDEN_DIR` 宏 / 链接 `cq_core`）是否如预期 | #1+#2 通过即成立 | baselines「AIEDIT-001」段由「未实测」改为实测行 |
| 编译耗时 [E] | #1 计时 | baselines 同段（可选项） |

**B · 相机（池 [9]）**

| 参数 | 取值方式 | 回填位置 |
|---|---|---|
| iOS/mac 双壳构建结果 + 告警数 | #4 | `camera.md` 门禁记录行 |
| Camera 契约测试 53/53 | #5 | `camera.md` + 三张 TASK 卡 |
| SharedUI 守恒 140（**CameraBeauty 改动的回归防线**） | #6 | `camera.md` + `ui-apple.md` |
| `@unchecked Sendable` 是否引出新告警 | #4 告警明细 | `camera.md` + TASK-CAM-027（**并发契约变更，必须给结论**） |
| metallib 大小 + kernel 名 | #7 | `camera.md`（旧值 8431B 可比对） |

**C · 真机（iPhone 17 Pro，传哲操作，一趟多单）+ GPU harness 剖面**

必记：**设备型号 + iOS 版本 + 录制档位（分辨率/帧率）+ 是否开双摄**。

| 场景 | 参数 | 回填到 |
|---|---|---|
| 美妆（CAM-026） | 五区域跟随是否漂移、口腔/牙齿是否被染色、强度滑杆是否单调、开关前后帧率 | baselines「美妆」段（新建） |
| 皮肤蒙版（CAM-027） | 眼/眉/唇是否还被磨皮波及（**卡验收第一条**）、无脸是否直通、锚点抖动时蒙版是否闪 | baselines「人像蒙版」段（新建） |
| 磨皮（CAM-029） | **harness 三参数**：保边保持率（≥60% [E]）、高频能量恢复（≥80% [E]）、全脸耗时（**≤8ms 是硬阈值**）；并与 **CAM-012 旧版本 A/B** | baselines「磨皮」段替换旧值 **9.85ms**（那是 CAM-012 的数，不能当升级后阈值） |
| 录制 WYSIWYG | 预览 = 录制色、双摄 PiP 路是否同样处理 | baselines「录制」段 |
| 性能与内存 | 全链路 fps、峰值 `footprint`（jetsam 排查必备，P75/P76）、`nonok/s` | baselines「性能/内存」段 |

金属 API 校验层是否开启要一并注明（P65/P61：开与关会让运行时合法性不同）。

#### 第 3 步：回填位置清单（逐项勾，别漏）

1. `.ai/memory/baselines.md`：上述各段由「未实测」→ 实测行（**必须带机器代号**）
2. `docs/tasks/TODO-POOL-门禁真机待办池.md`：失效项按标题加 ✅ + 日期 + 数字，移入「已消化」
3. `.ai/modules/ai.md`、`.ai/modules/camera.md`：门禁记录表加一行（日期/范围/结论数字）
4. `docs/tasks/TASK-AIEDIT-001.md`、`TASK-CAM-026/027/029.md`：进度表的 ❌ → ✅ 并写证据
5. `.workbuddy/memory/2026-10-XX.md`：当日日志（append-only）
6. **仍未拍板的 CAM-029 pass2**（保护与自适应 σ 只落在 `cq_beauty_down_h`、pass2 未动）
   —— 这条和 BeautyKernel 参数面（0.85 / 0.6×~1.4× 仍为写死常量）**必须回到传哲拍板**，
   AI 不得自行决定。

## 已消化

（集成机关闭的条目移到这里，带 ✅ + 日期 + 数字 / 结论。）

### [7] CAM B 期收官 + C 期开工大批——构建机门禁 + 真机一趟多单（⏳ 待门禁 + 待真机）

- 来源：开发机 / B 相机线 + 2026-10-07（commit df2a672；HANDOFF-014 全清单）
- 改动面：B 线 · ChuanqiCutCamera Pod 全域（契约 4 文件 +3 新 / Impl 9 文件改+8 新 /
  face_warp.metal 新）+ ios/project.yml（face_warp 编译段）+ podspec（MetalFX 框架）
- 待办（构建机，第一优先）：[ ] iOS 双壳构建（已知风险：MetalFXScaler.swift 的
  MTLFXSpatialScalerDescriptor 属性名 / newSpatialScaler / encode(to:) 本机无头文件
  未经对表，按 SDK 头文件修，一行级）；[ ] Camera 契约 swift test 全量（36 存量 +
  FaceMaskTests nil 语义用例已改 + 新契约文件用例未写）；[ ] 阶段批 + face_warp.metallib
  验收（大小 + kernelNames=cq_face_warp）；[ ] 冲突/旧号扫描
- 待办（真机 iPhone 17 Pro，归传哲，一趟多单）：[ ] CAM-018/019 五项（池[2] 沿用：
  磨皮不闪/区域化生效/预览=录制色/方向复核/全链走查——**断线修复后预览区域化首次生效，
  重点复验**）；[ ] CAM-021 双摄 A8：双摄同画预览、PiP 互换、录制产物含前后两路、
  A12 以下开关置灰不闪退、**双摄帧率/分辨率实测入 baselines**；[ ] CAM-013/014：美型
  三滑杆形变跟随无接缝、贴纸锚定无漂移（含贴纸旋转符号定案）；[ ] CAM-024/025：宠物
  贴纸锚定、美体形变；[ ] CAM-030：录制成功率回归（音频先到场景）、档位/帧率切换、
  高清拍照入相册、变焦/曝光对焦手感、录制计时；[ ] MetalFX 开/关 A/B 帧率与画质；
  [ ] 检测 30Hz 功耗对账（不划算回 24Hz，一行）
- 集成机落账清单：[ ] pitfalls **P87**=契约单测全绿≠装配正确（预览 FaceBoxStore 断线，
  两线同病过全部门禁）；**P88**=AVAssetWriter 音频必须守会话起点
  （2026-10-08 改号：原写的 P86 已被「同机双会话互吞」占用）（startSession 在首
  视频帧，音频先到即 .failed 不可恢复；注释声称的语义必须真实现）；[ ] **ADR-0032 提案**
  =人像能力算法驱动定则（无算法即无效果，nil→直通，传哲 2026-10-07；已落地代码与用例）；
  [ ] BACKLOG 登记 CAM-022~030 + 算法定则行；[ ] baselines 待实测项见 HANDOFF-014

### [8] AIEDIT-001 契约冻结 + EditPlan 校验器——构建机门禁（⏳ 待门禁）

- 来源：开发机 / A 编辑器线（AIEDIT 并入 A，PLAN-三线并行 §1a）· 2026-10-08 编码会话
- 改动面：engine/core/include/cq/ai/{feature_report.h, edit_plan.h, llm_client.h}(新) +
  engine/core/include/cq/platform/net.h(新) + engine/core/include/cq/base/status.h(+AI 决策段
  9500~9513 与 kAiPlan 分类，只追加不动既有段) + engine/core/src/base/status.cpp(case 补齐) +
  engine/core/src/ai/plan/edit_plan_validator.{h,cpp}(新) +
  engine/core/src/ai/plan/edit_plan_golden/(新，58 JSON 夹具 + manifest.txt，总 <100KB) +
  tests/unit/test_edit_plan_validator.cpp(新) + engine/core/CMakeLists.txt(1 源文件) +
  tests/CMakeLists.txt(1 测试目标) —— 与 TASK-AIEDIT-001 写集一致（路径按仓库实际
  core/ → engine/core/ 落）
- 待办（构建机，第一优先）：[ ] cmake 配置 + build_core.sh --platform=apple（-Werror，
  本机无 cmake/ninja 未跑；新增 TU 已过 clang13 -Wall -Wextra -Wconversion -Wshadow
  -Wold-style-cast 零警告自证）；[ ] ctest -R ai_edit_plan（本机 clang++ 直编最小组合
  已实测 117 检查 0 失败：合法 18/18 + 非法 40/40 错误码精确匹配，构建机需在 ctest 通道
  复跑确认 CMake 注册无误）；[ ] 冲突/旧号扫描（本轮未触碰任何在飞文件）
- 验收回填：模块册 ai.md 门禁记录行 + baselines「AIEDIT-001」段（无性能项，契约任务）
- 备注：真机无涉（纯 C++ 契约层，无 UI/无渲染）；池[4] 全量门禁触发时本条可并入

### [11] DEPS-012 FFmpeg 本地 Pod 接入——iOS 真机链接与运行验证（⏳ 待门禁 + 待真机）

- 来源：集成机 / media 线 + 2026-10-11~12（本机未推送，同会话交付）
- 改动面：media 域 + 基建（`tools/build/build_ffmpeg_demux.sh`、`third_party/CMakeLists.txt`、
  `engine/CChuanqiCut.podspec`、`core/cq/media/ffmpeg_probe.*`，全清单见 TASK-DEPS-012；ADR-0036）
- 待办：[ ] 门禁范围：全量（CMakeLists 顶层顺序改动 + podspec vendored 变更，属构建链）；
  [ ] 真机项 iPhone 17 Pro：①iOS App 能链上 `libffmpeg.xcframework` ios-arm64 slice
  （vendored `../third_party` 相对路径在 iOS 构建下生效）；②demo 页触发
  `FFmpegProbeFile` 对 golden mp4 探测返回 1080p/h264/5.0s（与 ctest 断言同口径）。
- 验收回填：baselines「FFmpeg demux 档位构建基线」（arm64/iOS 体积已回填）、
  TASK-DEPS-012 子步骤 6、模块册门禁表。

### [12] AUDIO-002 预览音频 + CAM 单摄前摄方向修复 —— 真机验证与构建机项（⏳ 待真机/待门禁）

- 来源：集成机 2026-10-11 会话（传哲直接下令：「预览没声音彻底解决；前置摄像头又横屏」）
- 改动面：B 线 camera（CameraManager 两 hunk）+ C 线 media/audio（AUDIO-002 全链）+ Editor 接线
- 真机 iPhone 17 Pro（归传哲，可与池 [2]/[9] 同趟）：
  - [ ] 相机：单摄**前摄**预览竖屏且镜像正确；前摄拍照不横躺、有镜像；切摄/旋转/双摄开合后
    方向仍对；后摄不回归（对照 P67/P72 语义）；前摄**录制文件**方向与预览一致（WYSIWYG）
  - [ ] 音频：导入带音轨视频 → 预览出声；暂停/恢复无残音；拖拽播放头 ≤ 半秒内收敛、无持续
    漂移告警（`CQ_LOG_WORKFLOW=preview` 看重锚日志）；静音轨不响；无声素材不出杂音
  - [ ] 音频 stats（`cq_audio_preview_stats`）：稳态 underruns/resyncs 应接近 0，异常增长要记录
- 构建机/门禁（集成机）：
  - [ ] iOS 壳工程构建（CChuanqiCut Pod 新增 2 个 .mm + cq_sdk.h 音频段；podspec glob 自动纳新，
    无需改 spec；框架 AVFoundation/CoreMedia 已列）
  - [ ] SPM 绑定 xcframework 重构建（tools/build/build_core_apple.sh + bindings/swift/prepare.sh）
    —— 现 xcframework 内 .a 无 cq_audio_preview_* 符号（头已新鲜），SPM 路线**链接**会失败
  - [ ] 全量门禁按阶段批（本次模块级：ctest 48/48 + Swift typecheck 0 错已记录）
- 已知风险（写明）：预览音频时钟 MVP=视频主音频从（漂移护栏收敛而非无缝同步）；
  同素材多 clip 各开一路解码会话（内存待真机观测）；AVAudioSession category=.playback
  与相机录制屏（playAndRecord）切换时由各屏自配，跨屏切换未验
- 验收回填：baselines 新增「预览音频」段（现为空）；关池 [12] 需真机数字；pitfalls P106 已记
- 追加（2026-10-11 下午）：壳工程已冻结入库（ADR-0037，XcodeGen 退役）——真机趟顺带确认
  冻结工程出包可跑（metallib 双产物 9391B/7123B 已核非空壳）；此后壳工程改动直接进 Xcode 提交。

## [13] TASK-INFRA-025 内核 Chq 前缀改名（ADR-0039）——Swift 侧与 Pod 布局待验（2026-10-11，集成机）

- 来源：传哲裁决「只 C++ 内核加 Chq 前缀」；189 类型 + 83 文件改名，模块级验证已过
  （Debug+Release 双配置 -Werror、ctest 48/48、check_platform_headers 41 头 0 违规、
  golden 21/21；`cq_sdk.h` 声明区 diff=0，ABI 未动）。
- 构建机/门禁（集成机）：**全部完成，2026-10-11 下午收尾批关池**
  - [x] Swift 窄检：xcframework 重建（build_core_apple.sh --config=Release +
    prepare.sh，三切片新鲜、16 个 ABI 符号含 cq_audio_preview 在位）→
    **bindings swift test 26/26 通过**。
  - [x] pod install（bundle exec 1.17.0）+ 双壳端到端：**macOS BUILD SUCCEEDED**
    （x86_64 原生架构，清 DerivedData 干净构建）；**iOS generic device BUILD
    SUCCEEDED**（arm64）。Headers 布局已收 chq_*（P96 双 chq_gfx.h 噪音仍在，无害）。
    过程中发现并修复壳工程对 Pods 的远程依赖三件缺失（pitfalls P108）。
  - [x] 全量门禁按阶段批照旧（模块级数字已记模块册）。
- 拆出新池 **[14]**：mac 通用双架构构建被 CP 1.17 Swift Compatibility Header
  共享路径坑（unsupported Swift architecture）——单 arch 验证口径见 P108④。

## [14] macOS 通用双架构构建（CP 1.17 Swift Compatibility Header 共享路径）（2026-10-11，集成机）

- **现象**：mac 壳默认 "Any Mac"（ARCHS=arm64;x86_64）构建，五个 Swift Pod 的
  `Swift Compatibility Header/<Name>-Swift.h` 走非 arch 专属路径，双 arch 互相覆盖
  → `error: unsupported Swift architecture`（-Swift.h:381，PCM 生成失败）。
- **根因**：CocoaPods 1.17 modular-headers 的兼容头 ditto 进 BUILT_PRODUCTS_DIR 的
  arch 无关路径，Xcode 26 显式模块构建下双 arch 并发互踩。单 arch（原生 x86_64 /
  `ARCHS=x86_64 ONLY_ACTIVE_ARCH=YES`）不受影响，已按 P108④ 口径验证通过。
- **待办（集成机，独立小任务）**：调研 CP 侧正确解法（per-arch 兼容头路径 /
  `SWIFT_OBJC_INTERFACE_HEADER_NAME` / 升级 CP），或壳工程钉 `ARCHS=arm64 x86_64`
  的官方发布口径与本地单 arch 验证口径分离；修完跑一次真通用构建作验收。
- 关池条件：通用双 arch mac 构建 BUILD SUCCEEDED（清 DerivedData 口径）。

### [15] 相机录像 P112/P113 修复收尾 + warp/pool kernel 两案（录制端到端 ✅，余项待修）

- **2026-10-11 17:06 端到端终验通过**：前摄探针录像 1080×1920 / 3.19s / 含音轨 /
  5.71MB 回传 Mac 核验；append 零失败（pool=true 装配正常）；smoke 全 PASS。
  P112/P113/P110 三案关闭；**A3 录像方向机器面已验**（WYSIWYG 听感/体感归 B 组人工项）。

- 来源：集成机 2026-10-11 真机探针批（5abcc11 / 37e2833；传哲实测报错驱动）
- 已修待终验（设备解锁后重跑 CQ_CAM_PROBE 一轮）：
  - [ ] 录制端到端：开始→结束无报错、产物 mp4 上传回 Mac、尺寸 1080×1920、帧数>0
    （P112 = adaptor 源属性色键毒化 startWriting，已隔离复现+修复；P110 死锁已修）
  - [ ] 切摄横屏闪现消失（P113 = switchPosition 补 begin/commitConfiguration 事务）
  - [ ] 相机页不再自动锁屏中断（isIdleTimerDisabled）
- 新登记待修（CAM 线）：
  - [x] **warp kernel 签名重写完成（美型复活，CAM-033 批）**：CIWarpKernel 契约 =
    首参 dest 坐标 + **零 sampler 参数**（旧版 src 只读 extent/coord 也被拒收）——
    画面信息改 float4 ext 由 Swift 传入。E13 真机：reshape 0.6/0.5/0.4 + 磨皮美白+
    分割全链满帧（0.9-1.4ms）零崩溃，landmarks 锚点正常。**变形效果目检归传哲**。
- 验收回填：baselines「录制」段；关 [15] 需真机产物核验数字。

- **2026-10-11 18:00 更新**：P114 完成 — 录制完成回调析构竞态修复（强持有 self），
  探针终验 finish frames=90×2 段、两段录像 5.8MB 回传核验；**录制功能全链修复完成
  （P110/P111/P112/P114 四案）**。新增：录制成功自动存相册（PHPhotoLibrary add-only，
  首次使用会弹权限，允许后每段录像自动入相册）。A3 录像方向待传哲相册目检。

- **2026-10-11 收口轮（集成机）**：P93/P94 MultiCam 档位修复 + 构建机批（Makeup 3 案 /
  MetalFX 对表 / 曝光夹取）入库 fdb4e97（Camera 62/62 + 双壳绿，详见 camera.md 模块册）。
  新增真机项：
  - [ ] **P93/P94 复验**：双摄会话下切换 720p/1080p/4K 不崩（preset 异常已根除），
    档位实际生效（activeFormat 分辨率对得上），帧率切换后仍准（选 format 后重放）；
    单摄档位回归（普通 Session preset 路径未动）
  - [x] **CAM-033（P1 检测裁剪）真机·远程验证完成**（2026-10-11，SOP 沉淀
    tools/probe/README.md）：①metadataOutput 装配顺序 P0 崩溃修复（P117 坑①）+
    available 时序修复（P117 坑②）；②美颜全关 Vision 检测归零 ✓（探针日志实证）；
    ③性能稳态回填 baselines：处理 0.5-2ms / 60fps / 177MB；④`outputRectConverted`
    语义陷阱实证（P117 坑③）→ **标定闸门 metadataFacesCalibrated=false**，
    metadata 框未定标不消费、plan 回退 Vision faceRectangles（坐标已验证正确）。
  - [x] **「磨皮美白开了会闪」三根因修复 + 美颜开 SIGTRAP 崩溃修复**（2026-10-11
    深夜，传哲反馈驱动，CrashProbe 信号处理器 11 轮取证定位）：①metadata 乱坐标
    进蒙版（闸门只关 plan 没挡回调→源头上挡，P118 前置）；②仅框模式检出丢帧 →
    FaceBoxStore 清空 → 磨/不磨交替闪（dropout 保持 500ms 修复）；③activate
    幂等分支绕过闸门（plan 以为 metadata 供框实为空→全直通闪，修复）；④美颜开
    SIGTRAP 必崩 = onResult 非隔离上下文 cq.debug 打印段触发 MainActor 断言
    （P118，删段+统计移 cam-stats 主线程）。**修复后磨皮0.5+美白0.5 真机：
    处理 1.6-3.0ms / 60fps 满帧 / noface 停止增长（不闪）/ 磨皮引擎确认工作**。
    检测耗时实证 **11.6-20.3ms/次**（baselines 已回填）→ **美颜脸框检测降频
    （10-15Hz）列 P1 收尾优化**。
  - [x] **「美白边缘闪/磨皮30%也闪」修复**（2026-10-11 深夜三）：根因 = 仅框模式
    框无帧间平滑（landmarks 点平滑对框路径不生效），Vision 框逐帧抖动直进蒙版 →
    边缘亮暗跳变（美白对比强所以边缘最显眼）。修 = FaceMask.smoothedBox 框级 EMA
    （与 landmarks 同参数源）。73/73 + 壳绿。
  - [x] **「磨皮程度一直在变化」根因修复**（2026-10-11 深夜，传哲澄清闪动语义后）：
    cq_beauty_sigma_local 按中心像素**绝对亮度**分档（0.6~1.4×，CAM-029 ③）——
    手持时相机 AE 的帧间亮度摆动被直接调制进磨皮强度 = 程度脉动（该参数自落地起
    无 harness 实测，模块册在案）。**禁用**（固定 σ_range），自适应留 P2 以帧内
    归一化 + harness 定标再启用。E2 真机：磨皮 0.6 满帧、noface 冻结、ms 2.4-2.6。
  - [x] **「磨皮开最大人脸涂抹过重」短期缓解**：mix 上限 1.0→0.85（保留 15% 原图
    高频细节，单调性保持）——正解是 P2 引导滤波 k 纹理保留系数（RESEARCH-015）。
  - [ ] **磨皮最大强度引擎状态验证（需设备解锁+人脸对镜头）**：远程 D15 因锁屏
    未跑成；待验证 mix 上限后的观感（传哲目检）。
  - [x] **P3 后半：美白重做 + 美颜链半分辨率**（CAM-035，2026-10-11 深夜九）：
    ①美白从线性曝光+CIColorControls 改 **CIToneCurve 五点亮度曲线**（两端锚定
    防死白+中调提亮）+ 肤色饱和度微降（防塑料），对强度单调（单测）；②**美颜
    子链半分辨率**（磨皮/美白 540×960 跑完上采样混回，CQ_CAM_FULLCHAIN=1 反向
    开关；奇数帧 1px 溢出 cropped 兜底，extent 恢复单测）——E12 实测双边引擎
    处理 1.1-3.5ms（半分辨率前 1.6-3.0 全帧基线上再降）。③合并混合等价测试
    改语义抽检（蒙版外保真/蒙版内生效——两次混合路径已删+半分辨率变量污染
    逐位对比）。
  - [x] **「磨皮区域一直变化/美白整头发白」修复（P3 前半提前，CAM-035）**：
    传哲实测双反馈的正解 = **人像分割蒙版 ∩ 脸框**（VNGeneratePersonSegmentation
    .balanced）。实现：独立 PortraitSegmenter 管道（15Hz 闸门+忙丢弃，**不挂
    detect**——前摄磨皮 metadata 路下 detect 早退，挂 detect 永不跑 E5 实证）；
    mask 立即渲染成独立 bitmap（CIImage 持采集 pixelBuffer 会拖爆 pool，E6 实测
    231↔283MB 锯齿）；PortraitSkinMask.skinMask(segmentation:) 契约纯函数
    （缩放+羽化+乘法交集）+ 语义闭包分级回落（分割→几何精修→框椭圆）；
    switchPosition 补 updateDetectionPlan（摄位切换刷新 metadata 兜底策略）。
    E7 真机：磨皮0.6 全链满帧 ms 0.8-1.8、noface 冻结、无崩溃；内存 240-276MB
    锯齿 = pool 正常回收（分割代价 +80MB 记录在案）。**待传哲目检**：美白只上
    皮肤不整头白、磨皮区域不再跟框变、后摄切摄验证。
  - [ ] **P1 收尾·检测降频**（本轮实证驱动）：美颜脸框（faceRectangles/metadata）
    detectionHz 从 30Hz 降 10-15Hz（单次 12-20ms × 30Hz ≈ 半核，蒙版有 EMA 兜着
    无需 30Hz）；仅美型/贴纸锚点保持 30Hz（跟手）。改 VisionDetector plan 分档。
  - [x] **P1 收尾·检测降频落地**（494756a）：仅框档（faceRectangles）15Hz（rectHz）
    + metadata 供框 15Hz 节流；锚点档（landmarks）保持 30Hz 跟手。
  - [x] **P2（CAM-034）guided 高通法引擎落地（CQ_CAM_GUIDED=1 启用）**（494756a）：
    beauty_guided.metal（两 pass box blur 结构层 + k 纹理保留回注，无 exp——
    「程度脉动」类问题的算法级免疫）+ GuidedBeautyKernel 装配（失败回落双边）+
    guidedRadius(2...6)/guidedKeep(0.9...0.1) 单调映射 + 壳脚本编译段（独立
    beauty_guided.metallib）。E8/E11 真机处理 0.8-2.1ms（显著低于双边基线
    1.6-3.0）。**观感对比（传哲）定稿后翻默认**。
  - [x] **美颜开间歇 SIGTRAP 治本（P118 归因二次修正）**（494756a）：真凶 =
    @MainActor 类闭包隐式隔离（onMetadataFaces max(by:) 二次栈实证；print 归因
    是冤案修正）→ 7 个队列回调属性标 @Sendable + renderer/store @unchecked
    Sendable → **E11 60s 长跑零崩溃**（此前 30-40s 必崩）。
  - [ ] **后摄+美颜验证**（探针 back 分支未切摄待查 + 需真人对镜头）：后摄磨皮
    目检 + 档位回归；同时跑 metadata 标定（见下）。
  - [x] **CAM-033 标定收尾完成**（2026-10-11 深夜，传哲人脸对镜头 30 秒
    calib_run2：874 meta + 771 vision 对照）：**映射反解 = 转置**（x_f=y_s、
    y_f=x_s、w/h 互换，iPhone 17 Pro 前摄，误差 ≤0.011）——90° 传感器安装角在
    归一化坐标下恰为转置，前摄镜像已含在实测复合映射内。已落
    MetadataFaceGeometry.contractRect(fromSensorBounds:mirrored:)（定标断言
    单测 2 例）+ **闸门翻 true** + VM metadataOK 加 position==.front（后摄映射
    未定标 → nil 丢框 → Vision 兜底，防"plan 空集无人写 store"回归）。
    **端到端验证（E1）：前摄磨皮零 Vision（det 计数冻结 324）、noface 冻结 103
    （不闪）、处理 0.5-2.8ms、无崩溃**。待传哲目检：预览蒙版对位（转置映射
    视觉终验）+ 后摄磨皮（Vision 兜底路径）目检。
  - [ ] **Makeup/MetalFX 回归目检**：美妆五区域正常（irisMask/羽化修复后）、
    MetalFX 升采样画质（SDK 命名全对表后首次真编译）

- **2026-10-11 20:xx 会话生命周期修复轮（集成机，50d5734）**：
  - 已修入库：①退出拍摄页停会话（onDisappear 此前只复位息屏开关，stop 只挂退后台
    ——摄像头绿点常开根因）；②wireCallbacks DEBUG 探针闭包 `self.renderer` 保留环
    （manager↔VM 互持，DEBUG 构建 VM/会话永不释放=内存只涨根因）；③VM deinit 补
    manager.stop() 兜底。验证 62/62 + iOS 壳绿。
  - [ ] 真机验证：退出拍摄后绿点灭；反复进出拍摄页内存曲线平稳（浮层内存读数）；
    进编辑器→返回拍摄页会话恢复正常
  - **磨皮「慢 + 效果不好」诊断结论（待传哲拍板，未动刀）**：
    - kernel 本身不是瓶颈：CAM-012 基线 9.85ms/帧@1080p（Intel Iris 640 宿主），
      真机 GPU 应 1-3ms [E]；CAM-029 的 protect/σ_local 只是每中心像素几个
      smoothstep，开销可忽略。
    - 慢的构成是四件叠加：①检测桥 30Hz×3~4 个 Vision 全请求（FaceLandmarks468+
      HumanBodyPose+RecognizeAnimals[+AnimalBodyPose]，2026-10-07 传哲提频 15→30
      的代价 [E]6-15% CPU/ANE）；②蒙版混合链每帧 1~2 次全帧 CIBlendWithMask +
      美白再加 2 个 CI filter；③录制时 appendVideo 同链再跑一遍（双开销）；
      ④若引擎被黏性停用（连续 3 次 nil）整体掉进默认 CI 高斯（慢 ~2×且观感塑料）
      ——真机日志 "beauty engine FALLBACK" 可判。
    - 效果不好的结构性原因：脸框椭圆蒙版只盖脸（不含颈/额际外）+ σr≤0.11 保守
      保边 + 半分辨率双边细节软；faces 时有时无的帧直通（磨皮断续感）。
    - 方案拍板项 **已升级为完整方案 [RESEARCH-015](../../docs/research/RESEARCH-015-相机美颜性能与效果重构方案.md)
      （2026-10-11 深夜，吸收 A 的检测裁剪 + B 的引导滤波 + 语义分割蒙版，三期分卡）**：
      P1 检测裁剪（metadataOutput 脸框 + 按需 Vision + 合并 Blend）→ P2 磨皮内核
      （引导滤波 + 纹理保留系数 k，磨皮 pass 预期 3-5×[E]）→ P3 蒙版语义（分割∩脸框
      + 美白重做）。原 A/B/C 归档：A=并入 P1+P3，B=并入 P2，C（商 SDK）仍不建议。
      **拍板前 CI 链冻结新特效。**
    - 拍板需要的真机读数（浮层已可看）：processing ms（磨皮开/关对比）、
      采集/渲染 fps、内存曲线、有无 FALLBACK 日志。
  - **2026-10-11 真机日志批（用户回传）三结论**：
    ① **磨皮引擎 INSTALLED 且全程无 FALLBACK** → 黏性回落假设排除，「慢」确证为
    检测 30Hz 全家桶 + Blend×2 + 全分辨率的叠加（方案 A 判断坐实）；
    ② 预览链健康：采集/渲染 1:1 同步增长、1920 帧零失败；
    ③ **新观察项**：`FigCaptureSourceRemote assert err=-17281`（采集栈 XPC 远端断言，
    与 P112 startWriting 被拒同错误码但不同调用点）出现 8 组，预览未断流——触发
    操作待定位（切摄/后台恢复/档位切换？），若与新加的 stop→resume 重连相关需确认
    resume 后功能完好；（`FigAudioSession -19224`/`Fig -12710` = Apple 私有栈启动期
    噪声，社区经验无害 [E]，留意 B-02 音频项是否正常）
  - **编排细化（2026-10-11 深夜追问轮，并入方案 A 范围）**：
    ① 磨皮+美白各做一次全帧 CIBlendWithMask（CameraBeauty.apply 两段独立 blended）
    → 合并为单次（美颜结果合成后再混合，省一次全帧混合）；
    ② **低分辨率过算法**可行且是业界标配：美颜链（磨皮/美白/美妆蒙版）在 540×960
    （或 720）跑完后 upscale 混回原图，预览/录制渲染分辨率不变——磨皮是低频信息
    观感无损 [E]；美型 warp 若启用应留全分辨率（几何变形低分辨率会糊边）；
    拍照路径不降（成片质量）；
    ③ 检测桥编排已是最优组织（单 handler.perform 共享预处理），但三处浪费可裁：
    请求组合按功能开关动态裁剪（现在全家桶常开：FaceLandmarks+HumanBodyPose+
    RecognizeAnimals[+AnimalBodyPose]，没开美体/宠物贴纸也全发）；30Hz 降为自适应
    （仅磨皮=15Hz 足够，贴纸/美型跟手才要 30）；输入传缩略帧（480p 级）替代
    1080p buffer。


### [16] iOS 模拟器全壳构建红：相机包 import MetalFX（模拟器无此模块）

- 来源：集成机 / 编辑器线 UIA-039 批（2026-10-12 发现）
- 现象：`xcodebuild -scheme ChuanqiCutApp -sdk iphonesimulator build` 失败——
  `ChuanqiCutCamera/Sources/ChuanqiCutCameraImpl/Effects/MetalFXScaler.swift:17`
  `import MetalFX`，iphonesimulator26.5 SDK 无 MetalFX 模块（真机 SDK 有）。
  **fdb4e97（2026-10-07 构建机批）起即红**；相机线只验过真机壳（BUILD SUCCEEDED 均为
  iphoneos），编辑器线池 [6] 的「iOS 模拟器构建」项被此挡。
- 修法（三选一，归属线定）：
  - [ ] ①`#if canImport(MetalFX)` 包住 import 与使用点 + 运行时能力降级（红线 #3 的
    运行时查询精神，最推荐）
  - [ ] ②Podsimulator 排除该文件（source_files 条件化）
  - [ ] ③阶段批门禁对相机包改真机构建口径（不推荐：门禁降档）
- 影响：阶段批门禁第 5 步（iOS 壳构建）不可绿；编辑器线全壳证据被挡。

### [17] 2026-10-12 真机日志批的三个未结项（内存 / 主线程 / 相册元数据）

- 来源：集成机 / 相机线 + 编辑线（2026-10-12 真机日志回传批）
- 现象（同一份日志的三条独立线索，都已定位到代码但**未取证或未修**）：
  1. **内存单调上升 → signal 9（jetsam）**：播放段 `footprint` 188.0→200.2→251.9→
     263.9→282.4MB（t=2→10s，1080×1920 BGRA ≈ 8.3MB/帧），随后相机会话长跑 3300+
     帧，末段 Metal 断言后进程被杀。解码队列已由 MEDIA-027 封顶 12 帧（≈100MB），
     **但「切到相机页后编辑器解码器/预览器是否仍在持帧」未取证**。三个候选
     （全部 `hypothesis`，未实测）：①编辑会话未随切页释放，12 帧队列 + 预览器
     常驻；②CIContext 逐帧 DAG 缓存（每帧新建 CIImage + CIVector 参数 → 新中间
     纹理）；③相机侧 scratch/FX 纹理随转屏重建而泄漏。
     取证手段：Xcode Memory Graph / Instruments Allocations，看是 CVPixelBuffer
     堆积还是 CI 缓存。
  2. **主线程同步 I/O 仍在（红线 #8）**：`importMedia` 是 @MainActor 同步调用，
     即使 probe 降到 OpenLight（毫秒级），`OpenLight` 内部仍是
     `dispatch_semaphore_wait` 等 Default QoS 的 AVFoundation 回调 —— 优先级反转
     的结构没变，只是时长短了。是否要改成异步导入链路需单独建卡决策。
  3. **`Missing prefetched properties for PHAssetOriginalMetadataProperties`**：
     PhotoLibraryImporter 在主队列按需取 PHAsset 元数据（Photos 明确警告会掉帧）。
     应改为 `PHImageManager`/`requestMetadata` 后台取或批量预取。
- 待办：[ ] 真机 iPhone 17 Pro：复现路径（导入相册 1080×1920 → 播放 30s → 切相机
  长跑 2min），抓 Memory Graph + footprint 曲线；[ ] 确认切页后编辑器会话是否释放；
  [ ] 美型 warp 修destination 后真机是否出现 `warp engine INSTALLED`
- 验收回填：baselines「真机内存」段（当前**未实测**）；LEDGER-W42

### [18] 门禁不覆盖 App 壳构建 —— metallib / 壳内 Swift 改动整类漏网（✅ 2026-10-17 集成机关闭 · TASK-INFRA-037 · 双壳暖 39s/冷 280s 两端 rc=0 error=0）

- 来源：集成机 / 2026-10-12 真机日志纠偏批（`32895d3`）
- 现象：`tools/ci/run_gate.sh` 的 14 步里**没有 iOS / macOS App 壳构建**（只有 XCFramework
  + 各功能 Pod 的 `swift test`）。`build/gate-logs/ios-app-build-device.log` 是 2026-10-09
  手跑留下的，不是门禁产物。
- 后果（本批实证）：`face_warp.metal` 改签名后**门禁全绿但 shader 一行没被编译过** ——
  `*.metal` 由壳工程 postBuildScripts 以 `-fcikernel` 编成 metallib，SPM 包测试不碰；
  同理壳内的 `ChuanqiCutApp` 目标源码也不进包测试。CIWarpKernel 这类「只有真机加载
  才知道对不对」的改动，门禁给的是**伪绿**（P123 就是在真机日志里才暴露的）。
- 待办：[x] 集成机决策：**2026-10-17 传哲批准进门禁**（原话「可以进，但是是不是可以用 APP 中的去跑」
  —— 是，用 App 自己的 workspace，不另立判据工程）。落法见 `tools/ci/check_apple_shells.sh`
  + `run_gate.sh` 第 6 步 `apple-shells`（TASK-INFRA-037）。
  [x] 同期把 macOS 壳一并纳入（`-arch $(uname -m) ONLY_ACTIVE_ARCH=YES`，不带 `-destination`，P96）
- 验收回填：**冷 280s / 暖 39s（两端合计）**，两端 rc=0、`BUILD SUCCEEDED=1`、`error:` 行 0；
  `pod install` 两端各 rc=0、14 个 pod。数字入 baselines「双壳进门禁」。
  ⚠️ 本池原写「约 10min」是**按冷壳手工配方估的**，实测暖跑 39s、冷跑 280s（≈4.7min），估算未采信。
  ⚠️ 覆盖范围=**真机 device 切片 + macOS**，iOS **模拟器**仍不在门禁内（池 [16] 的 MetalFX 模拟器红
  本步不接，那条债归模拟器专项）。

### [19] 内核缺「设置轨道静音」ABI —— 轨道头原声开关只能显示不能点（⏳ 待决策）

- 来源：集成机 / 2026-10-13 UI 线 UIA-041 U1（`f?` 本批），由轨道头 S2 落地时捞出
- 现象：`CQTrackInfo.muted` **只能读不能写**。
  * 读：`cq_sdk.cpp:488` `out->muted = t.muted ? 1 : 0;`（单向填出）
  * 写：**全仓搜不到** `cq_session_set_track_muted` 或任何改 `ChqTrack::muted` 的
    Command/SDK 入口（`ChqTrack.muted` 只在 `chq_timeline.h:72` 有默认值 `false`，
    `chq_editor_model_state.cpp:94` 与 `chq_preview_mixer.cpp:446` 消费它）。
  * 对比：`enabled` 同理（`cq_sdk.h:245` 注释已写「0/1」），颗粒度更细，也缺写。
- 后果：**UI 侧无法做「原声开关」**，只能显示回读状态。做能点的开关 = 点了没反应的假功能
  （违背 ADR-0034「严禁临时方案/不做假功能」）。当前 UI 实现刻意做成 **disabled 只读态**
  （见 `TimelineContentView.buildTrackHeaders`，2026-10-13）。
- 连带影响：音频面板（U2/UIA-042）、混音 UI（B5）、**导出时的静音轨处理**（B4 可见出口
  若要支持「导出不含静音轨」必须先有这个状态的可写性）。
- 待办：
  [ ] 内核侧决策：Command（`ChqCommand::SetTrackMuted`）+ SDK  thin wrapper
      `cq_session_set_track_muted(session, track_id, muted)` —— 需进 CommandHistory（可撤销）
      ，.edit approval 前先确认 B4/B5 的导出/混音是否依赖它（若要，优先级上调）
  [ ] 绑定层 Swift：`EditorViewModel.setTrackMuted(trackId:muted:)` 穿透
  [ ] UI：把 `buildTrackHeaders` 里的 disabled 态换成真开关（届时一行改回）
  [ ] 同期评估 `enabled`（单开关）是否也要写 —— 与其他268效果开关的关系
- 验收回填：本池条目 + LEDGER-W42 + RESEARCH-017 §2 S2 行
- **2026-10-17 裁定（合并版问卷 E1，传哲：「先补内核 muted ABI」）**：
  待决策态**已解**，本条转 **TASK-CORE-011** 编码（不关条目 —— ABI 还没落地就还是欠账）。
  两条**取证订正**（本条原文按 UIA-041/042 时期的代码状态写，布局与轨道区都变过了）：
  ① "disabled 只读态在 `TimelineContentView.buildTrackHeaders`" 这个落点**已不存在**，该文件
     随旧自绘轨道区在 UIA-044（`5cfcdcb`）删除；今天的落点是 `EditorTimelineKitView.swift:270`
     的 `showsTrackHeader: false`（整条轨道头不创建）。
  ② 组件侧**早就有**静音命令与回调（`TimelineStore` 的 `.setTrackMuted`，`TimelineView.swift:614` /
     `TimelineClipView.swift:257`），缺的只有内核 → **CORE-011 零改仓库外的 TimelineKit**，
     池 [20] 的资产风险不被触发。
  ③ "同期评估 `enabled`（与其他 268 效果开关的关系）"这句把两个东西混谈了：轨道的
     `ChqTrack::enabled` 与效果的 `ChqEffectBinding::enabled` 不是一个字段
     （mixer 在 `chq_preview_mixer.cpp:446` 同时消费 `!enabled || muted`）。
     轨道 `enabled` 要不要同批补，归传哲一句话，卡面已写明"一比一拓、成本极低"。

### [20] TimelineKit 在仓库外且无版本控制 —— iOS 轨道区依赖一个不可复现的本地路径（⏳ 待决策 / 资产风险）

- 来源：本机（集成机）/ 2026-10-16 RESEARCH-018 复勘（布局整改批顺带捞出）
- 现象：iOS 轨道区真源 = 本地开发 Pod `TimelineKit`（[ADR-0042](../decisions/ADR-0042-轨道区接入TimelineKit与内核真源方向.md)），
  Podfile 里写的是仓库外绝对路径：
  `apps/apple/ios/Podfile` → `pod 'TimelineKit', :path => '../../../../ChatGPT/zui'`
  即 `/Users/zhuning/Documents/ChatGPT/zui`。实测该目录**不是 git 工作树**
  （源码 = 15 个 Swift 文件 / `Sources` 252K；目录本体 119M，其中 116M 是它自己的 `.build`，
  落在本仓 `build/` 分区之外）。
- 后果：
  1. 换机 / 新 clone / 另一台开发机拉本仓后 `pod install` **必失败**（路径不存在）；
  2. 组件自身改动没有历史，UIA-045 已**就地改过 3 处**（无 commit 可回溯、无法 review、无法回滚）；
  3. 资产丢失风险：该目录不在任何版本控制下，误删即永久丢。
- 本轮明确**不收编**（传哲 2026-10-16 决策 1：先只登记风险 + 给 Podfile 加路径守卫，避免静默假绿）。
- 待办：
  [ ] 收编落点：`ui/TimelineKit`（与 INFRA-031 上提后的 UI 组件同层），Podfile 改相对路径 `../../../../ui/TimelineKit`
  [ ] 收编前把 UIA-045 就地改的 3 处 diff 固化（先建 git 历史再搬，否则搬完就分不清"原有"与"改过"）
  [ ] 判定归属线：轨道区组件属 UI 线（`.ai/modules/ui-apple.md`）还是独立组件册
  [x] 过渡防护：`apps/apple/ios/Podfile` 加路径存在性断言，缺失时**直接 fail 并打印本条目编号**，
      不要退化成"跳过该 pod 继续构建"的假绿 —— **已落（2026-10-16，INFRA-031）**：
      Podfile 内 `File.exist?('<dir>/TimelineKit.podspec')` 不成立即 `raise`，消息点名本条目 [20]。
      实测守卫生效后 ios `pod install` 仍 exit 0（14 dependencies / 14 pods）；收编本体仍未做。
- 验收回填：收编后双壳 `pod install` + xcodebuild 数字 + 本池条目 ✅

### [21] `ui/ChuanqiCutDraft/` 零门禁覆盖 —— 顶层六包里唯一一个从未被编译的包（⏳ 待决策）

- 来源：本机（集成机）/ 2026-10-16 INFRA-031 搬家时顺带核出
- 定性：这是 **INFRA-020 的原始意图**（BACKLOG §「骨架，暂不进 Podfile，首功能落地时接线」），不是事故；
  但"暂不进"已持续 9 天且无人认领接线，本条要的是**把状态写实**，不是追责。
- 现象：顶层 `ui/` 六个包中，`ChuanqiCutDraft` **既不在两份 Podfile**（`apps/apple/{ios,mac}/Podfile`）
  **也没有 `run_gate.sh` 的 step**，只有 `Package.swift` + `Sources` + `.podspec`。
  本批对它只做通 `swift package resolve`，**从未 `swift build`/`swift test` 过一次**。
- 后果：包内坏到什么程度都不会被门禁发现；一旦别的卡开始引用它，第一手报错会落在业务卡上
  （P148 同类事故：Editor 包在 mac 宿主 4 天没跑，裸 `import UIKit` 一直无人知）。
- 待办：
  [ ] 判定是否本期交付物：是 → `run_gate.sh` 加一段 `swift build`（无测试则先 build）；
      否 → 按 ADR-0044 决策 ⑨「预留空壳保留 + README 标注」写明"未接入、不保证可编译"
  [ ] 若保留，`.ai/modules/ui-apple.md` 补该包的归属与状态行
- 验收回填：本池条目 + 加段后的 `run_gate.sh` 分段数字

### [22] 活文档里仍在用**上上代**布局路径 `core/include/cq/**` —— 本批卫生门禁管不到它（✅ 2026-10-17 集成机关闭 · TASK-INFRA-036 · 判据 5/5、非豁免 0 行、豁免 64 行）

- 来源：本机（集成机）/ 2026-10-17 INFRA-034 收口时顺手量的
- 现象：`git grep -l 'core/include/cq'`（只认入库文件）命中 **90** 个 tracked 文件。其中
  **描述当前状态**（不是「原 xxx」历史说明）的集中在
  `.ai/modules/{core,media,preview,ai,session,gfx,model,platform,platform-apple}.md` 与
  `docs/specs/PLATFORM-接口契约.md`；其余在 `docs/tasks/TASK-*.md`、`docs/archive/handoff/**`、
  `.workbuddy/memory/**` 这些 **append-only 叙述域**，按红线保持原样。
  真路径：`engine/core/cq/**`（ADR-0033 起头与实现共置，`core/include` 这一层早就不存在）。
- 为什么门禁没报：`tools/ci/check_repo_hygiene.sh` 的旧路径判据只覆盖**本批搬过的**前缀
  （`engine/bindings/`、`apps/apple/packages/`、`shaders/src/`、`ai/plan/`、`tools/probe/`），
  实测 raw 命中 23 行全部带迁移标记、非豁免 0。`core/include/cq` 是**上一代**（ADR-0033）的债，
  不在本批判据射程内 —— 不是它绿，是没人判。
- 待办：
  [x] 逐文件人改非叙述用法（**禁止批量替换**，P156）。实做范围比原估更宽：不止 `core/include/cq`，
      还有同代的 `core/src/` 与中间态 `engine/core/include/`，以及**文件名漂移**
      （`base/time.h`→`chq_rational_time.h`、`chq_log.h`→`chq_logging.h`、`net.h`→`chq_net.h`）。
      改动面 50 文件 / +217 −158 行（模块册 14 份、`docs/specs` 6 份、`docs/{BUILD,COCOAPODS,CODESTYLE}.md`、
      源码注释 20 余处）。卡片：**TASK-INFRA-036**。
  [x] 三条死根已进 `check_repo_hygiene.sh` 旧路径模式（`core/include/cq|core/src/|engine/core/include`）
- 验收回填：hygiene **5/5 PASS**；`legacy-paths` 非豁免 **0** 行、迁移标记豁免 33 → **64** 行（新纳入的
  31 行历史标注）。`git grep -c 'core/include/cq' -- .ai/modules docs/specs` **raw 仍 18 行、全部带旧路径标注**。
  ⚠️ 本条目原写的「归零」是**验收口径写错了**：红线 5 的历史不回改与"grep 归零"互斥，
  实际口径以判据为准 = **非豁免 0**（P156/P163 同族：判据要能区分"当时的话"和"现在的话"）。
  遗留（明确不修，登记为噪声）：`docs/specs/UIA-011/012/013/019/032/043` 里 **17 处"将要新建"的文件名**
  —— 那是设计期意图不是磁盘承诺，展平等于伪造 Spec。

### [23] 本机 SPIRV-Cross 源码树里有一处**不入库的本地补丁** —— 依赖治理口径要写实（📌 2026-10-17 传哲裁定「具体事务具体分析」，保持开放、按案处理）

- 来源：本机（集成机）/ 2026-10-17 INFRA-034 P160 修复过程
- 补丁内容与位置：`third_party/src/SPIRV-Cross/CMakeLists.txt`（非 git 树，补丁只在**本机**存在，
  整个 `third_party/src/` 在 `.gitignore` 里 → **无法随仓库分发**）。
  补丁只做一件事：把 `spirv-cross-build-version` 固定成 `third_party/manifest.toml` 的 pin。
- 为什么必须改上游：该变量原本由 `git describe` 得出，而我们的源码树是**非 git 拷贝**，
  `git describe` 会**向上**抓到宿主仓库 `.git`，把 **ChuanqiCut 的 HEAD** 打进 SPIRV-Cross 自己的
  版本横幅（实测 `v0.1.0-244-g5cfcdcb+`）；`spirv-cross` 没有 `--version`，`--help` 首行就把这条
  假归属打给每一个读日志的人（P160 附注、P161 第二条）。
- 已落地的防护：`tools/build/build_shader_toolchain.sh` 把补丁行指纹当 cache key
  （`-DSPVC_PATCH_FP=…`），**指纹变了自动强制重编**，不依赖人记得手动 `--rebuild`。
- 口径写实（别当成"三端一致"）：CI / 新克隆机走 pin 的 `git checkout`，拿到的是**未打补丁的
  上游树**——那时 `git describe` 在真 git 树里跑，打印的是它自己的 commit，**可信**；
  本机与非 git 树则依赖这处补丁。两条路径的版本证据来源不同，已在脚本头部写明。
- **裁定（传哲 2026-10-17）：「具体事务具体分析」——不设统一口径。** 落到可执行含义：
  1. 不为本条改造 `deps.py`，也不把本机树强制换成 pin 的 `git checkout`（那是"为一个横幅改依赖治理"）；
  2. 判据仍然是**证据来源要写实**：本机日志里 `spirv-cross --help` 首行的版本号归 SPIRV-Cross 自己，
     不得用来指认 ChuanqiCut 的 commit（反之亦然，CI 的真 git 树版本也不代表本机树）；
  3. 以后再碰到"本机不可分发的本地补丁"，逐案判定**是否值得入库产出**（同 P160 铁律的分诊），
     而不是预设"一律不允许"或"一律容忍"。
- 待办：
  [x] 传哲判定 → **接受现状 + 按案处理**（不做统一改造，见上裁定）
  [ ] （条件项，随下一次同类事故再判）`tools/deps/deps.py` 是否要把"本地补丁存在"登记成显式字段
- 验收回填：本池条目**保持开放但已定调**（⏳→📌 按案处理）；`build_shader_toolchain.sh` 首行输出对比
  在下次动 shader 工具链时补。ADR-0045 的「未决」节按红线 5 **不回改**，裁定以追加修订条的方式落 ADR。
- 关联：本条与 P160 铁律一起写进 **ADR-0045**（`docs/decisions/ADR-0045-构建期依赖必须入库产出与门禁缓存状态口径.md`），
  该 ADR 的「明确没做 / 边界」节把这处不同源列为**未决项**——拍板结果请回填 ADR 与本池两处

### [24] iOS **模拟器切片**要不要下线 —— 传哲 2026-10-17 判「先不动」，留案（⏸ 冻结，勿开工）

- 来源：本机（集成机）/ 2026-10-17 门禁优化讨论
- 触发：传哲先说「首先模拟器没必要支持」，同一轮随后改判「**模拟器先不动**」。
  本条只登记，不动 `build_core_apple.sh`、不动 `check_ios_compile.sh`、不改 xcframework 切片组成。
- 若要下线，先解决这三件（顺序不能颠倒）：
- ⚠️ **口径更正（同轮，写这条时我没打开脚本核，核了才发现说反）**：上面第 1 件是**错的**。
  `check_ios_compile.sh:37` 是 `SLICE="ios-device"`，**默认根本不吃 `build/apple/ios-sim`**，
  两趟门禁日志里那一步都在编 device slice（P166 的教训又应验了一次：没核就写）。
  于是删 sim 切片的**真实前置**只剩两条：(a) `build_core_apple.sh:199` 不再产 sim slice；
  (b) 产物面（原第 3 件）——App 在模拟器上链接不了，池 [16] 要改判「明确不支持」。
  原第 1 件作废，**顺序不能颠倒那句也随之作废**（实际只剩 2→3）。
  ⚠️ 但有一条**别当成"随便删"**：`--slice` 的 case 分支里 `ios-simulator → build/apple/ios-sim`
  与构建目录名是**两处必须同步**的映射（脚本自己注释就这么写），删切片时若只删 `build_core_apple.sh`
  那行、留着 `check_ios_compile.sh` 的 simulator 分支，会得到一条"能选但永远配不出来"的死选项。
  1. ~~门禁里那一步（`ios-compile`）在吃 ios-sim 切片，删之前要先改它~~ → **已作废**，理由见上面的
     口径更正。（条目结构修复 12:5x：写更正块时把这条的行首挤掉了，现在补回并划掉，**正文内容未动**。
     前置真数就是 (a)(b) 两条，编号从 2 起是排版残留，不代表还有第 1 件。）
  2. `tools/build/build_core_apple.sh:199` 的 sim 切片是 `arm64;x86_64` **双架构**（`build/apple/ios-sim` 32M，
     比 device 的 27M 还大）→ 省的是"每个 TU 编两遍"，不是省一棵树。冷态收益**未实测**（本条冻结，
     测量脚本跑过一次即被叫停，无数字可引）。
  3. 产物面：xcframework 无 iphonesimulator slice ⇒ App 在模拟器上**链接不过**，池 [16]「iOS 模拟器壳」
     要从"待办"改判为"明确不支持"，并写进头文件/文档（不要只在对话里说）。
- 附带事实（与本条同批发现，已归 **INFRA-038**）：门禁 C++ 段全程**单线程编译**，
  同脏集 A/B 实测 254s → 70s（**3.6×**）。这比模拟器切片的收益大一个数量级，优先级应在本条之前。
- 验收回填：本条保持 ⏸；解冻时需传哲明确指令，且必须给出上面三件的落地顺序。
- 关联：TASK-BACKLOG **INFRA-039**（同题，状态=冻结）、池 [16]（模拟器壳）、P166（成本结构要实测）。

### [25] `core-dbg` 与 `core-rel` **共用一棵 `build/`** —— 每趟全量门禁白做一遍全量重编（⏳ 待决策，INFRA-038 实测副产品）

- 来源：本机（集成机）/ 2026-10-17 INFRA-038 落地趟
- 事实（实测）：`build_core.sh` 的 `BUILD_DIR="build"` 不含 config，两步只换 `-DCMAKE_BUILD_TYPE`
  → **同一棵树连编两遍不同档位**，第二遍必然把第一遍的全部产物顶掉。所以串行基线里
  379s + 438s 都是**真·全量重编**，不是增量。并行后仍是 251s + 208s。
- 若拆成 `build/dbg` + `build/rel`：一趟里第二遍变增量（暖态近乎 0），预计 core 段从 **459s → 100~200s**。
  ⚠️ 这句是**推算**，未实测。代价：磁盘两棵树（本机 `build/` 当前多大需量）、
  `--clean` 语义、`build_shader_toolchain.sh` 与 CI 的目录假设、`check_repo_hygiene.sh` 判据 5
  的 scratch 根清单要同步 —— **属构建脚本 + CI 高冲突面，不许开发机自行改**。
- 关联：TASK-BACKLOG **INFRA-040**（候选，未立项）、P166/P167（成本口径纪律）。
- **2026-10-17 13:2x 追加取证（推算→计数）**：同日第二趟全量门禁里
  `core-dbg` **113s / `Building CXX` 0 个 / ctest 107.63s**，`core-rel` **207s / 95 个 TU / ctest 136.49s**。
  → 本条"第二遍必然把第一遍产物顶掉"不再是推理，**同一趟里 0 vs 95 就是证据**；
  拆树能省的是 `core-rel` 的构建段（≈70s，本趟口径），
  省不掉的是两段 ctest（合计 **244s**）—— 所以下限 ≈**6min**，不是无限降。
  见 `baselines.md`「并行化后全量门禁第二趟」。仍 ⏳ 待传哲判（高冲突面）。

### [26] `media_sequential_real` **一个用例占 ctest 一半**（⏳ 待决策，本卡按纪律未动它）

- 来源：本机（集成机）/ 2026-10-17 INFRA-038 落地趟
- 实测（同一趟内占比可比；跨趟墙钟不可比 = P160）：Debug **113.88s / 195.5s = 58%**，
  Release **54.76s / 134.2s = 41%**；次慢的 `platform_apple_muxer` 只有 9.56s / 13.25s。
- 并行化之后，门禁 C++ 段的成本重心已从"编译"移到"这一个用例"。要再砍时间只有三条路，
  **都需要传哲判**（它测的是实时序播放/解码，缩样 = 削弱判据）：
  1. 保持现状（时间换判据强度）；
  2. 缩用例规模（如减少序列帧数），但必须在卡里写明"判据射程变小"；
  3. 给它单独一档触发频率（阶段批跑、`--fast` 不跑）—— 与 `SKIP_APPLE` 同族开关，属门禁语义变更。
- ⚠️ 本条**只登记不实施**：INFRA-038 写集里明确不含 `tests/**`，且 ctest 全程保持串行（未加 `-j`）。
- **2026-10-17 13:2x 追加取证**：同趟复现 **Debug 58.23s / 107.63s = 54%**、
  Release 59.17s / 136.49s = 43%。**与上面那组数（113.88s / 58%）差一倍** ——
  同机同树同代码，同一个用例两趟 113.88s vs 58.23s。
  → 本条的结论要按这个读：**"占一半"是稳的，"多少秒"是不稳的**；
  算缩样收益只能用比例（比如"少一半 ctest 时间"），**不能写"省 113s"**。
  顺带给"地板"定个数：本趟 ctest 两段合计 244s，即**拆树也拆不下去的 ≈6min**（见池 [25] 追加段）。
- 关联：TASK-BACKLOG **INFRA-041**（候选，未立项）、`baselines.md`「ctest 成本结构」。
