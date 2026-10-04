# TASK-CAM-004：首页 + 相机页 UI + EditorViewModel 惰性化

```yaml
id:          TASK-CAM-004
layer:       UI
goal:        首页两入口(编辑/相机);相机页(预览/翻转/滤镜条/录制钮/权限引导);EditorViewModel 迁到编辑器入口惰性创建
input:       [SPEC-CAM-001 v1.1 §7, ADR-0014, ui-apple.md(P8 惰性构造惯例)]
output:      [apps/apple/ios/iOSApp/HomeView.swift, ChuanqiCutApp.swift(重构),
             apps/apple/ios/iOSApp/Camera/CameraView.swift, CameraViewModel.swift,
             apps/apple/packages/SharedUI/Sources/SharedUI/Editor/EditorScreen.swift,
             apps/apple/packages/SharedUI/Tests/SharedUITests/(新增用例)]
write_set:   上述文件
read_set:    SharedUI/AppEntry.swift, EditorView.swift, MetalPreviewView.swift
deps:        [TASK-CAM-002, TASK-CAM-003]
acceptance:
  - SharedUI swift test 全量通过(既有用例不回归,报数字) + 新增:EditorScreen 惰性创建语义(进编辑器前不建 Session)
  - 相机页状态机纯逻辑单测(授权态→UI 分支映射)
  - iOS 构建 + Info.plist(经 project.yml)含 NSCamera/NSMicrophone/NSPhotoLibraryAddUsageDescription
verification:
  - cd apps/apple/packages/SharedUI && swift test --disable-sandbox
  - iOS 构建命令同 CAM-002
risk:        EditorViewModel 创建时机重构触碰编辑器回归(缓解:只改创建时机不改 Session 语义;既有测试全量跑)
parallel:    false
```

## 实现要点

- 首页：`NavigationStack` 两入口，纯导航壳，无业务。
- `EditorScreen`（SharedUI）：**先建值后包装**（pitfalls P8）——`EditorViewModel()`
  成功才进 `EditorView().environmentObject()`；DEBUG 演示片段挂到 onAppear。
- 相机页：竖屏、沉浸式；翻转钮/滤镜条（横滑）/录制钮（长按或点击）；权限拒绝态
  明示引导；录制中 UI 锁滤镜切换（本期简化）。
