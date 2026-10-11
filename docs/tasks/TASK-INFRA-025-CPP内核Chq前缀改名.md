# TASK-INFRA-025 — C++ 内核 Chq 前缀改名

> 状态：**完成（含收尾批，2026-10-11）**；集成全量门禁按阶段批照旧
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

## 收尾批（2026-10-11 下午，传哲指令「不留小辫子」；全部实测）

| # | 收尾项 | 结果 |
|---|---|---|
| 1 | ADR-0039 终态化（删 ChqI 逃生门；活文档同步义务入 ADR） | ✅ |
| 2 | 陈旧引用收口：CODESTYLE 路径与 golden python 版本、门禁脚本注释、9 份模块册旧类型名、CChuanqiCut 陈旧注释（podspec/CMakeLists） | ✅ 门禁脚本改后重跑行为不变（41 头 0 违规） |
| 3 | xcframework 重建 + Swift 窄检 | ✅ 修复 third_party 门禁只认 Darwin 的半成品（三 SDK 切片选择）→ 三切片 + smoke-link 过 → **bindings swift test 26/26** |
| 4 | 双壳 pod install + 端到端构建 | ✅ 发现并修复壳工程 Pods 远程依赖三件缺失（pitfalls **P108**，`edit_project.rb` 新增 add-remote-dependency 子命令）→ **macOS BUILD SUCCEEDED**（x86_64，清 DerivedData 干净口径）+ **iOS generic device BUILD SUCCEEDED**（arm64） |
| 5 | 池收口 | ✅ [13] 关池；拆出 [14]（mac 通用双 arch × CP 1.17 兼容头，独立小任务） |
| 6 | COCOAOPODS.md 机制附注（三件/聚合 target 位置/验证口径） | ✅ |

**明确不做（与他线边界）**：iOS 模拟器构建失败在他线未提交的 MetalFX 引入
（MetalFXScaler.swift，模拟器 SDK 无此框架），归相机线收口时验；`ChqI` 命名为终态，不再重开。

## 剩余风险与移交

- mac **通用双架构**构建未通（CP 1.17 Swift Compatibility Header 双 arch 互踩）→ 池 [14]
  独立小任务；本机/CI 验证口径用单原生架构（P108④）。
- iOS 模拟器构建待相机线 MetalFX 工作收口后补验（模拟器 SDK 无 MetalFX）。
- 全量门禁（run_gate.sh）与真机按 ADR-0030 阶段批，本轮未跑。
