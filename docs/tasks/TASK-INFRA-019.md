# TASK-INFRA-019：ChuanqiCutEditor Pod 迁移（编辑器域 + EditorViewModel + Timeline）

```yaml
id:          TASK-INFRA-019
layer:       基建
goal:        ADR-0031 阶段 5：Editor 三件套 + Timeline + AppEntry（EditorViewModel）迁入独立 Pod，SharedUI 达基座终态
input:       [ADR-0031, PLAN-壳工程与功能Pod, ADR-0012/0024, SPEC-UIA-032]
output:      [packages/ChuanqiCutEditor/{podspec,Package.swift,Sources,Tests}, SharedUI 终态（仅 Common/Theme+三注入器）, MediaSheet 注入化]
write_set:   apps/apple/packages/ChuanqiCutEditor/**、SharedUI/Sources/SharedUI/{AppEntry.swift,Editor/**,Timeline/**}（迁出）、SharedUI/Tests/**（随域迁出，基座无独立测试）、SharedUI/Package.swift（去 testTarget）、SharedUI.podspec 终态注记、双 Podfile、双壳 App 文件
read_set:    docs/handoff/HANDOFF-001~003
deps:        [TASK-INFRA-013]
acceptance:
  - 测试守恒（Editor 36 用例；全域 140 = Player 52 + Camera 36 + Import 16 + Editor 36）
  - EditorViewModel/EditorScreen/EditorView 公开面满足双壳消费
  - MediaSheet 的相册浏览器经 MediaLibraryInjector（async onDeliver 语义原样透传）
  - 双壳构建过；SharedUI swift build 过（基座无独立测试）
verification:
  - (cd apps/apple/packages/ChuanqiCutEditor && swift test --disable-sandbox --scratch-path <root>/build/spm/ChuanqiCutEditor)
risk:    EditorViewModel 直连内核 Session → Pod 需 SDK 依赖 + CChuanqiCut SWIFT_INCLUDE_PATHS（ChuanqiCutCamera 同款模板）
parallel:    false
```

## 验收（2026-10-07 实测）
Editor swift test **36/36**；双壳构建过；metallib 管线不受影响（8431B 新鲜产物）。

## 回写
`.ai/modules/ui-apple.md` 模块册（Pod 拓扑终态）；BACKLOG §14 ✅。
