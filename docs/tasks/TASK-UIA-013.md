# TASK-UIA-013:自研相册浏览器(伞任务,B 期)

```yaml
id:          TASK-UIA-013
layer:       UI
goal:        自研 SwiftUI 相册浏览器(网格/相簿/多选序号/时长过滤/iCloud/受限模式),替换 UIA-011 系统挂载点
status:      B 期任务,2026-10-04 用户决策提前启动（"对齐调研的两个大项目,UI 要
             足够优秀"）—— 单模块伞卡直接落地,子任务内联实现（权限与数据源 /
             网格与相簿 UI / 选择与导入接线 三件套一次交付;.limited 系统管理
             面板与选择器内预览播放器为后续增量）
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

## 状态（2026-10-04，提前启动轮）

- 代码已落盘（同分支 `mini.zhu/UIA-012-photo-multiselect`,与 UIA-012 串联）：
  `MediaPicker/` 六文件 —— AlbumPickerModels(纯逻辑：SelectionState /
  DurationFilter / 配置 / 文案)、AlbumPermissionModel(权限三态 + .limited)、
  PhotoKitAlbumStore(取数 seam + PHCachingImageManager 缩略图 +
  PHAssetResource 落盘含 iCloud 拉取)、MediaPickerViewModel(装配与确认导出)、
  MediaGridCell / AlbumPickerScreen(暗色网格 UI,交互范式对齐 ZL/HX)。
  挂载点：PropertyPanelZone 的 PhotosPicker 已替换为 AlbumPickerScreen sheet,
  确认交付走 UIA-012 同款 runBatch → sequencedImport → importMedia。
- project.yml 双端已加 `NSPhotoLibraryUsageDescription`(ADR-0015 决策 3 落地)。
- 测试：`AlbumPickerTests.swift` 12 用例(纯逻辑 + 夹具 VM:选取顺序/满选拒绝/
  时长过滤边界/权限映射/装载与切换/确认导出顺序与部分失败/全失败不交付)。
- ⚠️ 门禁未执行(本机 Swift 5.5,P39):`swiftc -parse` 全部新文件通过,
  唯一报错类别 = 既有"5.5 不识别 5.7 简写"噪音(与 UIA-011 代码同款写法),
  零新增错误类别;swift test / 两平台编译 / xcodegen+pod 须构建机执行。
- 真机项(权限弹窗 / .limited / iCloud 拉取 / 网格滚动帧率)沿用延期决策;
  已知留白(Spec §7):.limited 的"管理可选照片"系统面板 SwiftUI 接线、
  选择器内点击预览播放器,均为后续增量。

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
