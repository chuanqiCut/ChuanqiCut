# TASK-INFRA-016：ChuanqiCutImport Pod 迁移（素材导入域）

```yaml
id:          TASK-INFRA-016
layer:       基建
goal:        ADR-0031 阶段 2：MediaPicker 全域（7 文件）+ AlbumPickerTests 迁入独立 Pod
input:       [ADR-0031, PLAN-壳工程与功能Pod, ADR-0015（自研相册浏览器）, UIA-011/012/013]
output:      [packages/ChuanqiCutImport/{podspec,Package.swift,Sources,Tests}, SharedUI 删 MediaPicker, MediaLibraryInjector]
write_set:   apps/apple/packages/ChuanqiCutImport/**、SharedUI/Sources/SharedUI/MediaPicker/**（迁出）、SharedUI/Tests/SharedUITests/AlbumPickerTests.swift（迁出）、SharedUI/Common/{Theme.swift 公开化, MediaLibraryInjector.swift}、双 Podfile、双壳 App 文件
read_set:    SPEC-UIA-013
deps:        [TASK-INFRA-013]
acceptance:
  - 测试守恒（Import 16 用例随迁零丢失）
  - AlbumPickerScreen 公开化，编辑器经 MediaLibraryInjector 消费（横向零依赖）
  - 双壳构建过
verification:
  - (cd apps/apple/packages/ChuanqiCutImport && swift test --disable-sandbox --scratch-path <root>/build/spm/ChuanqiCutImport)
risk:    Theme 需公开化（基座唯一配色真源，MediaPicker 的 PickerTheme.accent 合并目标记 UIA-033）
parallel:    false
```

## 验收（2026-10-07 实测）
Import swift test **16/16**；双壳构建过（iOS 6 pods / mac 5 pods）。

## 回写
`.ai/modules/ui-apple.md` 模块册；BACKLOG §14 ✅。
