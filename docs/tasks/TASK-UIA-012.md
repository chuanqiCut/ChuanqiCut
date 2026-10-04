# TASK-UIA-012:相册多选批量导入

```yaml
id:          TASK-UIA-012
layer:       UI
goal:        相册入口改多选(maxSelectionCount=20),逐条汇入既有 importMedia,部分失败不中断
input:       [docs/specs/UIA-012-相册多选批量导入.md, docs/decisions/ADR-0015-相册选择器系统过渡与自研浏览器.md, .ai/modules/ui-apple.md]
output:      [PropertyPanelZone 多选胶水 + PhotoImportTests 批量用例 + 文档回写]
write_set:   apps/apple/packages/SharedUI/Sources/SharedUI/Editor/PropertyPanelZone.swift,
             apps/apple/packages/SharedUI/Tests/SharedUITests/PhotoImportTests.swift(追加),
             docs/specs/UIA-012-相册多选批量导入.md, docs/tasks/TASK-UIA-012.md,
             docs/tasks/TASK-BACKLOG.md(登记行), .ai/modules/ui-apple.md(回写)
read_set:    apps/apple/packages/SharedUI/Sources/SharedUI/AppEntry.swift(importMedia 不改),
             apps/apple/packages/SharedUI/Tests/SharedUITests/{RepoPath,MediaImportTests}.swift
deps:        [UIA-011 ✅(2026-10-04 代码已落盘;建议其构建机编译门禁通过后再开工,
             避免同文件两任务叠加未验证改动)]
acceptance:
  - SharedUI swift test 全绿(macOS 宿主),新增批量用例:M 条成功全入表且
    顺序一致 / 含 K 条失败汇总展示、失败条不产生素材 / 批量 loading 翻转
    复位 / 全失败不崩溃
  - macOS App xcodebuild build 通过
  - iOS 用 legacy -sdk iphoneos 链编译通过(编译门禁,无运行时)
  - 逐条导入间 Task.yield() 让出主线程,整批不同步占主线程(代码评审项)
  - importMedia(url:) 及内核/绑定层零改动(git diff 证明)
verification:
  - cd apps/apple/packages/SharedUI && swift test --disable-sandbox
  - cd apps/apple/mac && xcodegen generate && bundle exec pod install
    && xcodebuild build -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutMacApp
       -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
  - iOS legacy 链(见 .ai/modules/ui-apple.md 验证段,BUILD_DIR 三目标一致)
risk:        iOS 16 上 PhotosPickerItem 数组顺序是否等于选择顺序未实测
            (Spec §6.1,不一致则评估升 iOS17 selectionBehavior 或明示不承诺);
            批量 tmp 体积放大 D3 失效面(已知限制,素材库整理收口);
            真机项沿用 2026-10-04 延期决策,不阻塞编译门禁
parallel:    false(与 UIA-011 同文件,串行;与 UIA-013 写集不相交可并行规划)
```

## 状态（2026-10-04）

- 代码与测试已落盘（分支 `mini.zhu/UIA-012-photo-multiselect`）：
  `PropertyPanelZone.swift`（`photoItems: [PhotosPickerItem]` +
  `maxSelectionCount = 20` 常量 + `runBatch` 批量胶水 + `sequencedImport`
  逐条等落库）、`PhotoImportTests.swift`（UIA-011 旧 5 用例改以 count:1
  特例表达 + 批量新 4 用例 + golden 批量 3 条回归锁,共 11 用例）。
- 关键实现事实:批量顺序保证 = 逐条等"片段在快照可见"（`clips` 计数增加）
  再导下一条 —— **不能只等版本推进**（建轨也 bump 版本,会提前放行,下一条
  仍会撞重叠拒绝）;`importMedia` 每次调用注册新素材**不按路径去重**
  （golden 批量 3 条 = 素材表 3 条,测试按此断言）。
- ⚠️ **门禁本轮未执行**（本机 Xcode 13.1 / Swift 5.5,tools version 6.1
  拒跑,pitfalls P39）:已做 `swiftc -parse` 两文件语法级检查 ——
  PropertyPanelZone 仅剩 UIA-011 既有 5.7 简写 1 处已知噪音（非本轮引入）,
  测试文件 0 错误。**swift test / 两平台编译必须在真实构建机执行后才算
  验收通过**;真机项沿用 2026-10-04 延期决策。
- 开放问题 Spec §6.1（iOS 16 选择顺序保证）仍待宿主/真机实测。

## 背景

Spec:`docs/specs/UIA-012-相册多选批量导入.md`;选型:ADR-0015(系统
Picker 过渡、不引三方)。UIA-011 单选入口已落地,批量导入是多机位 /
分镜素材的真实高频路径,N 次进出系统选择器的代价随素材量线性增长。

## 实现要点

1. `$photoItem: PhotosPickerItem?` → `$photoItems: [PhotosPickerItem]` +
   `PhotosPicker(selection:matching:maxSelectionCount: 20)`;onChange 起
   Task 逐条 `loadTransferable(URL.self)` → `importMedia(url:)`,条间
   `Task.yield()`(红线 #8,importMedia 保持 MainActor 语义)。
2. 部分失败语义:单条失败/nil URL 只记入失败计数,不中断整批;结束汇总
   "成功 M / 失败 K"到面板既有 `importError` 展示位;清空 selection
   复用 UIA-011 的 itemIdentifier 判等结论。
3. 可测部分注入闭包(同 PhotoLibraryImporter 手法):批量状态机
   (成功顺序 / 失败汇总 / loading 翻转)进 XCTest;系统 sheet 多选
   交互靠宿主冒烟。
4. 零权限不变:PHPicker 进程外选择,不动 project.yml info 段。

## 验收

对应 acceptance 逐条:swift test 全绿数字;两平台 xcodebuild 退出码 0;
`git diff --stat` 证明 write_set 外零改动;人工(macOS 宿主)多选 3 条
→ 时间线 3 片段顺序一致。

## 回写

- `.ai/modules/ui-apple.md`:UIA-012 落地段(多选语义 + 顺序结论)
- `docs/tasks/TASK-BACKLOG.md`:登记 UIA-012 行
- `.ai/memory/baselines.md`:批量导入耗时实测(若有)
- `.workbuddy/memory/当日.md`:当日日志
