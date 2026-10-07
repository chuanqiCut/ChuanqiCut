# PLAN — 壳工程与功能 Pod 拆分实施（ADR-0031 配套，2026-10-07）

> 授权：传哲 2026-10-07 拍板「主工程作为壳工程；草稿逻辑、本地素材管理逻辑、播放器、拍摄、
> 素材导入分别由单独的 podspec 管理」。本 PLAN 定义六个迁移阶段、八张任务卡、每阶段的
> 阶段批门禁点。**全部热点文件（podspec / Podfile / project.yml / run_gate.sh）归集成机执行**；
> 域内源码迁移可由归属线协助（写集见各卡）。

## 1. 目标 Pod 拓扑（终态）

```
壳 App（apps/apple/ios + mac，App target = AppEntry/装配/路由/权限/启动钩子，零业务）
 ├─ ChuanqiCut          SDK（core+PAL+bindings，Source/Binary 双 subspec，不动）
 ├─ SharedUI            UI 基座（Common/Theme/令牌/通用组件；功能域全部迁出）
 ├─ ChuanqiCutPlayer    播放器          ← SharedUI/Player
 ├─ ChuanqiCutImport    素材导入        ← SharedUI/MediaPicker + UIA-009/011/012 导入链
 ├─ ChuanqiCutAssets    本地素材管理    ← 散在 Editor/Common 的素材逻辑 + LIB-* UI 配套
 ├─ ChuanqiCutCamera    拍摄（iOS 专属）← iOSApp/Camera + SharedUI/Camera 契约层
 ├─ ChuanqiCutDraft     草稿            ← 新域（PROJ-* 配套）
 └─ ChuanqiCutEditor    编辑器          ← SharedUI/Editor + Timeline（UIA-032 主战场）

依赖方向：功能 Pod → {基座, SDK, Assets}；**功能 Pod 之间横向零依赖**（交接走壳装配/协议注入）。
Camera 仅进 iOS Podfile；其余 Pod 双平台（ios 16.0 / osx 15.4）。
```

## 2. 任务卡（INFRA-013~020，均集成机執行，BACKLOG §14 登记）

| 卡 | 任务 | 关键写集 | 验收 |
|---|---|---|---|
| INFRA-013 | 壳工程改造：Pods 目录骨架（`apps/apple/packages/`）+ 双 Podfile 引新 Pod + 双 project.yml 适配 + `run_gate.sh` 适配（apple-sharedui 段改为逐 Pod 测试） | `apps/apple/{ios,mac}/Podfile`、`project.yml`、`tools/ci/run_gate.sh` | 双壳 xcodegen+pod install+构建冒烟过；门禁绿 |
| INFRA-014 | SharedUI 瘦身为 UI 基座：功能子域迁出后删源，仅留 Common/Theme | `SharedUI.podspec`、`Sources/SharedUI/Common/**` | SharedUI 测试套仍绿；`swift build` 零 Player/Editor 引用 |
| INFRA-015 | `ChuanqiCutPlayer` Pod：迁 `Sources/SharedUI/Player`（含测试），SharedUI 同步删源 | `packages/ChuanqiCutPlayer/**` | Player 测试在新 Pod 全绿（数字对齐迁移前）；双壳构建过 |
| INFRA-016 | `ChuanqiCutImport` Pod：迁 MediaPicker + 导入链（UIA-009/011/012），落库接口对 Assets 留接缝 | `packages/ChuanqiCutImport/**` | 导入链单测过；双壳构建过 |
| INFRA-017 | `ChuanqiCutAssets` Pod：素材表/素材库逻辑收敛建域（LIB-* UI 配套落此） | `packages/ChuanqiCutAssets/**` | 素材表回归测试过 |
| INFRA-018 | `ChuanqiCutCamera` Pod：`iOSApp/Camera` 迁入 + **metallib 构建链迁 podspec**（ADR-0021：`-fcikernel` 编 + `xcrun metallib` 链 + `resource_bundles` 下发）+ Camera 契约层从 SharedUI 迁入 | `packages/ChuanqiCutCamera/**`、相机 Podspec `script_phase` | 真机一趟：预览出画/滤镜/磨皮/录制（阶段批攒单）；metallib 非空壳（strings 查符号+大小） |
| INFRA-019 | `ChuanqiCutEditor` Pod：迁 Editor+Timeline；UIA-032 编辑页重构在新 Pod 内进行 | `packages/ChuanqiCutEditor/**` | 编辑器测试过；双壳构建过 |
| INFRA-020 | `ChuanqiCutDraft` Pod：草稿域骨架（PROJ-001 落地后填肉；引用素材走 Assets） | `packages/ChuanqiCutDraft/**` | 域骨架编译过；随 PROJ-005/UIA-029 填功能 |

批次：**阶段 0 = INFRA-013+014**；阶段 1 = 015；阶段 2 = 016；阶段 3 = 017；阶段 4 = 018；
阶段 5 = 019+020。与业务线并行时，写集互不相交（Pod 迁移动热点与 `packages/`，业务线动
域内源码——**同一域的迁移与业务任务不并行**，串行让路）。

## 3. 每阶段收尾 = 阶段批（ADR-0030）

1. `run_gate.sh` 全量（数字记入各相关模块册测试记录节 + review 报告）；
2. 双壳 `xcodegen generate && bundle exec pod install && 构建`（改一漏一在这一步拦）；
3. 迁移类阶段追加：迁移前后测试数字对照（不许掉用例）；SharedUI 删源后全仓 grep 无悬空 import；
4. 真机单（池）攒齐即一趟：阶段 4 后必须含相机真机检查点。

## 4. 风险与既有案底对照

| 风险 | 案底 | 对策 |
|---|---|---|
| CIKernel metallib 空壳/构建链断 | ADR-0021、P 案「必查符号+大小防空壳」 | 阶段 4 单独成阶段；metallib 验收脚本化 |
| Pod 依赖 Pod 的 CChuanqiCut module 可见性 | podspec 头注释（modulemap 事件） | `SWIFT_INCLUDE_PATHS` 从 user_target_xcconfig 改 pod_target_xcconfig 链，逐 Pod 验 import |
| 同一 Swift 源被 pod+SPM 各编一次 → 重复符号 | SharedUI.podspec 头注释 | 沿用「App 不用 SPM」；迁移完立即删 SharedUI 旧源 |
| ios/mac 双工程改一漏一 | INFRA-009 双工程拆分决策 | 每阶段两壳同改同验；Podfile diff 双侧核对 |
| xcodegen 缺 PRODUCT_NAME 等 settings | project.yml 注释 | project.yml 改动后跑双壳构建冒烟，不吃「生成成功」当验证 |
