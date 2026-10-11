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
  - [ ] **warp kernel 签名错**：`Function 'cq_face_warp' has an unsupported type
    "sampler2D" for the parameter 'src0'` —— CIWarpKernel 原型不允许显式 sampler
    参数（框架采样），face_warp.metal 需按 CIWarpKernel 契约重写参数表；
    现状 = 美型诚实跳过（跑 cq-shader-portability 纪律）
  - [ ] **Pool kernel width 越界**：`Invalid Pool kernel width (9)/(13), must be
    [1-8] or 14` —— **2026-10-11 真机日志重归因 [E]**：beauty_bilateral 是自有
    CIKernel（metallib 构建期才报错，不会逐帧刷），该告警格式（`Invalid layer:`）
    与 `numANECores: Unknown aneSubType` 同源，判为 **Vision 模型在 iPhone 17 Pro
    ANE 上的编译告警**（landmark 模型 pooling 层宽度超 ANE 子类型支持 → 疑似部分
    层回退 CPU → 检测更贵，加强检测裁剪必要性）。验证法：detectionHz 临时改 1
    看告警是否降频（下次真机一趟）
  - [ ] 横持拍照方向（P111 表只覆盖竖屏）+ 初始黑帧优化（会话启动客观延迟，
    可评估"启动中"占位）
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
  - [ ] **CAM-033 标定收尾（需传哲 30 秒）**：人脸对镜头、居中静止，跑
    `CQ_CAM_FACE_CALIB=1`（SOP §一键流程），日志回传后反解 metadata↔vision 映射 →
    修 MetadataFaceGeometry → 闸门翻 true 零成本启用 metadata 路（远程采到的样本
    脸贴边/出画，对照失真，无法定标）
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
