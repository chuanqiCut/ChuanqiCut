# TASK-CORE-007：能力查询 `ICapabilities` 与枚举（实现）

- **层**：跨平台内核 + Apple 后端
- **依赖**：CORE-006（PAL 接口冻结，已完成）
- **阻塞**：CORE-009（EditorSession）→ BIND-001（C ABI）→ BIND-002（Swift 绑定）
- **契约**：`docs/specs/PAL-接口契约.md` §4 Capabilities
- **日期**：2026-09-29

## 背景（为什么要做这个，而不是先做 BIND-001）

`core/include/cq/pal/capabilities.h` 在 CORE-006 里**只冻结了接口与枚举**：

```cpp
Status SetCapabilitiesBackend(ICapabilities* backend);
CapabilityValue QueryCapability(Capability cap);
```

实测确认（2026-09-29）：这两个函数**没有任何实现**。全仓库唯一引用是
`tests/unit/pal_headers_compile.cpp` 里的 `static_assert`，属于**编译期检查、不链接**，
所以 CTest 一直全绿看不出来——这与 CORE-006 当时的教训同型
（「编译验证 7/7 全绿，但接口其实是断的」）。

同时，AGENTS.root.md 红线 #3 要求「能力必须运行时查询，一律走 `cq_query_capability()`」，
而该能力当前为空头声明，红线**尚未真正兑现**。

## 目标

1. 实现能力查询的**内核侧注入与分发**（平台无关）
2. 实现 **Apple 后端**（Metal / VideoToolbox），运行时查询，不用 `#if __APPLE__` 推断
3. 建立可验证的行为契约：未注入后端时一律 `kNo`（不谎报）

## 写集（write_set）

| 文件 | 动作 | 说明 |
|---|---|---|
| `core/src/pal/capabilities.cpp` | 新增 | `SetCapabilitiesBackend` / `QueryCapability` 实现 |
| `pal/apple/capabilities.mm` | 新增 | Apple 能力后端（Metal / VideoToolbox） |
| `pal/apple/capabilities_apple.h` | 新增 | 安装函数的 Apple 侧声明（**不进 core/include**，避免平台类型污染） |
| `core/CMakeLists.txt` | 修改 | 登记 `src/pal/capabilities.cpp` |
| `pal/apple/CMakeLists.txt` | 修改 | 登记 `capabilities.mm` + ARC 属性 + 框架 |
| `tests/unit/test_capabilities.cpp` | 新增 | 平台无关行为单测（注入/nullptr/枚举完备） |
| `tests/unit/test_capabilities_apple.cpp` | 新增 | Apple 后端真实查询单测 |
| `tests/CMakeLists.txt` | 修改 | 注册两个新用例 |

## 设计决策（评审点）

### D1 · 未注入后端返回 `kNo`，不返回 `kYes`

契约已定「未注入返回 kNo」。这是**安全默认**：上层拿到 kNo 会走降级路径，
拿到错误的 kYes 会调用不存在的能力直接崩。宁可降级不可用，不可谎报可用。

### D2 · 查不到就诚实返回 `kNo`，不做「 optimistic guess 」

部分能力（如 AV1 硬解、`kNpuInference` 是否实际跑在 ANE）Apple 没有公开的可信运行时 API。
本项目立场：**查不到就返回 kNo 并在注释里写明原因**，不用机型/芯片名单猜、
不用编译期宏推断。猜测会让上层基于不可靠前提做调度，比降级更危险。

### D3 · `kNpuInference` 语义收窄为「CoreML 推理可用」

是否**实际跑在 ANE** 由 CoreML 运行时决定（见 `.ai/memory/pitfalls.md` R1），
没有任何 API 能预先查询。故本项只表示「CoreML 可用」（iOS 11+ / macOS 10.13+，
部署目标 iOS 16 / macOS 15.4 已远超 → `kYes`），并在注释里明确
「不代表 ANE 加速」。

### D4 · 部署目标不抬高，用 `@available` 守卫

ADR-0010 定 iOS 16 / macOS 15.4。iOS 侧部分 VideoToolbox 探测常量要求更高系统版本
（PALA-011 已踩过一次：硬解探针常量要求 iOS 17.0，硬编要求 iOS 17.4）。
处理方式沿用既有约定：**`@available` 守卫 + 诚实降级**，不抬高部署目标、不加 `-Wno-*`。

### D5 · 后端为静态单例，注入不接管所有权

契约规定「不接管所有权，生命周期须长于查询调用」。Apple 后端提供
`cq::apple::InstallCapabilities()`，内部持有一个静态后端实例，
进程生命周期内有效，满足契约且不引入所有权歧义。

## 验证命令

```bash
# 1. 主构建（Debug + Release 都要跑，本项目出现过 Release-only 缺陷）
tools/build/build_core.sh --platform=apple --config=Debug   --test
tools/build/build_core.sh --platform=apple --config=Release --test

# 2. 三切片打包（含 LTO 预检 + 消费者侧链接冒烟）
tools/build/build_core_apple.sh --config=Release

# 3. 静态门禁
python3 tools/pal/check_pal_headers.py
```

## 验收标准

- **不再是断接口**：`QueryCapability` 有真实实现，未注入返回 `kNo` 且可测
- Apple 后端在真实 macOS 上返回**可解释**的结果（每项都能说明依据来源）
- `Capability` 枚举 16 项**全部有明确处置**，无 `default: return kYes` 式兜底
- 零平台类型进入 `core/include`；PAL 头文件门禁仍 0 violation
- iOS 切片仍可编译（部署目标不做任何抬高）
- CTest 全绿，用例数 22 → 24

## 剩余风险

- 本机为 Intel Mac（无 ANE、无 ProRes 硬编），**本机查询结果不能代表 iPhone 17 Pro**。
  真机结果需传哲在 iPhone 17 Pro 上实测回填 `.ai/memory/baselines.md`。
- AV1 / ProRes 的硬件支持随芯片差异大，本任务只做「能查到的查」，
  查不到的诚实返回 kNo；若实测发现需要更细粒度（区分「不可用」与「未知」），
  需回来扩展 `CapabilityValue` 枚举（属冻结接口变更，需提 ADR）。
