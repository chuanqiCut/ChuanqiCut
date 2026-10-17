# 模块：时间线模型与命令

> **归属**：A 线（编辑器/UI；时间线模型与命令） —— 归属表见 docs/tasks/PLAN-三线并行.md §1a / ADR-0029（双机分工与门禁跑批，2026-10-07）

> **落地状态（2026-10-12，MODEL-003 / B0）**：EffectBinding 数据模型已落地 ——
> `engine/core/cq/model/chq_property.h`（属性值/属性袋/效果栈）挂到 ChqClip，
> 属性变更走 Command（红线 #5），最小 C ABI 已暴露。**效果目录（默认参数）与
> 渲染消费未实现**（EFFECT-001 / RENDER-011）；关键帧与插值引擎未动（anim 模块）。
> 属性标量用 float（非时间量；契约头门禁禁 double），时间字段仍一律 RationalTime。

**边界**：`engine/core/cq/model/`、`engine/core/cq/command/`、`engine/core/cq/anim/`

## 职责
ChqTimeline / ChqTrack / ChqClip / Transition / EffectBinding 数据模型；Command 模式与 Undo/Redo；关键帧与插值引擎。

## 入口
- `TimelineModel` — 轨道、片段、转场、效果挂载
- `EditorCommand` / `ChqCommandHistory` — **所有模型变更的唯一入口**
- `Keyframe<T>` / `AnimationChannel<T>` / 插值引擎 — Linear / Bezier / Hermite / Catmull-Rom

## 硬约束
1. **UI 不得直接修改模型**，一律走 `Command`。这是 Undo/Redo 与三端一致性的前提。
2. Command 只存"怎么撤销"（如 clipID + oldTime + newTime），不存数据拷贝。
3. 时间字段一律 `ChqRationalTime`。
4. 模型序列化必须能往返（serialize → deserialize → 相等）。

## 验证
```bash
ctest -R model_command     # 100 次 undo 后回到初始态
ctest -R model_timeline    # 多轨 / 同轨重叠拒绝 / 转场计入总时长
ctest -R model_property    # 属性值/袋/栈 + 四条属性命令（MODEL-003）
ctest -R model_transform   # 变换/层级/变速/关键帧 + 六条命令（MODEL-004）
# ⚠️ `model_serialize`（序列化往返）与 `anim_interp`（四种插值曲线）**用例尚不存在**：
#    B3 持久化未开工、关键帧插值归 B8。本模块只立了关键帧**数据槽**，没有求值器。
#    引用这两个名字当"待跑的验证"会让下一个人判红（2026-10-17 核对：`ctest -N` 53 例无此两名）。
# 本机 ctest 不在 PATH：用 ~/.workbuddy/binaries/cmake/CMake.app/Contents/bin/ctest --test-dir build
```

## 相关
ADR-0006、`docs/tasks/TASK-BACKLOG.md` 的 `MODEL-0xx` / `ANIM-0xx`


---

# MODEL-002 落地（2026-10-03）：Command / ChqCommandHistory

## 位置与入口

- `engine/core/cq/command/chq_command.h` + `engine/core/cq/command/chq_command.cpp`
- `ChqICommand`（Do / Undo / Redo / Name）+ `ChqCommandHistory`（Execute/Undo/Redo/CanX/Depth/Clear）
- 首批 6 个命令覆盖 ChqTimeline 全部变更面：
  `AddTrack / RemoveTrack / InsertClip / RemoveClip / MoveClip / TrimClip`

## 语义要点

| 主题 | 约定 |
|---|---|
| 失败语义 | Execute 失败 = 不入栈、模型不变、**redo 分支保留**；Undo/Redo 失败 = 栈不动（不变量破坏，测试守卫） |
| 线性历史 | 新 Execute 丢弃 redo 分支；Clear() 清双栈不动模型 |
| 编辑类命令 | 只存增量（clipID + old/new 值），不存实体 —— 硬约束 #2 原型 |
| 结构类命令 | 持有受影响**单个实体**的内容（命令输入参数 / 回放依据），不做模型级快照 |
| Redo 的 id | Add/Insert 重放会分配新 id → 必须走 `RestoreTrack/RestoreClip` 恢复**原 id**，否则历史里后续命令的引用悬空 |
| 线程 | 非线程安全，在 session 线程用（CORE-009 已串行化） |

## ChqTimeline 最小扩展

`RestoreTrack(const ChqTrack&)` / `RestoreClip(uint64_t track_id, const ChqClip&)`：
按实体自带 id 恢复，不分配新 id；校验与 Add/Insert 一致；`next_id_` 仍单调推进。
**仅供 Command 回放 / 序列化载入**，业务代码不要直调。

## 不变量（破坏即 Undo 栈失效）

1. ChqTimeline 只能经 ChqCommandHistory 变更（绕过直改会让历史 id 引用悬空）。
2. 命令 Do/Undo/Redo 失败时不得改动模型（先校验后变更，与 ChqTimeline 同风格）。
3. Undo/Redo 按栈序（LIFO）：相邻命令的实体引用靠顺序保持有效。

## 验证

```bash
ctest --test-dir build -R model_command   # 4 组用例：逐命令往返 / 201 深度全撤销回初始态 /
                                          # 失败语义 / 排序不变量（门禁 35/35）
ctest --test-dir build -R c_abi_edit      # UIA-005：move/trim/undo/redo 经 C ABI 的往返
```

# UIA-005 落地（2026-10-03）：撤销链路接到 C ABI

`ChqCommandHistory` 此前只有 C++ 侧入口（MODEL-002 完成但**对外不可用**）。
UIA-005 把它接到 `ChqEditorModelState::Undo/Redo` 与 `cq_session_undo/redo`。

- **撤销也发布新快照**：`Undo/Redo` 成功后 `Publish()`（否则 UI 读到的还是旧
  时间线）+ `RefreshHistoryFlags()`（刷新 can_undo/can_redo 原子标志）。
- **id 稳定性得到 C 侧实证**：全 undo 到空再全 redo，clip id 与撤销前完全相同
  （`RestoreClip` 生效，未重分配）—— 这是不变量 3 的端到端守卫。
- **digest 可回退**：undo 到某一步时 fingerprint 与「那一步之前」的值相等，
  测试直接断言相等（不是"变了就行"）。

---

# MODEL-004 落地（2026-10-17）：空间变换 / 层级 / 变速 / 关键帧数据槽（B5.5 第一块）

## 位置与入口

- `engine/core/cq/model/chq_transform.{h,cpp}`（新）— `ChqTransform` / `ChqMirrorKind` /
  `kLayerMin~kLayerMax(0~1000)` / `ChqSpeed` / `ChqKeyframe` + `ChqKeyframeList`
- `chq_timeline.{h,cpp}` — `ChqClip` 加 `transform/layer/speed/keyframes`，`ChqTrack` 加 `transform`；
  新增 `ChqCanvasRelativeFix` 与六个 setter（`SetClipTransform/SetClipLayer/SetClipSpeed/`
  `SetTrackTransform/SetClipKeyframe/EraseClipKeyframe`）；`SetCanvas` 多一个可选 `out_fix` 出参
- `chq_command.{h,cpp}` — 六条新命令（同六个 setter 一比一）+ `ChqSetCanvasCommand` 加留档字段
- 单测 `tests/unit/model/test_model_transform.cpp`（ctest 名 `model_transform`，203 断言）

## 语义要点（本模块新增的约定）

| 主题 | 约定 |
|---|---|
| 恒等默认值 | `ChqTransform` 默认 = 不位移 / scale 1 / 旋转 0 / mirror kNone / relative 1 / opacity 1；`layer = kLayerMin`、`speed = 1:1`、关键帧空。**新建 clip 不填这些字段时渲染必须与改前一致** |
| 标量用 float | 非时间量允许浮点（同 `chq_property.h` 先例）；契约头门禁禁 `double`（`chq_transform.h` 是被检头之一，44 头 0 违规） |
| 取值域 | `Validate()` 拦 NaN/±Inf、scale ≤ 0、relative ≤ 0、opacity ∉ [0,1]、`rotation ∈ (-360,360)`、mirror 野枚举。四条写路径（`InsertClip`/`ReplaceClip`/`RestoreClip`/`RestoreTrack`）过**同一道**校验，Command 回放不开后门 |
| 变速 | `speed` **只存比值**（整数 `numerator/denominator`），时间线占时 = `ScaleRational(source_duration, den, num)`；模型不隐式改写 `duration`（trim 已把两者解耦）。 absurd 比值过域检查但在 `ApplyTo` 落 `kOverflow` —— 这不是 bug，是 `MulFits` 的既有语义 |
| 关键帧时刻 | **相对片段起点**，不是时间线绝对时刻（拖片段不改动画相位 ⇒ MoveClip 系列无需重基）。负时刻被 `ChqKeyframeList::Set` 拒（局部时间里"片段开始之前"永远采不到）。空属性袋同样拒 ⇒ "空关键帧"这个状态构造不出来 |
| SplitClip 分箱 | 切点左边的帧进左半（原时刻），切点及其右边进右半并**减去左半时长**；切点上的值**两半同值**（否则接缝处闪一帧）。`transform/layer/speed` 两半各自原样继承（非时间量，不重基） |
| 关键帧插值 | **本卡没有求值器**：只有数据槽与升序不变量。插值归 B8 |
| layer | 只在片段上（轨级不设 —— 两份层级会互相问"谁赢"）；`layer` **不是排序键**，模型数组顺序仍只由 `start` 决定。RENDER-011 必须为 `(轨序, layer)` 定确定性 tiebreak |
| 改画布比例 | `SetCanvas` **一定**连带修正全部实体 `relative_*`（像素守恒），没有"只改宽高"的旁路。Undo 不重算反比：Do 时用 `out_fix` 捕获原值，Undo 原样写回 |

## 浮点实测（2026-10-17，float32，代码就是 `chq_transform.cpp:116-120` 那两行）

`1080×1920 → 720×1280 → 回`：`1.7 → 2.55000019 → 1.70000017`（**差 1.2e-7，没回来**）；
同一条路径 `0.3 → 0.450000018 → 0.3`（**恰好回来**）、`1.0 → 1.5 → 1.0`（回来）。
`1080×1920 → 1080×1080 → 回`：高度 `0.7 → 1.05 → 0.70000005`（没回来）。
⇒ **回不回取决于值**，所以"Undo 再乘一次反比"这种写法不能要；两种情形都写成了单测断言（`[C]`）。

---

## 模块册（ADR-0030：任务/进度/测试门禁记录按模块归口）

> 本节由归属线更新（一机一线，天然单写者）；BACKLOG / pitfalls / baselines 等
> 全局册零直写（集成机阶段批落账）。新调研/规格/审查落 docs/ 原位，但必须在此登记指针。

### 任务与进度（在飞 + 近期；全量 DAG 见 TASK-BACKLOG）

| ChqTask ID | 标题 | 状态 |
|---|---|---|
| MODEL-001/002 | 时间线模型 / Command+History | ✅（编辑链在用） |
| MODEL-003 | 效果属性系统（属性值/袋/栈 + 四条属性命令） | ✅ 2026-10-13（随 B0 提交 `6ccf29b`；本表此前漏记这一行） |
| **MODEL-004** | 空间变换 / 层级 / 变速 / 关键帧数据槽（B5.5 第一块，ADR-0040 §2） | ✅ 2026-10-17 编码 + 窄检（见下「测试与门禁记录」；**L3 未跑**、真机问卷待回收） |
| EDIT-007 | Split/Remove C ABI（B1，RESEARCH-010 §5.2） | ✅ 2026-10-11（SplitClip/ReplaceClip 入模型层；48/48） |
| EDIT-008 | 左缘裁剪 trim-clip-in（B1） | ✅ 2026-10-11（ChqTrimClipInCommand + ReplaceClip 基座；48/48） |
| EDIT-009/010 | 跨轨移动 + 画布属性（UIA-040 内核面） | ✅ 2026-10-12（MoveClipToTrack/SetCanvas + 命令×2 + ABI×3；指纹纳入画布；全量 48/48） |
| **CORE-011** | 轨道静音写路径（`ChqSetTrackMutedCommand` + `cq_session_set_track_muted`，池 [19] / 问卷 E1 裁定） | ✅ 2026-10-17（照 `SetCanvas` 一比一拓；新增 `ChqTimeline::SetTrackMuted`，未知轨 `kInvalidArgument`；Debug **38/38** 37.74s、Release **52/52** 227.00s（重编 **95 TU**）；ctest 用例数不变，只在 command/session/abi 三处加断言） |

### 测试与门禁记录（阶段批）

| 日期 | 阶段/范围 | 结论（数字） |
|---|---|---|
| 2026-10-11 | EDIT-007/008 编码轮（build_core apple + 窄检 6 + 全量兜底） | build -Werror 零告警；model_timeline/model_command/c_abi_edit/editor_session/c_abi_session/c_abi 6/6；全量 ctest 48/48（Debug，134s） |
| 2026-10-17 | **MODEL-004 编码轮（窄检，L3 未跑）**：`chq_transform.{h,cpp}` 新增 + clip/track 挂字段 + 六条命令 + digest | `build_core.sh --platform=apple` **Debug + Release 双 -Werror 全过**；`model_transform` **203 断言 0 失败**（首轮 6 红，两类成因见 **P185/P186**）；Debug 跳 heavy **39/39** 33.15s（+1 例）、Release 全跑 **53/53** 124.40s（heavy 14 例 = 114.16 sec*proc）；headers **44 头 0 违规**；hygiene **5/5**、clang-format 违规 **0**；golden **21/0/0 901784B**；`gate_scope.sh` 路由的两条窄检全跑。**回归面**：`SetCanvas` 现在会连带修正 relative_*；`model_timeline`/`c_abi*` 全过（旧调用点仍是两参，`out_fix` 默认 `nullptr`） |

### 调研 · 决策 · 池指针

- ADR-0012（命令提交时机）· 红线 #5（UI 不直改模型）
- **RESEARCH-016（2026-10-13，对标产品 SDK 架构调研）**：§1.2 给出 NLE 模型层级（Node→TimeSpaceNode→
  Model/Track/Slot/Segment）与 **ChqClip vs 其轨道槽位模型 缺口表**（transform / layer / speed /
  keyframes / mask / audioFilter / relative 布局均缺）；§2.3 建议做 B0 前补齐并连带设计 relative
  布局（否则改画布比例时子元素漂移）。**状态：已由 ADR-0040（2026-10-13 传哲拍板）落地 ——
  §2 字段清单 = MODEL-004（2026-10-17 编码），三条有意偏差（`opacity` 补记 / 轨级不设 `layer` /
  关键帧取片段局部时刻）见 [TASK-MODEL-004](../../docs/tasks/TASK-MODEL-004.md) 落地记录。
  `mask` 与 `audioFilter` 仍缺：mask 无卡，片段音量归 B5（EDIT-011）。**
