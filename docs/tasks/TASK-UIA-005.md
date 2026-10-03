# TASK-UIA-005：片段拖拽/裁剪交互（含 undo/redo C ABI）

```yaml
id:          TASK-UIA-005
layer:       UI + BIND
goal:        时间线上的片段可拖拽移动、右边缘可裁剪，结束手势时提交 Command；undo/redo 有 C ABI 与 UI 入口
input:       [docs/tasks/TASK-BACKLOG.md §3.5 UIA-005/UIA-008, docs/tasks/TASK-UIA-004.md,
              docs/tasks/TASK-MODEL-002.md, docs/HANDOFF-003 §2, .ai/modules/{model,session,ui-apple}.md]
output:      [move/trim/undo/redo C ABI + C TU 测试, Swift 封装, SharedUI 拖拽/裁剪交互, undo/redo 入口, 测试]
write_set:   core/include/cq/cq_sdk.h, core/src/cq_sdk.cpp,
             core/include/cq/session/editor_session.h, core/src/session/editor_session.cpp,
             core/include/cq/model/editor_model_state.h, core/src/model/editor_model_state.cpp,
             tests/unit/test_c_abi_edit.c（新）, tests/CMakeLists.txt,
             bindings/swift/Sources/ChuanqiCut/Timeline.swift,
             bindings/swift/Tests/ChuanqiCutTests/TimelineTests.swift,
             apps/apple/packages/SharedUI/Sources/SharedUI/Timeline/{TimelineLayout,EditorTimelineView}.swift,
             apps/apple/packages/SharedUI/Sources/SharedUI/AppEntry.swift,
             apps/apple/packages/SharedUI/Sources/SharedUI/Editor/{TimelineZone,EditorView}.swift,
             apps/apple/packages/SharedUI/Tests/SharedUITests/TimelineInteractionTests.swift（新）
read_set:    core/include/cq/{command/command.h,model/timeline.h}, docs/decisions/ADR-0011
deps:        [UIA-004 ✅, MODEL-002 ✅, UIA-009 ✅]
acceptance:
  - 拖拽片段到新位置，松手后内核时间线的 start 真的变了（查询可证，不是只有 UI 动）
  - 右边缘裁剪改变 duration；duration ≤ 0 或与同轨片段重叠时内核拒绝，UI 回到内核真值
  - 撤销/重做经 C ABI 生效：undo 后 start/duration 回到变更前，redo 再前进
  - 拖拽期间不提交命令（结束时单次提交），UI 有本地预览层
  - 新 ABI 有真正的 C TU 测试；cq_tests_c_abi_edit 只链 cq_core
verification:
  - ./tools/build/build_core.sh --platform=apple --config=Debug --test
  - ./tools/build/build_core.sh --platform=apple --config=Release --test
  - ctest --test-dir build -R c_abi_edit
  - cd bindings/swift && swift test --disable-sandbox
  - cd apps/apple/packages/SharedUI && swift test --disable-sandbox
  - macOS App xcodebuild build + 启动冒烟（演示素材可拖拽）
risk:  拖拽结束提交被内核拒绝时，UI 本地预览会留下"幽灵位置"—— 必须主动回到内核真值；
       左边缘 trim 会牵动 source_in，当前 TrimClipCommand 语义不支持（本期不做，见 D2）；
       can_undo/can_redo 跨线程读必须走原子量，不能直接读 CommandHistory。
parallel:    false（cq_sdk.h 高冲突文件；UI 与内核串行推进）
```

## 关键决策

### D1：拖拽期间不提交，结束时单次提交（不做 coalescing）

HANDOFF-003 写的是「拖拽连续命令合并（coalescing）届时设计」。实现时的结论是
**不需要 coalescing**：拖拽期间 UI 用本地预览层绘制（不碰模型），松手时提交
一条 Move/Trim Command。合并的需求来自"每帧都提交"的设计，而那个设计本身
会污染 Undo 栈（一次拖拽 = 几十条命令）。故不引入合并机制。

### D2：裁剪只做右边缘（改 duration）

`TrimClipCommand` 的语义是「只改 duration，不动 source_in」（MODEL-002 已定）。
左边缘裁剪必须同时改 start + source_in + duration，属新命令 —— 本期不做。
UI 上左边缘不出现裁剪手柄（该区域归「移动」）。卡上写死，不假装支持。

### D3：can_undo / can_redo 走原子量

`CommandHistory` 非线程安全且只在 session 线程变更，UI 线程不能直读。
`EditorModelState` 维护 `atomic<bool> can_undo_ / can_redo_`，在
Execute / Undo / Redo 成功后更新；C ABI 只读这两个原子量。

## 子步骤

| # | 内容 | 验证 |
|---|---|---|
| 1 | 内核：EditorModelState 增 Undo/Redo/CanUndo/CanRedo；EditorSession 增 SubmitMoveClip/SubmitTrimClip/SubmitUndo/SubmitRedo；cq_sdk 增 6 个 ABI | 编译通过 |
| 2 | C TU 测试 test_c_abi_edit.c（move/trim/undo/redo/失败语义/can 查询），登记 CMake | ctest -R c_abi_edit |
| 3 | Swift 绑定封装 + 绑定测试（真实 Session 上跑 undo/redo） | swift test |
| 4 | SharedUI：TimelineLayout 命中测试（纯函数）+ 拖拽/裁剪手势 + undo/redo 入口 | swift test |
| 5 | 门禁（Debug+Release / 绑定 / SharedUI / App 编译）+ 上下文回写 | 见「验证」 |

## 进度（2026-10-03）

| 子步骤 | 状态 |
|---|---|
| 1 内核：move/trim/undo/redo C ABI（+ EditorModelState::Undo/Redo、原子能力标志） | ✅ |
| 2 C TU 测试 `test_c_abi_edit.c`（61 条断言）+ CMake 登记（只链 cq_core） | ✅ |
| 3 Swift 绑定封装 + 绑定测试（真实 Session 上的 undo/redo 往返） | ✅ |
| 4 SharedUI：命中测试纯函数 + 拖拽/裁剪手势 + 撤销/重做入口 + 测试 | ✅（手势本体未自动测，见下） |
| 5 门禁与上下文回写 | ✅ |

**门禁**：内核 Debug **37/37**、Release **37/37**（新增 c_abi_edit）；
Swift 绑定 **18/18**；SharedUI **18/18**（新增 TimelineInteractionTests 5 用例）；
macOS App BUILD SUCCEEDED + 启动冒烟 6s 存活无崩溃。

**本轮未验证 / 剩余风险**：
- **iOS 编译本轮未跑通**：Xcode 26.6 的 IDESimulatorFoundation 插件加载失败
  （`-runFirstLaunch` 修好插件后仍报 "Found no destinations" —— 本机无 iOS 运行时）。
  属环境问题，非代码问题；SharedUI 新增代码无 `#if os(iOS)` 分支，风险低但**未证明**。
- **SwiftUI 手势本体无自动测试**（DragGesture 无法在 XCTest 驱动）：
  命中判定 / 夹取 / 提交结果已抽成纯函数与 ViewModel 方法并测到，手势接线靠 App 冒烟。
- **拖拽成功时的旧值回弹**：提交后立刻 `refreshFromKernel()` 会先显示旧位置，
  observer 回流后跳到新位置 —— 已知且刻意（ADR-0012 D2），真机上若观感差再优化。

## 验收对照

- ✅ 拖拽后内核 start 真的变了：C 侧 `move 生效：A.start == 1000`、SharedUI
  `testMoveTrimUndoRedoThroughViewModel`（查的是内核快照，不是本地预览）
- ✅ 裁剪改 duration；duration=0 / 重叠被拒且 UI 回到内核真值
  （`testRejectedMoveLeavesKernelValueIntact`）
- ✅ undo/redo 经 C ABI 生效：值回退、digest 回退到原值、全 undo→全 redo 后
  clip id 不变（`RestoreClip` 生效）
- ✅ 拖拽期间不提交（本地 ClipDrag），松手单次提交
- ✅ 新 ABI 有 C TU 测试；`cq_tests_c_abi_edit` 只链 cq_core
