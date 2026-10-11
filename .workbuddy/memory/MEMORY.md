# ChuanqiCut 项目长期约定

> 仅记录 AGENTS/ADR 之外仍需跨会话保留的事实；架构与门禁规则以 `.ai/source/AGENTS.root.md`、模块册、ADR 为准。

## 用户协作偏好（传哲）
- 称呼「传哲」；直给、少填充，主动指出事实错误、矛盾和未验证假设。
- **全量门禁、合并快检、真机测试都必须先询问**，得到明确同意后执行。
- 交付必须报告：具体命令、通过/失败数字、跳过项、剩余风险；未跑门禁不能称“验收完成”。
- 估算标 `[E]`，推测标 `hypothesis`；只有实测可作验收阈值，引用基线必须带机器环境。
- 计数埋点绑定真实效果完成，不绑定代码路径到达；成功计数放在命令缓冲完成且无错后，并有 failureCount 防伪绿。
- **（2026-10-10 新增，ADR-0034）不急于求成**：要耐心、逐步推进、稳扎稳打；功能点要做全做透，不能模仿个形状就算完；方案必须全局考虑。批次可并行（写集不相交），但**一批未验收不得在其上叠加下一批**。
- **（2026-10-10 新增，ADR-0034）严禁临时方案**：任何“先 XX 顶着 / 以后替换 / 本期先用 Swift 写”一律不采用；被下层阻塞就排队等地基。已是第二次踩「两套渲染路径」的坑（ADR-0014 代价），不得再犯。
- **（2026-10-10 新增，ADR-0034）交付节奏固化**：写代码 → 出真机问卷 → 传哲实测给表现 → 集成机纠偏登记。**问卷未回收不得标记完成**（呼应 P99：门禁绿 ≠ 功能可用）。
- **Mac 与 iOS 分端形态**（ADR-0034 §6）：不再把 iOS 视图塞进 Mac 窗口。iOS 走移动端单焦点抽屉范式，macOS 走桌面专业范式（常驻属性面板 + 顶部工具栏 + 菜单命令 + 多窗口 + 快捷键全表 + 拖拽导入）。两端只共享 ViewModel 与 Command 链路，UI/交互/菜单/快捷键不共享。
- **决策必须署名带时间戳**：什么模型、什么时间、做了什么决策、写了什么代码、传哲拍板了什么、做了什么调整 —— 全部登记 `docs/reports/LEDGER-*.md`（append-only），不留在对话里。

## 当前协作与工程事实
- 本机是集成机：全局册单写者、唯一发号器、唯一可信全量门禁/真机口径；其他设备按模块线开发。
- **（2026-10-11 新增）多 agent 并行协作是常态**：传哲会同时开多个 agent 在**同一工作区**
  跑不同模块线（如 2026-10-11 我跑 INFRA-022 整改、另一 agent 跑 DEPS-012 FFmpeg 集成）。
  规则：① **写集不相交是硬约束**，撞车的文件先核再动，不抢；② 发现对方改动后
  **不碰、不顺手提交**，只登记事实并上报；③ 交接要写到**文件 + 行号级**
  （谁改了哪几行、是否行区间重叠），只说「别打架」不可执行；④ **不用 `git pull --rebase`**
  （会动别人未推送的本地提交）；⑤ 自己的门禁数字**不能当对方的回归基线**
  （各自跑出来的版本不同）。交叉点核查命令：`git show --name-only <c>` 逐个核自己的提交里
  有没有混进对方文件。
- **可追溯三件套（ADR-0034，2026-10-10 起必用）**：`docs/reports/LEDGER-W42.md`（决策与实现台账，append-only，含模型/时间/写集/验证/拍板）、`docs/reviews/TEMPLATE-真机问卷.md`（交付必附）、`docs/reviews/QUESTIONNAIRE-<批号>-<主题>.md`（实例）。
- **编辑功能对齐路线**：`RESEARCH-010` §5 的 B0~B8 批次。地基先行：B0 = RENDER-001 最小 RenderGraph + MODEL-003 属性系统 + SHADER-001 Portable shader，这是红线 #9（预览与导出共用 RenderGraph）的必然要求；B4 才是第一个可见出口（导出闭环）。当前全部未开工。
- 热点文件（`cq_sdk.h`、CMake、podspec、Podfile、project.yml、构建脚本、真源、CI）及 ABI/依赖变更须由集成机处理。
- 收工同步顺序：模块册 → 必要 ADR → TASK → HANDOFF → pitfalls → baselines → 当日日志 → 本文件（仅新增长期规则时）。
- 构建产物不得入库；临时编译统一放根 `/build/`。SPM 必须指定 `--scratch-path "$ROOT/build/spm/<包>"`。
- **壳工程已冻结入库（ADR-0037，2026-10-11，XcodeGen 退役）**：`ChuanqiCut.xcodeproj`/`.xcworkspace` 是手工源文件——Xcode 可视化改动即真源、直接提交，禁止任何工具重新生成。依赖变更只跑 `bundle exec pod install`；**podspec 增删文件后必须重跑**（Pods.xcodeproj 是文件清单快照，旧清单会编已改名/已删除的文件——2026-10-11 实踩：旧清单编已不存在的 pal_frame_provider.cpp）。
- iOS App 构建只认 `ChuanqiCutApp` scheme + `iphoneos` generic device；模拟器 MetalFX 解析失败是 SDK 限制，不改代码规避。
- macOS App 构建只认 `ChuanqiCutMacApp` scheme，命令行必须带 `-arch x86_64 ONLY_ACTIVE_ARCH=YES`（本机 Intel；默认 universal 会编 arm64，而 SDK 26.5 无该 slice 的预编译 Swift 模块 → 一片 `Unable to resolve module dependency`，P96）。报双壳结论时写明架构。
- 分发静态库默认关闭 LTO，打包后必须消费者侧链接冒烟；Swift 绑定验收含 `swift test` 与 `run_smoke.sh`。
- 系统框架清单以 `ChuanqiCut.podspec` 为单一真源，需同步 Package.swift 与 run_smoke.sh。

## 关键实现契约
- Timeline 变更只走 CommandHistory；提交后 `refreshFromKernel()`；拖拽结束只提交一条命令。
- 预览渲染只在 PreviewPump 线程；主线程 Request + Lock/blit/Unlock，持锁期间不 Request，不 waitUntilCompleted。
- 异步等待必须同时有超时和独立内存上界；回调先交付数据再登记完成；Platform 逐帧入口自带 `@autoreleasepool`。
- Camera：检测坐标左上原点归一化；Vision 翻转只在转换层一次；采集/渲染/检测三队列；人像能力无算法即直通，不退化为全画面滤镜。
- CIContext 显式 gamma sRGB；区域三态：faces=nil 全画面兜底、空数组直通、非空区域蒙版。
- 日志按 Level/Stage/Workflow；偏离正轨一律 Warn 且 Release 可见；慢调用统一 `CQ_SLOW_CALL_WF`。

## 命名：`PAL` 已统一改名为 `Platform`（ADR-0035，2026-10-11 执行完毕）
- 目录 `engine/core/cq/platform/`（契约）+ `engine/platform/`（实现）+ `tools/platform/`；
  全仓不再有 `pal` / `PAL`（**历史卡号 `PALA-xxx` / `PALD-xxx` 除外，有意保留，改了会断链**）。
- 代码标识符一律用新名：`PlatformPtr<T>`、`IPlatformResource`、`CQ_PLATFORM_*_H_`、
  `cq_platform_apple`（CMake target）、`cq_tests_platform_apple_*`（test target）、
  `platform_apple_*`（ctest 名）。
- **动 platform 模块前先读这三条红线**：
  ① 门禁脚本 `tools/platform/check_platform_headers.py` 的 `CONTRACT_DIR_NAMES` **白名单写死目录名**，
  目录再改不同步 → **静默漏扫**（P95 复发，本次踩过）；
  ② ctest 名随 target 改，**文档里的 `ctest -R <name>` 必须同步**（编译抓不到，只有跑测试才炸）；
  ③ podspec 路径不走 CMake 链路，**编译过 ≠ pod install 过**。
- **全仓机械替换必须显式排除 append-only 文件**（P103）：`docs/reports/LEDGER-*.md`、
  `.workbuddy/memory/YYYY-MM-DD.md`、`.zcode/plans/*`。替换后**专门复核 `→` 形式的行**是否仍成立
  （`A → A` 式破坏 grep 计数看不出来）。

## 目录与 Pod 边界（ADR-0033，2026-10-09 定案）
- 内核头与实现**共置**在 `engine/core/cq/<功能>/`；Apple Platform 分 `engine/platform/apple/{base,gfx,media}`。CMake include root = `engine/core`，`#include "cq/..."` 不变。
- Engine 两个 Pod：`CChuanqiCut`（C ABI + C++20 + Platform，**唯一 public 头 `core/cq/cq_sdk.h`**）+ `ChuanqiCutEngine`（Swift adapter，消费端仍 `import ChuanqiCutEngine`）。**两个本地 spec 必须都在 Podfile 显式 `:path`**。
- 已废弃：主工程头文件 folder reference、`pods_post_install.rb` 补 PBX 引用、UI Pod 手工传播 `SWIFT_INCLUDE_PATHS`。头文件可见性只由 podspec 的 public/private 边界决定。
- XCFramework 只打包 `cq_sdk.h`（staging 目录），不要把整个 `core/cq` 当 public headers。
- 门禁脚本凡「按目录递归」的（如 `check_platform_headers.py`），扫描范围必须显式写死语义；目录重构后必重跑（P95）。
- MultiCam 定则：`AVCaptureMultiCamSession` **不支持 sessionPreset**（抛 NSException，canSet* 拦不住）；其 activeFormat 还必须在 `isMultiCamSupported` 子集内（P93/P94）。相机域「选哪个」的逻辑一律做成契约层纯函数 + 单测。

## 当前工具链与编号
- 当前集成机实测：macOS 26.7.1 / Xcode 26.6 / Swift 6.3.3；cmake 4.4.3 位于 `~/.workbuddy/binaries/cmake/CMake.app`；无 Homebrew；CocoaPods 1.17.0。**CPU 是 Intel（`uname -m` = x86_64）** —— 报任何构建/性能结论都要带上这个前提。
- 最近一次全量门禁（2026-10-08）：PASS 14 / FAIL 0；core Debug/Release 各 46/46，bindings 26，Player 52，Camera 57，Import 16，Editor 57，golden 21。
- 最近一次 core 编译 + ctest（2026-10-11，PAL→Platform 改名后）：`build_core.sh --platform=apple --config=Debug --test` → **EXIT 0，46/46 通过**（113.32s），0 error / 0 warning。**全量门禁 `run_gate.sh` 尚未重跑**。
- 编号取号前必须 `git fetch` 核远端；截至 2026-10-11 09:40：ADR 下一号 **0037**（0035 我用、0036 被 DEPS 线同日取用），INFRA 卡下一号 025（024 已用），pitfalls 下一号 **P104**（P98/P99/P100/P101/P102/P103 已占）。**并发时更要现取现核** —— 两个 agent 同日取号极易撞。

## 未决事项
- FFmpeg LGPL v2.1+ 链接处置待法务拍板，不由 AI 代决。
- PERF-001 尚未建立正式性能基线；Intel Mac 无 ANE/ProRes 硬编，不得用其数字作产品阈值。
- 2026-10-08 以前 baselines 中“本机实测”仍需逐条归属真实机器 A/B/C。
