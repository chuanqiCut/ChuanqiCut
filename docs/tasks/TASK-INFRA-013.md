# TASK-INFRA-013：壳工程改造（Pods 骨架 + 双 Podfile + 门禁逐 Pod 测试段）

```yaml
id:          TASK-INFRA-013
layer:       基建
goal:        落地 ADR-0031 阶段 0：apps/apple/packages/ 多 Pod 骨架、双壳 Podfile 引功能 Pod、run_gate.sh 支持逐包测试
input:       [ADR-0031, PLAN-壳工程与功能Pod, SharedUI.podspec, docs/COCOAPODS.md]
output:      [双 Podfile 更新, run_gate.sh apple 段逐 Pod, 基座注入点 PlayerPreviewInjector]
write_set:   apps/apple/{ios,mac}/Podfile、tools/ci/run_gate.sh、apps/apple/packages/SharedUI/Sources/SharedUI/Common/PlayerPreviewInjector.swift、SharedUI.podspec 头注释
read_set:    apps/apple/ios|mac/{project.yml,Podfile.lock}
deps:        []
acceptance:
  - 双壳 pod install 解析 ChuanqiCut + SharedUI + ChuanqiCutPlayer 三个本地 Pod，无版本冲突
  - SharedUI（基座）不 import 任何功能 Pod（横向零依赖方向正确）
  - run_gate.sh 含 apple-player 步骤，摘要行同步
verification:
  - (cd apps/apple/ios && xcodegen generate && bundle exec pod install)
  - (cd apps/apple/mac && xcodegen generate && bundle exec pod install)
  - grep -n "apple-player" tools/ci/run_gate.sh
risk:        pod-依赖-pod 的 module 可见性（SWIFT_INCLUDE_PATHS 链）；缓解=阶段 1 Player 不依赖 SDK，链路推迟到 Editor/Assets 阶段实测
parallel:    false   # 热点文件（Podfile/run_gate.sh），集成机执行
```

## 背景
ADR-0031 壳工程化第一步。本卡只动**装配与门禁骨架**，不搬业务源码（搬移归各域卡）。
MediaSheet→PlayerScreen 的横向引用在本卡以基座注入点解耦（Editor 不依赖 ChuanqiCutPlayer）。

## 实现要点
- 注入点放 SharedUI/Common（`PlayerPreviewInjector.makePlayerPreview`），壳层 init 装配；
  未注入时 MediaSheet 空占位兜底（单测环境可观察降级，不崩）。
- AppEntry.swift 留在 SharedUI（平台共享代码），真壳化（迁 App target）挂阶段 5 与
  Editor 迁移同批——避免 iOS/mac 双份拷贝的方案届时定。

## 验收
pod install 双壳通过 + 双包 swift test 绿 + 门禁脚本新步骤可执行。

## 回写
- `.ai/modules/ui-apple.md` 模块册（进度+门禁数字）；pitfalls 如踩新坑。
