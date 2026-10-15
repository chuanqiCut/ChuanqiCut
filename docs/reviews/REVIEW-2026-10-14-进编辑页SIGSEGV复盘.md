# REVIEW — 进编辑页必现 SIGSEGV（UIView backing layer 全清复盘）

- 日期：2026-10-14（定位与修复）／2026-10-15（复盘与治理落地）
- 设备：iPhone 17 Pro，iOS 26.6.1 (23G83)，DEBUG 包；本机 macOS 26.7.1 / Xcode 26.6 / Swift 6.3.3
- 坑号：[P131](../../.ai/memory/pitfalls.md)（根因）、[P132](../../.ai/memory/pitfalls.md)（取证通道）
- 任务上下文：UIA-042（SnapKit 迁移）期间真机走查暴露；**与 UIA-042 无因果关系**
- 性质：**复盘**（根因 / 治理 / 防复发 / 静态检查与 CR 的效力边界），不是任务卡、不是 ADR

---

## 0. TL;DR

用户报「进入编辑直接卡在这个堆栈」，我们按"卡死（死锁 / 无限递归）"查了一轮，**方向是错的**：
真机上是**必现 SIGSEGV（signal 11）**，不是卡住。

根因一行：`TimelineContentView.rebuild` 里的

```swift
layer.sublayers?.forEach { $0.removeFromSuperlayer() }
```

清的是 UIView 的 **backing layer**，而**子视图（主轨右端「+」按钮）的 layer 也挂在它的 sublayers 里**，
被一并从树上拔掉。UIKit 的 `subviews` 仍持有该 view，layer 却已离树 → CA 首次提交事务走到
「有 view / 无 layer」的畸形状态 → `_parentTraitEnvironment → superview → CALayerGetSuperlayer`
解引用野指针 → 崩。

治理：加一层**自绘专用容器层 `canvasLayer`**，自绘层全挂它，清空只清它 —— 子视图层永不被触碰。

**防复发交给机器，不交给人：**
新增门禁规则 `tools/compliance/check_uiview_layer_hygiene.py`（已接入 `run_gate.sh` 步骤 2c）。
实测：当前 116 个 Apple 端文件 **PASS**；喂修复前的代码 —— **精确命中 `EditorTimelineUIView.swift:321`**；
喂「注释反例 + 容器层写法 + 逃逸阀标记」—— **零误报**。

**对「Code Review 能否避免」的诚实答案：基本不能。** 不是 reviewer 不认真，是这条缺陷的
激活方式超出了 CR 的视野 —— 详见 §6。

---

## 1. 症状与时间线

| 时间 | 事件 |
|---|---|
| 10-14 16:21 | 传哲报「进入编辑直接卡住」+ Xcode 暂停栈（trait 传播 → `[UIView superview]` → `CALayerGetSuperlayer`）。本机只读码分析，给出三条真机诊断路径，**未改代码**。 |
| 10-14 21:28 | 传哲连上手机，要求直接跑。采用仓库既有真机配方（`HANDOFF-020` §4：`devicectl --console` + 环境变量探针）。 |
| 10-14 21:34 | 首次运行即**必现 signal 11**（崩溃在 1s 内）。至此"卡住"被证伪。 |
| 10-14 21:39–21:45 | 两条外部取证通道先后失效（P132），改用进程内信号处理器取到栈，并用设备符号全量符号化。 |
| 10-14 21:48 | 退回 HEAD（UIA-042 之前）**同样崩** → 排除当天改动，确认存量缺陷。 |
| 10-14 22:00–22:05 | 6 组组件二分，锁定「`TimelineContentView` 的 backing layer 全清」。 |
| 10-14 22:09 | 修复 + 双路径复验通过；临时诊断开关全部撤除。 |
| 10-15 上午 | 复盘 + 静态规则落地 + 接入门禁。 |

**方法论代价**：从"卡住"这个描述出发，按死锁/递归查了约 30 分钟没有任何进展；
一旦改成"跑起来看"，10 分钟内就拿到了必现崩溃。→ **真机可复现的问题，先复现再分析，
不要对着一张暂停栈做推理。**

---

## 2. 取证过程（三层，全部可复用）

### 2.1 两条外部通道为什么都废了（P132）

1. `devicectl device process launch` 启动的进程崩溃后，**CrashReporter 不写 .ips** ——
   `device copy from --domain-type systemCrashLogs` 反复拉取都没有新日志。
2. `lldb`：`device process attach -n <name> -w` 抢不上（崩溃 <1s）；按 pid attach 能挂上
   （`process status` 报 running），但后续 `continue` / `thread list` 一律
   `error: Process must be launched` —— 拿不到可用 Process 对象。`--start-stopped` 起挂起态也一样。

### 2.2 进程内取证（本次实际起作用的那条）

新增 `apps/apple/ios/iOSApp/DebugCrashDumper.swift`（DEBUG only）：
`sigaction(SIGSEGV/SIGBUS/SIGABRT)` → 回调里把 `Thread.callStackSymbols` 打到 **stderr**
（`--console` 可见；stdout 全缓冲会丢，这是仓库踩过的老坑）。

### 2.3 符号化

设备系统库符号在 `~/Library/Developer/Xcode/iOS DeviceSupport/<版本>/Symbols`。
基址 = 崩溃地址 − 日志里的文件内偏移（UIKitCore 实测 `0x197ca0000`），再
`atos -o <镜像> -l <基址> <地址>`。符号化后的关键段：

```
CA::Transaction::flush_as_runloop_observer → CA::Layer::perform_update_
 → -[UIView(CALayerDelegate) _performPreLayoutUpdateOfLayer:]
 → -[UIView _updateTraitCollectionAndProcessChangesWithBehavior:]
 → -[UIView _wrappedProcessTraitChanges:] ×9（沿层级下钻）
 → -[UIView _updateCachedTraitCollectionIfNeeded] → _parentTraitCollection
 → _parentTraitEnvironment → -[UIView(UIKitManual) superview]
 → CALayerGetSuperlayer + 72   ← SIGSEGV
```

**读栈要点（这次最关键的判读）**：栈只有 42 帧且一直收敛到 `main`。
→ **不是栈溢出**（真无限递归会撑出成百上千帧、且到不了 `main`），
→ 是 `superview` 这一帧读到了坏指针。这一步直接把排查方向从"递归"扭到"悬垂对象"。

---

## 3. 根因

### 3.1 机制链

```
TimelineContentView（UIView 子类，自绘）
├─ layer（backing layer）
│   ├─ 自绘层：轨道行 / 标尺 / 刻度 / 片段块 / 缩略图槽 / 轨道头 …
│   └─ ⚠️ addButton.layer（子视图「+」的 layer 也在这里）
└─ subviews: [addButton]

rebuild() 执行 layer.sublayers?.forEach { $0.removeFromSuperlayer() }
→ addButton.layer 被一并拔掉
→ UIKit.subviews 仍有 addButton，但它的 layer 不在层级树中
→ CA 首次提交事务：perform_update_ → _performPreLayoutUpdateOfLayer → trait 下钻
→ 问到这个 view 的 superview → CALayerGetSuperlayer(坏指针) → SIGSEGV
```

### 3.2 二分证据（真机实测，6 组）

| 实验 | 结果 | 结论 |
|---|---|---|
| 摘掉整个时间线视图 | 不崩 | 病灶在时间线 |
| 摘掉 `addButton` | 不崩 | 与子视图有关 |
| `rebuild` 不执行（不建自绘层） | 不崩 | 与清层动作有关 |
| 用裸 UIView 顶替按钮 | **照崩** | **与按钮类型无关** → 条件是「有子视图」+「清层」同时成立 |
| 摘传输条 / 工具栏 / 预览 MTK / 红框 / 空态 | 全崩 | 与这些无关 |
| 退回 HEAD（UIA-042 SnapKit 迁移之前） | **照崩** | **与当天改动无关**，是更早期的存量缺陷 |

### 3.3 为什么这次才暴露

- 清层写法先存在（自绘时间线一直这么重建）；
- **子视图（「+」按钮）是后来 UIA-041 才加进来的**。
→ **缺陷不是被写下的那次提交"引入"的，而是被后来一次完全合法的改动"激活"的。**
这类"组合效应型缺陷"是 CR 最难拦的一类（见 §6）。

### 3.4 为什么在 Xcode 里看起来像"卡住"

同一条栈，调试器暂停时会停在 UIKit 内部帧上；进程随后 SIGSEGV 退出，
在没接崩溃日志的上下文里很容易被读成"卡死"。**"卡住"是观察方式的产物，不是事实。**

---

## 4. 治理手段

### 4.1 修复：专用容器层（治本）

```swift
private let canvasLayer = CALayer()

override init(frame: CGRect) {
    super.init(frame: frame)
    layer.masksToBounds = true
    layer.addSublayer(canvasLayer)
}

override func layoutSubviews() {
    super.layoutSubviews()
    canvasLayer.frame = bounds
}

// rebuild：清空只清容器层；9 处自绘层全部改挂 canvasLayer
canvasLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
```

**为什么不做"清层时跳过子视图 layer"的补丁式修法**（`Set(subviews.map { $0.layer })` 过滤）：

| | 补丁式 | 容器层（采用） |
|---|---|---|
| 修好这一处 | ✅ | ✅ |
| 将来再往该视图加子视图 | 仍需每处清层代码都记得过滤 → **同一类 bug 会复发** | 结构上不可能碰到子视图层 |
| 语义清晰度 | "清我的层，但跳过某些" —— 含隐式前提 | "自绘层有自己独立的家" —— 一说就懂 |

按 ADR-0034「严禁临时方案」，选后者。

### 4.2 真机验证（iPhone 17 Pro / iOS 26.6.1 DEBUG 包）

| 验证项 | 结果 |
|---|---|
| push 路径（`CQ_AUTO_PUSH_EDITOR=1`，新增自动入口）25s | **零 crash、零约束冲突** |
| 编辑页直挂（`CQ_AUTO_ROUTE=editor`）25s | **零 crash、零约束冲突** |
| 首页默认路径 15s | 零 crash |
| iOS 壳 `-scheme ChuanqiCutApp -destination generic/platform=iphoneos` | BUILD SUCCEEDED |
| macOS 壳 `-scheme ChuanqiCutMacApp -arch x86_64 ONLY_ACTIVE_ARCH=YES` | BUILD SUCCEEDED |
| 全量 `run_gate.sh` | **未跑**（按约定需先询问） |

---

## 5. 未来如何防止（三层）

| 层 | 手段 | 状态 |
|---|---|---|
| **L1 机制** | 自绘 UIView 一律配专用容器层；约定写进代码注释 + pitfalls P131 | ✅ 已落地 |
| **L2 静态检查** | `tools/compliance/check_uiview_layer_hygiene.py`，接入 `run_gate.sh` 步骤 2c | ✅ 已落地 |
| **L3 真机** | `DebugCrashDumper`（崩溃即出栈）+ `CQ_AUTO_PUSH_EDITOR`（无手点复现 push 转场）+ 真机问卷 I06~I10 | ✅ 已落地 |

规则细节（R1 失败 / R2 告警）：

- **R1（FAIL）**：`layer.sublayers = nil / = []`、`layer.sublayers?.forEach { … removeFromSuperlayer() }`、
  `layer.sublayers?.removeAll()`、`.map/.filter { … removeFromSuperlayer() }`，
  含 `xxx.layer.sublayers` 形态（动别人 view 的 backing layer 同样禁止）。
- **R2（WARN，不阻断）**：同文件 `layer.addSublayer(` ≥ 2 次 = 自绘与 backing layer 混排，提示收敛到容器层。
- 逃逸阀：确需清空时行内写 `cq-allow: backing-layer-clear`，评审须能说出「该 UIView 确认无子视图」。
- 扫描范围：`apps/apple` 下 `.swift/.m/.mm`，排除 `Pods / .build / build / vendor / third_party`。

---

## 6. 静态检查与 Code Review，到底能不能避免？

### 6.1 静态检查：**能拦住这条具体写法，但拦不住这类语义问题**

**能力已实测（这是结论，不是设想）**：

| 输入 | 结果 |
|---|---|
| 当前仓库 `apps/apple`（116 个文件） | **PASS**，R1 违规 0 |
| 修复前版本（`git show HEAD:…EditorTimelineUIView.swift`） | **FAIL，精确命中第 321 行** + R2 告警「混排 ×8」 |
| 反例探测文件（注释里写反例 / 容器层写法 / 逃逸阀标记） | **零误报**（注释已剔除） |

**边界（必须写清楚，否则会误以为有了它就安全）**：

- 抓不到"等价但形态不同"的破坏：例如 `view.layer.sublayers?.last?.removeFromSuperlayer()`、
  把子视图 layer 单独 `removeFromSuperlayer()`、跨文件的间接引用、ObjC 运行时动态操作。
- 抓不到"`layer.sublayers` 读取"这类无副作用用法（本规则只匹配"清空"形态，这是刻意的，避免噪音）。
- 结论：**它能保证"同一条写法不再入库"，不能保证"这类问题为零"。**
  真正兜底的是 L1（容器层约定）+ L3（真机崩溃即出栈）。

### 6.2 Code Review：**诚实说，基本拦不住**

不是 reviewer 的问题，是这条缺陷的结构决定的：

1. **写法本身极"正常"**：`layer.sublayers?.forEach { $0.removeFromSuperlayer() }` 是自绘视图
   最常见的重建惯用法，语义上"清空我自己的层"完全自洽，看不出危险。
2. **危险来自隐式前提**：`layer` 里混着"别人的 layer（子视图的）"这件事，
   不在那一行里，也不在那次 diff 里 —— 它在"这个 UIView 有没有子视图"这个跨文件事实里。
3. **激活它的是后来的改动**：见 §3.3。CR 天然只看 diff：
   引入清层代码时，视图还没有子视图（写法正确）；后来加「+」按钮的 diff 里只有几行 addSubview，
   reviewer 不会（也不该被要求）回头审视几周前那行清层代码。
   → **CR 的结构性盲区：只看增量，看不到跨版本的组合效应。**

所以：

- **不该指望 CR** 兜住这类问题；
- CR 能做的只是弱约束：checklist 加一条「自绘 UIView 有子视图吗？清层是清谁的层？」；
  这条清单对新代码有用，对存量代码基本无效（没人会去逐行重审）。
- **该指望的是机制**：把"隐式前提"变成"结构上不可能"（容器层），
  再把"违规写法"变成"门禁会红"（静态规则）。这两件都已落地。

### 6.3 一句话总结

> 这次不是"人不够仔细"，是"人眼 + diff 视野"本来就看不到跨版本的组合效应。
> 治理的正解是把隐式前提结构化为不可能，再把违规写法交给机器拦。

---

## 7. 遗留与待办

1. **真机目检未回收**：canvasLayer 改动后时间线图层位置/层级需肉眼确认
   （`QUESTIONNAIRE-UIA-042` §4.1 的 `Q-UIA042-I06~I10`）。**未回收前不标记完成**（ADR-0034）。
2. **SwiftUI 侧已核**：`EditorTimelineView.swift` 走 Canvas 绘制，不涉及 CALayer 层级操作，不适用本规则。
3. **全量门禁未跑**：本次只跑了新增的 `layer-hygiene` 步骤与双端壳构建；`run_gate.sh` 全量需传哲点头。
4. **门禁新增项**：`run_gate.sh` 步骤 2c 为新增（热点文件改动），若某台开发机上误报，
   先用 `cq-allow:` 逃逸阀 + 池登记，不要直接改规则去适配。

---

## 8. 指针

- 坑册：[P131](../../.ai/memory/pitfalls.md)（backing layer 全清 → SIGSEGV）、[P132](../../.ai/memory/pitfalls.md)（取证通道与 atos 配方）
- 台账：`docs/reports/LEDGER-W42.md` 补记八（决策链 / 写集 / 验证数字）
- 模块册：`.ai/modules/ui-apple.md`（UIA-042 段 + 2026-10-14 追加）
- 代码：`EditorTimelineUIView.swift`（修复）、`iOSApp/DebugCrashDumper.swift`（取证）、
  `iOSApp/HomeView.swift`（`CQ_AUTO_PUSH_EDITOR` 自动入口）
- 门禁：`tools/compliance/check_uiview_layer_hygiene.py` + `tools/ci/run_gate.sh` 步骤 2c
- 问卷：`docs/reviews/QUESTIONNAIRE-UIA-042-预览选中红框与布局保真.md` §4.1
