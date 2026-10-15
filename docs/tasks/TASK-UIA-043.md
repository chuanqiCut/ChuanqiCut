# TASK-UIA-043：编辑页视觉改版（对标 App单色系 · 外壳 chrome 重做）

> 模板。缺任一项不得进入编码。

```yaml
id:          TASK-UIA-043
layer:       UI
goal:        编辑页外壳视觉改版为对标 App单色系（顶栏/空态/传输条/底栏/空时间线），不动交互链路与命令层
input:       [SPEC-UIA-043, 用户 2026-10-15 真机截图 IMG_2645.PNG, RESEARCH-017, ADR-0024, ADR-0034, ADR-0041]
output:      [新增 EditorChromePalette.swift, 改 4 个 UIKit 视图 + EditorScreen, 双壳 BUILD SUCCEEDED]
write_set:   apps/apple/packages/ChuanqiCutEditor/**（含 SwiftUI 侧 EditorScreen.swift）
read_set:    apps/apple/packages/SharedUI/Sources/SharedUI/Common/Theme.swift（只读，不改）
deps:        [UIA-032, UIA-034, UIA-040, UIA-041, UIA-042]
blocked_by:  []
merge_note:  SPEC §0 裁定 C：与 UIA-042 **同批同 commit** 交付；UIA-042 问卷作废，改发合并问卷
acceptance:
  - iOS 壳构建 BUILD SUCCEEDED
  - macOS 壳构建 BUILD SUCCEEDED（x86_64 ONLY_ACTIVE_ARCH=YES）
  - UIKit/ 下 Theme.accent 零引用（除 #if DEBUG 标注）
  - 底栏零 makeSpacer()、撤销/重做已迁至传输条
  - 空时间线不画刻度尺与播放头
  - check_uiview_layer_hygiene.py PASS
verification:
  - cd apps/apple/ios && xcodebuild -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutApp -destination generic/platform=iOS build
  - cd apps/apple/mac && xcodebuild -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutMacApp -arch x86_64 ONLY_ACTIVE_ARCH=YES build
  - grep -rn "Theme.accent" apps/apple/packages/ChuanqiCutEditor/Sources/ChuanqiCutEditor/UIKit
  - python3 tools/compliance/check_uiview_layer_hygiene.py
risk:        与未提交的 UIA-042 改动同文件（见 SPEC §0）；新增文件需重跑 pod install（P34）；
            自绘 layer 必须挂容器层（P131）；macOS SPM 跳过 #if os(iOS)，swift test 不能当证据（P129）
parallel:    false
```

## 背景

用户真机截图反馈编辑页「丑」，要求按对标 App（行业标杆）的 UI/操作范式整改。
UIA-032 已把**结构**做对（预览最大化 + 传输条 + 时间线 + 底栏 + 抽屉），本批只重做**视觉执行**。
完整问题清单、色表与布局见 `docs/specs/UIA-043-编辑页视觉改版.md`。

## 子步骤

| # | 内容 | 状态 |
|---|---|---|
| 0 | 裁定 SPEC §0（UIA-042 未提交 + 问卷未回收的叠加冲突） | ✅ 传哲 2026-10-15 裁定 **C**（同批同 commit，旧问卷作废重发） |
| 1 | 确认 §8-1 传输条布局读法 | ✅ 按默认读法落地：左 撤销+重做 ｜ 中 播放 ｜ 右 时间码 |
| 2 | 新增 `EditorChromePalette.swift`（色表 + 尺寸常量） | ✅ |
| 3 | `EditorTransportBarView`：撤销/重做 + 居中播放（去圆底）+ 时间码 | ✅ |
| 4 | `EditorToolbarUIView`：去撤销/重做与 spacer；84pt；图标 22/标签 10；单色 | ✅ |
| 5 | `EditorViewController`：高度常量切换、空态改胶囊、空时间线隐藏刻度、出口改挂传输条 | ✅ |
| 6 | `EditorTimelineUIView`：空 tracks 不画 ruler/播放头 | ✅ `setEmpty(_:)` |
| 7 | `EditorScreen`：顶栏「导出」置灰项（iOS 专属，`.navigationBarTrailing`） | ✅ |
| 8 | `bundle exec pod install`（新增文件，P34）+ 双壳构建 | ✅ iOS / macOS 双壳 **BUILD SUCCEEDED** |
| 9 | layer-hygiene 门禁 + accent grep 自查 | ✅ 117 文件 / R1 0；iOS UIKit 路径 accent 0 命中 |
| 10 | 出真机问卷（ADR-0034，合并 UIA-042 回归检查点） | ✅ `QUESTIONNAIRE-UIA-043-编辑页视觉改版与042回归.md`（旧 042 问卷作废） |
| 11 | 未跑：全量 `run_gate.sh`（待传哲授权） | ⬜ |

## 写集

- `apps/apple/packages/ChuanqiCutEditor/Sources/ChuanqiCutEditor/EditorChromePalette.swift`（新增）
- `apps/apple/packages/ChuanqiCutEditor/Sources/ChuanqiCutEditor/UIKit/EditorTransportBarView.swift`
- `apps/apple/packages/ChuanqiCutEditor/Sources/ChuanqiCutEditor/UIKit/EditorToolbarUIView.swift`
- `apps/apple/packages/ChuanqiCutEditor/Sources/ChuanqiCutEditor/UIKit/EditorViewController.swift`
- `apps/apple/packages/ChuanqiCutEditor/Sources/ChuanqiCutEditor/UIKit/EditorTimelineUIView.swift`
- `apps/apple/packages/ChuanqiCutEditor/Sources/ChuanqiCutEditor/EditorScreen.swift`

**不碰**：`SharedUI/**`（跨包）、`apps/apple/mac/**`、`apps/apple/ios/iOSApp/**`、`engine/**`。

## 指针

- Spec：`docs/specs/UIA-043-编辑页视觉改版.md`
- 上游：UIA-032（结构）/ UIA-041（轨道视觉）/ UIA-042（SnapKit 布局）
- ADR：ADR-0024（UIKit 路径）、ADR-0034（节奏与禁叠加）、ADR-0041（SnapKit）
- 坑：P34（新增文件要 pod install）、P129（macOS SPM 跳过 iOS 文件）、P131（backing layer 铁律）
