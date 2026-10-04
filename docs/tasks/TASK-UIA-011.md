# TASK-UIA-011:相册素材导入(PhotosPicker 入口)

```yaml
id:          TASK-UIA-011
layer:       UI
goal:        素材库面板新增「从相册导入」入口,选视频后汇入既有 importMedia 链路
input:       [docs/specs/UIA-011-相册素材导入.md, .ai/modules/ui-apple.md, docs/tasks/TASK-UIA-009.md]
output:      [PropertyPanelZone 相册入口 + 加载态/错误路径胶水 + SharedUI 测试 + 文档回写]
write_set:   apps/apple/packages/SharedUI/Sources/SharedUI/Editor/PropertyPanelZone.swift,
             apps/apple/packages/SharedUI/Tests/SharedUITests/PhotoImportTests.swift(新),
             docs/specs/UIA-011-相册素材导入.md, docs/tasks/TASK-UIA-011.md,
             docs/tasks/TASK-BACKLOG.md(登记行), .ai/modules/ui-apple.md(回写)
read_set:    apps/apple/packages/SharedUI/Sources/SharedUI/AppEntry.swift(importMedia 不改),
             apps/apple/packages/SharedUI/Tests/SharedUITests/{RepoPath,MediaImportTests}.swift
deps:        [UIA-009 ✅]
acceptance:
  - SharedUI swift test 全绿(macOS 宿主),含新增 PhotoImportTests
  - macOS App xcodebuild build 通过
  - iOS 用 legacy -sdk iphoneos 链编译通过(无运行时,编译门禁)
  - 相册入口 filter 为 .videos、单选;loadTransferable 失败不产生素材不崩溃(测试锁)
  - importMedia(url:) 及内核/绑定层零改动(git diff 证明)
verification:
  - cd apps/apple/packages/SharedUI && swift test --disable-sandbox
  - cd apps/apple/mac && xcodegen generate && bundle exec pod install
    && xcodebuild build -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutMacApp
       -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
  - iOS legacy 链(见 .ai/modules/ui-apple.md 验证段,BUILD_DIR 三目标一致)
risk:        PhotosPicker 的 UI 交互无法进 XCTest(同 UIA-005 既有结论),
            手势/系统选择器接线靠 App 冒烟 + 人工验证;
            真机 HEVC/iCloud 素材表现未实测(开放问题,见 Spec §7)
parallel:    true(写集与其他在途任务不相交)
```

## 状态（2026-10-04）

- 代码与测试已落盘：`PropertyPanelZone.swift`（双入口 + PhotoLibraryImporter 胶水）、
  `PhotoImportTests.swift`（6 用例）。PhotosUI / PhotosPicker 均在 iOS 16 /
  macOS 15.4 基线内，无需动 project.yml / Podfile。
- ⚠️ **verification 段的门禁本轮未执行**：当前机器无 Swift 6.1 工具链
  （Xcode 13.1 / Swift 5.5 / macOS 12.6，SDK 里没有 PhotosPicker；
  见 pitfalls P39）。已做：`swiftc -parse` 两文件语法级通过（仅 Swift 5.5
  不识别 5.7 简写的两条已知噪音，与既有代码同款写法）。
  **swift test / macOS / iOS 编译必须在真实构建机执行后才算验收通过。**

- ✅ **2026-10-04 用户决策:低配设备(本机 Mac mini 2014,i5-4278U / 8GB /
  macOS 12.7.6)暂时不跑真机测试** —— 真机相关验证(Spec §7.1)**延期非取消**,
  待有条件时恢复;剩余缺口只有构建机上的编译门禁(swift test + 两平台编译)。

## 背景

Spec:`docs/specs/UIA-011-相册素材导入.md`。现有导入只有 fileImporter("文件"App
路径),相册视频导入体验割裂。系统 `PhotosPicker`(iOS 16 / macOS 13+,基线内)
零依赖覆盖 MVP;不引第三方(红线 #10 依赖治理成本 > 收益),自定义相册浏览器
是后续任务,替换挂载点即本任务的按钮 + item→URL 胶水。

## 实现要点

1. **View 层胶水,ViewModel 零改动**:`@State photoItem: PhotosPickerItem?` +
   `PhotosPicker(selection:matching:)`,onChange 起 `Task` 做
   `loadTransferable(type: URL.self)`,成功回 MainActor 调既有
   `viewModel.importMedia(url:)`。加载期间置 loading 态(防重复点击,
   ViewModel 已有 importInFlight 双保险)。
2. **过滤与语义**:`PHPickerFilter.videos`、单选,与 fileImporter 白名单对齐;
   不加 NSPhotoLibraryUsageDescription(PHPicker 进程外选择,无需权限)。
3. **错误路径收敛**:loadTransferable 抛错 / 返回 nil URL → 面板既有
   `importError` 展示,不产生素材;测试锁"失败不污染素材表"。
4. **可测部分抽纯逻辑**:item→URL 的异步胶水无法在无相册数据的 XCTest 宿主里
   驱动(PhotosPickerItem 需真实 PHAsset),故测试锁定:loading 态翻转、
   失败路径状态、以及"成功路径汇入 importMedia"用文件 URL 直接调
   ViewModel(等价 MediaImportTests 手法)。

## 验收

对应 acceptance 逐条:swift test 输出全绿数字;两平台 xcodebuild 退出码 0;
`git diff --stat` 确认 write_set 外无改动(尤其 AppEntry.swift / core/ / bindings/)。

## 回写

- `.ai/modules/ui-apple.md`:UIA-011 落地段(入口形状 + D3 沿用说明)
- `docs/tasks/TASK-BACKLOG.md`:登记 UIA-011 行
- `.ai/memory/pitfalls.md`:如踩新坑(PhotosPicker/loadTransferable 平台差异)
- `.workbuddy/memory/2026-10-04.md`:当日日志
