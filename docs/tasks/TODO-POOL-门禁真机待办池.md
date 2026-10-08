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
- 改动面：B 线 · camera + pal-apple 相机子域
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
| 5 | ChuanqiCutCamera `swift test` | 通过数/总数 | 守恒 36 + 新增 MakeupMask 10 + PortraitSkinMask 7 = **53/53** |
| 6 | SharedUI `swift test` | 通过数/总数 | 守恒 **140**（改了 CameraBeauty，必须零回归） |
| 7 | metallib 核对 | 字节数 + `cq_beauty_down_h/up_v_mix` kernel 名均在 | 旧值 8431B；CAM-029 改过 `beauty_bilateral.metal`，要重新核大小 |

SPM 临时产物一律 `swift test --disable-sandbox --scratch-path "$ROOT/build/spm/<包名>"`（P84）。

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
  engine/core/include/cq/pal/net.h(新) + engine/core/include/cq/base/status.h(+AI 决策段
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
