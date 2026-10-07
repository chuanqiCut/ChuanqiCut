# HANDOFF-010：壳工程阶段 0/1 完成（Player Pod 落地）+ P83 相机构建修复（会话交接）

> 2026-10-07 深夜。[ADR-0031](../decisions/ADR-0031-主工程壳化与功能Pod分治.md) 实施第一批：
> **INFRA-013（壳改造）+ INFRA-015（ChuanqiCutPlayer 迁移）完成**，[ADR-0030](../decisions/ADR-0030-模块册分册制与阶段批门禁节奏.md)
> 阶段批节奏首次执行。数字与证据见 ui-apple 模块册 + 当日日志。

## 本轮成果（对着 commit 核）

1. **ChuanqiCutPlayer Pod 落地**：`apps/apple/packages/ChuanqiCutPlayer/`（podspec + Package.swift
   测试宿主 + 14 源文件 + 4 测试文件）。测试守恒：HEAD 140 = SharedUI 88 + Player 52，零丢失。
2. **横向解耦样板**：MediaSheet→PlayerScreen 改经 `SharedUI/Common/PlayerPreviewInjector.swift`
   （@MainActor 注入器），两端壳 App.init 装配 `PlayerScreen` 工厂。**功能 Pod 横向零依赖首次成例**。
3. **拓扑实测微调**：Player 对基座/SDK 零符号引用（触感反馈内联）→ Pod 零依赖声明（记录在 podspec 注释，未来消费 Theme 时恢复）。
4. **P83（P0 顺手修）**：美颜合并轮的 `kCVPixelBufferColorSpaceKey` 不存在于 SDK——首次对
   9da6270 跑 App target 真编译即炸；已修 `kCVImageBufferCGColorSpaceKey`。**合并快检清单已补
   双壳真编译**（ADR-0030/PLAN §4.3 同步更新）。
5. 门禁脚本新增 `apple-player` 步骤（PASS 基线 9→10）。

## 下一个会话怎么接手

1. **阶段批结果**：本轮全量门禁后台跑（数字见当日日志/门禁摘要），PASS 基线 = **10 步**。
2. **阶段 2（INFRA-016 Import Pod）**：迁 `SharedUI/MediaPicker`（7 文件）+ UIA-009/011/012
   导入链。**开工先做跨域引用分析**（grep 域外符号，Player 阶段的 PickerFeedback 教训：
   不能只查类型名，要查所有未限定标识符）——落库接缝对 Assets（阶段 3）留注入点。
3. **阶段 3（INFRA-017 Assets）→ 阶段 4（018 Camera，metallib 风险顶格）→ 阶段 5（019 Editor + 020 Draft）**。
4. **池**：[TODO-POOL](../tasks/TODO-POOL-门禁真机待办池.md) 在飞 [1] 播放器真机 5 检查点、
   [2] CAM-018/019 真机 5 项——攒齐一趟；真机执行前 `build_core_apple.sh --config=Debug &&
   bindings/swift/prepare.sh`（P70）。
5. 发号水位：ADR 下一号 **0032**；pitfalls 下一号 **P84**（本轮已用 P83）；INFRA-016/017 未建卡
   （开工前建卡）。

## 坑（本轮新沉淀）

- **P83**：SDK 常量凭记忆书写 + App target 从未真编译。快检必须含双壳真编译；
  CoreVideo/AVFoundation 常量先 grep SDK 头文件定名。

## 验证

- SharedUI `swift test` 88/88；ChuanqiCutPlayer `swift test` 52/52。
- iOS `-sdk iphonesimulator` BUILD SUCCEEDED；macOS BUILD SUCCEEDED（双壳，含新 Pod）。
- 全量门禁 `run_gate.sh`：见当日日志（本轮阶段批）。
