# TASK-UIA-013:自研相册浏览器(伞任务,B 期)

```yaml
id:          TASK-UIA-013
layer:       UI
goal:        自研 SwiftUI 相册浏览器(网格/相簿/多选序号/时长过滤/iCloud/受限模式),替换 UIA-011 系统挂载点
status:      规划中 —— B 期启动时先跑 cq-task-planning 拆 3~4 子任务
             (权限与数据源 / 网格与相簿 UI / 选择与导入接线 / 受限模式与 iCloud),
             届时以子任务卡为准,本卡只锁伞范围与总写集
input:       [docs/specs/UIA-013-自研相册浏览器.md, docs/decisions/ADR-0015-相册选择器系统过渡与自研浏览器.md,
             .ai/modules/ui-apple.md, ZLPhotoBrowser/HXPhotoPicker 源码(仅设计参考,不引代码)]
output:      [SharedUI MediaPicker 新组件 + 权限 info 变更 + AlbumPickerTests + 文档回写]
write_set:   apps/apple/packages/SharedUI/Sources/SharedUI/MediaPicker/(新目录),
             apps/apple/packages/SharedUI/Tests/SharedUITests/AlbumPickerTests.swift(新),
             apps/apple/{ios,mac}/project.yml(info 段权限 —— 高冲突文件,
             开工时按写集规则与在途任务串行,必要时交 Integrator),
             docs/specs/UIA-013-*.md, docs/tasks/TASK-UIA-013.md, TASK-BACKLOG 行,
             .ai/modules/ui-apple.md(回写)
read_set:    apps/apple/packages/SharedUI/Sources/SharedUI/Editor/PropertyPanelZone.swift(挂载点),
             apps/apple/packages/SharedUI/Sources/SharedUI/AppEntry.swift(importMedia 不改)
deps:        [UIA-012(多选语义先行定型), 素材库整理任务(仅建议先后关系:
             落盘路径在"选中项→文件 URL"一步汇合,不硬依赖,见 Spec §4.3)]
acceptance:  # 子任务拆解时细化,伞级底线:
  - SharedUI swift test 全绿,含 AlbumPickerTests(时长过滤边界 / 选择状态机 /
    权限分支 / 空相簿路径)
  - macOS xcodebuild build 通过;iOS legacy 链编译通过
  - 真机项(权限弹窗 / .limited 补选 / iCloud 拉取 / 网格滚动帧率)
    随 UIA-011 真机恢复决策一并执行,不阻塞编译门禁
  - PropertyPanelZone 挂载点以外,Editor 导入链路(AppEntry/内核/绑定)零改动
verification:
  - cd apps/apple/packages/SharedUI && swift test --disable-sandbox
  - 两平台 xcodebuild(同 ui-apple.md 验证段命令)
  - 真机性能:Instruments 滚动帧时间 p95 < 16.7ms(万级图库,[E] 目标,
    实测回填 baselines.md)
risk:        PhotoKit 边缘 case 自担(缓解:边缘 case 清单提炼自 ZL/HX 源码,
             见 ADR-0015 决策 5);权限引入改变零权限惯例(ADR-0015 决策 3
             显式批准);project.yml 高冲突(缓解:开工时声明写集串行)
parallel:    true(新目录为主,唯一高冲突点 project.yml 开工时协调)
```

## 背景

Spec:`docs/specs/UIA-013-自研相册浏览器.md`;决策:ADR-0015(B 期自研、
不引三方、显式偏离零权限)。系统 sheet 的不可品牌化 / 无相簿 / 无时长
过滤是结构限制,多选(012)解决不了这三条,故立 B 期自研。

**方向锚(先读 Spec §2)**:core 的 probe/解码消费文件 URL,自研浏览器
只换**选择 UI**,不改变"选中项落成文件 URL → `importMedia`"的导入落盘
路径;试图在浏览器层跳过落盘会撞 PAL 不透明句柄红线(#2)。

## 实现要点(伞级,细节归子任务拆解)

- SwiftUI 主体 + PhotoKit 数据面:`PHFetchResult` 懒加载 + 
  `PHCachingImageManager` 缩略图;纯逻辑(fetch 包装 / 过滤 / 选择状态机 /
  权限分支)抽可单测类型。
- 权限:`NSPhotoLibraryUsageDescription` + 隐私标签申报随任务落地;
  `.limited` 用 automatic limited selection。
- 与素材库整理:先沿用 D3(tmp + importMedia),素材库整理落地后替换
  落盘步骤,浏览器不感知。

## 验收

见 yaml acceptance 伞级底线;子任务拆解时按子任务细化,伞卡只核"链路
零改动 + 编译门禁 + 真机项登记"。

## 回写

- `.ai/modules/ui-apple.md`:UIA-013 落地段(组件结构 + 权限惯例变更)
- `.ai/memory/baselines.md`:网格滚动 / 冷进首屏实测数字(真机恢复后)
- `docs/tasks/TASK-BACKLOG.md`:子任务行
- `.workbuddy/memory/当日.md`:当日日志
