# HANDOFF-019 — 内核 Chq 前缀改名会话交接（TASK-INFRA-025 / ADR-0039）

> 2026-10-11 · 集成机 · 分支 `chuanqi/TASK-INFRA-025-chq-cpp-prefix`（两个 commit，未并 main 未推）

## 一句话

传哲裁决 C++ 内核全部类型/文件加 `Chq` 前缀（ADR-0039 三参数：只 C++ 内核 / 串 `Chq` /
方法名不加），改名落地后按「不留小辫子」指令完成收尾批：决策终态化、陈旧引用清零、
xcframework/Swift 窄检补齐、**修复壳工程 Pods 集成假绿根因**、双壳端到端构建通过。

## 装配形状（改了什么）

- 189 类型 `Xxx` → `ChqXxx`（`CqDecoder`→`ChqDecoder`；接口终态 `ChqIGfxDevice`，不再重开）。
- 83 文件 git mv 为 `chq_*`；include 路径、guard（`CQ_<路径>_CHQ_<名>_H_`）、CMakeLists 同步。
- `cq_sdk.h` 声明区 diff=0（仅注释跟改）；`test_c_abi*.c` 零改动；Swift / C ABI / 方法名 /
  宏 / k 常量 / 平台层文件名**零改动**。
- 收尾批额外动到（均为修复既有基础孔，见 pitfalls P108）：`third_party/CMakeLists.txt`
  （ffmpeg 三 SDK 切片选择）、`tools/build/edit_project.rb`（新增 add-remote-dependency）、
  双壳 `ChuanqiCut.xcodeproj/project.pbxproj`（补 Pods 远程依赖三件）。

## 验证数字（全部清 DerivedData / 干净口径）

- 内核：Debug + Release 双配置 -Werror 过；ctest **48/48**；check_platform_headers **41 头
  0 违规**；golden **21/21**（python3.12）。
- Swift：xcframework 三切片重建 + smoke-link 过 → **bindings swift test 26/26**。
- 双壳：**macOS BUILD SUCCEEDED**（x86_64 原生架构）+ **iOS generic device BUILD
  SUCCEEDED**（arm64）——修复 Pods 依赖后从零构建，非增量假绿。

## 坑与注意（本轮全部入册）

1. **壳工程对 Pods 的远程依赖三件曾被剥**（containerPortal/proxy/dependency = 0），
   历史构建成功全是旧 DerivedData 假绿；`pod install` 静默 no-op。修法与验证口径见
   pitfalls **P108** + COCOAOPODS.md 附注；`edit_project.rb` 新子命令可复用。
2. mac **通用双架构**被 CP 1.17 Swift Compatibility Header 双 arch 互踩
   （`unsupported Swift architecture`）→ 池 **[14]** 独立小任务；本机验证用单原生架构。
3. `third_party/CMakeLists.txt` 的 ffmpeg 门禁只认 Darwin 是 DEPS-012 半成品，已修成
   三 SDK 切片选择（切片产物本就齐全）。
4. 发号水位必须现场 `ls`（HANDOFF-015~018 已被并行会话占用，我撞号一次让位 019）→
   pitfalls **P109**。
5. iOS 模拟器构建失败在他线未提交的 MetalFX 引入（模拟器无此框架），归相机线，非本任务。

## 下一步

1. 传哲验收 → 分支并回 main（含 ADR-0038 等当日提交，快进）→ 集成快检。
2. 池 [14]：mac 通用双架构构建修复（独立小任务）。
3. 相机线收口后补 iOS 模拟器构建验证。
