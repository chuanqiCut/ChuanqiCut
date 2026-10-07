# ADR-0031：主工程壳化与功能 Pod 分治（草稿 / 素材管理 / 播放器 / 拍摄 / 素材导入各自 podspec）

- **状态**：已接受（2026-10-07，传哲拍板：「主工程作为壳工程；草稿逻辑、本地素材管理逻辑、播放器、拍摄、素材导入分别由单独的 podspec 管理」）
- **关联**：[ADR-0030](ADR-0030-模块册分册制与阶段批门禁节奏.md)（阶段批节奏）、[PLAN-壳工程与功能Pod](../tasks/PLAN-壳工程与功能Pod.md)（实施路线）、INFRA-009（CocoaPods 源码集成）、ADR-0014（相机 iOS 原生）、ADR-0021（CIKernel metallib 构建链）、ADR-0025~0028（素材库多轨预留，落各 Pod）
- **影响面**：`apps/apple/**`（ios/mac 双壳工程）、`SharedUI.podspec`、新增 7 份 podspec、双 Podfile、`run_gate.sh`、热点文件（集成机执行）

## 背景

现状（INFRA-009 起）：SDK 层 `ChuanqiCut.podspec`（core C++ + PAL + Swift 绑定，Source/Binary
双 subspec）+ `SharedUI.podspec` **一个大 pod 混装全部 UI 域**（`Sources/SharedUI/` 下
AppEntry、Camera 契约、Common、Editor、MediaPicker、Player、Timeline 七个子域）；
拍摄实现（`iOSApp/Camera/`）还直接挂在 App target 里。两份独立 xcodegen 工程
（`apps/apple/ios`、`apps/apple/mac`）各引两个 pod。

问题：①任何域改动都重编整个 SharedUI；②域间边界靠目录约定没有编译期约束，域间随手
import 没有护栏；③多机分线开发后（ADR-0029 §1a），A 线内部各域写集仍在同一个 pod 里
互相纠缠；④草稿、素材管理等新域（BACKLOG §13）没有落点，会长在 Editor 或壳里。

## 决定

1. **壳工程**：`apps/apple/ios` 与 `apps/apple/mac` 的 App target 只保留**装配层**——
   AppEntry、路由/导航壳、权限声明、依赖注入（把各功能 Pod 的入口装进 App）、启动钩子。
   业务与 UI 一律下沉 Pod。
2. **Pod 结构（SDK 不动，UI 拆一基座 + 七功能）**：

| Pod | 内容 | 来源 | 依赖 |
|---|---|---|---|
| `ChuanqiCut` | SDK 层：core C++ + PAL + Swift 绑定（**不动**） | 现状 | — |
| `SharedUI`（基座，瘦身重定位） | Common/Theme 设计令牌/通用组件 | SharedUI/Common | ChuanqiCut |
| `ChuanqiCutPlayer` | 独立播放器全域 | SharedUI/Player | 基座、SDK |
| `ChuanqiCutImport` | 素材导入（相册/文件/拍摄产物落库；MediaPicker 迁入） | SharedUI/MediaPicker + 导入链（UIA-009/011/012） | 基座、SDK、Assets |
| `ChuanqiCutAssets` | 本地素材管理（素材库 UI + Session 素材表；core `LIB-*` 配套） | 散在 Editor/Common 的素材逻辑收敛 | 基座、SDK |
| `ChuanqiCutCamera` | 拍摄全域（采集/渲染/录制/特效） | `iOSApp/Camera` 迁入 + SharedUI/Camera 契约层 | 基座、SDK |
| `ChuanqiCutDraft` | 草稿逻辑（草稿箱/自动保存/恢复；core `PROJ-*` 配套） | 新域 | 基座、SDK、Assets |
| `ChuanqiCutEditor` | 编辑器（三件套 + Timeline；UIA-032 重构主战场） | SharedUI/Editor + Timeline | 基座、SDK、Assets |

3. **依赖纪律**：**功能 Pod 之间横向不直接依赖**（Camera↔Import↔Player↔Draft↔Editor），
   产出/事件交接（如拍摄产物落库、草稿引用素材）在**壳层装配**或经基座协议注入；
   依赖只允许指向基座、SDK、Assets（素材是公共数据源）。禁止网状依赖。
4. **构建事实**：全部走 `:path` 开发 Pod（沿用 INFRA-009「App 不用 SPM」决策）；
   `use_modular_headers!` 保留；Swift pod 声明 `swift_version 6.1`、平台基线 iOS 16 /
   macOS 15.4（ADR-0010）；**Camera Pod 为 iOS 专属**（mac 壳不引）；macOS 能力子集
   （编辑器/播放器/素材/导入）两壳都引，Camera 只进 iOS Podfile。
5. **迁移分六个阶段**（每阶段收尾 = 一个阶段批门禁点，ADR-0030）：
   阶段 0 骨架与壳改造（Podfile×2 + xcodegen + 基座瘦身路由）→ 1 Player → 2 Import →
   3 Assets → 4 Camera（含 metallib 构建链迁 podspec `script_phase`）→ 5 Editor+Draft。
   详细任务卡 = INFRA-013~020（BACKLOG §14）。

## 后果

- 正向：域边界获得编译期护栏；SharedUI 改动不再牵连全域重编；多线开发写集按 Pod 天然
  相交为零；草稿/素材管理有了明确落点；壳工程可被最小化复用（未来换壳/多壳）。
- 代价与风险：①`beauty_bilateral.metal` 的 CIKernel 构建链（ADR-0021）随 Camera Pod 迁入
  podspec `script_phase` + `resource_bundles`，是迁移中最容易坏的点；②`import CChuanqiCut`
  的 `SWIFT_INCLUDE_PATHS` 注入要复制到每个依赖 SDK 的 podspec（现由 ChuanqiCut 的
  user_target_xcconfig 提供，pod-依赖-pod 时需改为 pod_target_xcconfig 链）；③ios/mac 双
  工程要同步改，改一漏一 = 门禁才炸；④迁移期 SharedUI 与新 Pod 并存，重复符号风险——
  每阶段迁完立即从 SharedUI 删源。
- 反转条件：若 Pod 拆分导致构建时间或 Podfile 复杂度失控（阶段批连续两次因构建链问题
  超时），回退为「SharedUI 单 pod + 目录域纪律」，保留 Pod 目录结构仅拆编译单元。
