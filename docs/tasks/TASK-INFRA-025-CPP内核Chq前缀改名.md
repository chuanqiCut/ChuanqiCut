# TASK-INFRA-025 — C++ 内核 Chq 前缀改名

> 状态：**编码+模块级验证完成**（2026-10-11；集成全量门禁按阶段批，待办池 [13]）
> 决策：ADR-0039（传哲三项裁决：只 C++ 内核 / 前缀串 `Chq` / 方法名不加）
> 分支：`chuanqi/TASK-INFRA-025-chq-cpp-prefix`

## 背景

传哲评审要求内核类名/文件名加前缀，防未来多库引入撞名。范围裁决为 C++ 内核层；
Swift、C ABI、平台层、方法名全部不动。机械改名为本任务主体。

## 写集（与其他任务不相交；不碰工作区里 ADR-0038 在途文件）

- `engine/core/cq/**`（改名 + token + include + guard；**`cq_sdk.h/.cpp` 零改动**）
- `engine/core/CMakeLists.txt`（源列表路径）
- `engine/platform/apple/**`（仅 token / include 消费点）
- `tests/unit/*.cpp`（仅 token；`test_c_abi*.c` 零改动；测试文件名不变）
- `docs/CODESTYLE.md` §1、`docs/decisions/ADR-0039-*.md`、本卡、`.ai/modules/core.md`、
  `.workbuddy/memory/2026-10-11.md`、`docs/tasks/TODO-POOL-门禁真机待办池.md`

**明确不碰**：`apps/**`、`engine/bindings/**`、`third_party/**`、`tools/`（smoke_link 只用
ABI 头）、Podfile/pbxproj。

## 子步骤

| # | 步骤 | 状态 |
|---|---|---|
| 1 | 盘点：类型清单、写集冲突检查、CMake 源列表方式确认 | ✅ |
| 2 | ADR-0039 + CODESTYLE §1 修订 + 本卡 | ✅ |
| 3 | 脚本化改名：git mv（`chq_*`）+ 类型 token + include 路径 + guard | ✅ 189 类型 / 83 文件 |
| 4 | `engine/core/CMakeLists.txt` 源列表同步 | ✅ |
| 5 | `build_core.sh --platform=apple` 编译过 + 修尾差 | ✅ Debug+Release 双配置 |
| 6 | ctest + check_platform_headers + golden verify（数字待实测） | ✅ 数字见下 |
| 7 | 收工清单（模块册/日志/池）+ 选择性 commit | ✅ 池 [13] / HANDOFF-019 |

## 验收（2026-10-11 实测）

- `build_core.sh --platform=apple`：**Debug + Release 双配置编译通过（-Werror）**。
- `ctest --test-dir build`：**48/48 通过**（154.5s；含 `test_c_abi*.c` 纯 C ABI 三卡零改动全绿）。
- `tools/platform/check_platform_headers.py --json`：**41 头 0 违规**（脚本零改动）。
- `tests/golden/verify.py --json`（python3.12）：**21 built_ok / 0 fail**。
- 残留扫描：engine+tests 旧类型 token / 旧 include 路径 **0 残留**；`cq_sdk.h` 声明区 diff=0。

## 剩余风险与移交

- `pod install` 后 Pods 工程的 Copy Headers 布局未验证（podspec glob 自动收新文件名，
  理论无影响）→ 待办池登记。
- `ChqI*` 叠加命名观感 → ADR-0039 已记录，后续可立独立小任务改后缀式。
