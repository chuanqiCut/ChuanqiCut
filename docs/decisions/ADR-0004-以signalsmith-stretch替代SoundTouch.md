# ADR-0004：以 signalsmith-stretch 替代 SoundTouch

- **状态**：提案（待批准）
- **日期**：2026-09-23
- **相关**：RESEARCH-001 F1

## 背景

原调研在两处把 SoundTouch 的协议写成 **MIT**（技术方案决策书 §1 技术栈表、§2.4；管线选型决策表 §[15]），并在另一处写成 LGPL（同一份表的依赖清单）—— 自相矛盾。

**核验结论：SoundTouch 是 LGPL v2.1-or-later**，上游官方明示「Commercial Non-LGPL license alternative available upon request」。MIT 的说法是错误。

这一错误的实际影响：LGPL 静态链接存在"接收者可替换并重新链接"的义务，在 iOS 上处置复杂；若按 MIT 处理，存在合规风险。

另外两个现实问题：
1. SoundTouch 是 C++ 但带平台优化分支，跨 Android/鸿蒙需要额外适配工作；
2. 原调研自己指出 `AVAudioUnitTimePitch` 的缺陷是"不分离 formant，变声不自然"，而 SoundTouch 在 formant 保持上并非其强项。

## 决策

采用 **signalsmith-stretch**：
- **MIT 协议**（已核验，上游仓库与 Qt Multimedia 的第三方声明均确认）
- C++11 **header-only**，零链接负担
- 支持 tempo / pitch / formant 独立控制，含 `setFormantFactor` 与 tonality limit —— 正好覆盖原调研提出的"变声不自然"问题
- 已被 Qt Multimedia 采用为默认 pitch/time 方案，有生产验证
- 纯 C++，天然跨三端

替代范围：音频时间拉伸（变速保调）与变声（含 formant 补偿）。

**不引入**：SoundTouch（LGPL）、Rubber Band（GPL/商业双许可，GPL 属 RESTRICTED 级）。

## 备选方案

| 方案 | 否决理由 |
|---|---|
| 保留 SoundTouch | LGPL 义务；原"MIT"认知错误；跨端适配成本 |
| Rubber Band | GPL 版本属 RESTRICTED，商业授权需采购 |
| 各端系统 API（AVAudioUnitTimePitch / Android Sonic） | 变声不自然（无 formant 分离）；三端效果不一致 |
| 自研 WSOLA/PSOLA | 工作量与音质风险不必要，有成熟 MIT 方案 |

## 后果

**正面**
- 消除 LGPL 合规不确定性
- 三端音频变速/变声行为一致（同一份 C++ 代码）
- 变声质量优于原方案

**负面 / 风险**
- 时间拉伸质量在 0.75x–1.5x 之外会下降（上游自述），超出该范围的变速需要评估或叠加处理
- Debug 构建下性能极慢（上游提示可达 10 倍），需在 CMake 中对该模块单独开启优化
- 上游提示 Apple Clang 16.0.0 配合 `-ffast-math` 会生成错误 SIMD 代码 —— **必须在构建配置中规避该组合**
- 延迟（inputLatency + outputLatency）需要在导出路径上做补偿处理，否则时长会有偏差

**缓解**：`AUDIO-0xx` 任务组中必须包含"端到端时长准确性测试"（变速后输出时长与目标时长误差 ≤ 1 帧）。

## 反转条件

- MIT 协议状态变更，或上游停止维护且无可维护 fork；
- 实测音质在目标变速区间不满足产品要求。

## 落地任务
`DEPS-0xx`（登记依赖）、`AUDIO-0xx`（时间拉伸与变声节点）
