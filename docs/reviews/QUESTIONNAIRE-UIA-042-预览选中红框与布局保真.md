# 真机问卷：UIA-042（预览选中红框修复 + SnapKit 布局迁移回归）

> ⚠️ **本问卷已作废（2026-10-15，传哲裁定 SPEC-UIA-043 §0 的 C）**：
> UIA-043（编辑页视觉改版）与 UIA-042 **同批同 commit** 交付，范围扩大 → 本问卷口径作废，
> 检查点改由 `docs/reviews/QUESTIONNAIRE-UIA-043-编辑页视觉改版与042回归.md` 承接
> （含 UIA-042 的红框/布局回归检查点）。**本文件保留不删**（append-only 惯例，留痕）。
>
> 照 ADR-0034 交付节奏：代码 → 机器自证 → **本问卷** → 传哲实测 → 集成机纠偏登记。
> **问卷未回收，UIA-042 不得标记完成。**
> 时间：2026-10-14 · 发起：WorkBuddy（集成机）· 依据：RESEARCH-017 §3 S11（预览选中红框）、原始约束冲突日志

## 0. 本批基本信息

| 项 | 值 |
|---|---|
| 批号 | `B-UIA042` |
| 主题 | 预览选中红框可见性修复 + 编辑器 UIKit 布局统一迁移 SnapKit |
| 关联卡 | TASK-UIA-042 / ADR-0041 / pitfalls P130 |
| 提交 range | 本批改动：`ChuanqiCutEditor.podspec` + 4 个 `UIKit/*.swift`（含 `EditorViewController`） |
| 机器侧填写人与时间 | WorkBuddy（集成机），2026-10-14 |
| 集成机环境 | macOS 26.7.1 / Xcode 26.6 / Swift 6.3.3 / **Intel x86_64**（无 ANE、无 ProRes 硬编） |

## 1. 这批改了什么（面向人 readable，不贴代码）

一句话：把编辑器 UIKit 的自动布局从原生 `NSLayoutConstraint` 统一换成 SnapKit，并修好了「选中片段时
预览区四周红框不显示」的问题（原来红框尺寸被解成 0×0 + 与系统 mask 约束冲突）。

| 文件 | 变更类型 | 说明 |
|---|---|---|
| `ChuanqiCutEditor.podspec` | 修改（热点：依赖真源） | 新增 `s.ios.dependency 'SnapKit', '~> 5.7.0'`（iOS 专属） |
| `UIKit/EditorViewController.swift` | 修改 | 预览红框几何改为 `center + 高满容器 + 宽=画布比×高`；四区栈与预览子视图改 SnapKit |
| `UIKit/EditorTransportBarView.swift` | 修改 | 播放钮/圆底/时间码改 SnapKit |
| `UIKit/EditorToolbarUIView.swift` | 修改 | 按钮栈四边改 SnapKit |
| `UIKit/EditorTimelineUIView.swift` | 修改 | 滚动容器四边改 SnapKit |

**热点文件与 ABI 影响**：触碰了 `ChuanqiCutEditor.podspec`（依赖真源）。已做：iOS 端 `bundle exec pod install`
（SnapKit 5.7.1 落地）；mac 端因依赖是 ios 作用域不拉入、`pod install` 通过。**两端 Pods 均已刷新**。
无需重生成 `docs/api/engine-api.md`（未碰引擎头）。

## 2. 机器侧证据（必须真实执行的命令与数字）

| 命令 | 结果 | 备注 |
|---|---|---|
| `cd apps/apple/ios && xcodebuild -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutApp -destination generic/platform=iOS build` | **BUILD SUCCEEDED** | 真正编译了 `#if os(iOS)` UIKit 改动（SnapKit import + 红框几何） |
| `cd apps/apple/mac && xcodebuild -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutMacApp -arch x86_64 ONLY_ACTIVE_ARCH=YES build` | **BUILD SUCCEEDED** | ios 专属依赖未泄漏到 mac |
| `bundle exec pod install`（apps/apple/mac） | 成功（exit 0） | 仅解析 ios 作用域依赖，mac 不编 SnapKit |
| `grep -rnE 'NSLayoutConstraint|translatesAutoresizingMaskIntoConstraints' …/UIKit/` | 仅注释命中（0 处代码） | 迁移干净 |
| `swift test`（Editor 包，macOS 宿主） | **未跑** | 本机 macOS SPM 跳过 `#if os(iOS)`（P129），数字不能替代壳构建 |
| 全量 `run_gate.sh` | **未跑**（未申请） | — |

**没跑的项目必须在此列出并写明原因**：
- `swift test`：P129 已证实 macOS 宿主整文件跳过 `#if os(iOS)`，跑它只是伪绿，故不依赖它作证。
- 全量门禁 `run_gate.sh`：按协作约定需先询问，本批未申请；双壳构建已覆盖 Apple UI 改动最小自证口径（P129）。

## 3. 已知偏差与本期明确不做

- 已知偏差：无功能行为变化，纯布局实现替换；红框**视觉尺寸/线宽**沿用既有 `TimelinePalette.previewSelectionBorder`（[E] 估算，未经真图校准）。
- **本期明确不做**：SwiftUI 侧 `EditorTimelineView` 的同类布局改造（本批 Scope 仅 UIKit 路径）；红框点击交互（只读展示，非按钮）。
- 上机前注意：请用 **iPhone 真机**（iOS 26.x）；导入一段 ≥10s 素材便于观察红框贴合画布外沿。

## 4. 真机检查点（传哲填写）

> 编号格式 `Q-<批>-<序号>`。每条写下「怎么操作」「应该看到什么」「**实际**」。

### iOS 端专属

| 编号 | 操作步骤 | 预期 | 实际（留白） |
|---|---|---|---|
| `Q-UIA042-I01` | 导入素材 → 点选时间线中的片段 | 预览区**四周出现红色边框**（约 2pt），未选中时红框消失 | |
| `Q-UIA042-I02` | 切换横/竖画布比例（面板「比例」） | 红框随画布外沿等比缩放、始终贴合预览画布边缘，不漂移不超出 | |
| `Q-UIA042-I03` | 观察编辑页整体布局 | 预览区 / 传输条 / 时间线 / 底部工具栏四区比例、位置与迁移前一致，无错位/重叠 | |
| `Q-UIA042-I04` | 拖动时间线空白处 + 捏合缩放 | 预览区与红框随播放头居中、缩放行为正常，无约束冲突告警（原日志那种 `Unable to simultaneously satisfy` 不再出现） | |
| `Q-UIA042-I05` | 播放 / 暂停 / 空态点「打开素材库」 | 传输条、空态引导、工具栏按钮位置正常（这几处也从原生约束迁到了 SnapKit） | |


## 4.1 追加（2026-10-14 22:15，SIGSEGV 修复后的回归目检）

修复把时间线自绘层从 `TimelineContentView.layer` 改挂到专用容器层 `canvasLayer`
（`EditorTimelineUIView.swift`）。崩溃已消失（真机 push / 直挂两条路径各 25s 零 crash），
但**图层位置与层级需要肉眼确认**：

| 编号 | 操作 | 期望 | 实测 |
|---|---|---|---|
| `Q-UIA042-I06` | 进编辑页（有素材）看时间线 | 标尺刻度/文字、轨道行底色、片段块、轨道头「原声开」位置与修复前一致，无整体偏移/半屏错位 | |
| `Q-UIA042-I07` | 点选一个片段 | 选中白描边 + 左右把手 + 中央时长数字位置正确（不被片段块遮挡、也不飘到别处） | |
| `Q-UIA042-I08` | 拖时间线到片尾 | 主轨右端「+」按钮出现在内容尾部，可点、可弹素材库 | |
| `Q-UIA042-I09` | 捏合缩放 | 标尺/片段/缩略图一起重排，无残留旧层、无重叠鬼影 | |
| `Q-UIA042-I10` | 播放 5 秒 | 播放头红条恒在视口中央、时间线跟随滚动，无闪跳 | |

## 5. 主观评价（传哲填写，可选但很有用）

- 手感：（布局是否跟手 / 有无迟滞）
- 观感：（红框是否如预期在画布外沿；是否还有别扭的空白或挤压）
- 相对对标 App差距：（红框样式/位置与对标 App的差异）
- 有没有出现你没想到的问题：

## 6. 回收与纠偏（集成机在传哲回复后填写）

| 编号 | 传哲反馈 | 判定 | 处置（写入哪张卡 / 哪条 LEDGER 条目） |
|---|---|---|---|
| | | 通过 / 需返工 / 改需求 | |

- 本批结论：**通过 / 有条件通过 / 未通过**
- 未通过项是否阻塞下一批：是 / 否
- LEDGER 纠偏条目：`docs/reports/LEDGER-W42.md` 追加于 `2026-10-14`
