# ADR-0039 — C++ 内核 `Chq` 命名前缀强制

> 状态：**已采纳并实施**（2026-10-11，传哲裁决「我要求加前缀」；三项参数当轮确认）
> 关联：ADR-0038（ABI 层 `CQ` 前缀不动，与本 ADR 的 `Chq` 分层并存）、
> CODE-001 / `docs/CODESTYLE.md` §1（本 ADR 修订其 C++ 类型与文件名两行）、AGENTS.md 红线 7
> 任务卡：TASK-INFRA-025

## 背景

传哲 2026-10-11 评审提出：内核类名/文件名无前缀，未来引入多个库时会"乱"。
经三轮评估（类名方法名 → 文件名 → header search 机制），结论一致：现代 C++/Swift
以 namespace/module 隔离为惯例，防撞前线在符号层（本库已由 `cq_`/`CQ` + 门禁承担）。
**传哲在知悉上述结论后仍裁决加前缀**——这是风险偏好决策（面向未来多库引入与
SharedUI 泛用名如 `Theme` 的防御冗余），本 ADR 记录裁决并固化执行边界，不再反复。

三项裁决参数（传哲当轮选定）：

1. **范围 = 只 C++ 内核**（engine/core/cq 第一方类型 + 文件）；Swift 层维持
   module 隔离、不加前缀（CODESTYLE 成文决策保留）。
2. **前缀串 = `Chq`**（否决 `CQ`：与 ABI 层既有 `CQSession` 等混淆；
   否决 `CCQ`：三字母冗余。与 ABI 并存的边界：`CQ` = 跨界 C 符号，`Chq` = 内部 C++ 类型）。
3. **方法/函数名不加前缀**（方法经类型限定调用，无全局撞名面）。

## 决策

### 1. 类型：PascalCase 名一律加 `Chq` 前缀

- `Timeline` → `ChqTimeline`、`Status` → `ChqStatus`、`RationalTime` → `ChqRationalTime`。
- 既有 `Cq` 开头名剥旧前缀再统一：`CqDecoder` → `ChqDecoder`。
- 接口 `I` 前缀保留并叠加：`IGfxDevice` → `ChqIGfxDevice`（叠加观感已记录为取舍）。
- 不动：枚举值 `k*`、常量 `k*`、宏（`CQ_LOG_*` 等）、`namespace cq`、嵌套类型名。

### 2. 文件：snake_case 加 `chq_` 前缀，与主类型对应

- `model/timeline.h` → `model/chq_timeline.h`；`base/time.cpp` → `base/chq_time.cpp`。
- 既有 `cq_` 开头内部文件剥 `cq_` 段：`cq_build_anchor.cpp` → `chq_build_anchor.cpp`、
  `cq_session_impl.h` → `chq_session_impl.h`。
- **例外**：`cq_sdk.h`（C ABI 唯一公开面，纯 C）：**声明区零改动**（`git diff` 的声明行
  必须为 0，作为 ABI 未变的机器可验证据）；注释允许把旧类型概念名跟改为新名
  （注释纪律要求引用真实存在的名字）。`cq_sdk.cpp` 文件名不动，但作为内部类型的实现
  消费者，include/类型 token 跟改（不对外，不构成 ABI 变化）。测试文件
  （`test_*.cpp` / `test_c_abi*.c`，沿用 CODESTYLE §4 命名）与平台层文件
  （`engine/platform/apple/**`，Platform-Native 层）文件名不变。
- include 路径根 `cq/` 与 `namespace cq` **不变**（目录/命名空间不因本决策扩大改动面）。
- include guard 随文件名更新为 `CQ_<路径>_CHQ_<名>_H_` 形态（guard 根前缀 `CQ_` 约定不变）。

### 3. 消费层只跟改引用，不改自身命名

`engine/platform/apple/**`（.mm/.cpp/.h）与 `tests/unit/*.cpp` 作为消费者：类型 token、
include 路径、guard 引用机械跟改；自身类型与文件名不变。

## 已知取舍（记录在案，不再辩论）

- 与 Apple Swift API Design Guidelines / Google C++ Style Guide 的"无前缀 + namespace"
  惯例偏离；防御冗余换来未来多库引入时的检索与识别收益。
- `ChqI` 叠加观感差；后续若评审反感，可将 I 改为后缀（`ChqGfxDeviceInterface`），
  属独立小任务，不在本 ADR 范围。
- 注释中的旧类型名随机械替换同步更新（注释纪律要求引用真实存在的名字）。

## 验证

`tools/build/build_core.sh --platform=apple`（-Werror）+ `ctest` 全量 +
`tools/platform/check_platform_headers.py --json` + `tests/golden/verify.py --json`。
数字记 TASK-INFRA-025 与模块册。
