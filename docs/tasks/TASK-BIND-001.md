# TASK-BIND-001：`cq_sdk.h` 纯 C ABI 冻结

- **层**：SDK 对外边界
- **依赖**：**CORE-009（已完成）**、CORE-007（能力查询）、CORE-008（线程模型）
- **阻塞**：BIND-002（Swift 绑定）→ 所有 UIA-*；BIND-003（Kotlin）→ 所有 UID-*
- **红线**：AGENTS.root.md #7（公共头只有 C 类型 + opaque 句柄）、#3（能力运行时查询）
- **日期**：2026-09-29

## 背景

`core/include/cq/cq_sdk.h` 目前是 **INFRA-001 建立的占位**：只有一个
`typedef struct CQSession CQSession;` 和注释里写的两个函数名。
`nm` 可见的导出全是 C++ mangled 符号（`__ZN2cq...`）与 ObjC++ 实现符号，
**Swift / Kotlin 一个都接不上**。

依赖链 CORE-007 → CORE-008 → CORE-009 现已全部完成，
`EditorSession` 这个"对外唯一门面"存在了，冻结 C ABI 才有真实支撑 ——
不会再出现「接口冻结但实现是断的」（CORE-006 / CORE-007 两次教训）。

## 写集（write_set）

| 文件 | 动作 | 说明 |
|---|---|---|
| `core/include/cq/cq_sdk.h` | **重写** | 纯 C ABI 声明（零 C++ / 零平台类型） |
| `core/src/cq_sdk.cpp` | 新增 | C ABI 实现（C++ 侧包装 EditorSession 等） |
| `tests/unit/test_c_abi.c` | 新增 | **纯 C 编译 + 功能验证**（见 D1） |
| `core/CMakeLists.txt` | 修改 | 登记 `cq_sdk.cpp` + 版本宏 |
| `tests/CMakeLists.txt` | 修改 | 注册 C 编译用例（LINKER_LANGUAGE CXX） |

> BACKLOG 原写集只有 `cq_sdk.h`，但"只有声明无实现"正是本项目踩过两次的坑。
> 故一并补实现 + 一个真能链接运行的用例。

## 设计决策（评审点）

### D1 · 用**纯 C 翻译单元**证明"零 C++ 类型"，不靠人眼审查

新增 `tests/unit/test_c_abi.c`（`.c`，clang 以 C 语言编译）。
只要 `cq_sdk.h` 里混进任何一个 C++ 类型（`std::*`、`class`、`bool` 之外的一切），
这个 TU 就编译失败 —— 比"评审时看一眼"可靠得多。
链接仍走 C++ 链接器（`LINKER_LANGUAGE CXX`），因为底层实现是 C++。

### D2 · 回调一律用「函数指针 + `void*` 上下文」

`std::function` 无法跨 C ABI。故：
```c
typedef int32_t (*CQMutateFn)(void* ctx);
typedef void (*CQSnapshotObserver)(CQSnapshot snapshot, void* ctx);
```
这是所有 C SDK 的通行做法，也是 Swift/Kotlin 都能对接的形态。

### D3 · 状态码不重新发明枚举，直接复用内核数值

C 侧不复制一份 `StatusCode` 枚举（会漂移），改为：
```c
int32_t cq_status_is_ok(int32_t code);
int32_t cq_status_is_error(int32_t code);
int32_t cq_status_is_cancelled(int32_t code);
const char* cq_status_to_string(int32_t code);
```
码值与内核 `StatusCode` **同构且稳定**（CORE-002 已固化数值）。

### D4 · 必须暴露「主线程标记」和「能力查询」

这两条不是可选便利，是**红线的执行入口**：
- 红线 #3「能力一律走 `cq_query_capability()`」→ C ABI 必须给出该函数，否则
  Swift 侧无从遵守。
- CORE-008 约定「宿主必须在主线程标记角色，否则零阻塞守卫失效」→
  C ABI 必须给出 `cq_mark_main_thread()`，否则 Swift 侧做不到。

### D5 · 版本号由 CMake 注入，不在头文件里硬编码

`cq_version_major/minor/patch` 的实现读 CMake 传入的 `CQ_VERSION_*` 宏。
头文件**不**定义版本宏 —— 否则会出现"头文件写 0.1、CMake 已是 0.2"的漂移
（与"注释不能比代码走得快"同一类问题）。

### D6 · `create` 即启动，`destroy` 即停止释放

不单独导出 `start` / `shutdown`：少一层状态，调用方不会忘。
`cq_session_destroy(NULL)` 安全（幂等）。

## 已知限制（诚实标注，不夸大）

- **digest 恒为 0**：模型层（MODEL-001 TimelineModel）未接入，`ISessionState`
  无 C 侧实现入口。快照的**版本号**语义完整可用，digest 待模型层接入后再暴露注入点。
- 尚未暴露媒体/渲染/导出能力（PALA-* / EXPORT-001 未接入门面），
  本期 C ABI 只覆盖「会话 + 变更 + 快照 + 能力查询 + 线程角色」。

## 验证命令

```bash
tools/build/build_core.sh --platform=apple --config=Debug   --test
tools/build/build_core.sh --platform=apple --config=Release --test
tools/build/build_core_apple.sh --config=Release
python3 tools/pal/check_pal_headers.py
```

## 验收标准（对应 BACKLOG「零 C++/平台类型；评审通过」）

- `tests/unit/test_c_abi.c` 以 **C 语言**编译通过并运行通过（D1 硬证据）
- 头文件只包含 `<stdint.h>` / `<stddef.h>`，零平台类型，门禁 0 violation
- 端到端：create → submit → 快照版本 1 → changes_since → destroy
- `cq_query_capability` 返回合法值（未注入后端时为 0 = kNo）
- `cq_mark_main_thread()` 后 `cq_is_main_thread()` 为真
- CTest 26 → 27

## 剩余风险

- Swift 侧（BIND-002）拿到的是 **session 线程**的观察者回调，必须自行 dispatch
  到主线程 —— 需在 BIND-002 明确处理，本任务只在头文件注释里警告。
- `CQChangeRecord.name` 指向**静态存储**，C 调用方不得在其生命周期外使用
  （与内核 `ChangeRecord` 同一约定）。
