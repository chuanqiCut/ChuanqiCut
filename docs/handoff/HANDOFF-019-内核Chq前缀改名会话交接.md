# HANDOFF-019 — 内核 Chq 前缀改名会话交接（TASK-INFRA-025 / ADR-0039）

> 2026-10-11 · 集成机 · 分支 `chuanqi/TASK-INFRA-025-chq-cpp-prefix`

## 一句话

传哲裁决 C++ 内核全部类型/文件加 `Chq` 前缀（ADR-0039 三参数：只 C++ 内核 / 串 `Chq` /
方法名不加）。已机械改名并模块级验证通过；**未 commit、未并 main**。

## 装配形状（改了什么）

- 189 类型 `Xxx` → `ChqXxx`（`CqDecoder`→`ChqDecoder`；接口叠加 `ChqIGfxDevice`）。
- 83 文件 git mv 为 `chq_*`（`cq_session_impl.h`→`chq_session_impl.h`、
  `cq_build_anchor.cpp`→`chq_build_anchor.cpp`）；`cq_sdk.h/.cpp` 文件名不动。
- `engine/core/CMakeLists.txt` 源列表、全部 include `cq/**/chq_*.h`、guard
  `CQ_<路径>_CHQ_<名>_H_` 同步。Swift / C ABI（`cq_*`/`CQ*`）/ 方法名 / 宏 / k 常量 / 平台层
  文件名 **零改动**。

## 验证数字（模块级，集成机全量门禁仍按阶段批）

- `build_core.sh --platform=apple`：Debug + Release 双配置 -Werror 全过。
- ctest **48/48**（154.5s）；check_platform_headers **41 头 0 违规**；golden **21/21**（python3.12）。
- `cq_sdk.h` 声明区 diff = 0（仅注释跟改）。

## 坑与注意

1. `engine/bindings/swift/Frameworks/ChuanqiCut.xcframework` 内嵌**旧 pal 头**，先于本任务
   已与源码脱节——重建 xcframework（池 [12]/[13] 同一趟）自然消除。
2. golden verify 需 Python ≥3.11（本机用 `python3.12`；系统 python3 无 tomllib）。
3. 工作区尚有 ADR-0038 在途 48 文件（Pod 重命名）——本任务 commit 严格按路径选择性暂存，
   接手者合并前先分清两条线的写集。

## 下一步

1. 传哲验收本 HANDOFF + ADR-0039 → commit 本任务文件 → 并回 main（集成机快检后）。
2. ADR-0038 收口趟：Swift 窄检 + pod install 布局 + xcframework 重建（池 [13] 三项）。
3. 若评审反感 `ChqI*` 叠加观感 → 独立小任务改接口后缀式（ADR-0039 已留口）。
