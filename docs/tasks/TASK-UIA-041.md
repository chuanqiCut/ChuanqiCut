# TASK-UIA-041：轨道区交互收敛 + 对标 App视觉保真第一批（U0+U1）

> **状态：📋 已立卡，未开工**（2026-10-13，RESEARCH-017；A 线独立并行批，写集仅在 apps/，与 B0 不相交）。
> 目标形态：传哲提供的 6 张对标 App截图（RESEARCH-017 §1 规格表 S1~S4/S7/S11）。

```yaml
id:          UIA-041
layer:       Apple（iOS 竖屏为主，Mac 时间线走查不回归即可）
goal:        ① 抽 TrackInteraction 纯逻辑 reducer，收敛 SwiftUI/UIKit 双份手势与 commit
             （RESEARCH-013 §4.1 红线边缘 → §5.1 方案落地）；
             ② 对照对标 App截图补齐视觉保真：选中态（白描边+左右把手+片段中央时长数字）、
             轨道头（原声开关接 muted ABI / 设置封面占位）、播放头红→白、
             刻度尺样式（圆点分隔 minor）、主轨右端"+"、预览选中描边
input:       [RESEARCH-017（截图规格 §1/对照 §2）, RESEARCH-013 §4.1/§5.1（双实现收敛）,
             RESEARCH-008 §2（交互契约）, ADR-0012（交互期不提交/松手一条）,
             ADR-0034 §6（iOS 单焦点抽屉范式）, ADR-0024（UIKit 边界）]
output:      [ChuanqiCutEditor/Timeline/TrackInteraction.swift(新, 纯逻辑),
             UIKit/EditorTimelineUIView.swift(薄化+selectionLayer),
             EditorTimelineView.swift(SwiftUI 版薄化),
             TimelineLayout.swift(snapCandidates 预留不在本卡, 选中框几何在),
             TimelineInteractionTests.swift(扩展)]
write_set:   apps/apple/packages/ChuanqiCutEditor/Sources/ChuanqiCutEditor/**
             （不含 ChuanqiCutCamera / Player / SharedUI / engine/** / 壳工程）
read_set:    TimelineThumbnails.swift、ChuanqiCutEngine 绑定层（只读调用）、
             engine/core/cq/cq_sdk.h（只读：CQTrackInfo.muted 回读）
deps:        []   # 不依赖 B0/B4；与 B0 验收解耦（写集不相交）
acceptance:
  - TrackInteraction 为值类型 reducer：输入归一化手势事件（tapAt/drag三相/长按/捏合），
    输出渲染态 + 待提交命令；`swift test` 覆盖 hit→region→command 全路径
  - 双实现消除：EditorTimelineView(SwiftUI) 与 EditorTimelineUIView(UIKit) 的
    手势解析/commit 逻辑不再各持一份（代码结构可证：两文件不再含命中判定与命令拼装）
  - 选中态视觉：点选片段 → 白描边 + 左右把手 + 片段中央时长数字（对照截图图2/4）；
    取消选中（点空白）恢复；选中把手拖拽 = 既有 trim-in/out 语义不变
  - 轨道头：主轨行左端原声开关（接 CQTrackInfo muted 回读 → set 命令若 ABI 未有则
    登记池条目，UI 先 disabled 态——**不做假开关**）；"设置封面"占位（不响应或 toast 未开放）
  - 播放头白色 + 顶部小把手；刻度尺 minor 刻度带圆点分隔（对照 S1）
  - 主轨右端 "+"（点击 = 打开素材选择，复用既有导入路径）
  - 预览区选中描边（红框，对照 S11）
  - 全部交互仍走 Command（红线 #5）；拖拽中不提交、松手一条命令（ADR-0012）
  - 既有 TimelineInteractionTests 全绿；swift test 新增用例全绿；iOS 壳构建通过
non_goals:
  - 音频占位条/空音频行（U2，UIA-042）
  - 吸附/边缘滚动/触觉（U3，UIA-043）
  - 波形（U4）、添加音频真能力（B5）、多轨合成（B7）
  - Mac 桌面范式（UIA-017 线）
```

## 交付节奏（照 ADR-0034）

写代码 → 机器自证（swift test + iOS 壳构建，数字进台账）→ 出真机问卷
（走查清单 = RESEARCH-017 §1 的 S1~S4/S7/S11 逐项对照截图）→ 传哲实测 → 纠偏登记。
**问卷未回收不得标记完成。**

---

## 签名

- 立卡：WorkBuddy（集成机），2026-10-13
- 依据：RESEARCH-017 + 传哲 6 张截图
