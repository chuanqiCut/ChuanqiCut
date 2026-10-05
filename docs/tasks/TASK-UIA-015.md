# TASK-UIA-015：iOS 编辑页重构（剪映式单焦点 + 抽屉）

> **状态：✅ 已落地（2026-10-05，本集成机）**——门禁数字与走查证据见 `docs/reviews/REVIEW-2026-10-05-UIA015-编辑页走查.md`、`.workbuddy/memory/2026-10-05.md`。

```yaml
id:          TASK-UIA-015
layer:       UI
goal:        iOS 竖屏编辑页改为"预览最大化 + 播放控制条 + 时间线 + 底部工具栏 + 媒体抽屉"，消除桌面三区与调试元素外露
input:       [docs/specs/UIA-015-编辑页重构.md, RESEARCH-004 §3.4/§6.2, RESEARCH-005（上位面板框架，仅参考）]
output:      [Editor 域视图重组 + MediaSheet/TransportBar/BottomToolbar 三新文件 + DEBUG 直进钩子]
write_set:   apps/apple/packages/SharedUI/Sources/SharedUI/Editor/EditorView.swift、EditorLayout.swift、
             PreviewZone.swift（空态/点按增强）、TimelineZone.swift、PropertyPanelZone.swift（删）、
             MediaSheet.swift（新，含 PhotoLibraryImporter 胶水迁移）、
             EditorTransportBar.swift（新）、EditorBottomToolbar.swift（新）、
             apps/apple/packages/SharedUI/Sources/SharedUI/AppEntry.swift（增量：timecode 只读计算）、
             apps/apple/ios/iOSApp/ChuanqiCutApp.swift（DEBUG 钩子）
read_set:    Common/Theme.swift（UIA-016 产出，只读）、AppEntry.swift（只读）、Timeline/*（只读）、
             MediaPicker/*（只读，AlbumPickerScreen 挂载迁移）
deps:        [TASK-UIA-020, TASK-UIA-016]
acceptance:
  - iOS 竖屏走查清单（SPEC §5-4/5-5）：预览弹性满/播放条/时间线 140pt/底部工具栏/媒体抽屉半屏/点按预览切换播放/空态引导/导出置灰/无 v\d+ 调试文本 —— 模拟器截图存 docs/reviews/
  - macOS 布局行为等价（HSplitView 三区保留，右栏嵌媒体库内容），既有 Cmd+Z/Cmd+Shift+Z 不回归
  - 既有 SharedUI 全量测试零回归（TimelineInteractionTests/PhotoImportTests 等）
  - 双平台编译零错误
verification:
  - cd apps/apple/packages/SharedUI && swift test --disable-sandbox
  - 双平台 xcodebuild（同 TASK-UIA-020）
  - xcrun simctl launch（CQ_DEMO_VIDEO + CQ_AUTO_ROUTE=editor）+ 截图走查
risk:        HomeView.swift 是 AIEDIT-008 高冲突文件 → 本卡不碰 HomeView，DEBUG 直进钩子放 ChuanqiCutApp.swift（未列热点，AIEDIT-008 开工时若冲突让位）；新文件后必须 pod install（P34）
parallel:    false  # 串行于 020/016 之后
```

## 背景
SPEC-UIA-015 §1 症状 1/3/4/5：桌面三区硬切、播放入口弱、调试元素外露、无时间码/空态引导。布局范式对齐剪映（RESEARCH-004 §3.4）。

## 实现要点
1. **EditorView**（iOS compact）：`VStack{ PreviewZone(弹性) / EditorTransportBar / 时间线(140pt) / EditorBottomToolbar }`；regular 宽度沿用现 macOS 同构横排（UIA-017 再惯例化）。平台差异仍收敛在 `EditorLayout.swift`。
2. **PreviewZone**：加点按手势 → `viewModel.togglePlayback()`；空时间线显示引导视图（标题 + 「导入素材开始创作」+ 主按钮开媒体抽屉）。
3. **EditorTransportBar**：播放/暂停（复用 `togglePlayback`）+ 时间码 `当前/总时长`（ViewModel 新增 `timecodeText`，有理数→字符串换算在 VM，红线 #4）。
4. **EditorBottomToolbar**：撤销/重做（迁移自 TimelineZone）+ 工具位「媒体/音频/文字/特效」——媒体开抽屉，其余 disabled + 标注；DEBUG 版本号移入 `#if DEBUG`。
5. **MediaSheet**：PropertyPanelZone 的素材库能力整体迁移（fileImporter + AlbumPickerScreen sheet + 列表/失效标记/错误汇总）；detents `[.medium, .large]`；macOS 固定窗口（UIA-013 同款处理）。PropertyPanelZone 删除，macOS 右栏改嵌 MediaSheet 内容（行为等价）。
6. **DEBUG 直进钩子**：ChuanqiCutApp `init` 读 `CQ_AUTO_ROUTE=editor`（DEBUG only）→ WindowGroup 直挂 `EditorScreen()`，绕过首页 —— 供模拟器截图走查与未来冒烟（与 CQ_DEMO_VIDEO 同模式）。
7. 红线对照：#1 无业务逻辑进 UI；#4 时间码换算用 RationalTime；#5 点按暂停走既有 togglePlayback；#8 批量导入条间 yield 语义原样保留。

## 验收
acceptance 四条；走查截图归档 `docs/reviews/REVIEW-2026-10-05-UIA015-编辑页走查.md`。

## 回写
`.ai/modules/ui-apple.md` 增补 UIA-015 落地段（结构图 + 文件清单）；pitfalls 记录新坑；HANDOFF 或工作日志登记真机走查待办（开放问题 §7-1）。
