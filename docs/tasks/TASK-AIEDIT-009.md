# TASK-AIEDIT-009：对话式调整（文字 + 语音输入）

```yaml
id:          AIEDIT-009
layer:       UI
goal:        结果页常驻半屏对话框：文字输入 + 按住说话（系统 STT）转文字，逐轮增量调整（逐条接受/全部接受/撤销本轮）
input:       [AIEDIT-005/007/008, SPEC §6.4/§9, RESEARCH-003 §4（Descript 对话隐喻 / Opus 决策透明）]
output:      [Chat 视图与 VM, 语音输入组件, 逐条接受交互, 单测]
write_set:   apps/apple/packages/SharedUI/Sources/SharedUI/SmartCut/Chat/*(新)、
             apps/apple/packages/SharedUI/Sources/SharedUI/SmartCut/Voice/*(新)、
             apps/apple/ios/iOSApp/Info.plist + apps/apple/{ios,mac}/project.yml(info 段: NSSpeechRecognitionUsageDescription + 麦克风 —— 高冲突文件)、
             apps/apple/packages/SharedUI/Tests/SharedUITests/SmartCutChatTests.swift(新)
read_set:    apps/apple/packages/SharedUI/Sources/SharedUI/SmartCut/**, bindings/swift/*, docs/specs/AIEDIT-001
deps:        [AIEDIT-008]
acceptance:
  - 一条指令 → 增量 EditPlan → 逐条展示（action + reason + 接受/拒绝）→ 应用为一次可撤销批次（"撤销本轮"定位 plan 批次 id，断言快照还原）
  - 语音：按住录音 → 松开转文字进输入框（SFSpeechRecognizer），权限拒绝/不可用/方言不支持三路径降级为纯文字（无崩溃）
  - 对话历史轮次截断（K=6）与"重新成片"（全量重排）入口
  - 逐条拒绝后剩余 actions 仍可原子应用（部分接受语义：拒绝项从批次剔除后整体 Do，断言时间线）
  - 纯逻辑单测全绿；macOS/iOS 编译门禁通过
verification:
  - swift test --disable-sandbox（SharedUI）
  - xcodebuild build（macOS）
  - 真机语音走查（不阻塞门禁，同 008 政策）
risk:        STT 权限与隐私申报是上架审查敏感点 → Info 段文案明确"语音仅用于生成编辑指令，不上传音频"；Info/project.yml 高冲突文件独立声明
parallel:    false（批次 6）
```

## 背景

对话框是本产品与全部竞品的差异化（RESEARCH-003 §3 矩阵：无人做多轮对话式剪辑调整）。语音是同一输入通道的加速器，不是独立功能。

## 实现要点

1. Chat 状态机：`idle/listening/recognizing/thinking/applying`；"thinking/applying"双阶段进度（LLM 生成 vs Command 应用）分开展示。
2. 部分接受语义在 UI 层完成：被拒 action 从 plan 剔除 → 调 apply（C++ 校验器对剔除后的 plan 再验一次，保证仍合法）。
3. 语音组件封装 SFSpeechRecognizer + AVAudioEngine，纯逻辑（权限状态机/转写回调）可测，系统交互冒烟。
4. 消息气泡渲染 assistant_message + actions 卡片；Markdown 不引入（纯 Text 组合）。

## 回写

.ai/modules/ui-apple.md 增补 Chat 域；pitfalls 记录 STT 坑（区域/locale 限制）。
