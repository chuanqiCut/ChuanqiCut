# 已知坑与排障步骤

> 每条必须含：**日期 / 来源 / 适用范围 / 验证状态**。未验证的推测标注 `hypothesis`。
> 只有经过实际遇到并解决的才写入这里。不要记录一次性任务状态。

## 模板

```markdown
### <简述>
- 现象：
- 根因：
- 影响范围：
- 排障步骤：
- 修复：
- 防复发规则：
- 日期 / 来源 / 验证状态：
```

---

## 已识别但未实测的风险（Phase 0 需验证后转为正式条目）

| # | 风险 | 来源 | 状态 | 验证任务 |
|---|---|---|---|---|
| R1 | CoreML 模型不一定跑在 ANE 上，由运行时决定 | RESEARCH-001 F8 | `hypothesis` | `AI-002` |
| R2 | MediaPipe landmark 输出不是可直接使用的屏幕坐标，需自实现后处理 | RESEARCH-001 F8 | `hypothesis` | `AI-011` |
| R3 | GLES 3.1 compute shader 在部分国产 ROM 上有缺陷 | ARCH-003 §7 | `hypothesis` | `PALD-001` + 设备矩阵 |
| R4 | `AHardwareBuffer → EGLImage` 部分机型失效 | ARCH-004 §4.2 | `hypothesis` | `PALD-003` |
| R5 | Apple Clang 16.0.0 + `-ffast-math` 使 signalsmith-stretch 生成错误 SIMD 代码 | 上游 README | `verified-by-upstream` | `DEPS-020` 构建配置规避 |
| R6 | signalsmith-stretch 在 0.75x–1.5x 之外时间拉伸质量下降 | 上游 README | `verified-by-upstream` | `AUDIO-002` 需评估 |
| R7 | MediaCodec 硬解实例数受限，多轨时可能不够用 | ARCH-004 §4.2 | `hypothesis` | `MEDIA-012` |
| R8 | `coremltools` 对 `.tflite` 的输入支持不在官方文档主列的 source framework 之列（主列：PyTorch / TF2 SavedModel / TF1 Frozen Graph / ONNX），转换可行性与数值一致性未经实测 | 官方文档核对 | `hypothesis` | `AI-013`（不过则切路径 B：LiteRT + CoreML delegate） |
| R9 | LiteRT CoreML delegate 官方仅支持 FP32 / FP16 浮点模型，且默认只在 A12+ 设备创建，量化模型与老设备会回退 CPU | 官方文档 | `verified-by-upstream` | `AI-002` / 路径 B 选型 |

---

## 已实测并解决的坑

### P94 · MultiCam 下 activeFormat 不只是"不能设 preset"，还必须是 multiCamSupported 子集
**日期**：2026-10-09　**来源**：P93 修复轮的连带核对（iPhoneOS 26.5 SDK `AVCaptureDevice.h` 原文）　**验证状态**：已修 + 单测覆盖（选择器纯函数，Camera 62/62），**真机复验待传哲**

- **现象**：P93 把 multiCam 路径改成"逐设备选 activeFormat"后，初版只按**帧率区间**筛 format。
  查头文件发现漏了第二条硬约束：`AVCaptureDeviceFormat.isMultiCamSupported` ——
  MultiCamSession 下 device.activeFormat **只能落在 multiCamSupported 的子集里**
  （"This limited subset of capture formats are known to run sustainably in a multi camera capture scenario"）。
  漏掉它不会立刻崩，但会话起不来/走样，且**在 macOS 与 SPM 侧完全测不到**（相机实现层 iOS 专属）。
- **为什么"补一个条件"不够**：这次事故的模式是「约束记在脑子里，代码里没地方表达」。
  `AVCaptureDevice.formats` 的真实选择在 Impl 层，SPM 测试宿主编不到 → 约束零测试覆盖。
- **修复形状**：把选择规则抽成契约层纯函数 `CameraFormatSelector.bestIndex(...)`
  （候选结构 + target + fps + multiCam 四个入参），Impl 层只负责把 `AVCaptureDevice.Format`
  映射成候选、把结果下标还原成 format。约束从此有单测（`CameraFormatSelectorTests` 5 例：
  分辨率最近 / 帧率不覆盖拒绝 / multiCam 只认支持子集 / 单摄不受该约束 / 空候选 nil）。
- **规约**：① 相机域里**凡是"选哪个"的逻辑**（format / 设备 / 帧率），一律做成契约层纯函数 + 单测，
  不要在 Impl 层用一串 `filter/min` 就地写；② 引用 Apple API 约束时**先读 SDK 头文件原文**，
  不要凭记忆补条件（P48/P83/P93 同族，第 7 次）。

### P95 · 头文件与实现共置后，按目录递归的门禁会把"内部统计头"一起判违规（扫描范围语义漂移）
**日期**：2026-10-09　**来源**：ADR-0033 / INFRA-024 目录迁移后 `platform_header_gate` 由绿转红　**验证状态**：已修（ctest 46/46，`platform_header_gate` 复跑 0 违规）

- **现象**：`tools/platform/check_platform_headers.py` 扫描根由 `core/include/cq` 改为 `engine/core/cq` 后，
  `platform_header_gate` 报 8 处 `double_type`，全部落在 `cq/ai/feature_report.h` 与 `cq/ai/llm_client.h`
  （人脸占比 / 响度 / temperature 这类**统计类浮点**，本来就允许）。
- **根因（不是代码坏了，是语义漂移）**：旧扫描根 `include/cq` **只包含对外契约头**，
  "递归全部目录"那时恰好等于"扫契约"；共置后同一棵树里混进了内部头，
  "递归全部"不再等于"扫契约"——门禁语义被目录结构悄悄改掉了。
- **修复**：脚本加**契约目录白名单**（platform/gfx/media/preview/session/model/command/audio）
  + 保留 base/ 与新增 ai/ 排除，扫 38 头 0 违规。
- **规约**：① 门禁脚本的"扫描范围"必须显式写死语义（契约 vs 全部），**不能靠目录布局隐含**；
  ② 目录结构类重构后，凡"按目录递归"的脚本（门禁 / 生成器 / 引用清扫）都要重跑一遍对表，
  否则是"结构改了、语义也跟着改了但没人发现"的静默缺口（与 P27「mv 后必须 grep 引用」同源）。

### P96 · Intel 机上命令行编 macOS 壳默认 universal 会挂（SDK 26.5 无 arm64 macOS 预编译模块）
**日期**：2026-10-09　**来源**：INFRA-024 双壳验证（本机 `uname -m` = x86_64，macOS 26.7.1 / Xcode 26.6）　**验证状态**：已定位，`-arch x86_64` 下双壳均 BUILD SUCCEEDED

- **现象**：`xcodebuild -scheme ChuanqiCutMacApp -sdk macosx build` 报一串
  `error: Unable to resolve module dependency: 'Accessibility' / 'simd' / 'Darwin' / '_Builtin_float'`，
  随后级联出 `Module map file '.../ChuanqiCutEditor.modulemap' not found`；**iOS 壳同一轮却是绿的**。
- **根因（环境，不是代码回归）**：命令行 `xcodebuild` 默认 `ONLY_ACTIVE_ARCH=NO` → 编
  arm64 + x86_64 两个 slice；而 SDK 26.5 的 macOS 预编译 Swift 模块目录
  `.../swift/macosx/prebuilt-modules/26.5/` 只有 `arm64e-apple-macos` 与 `x86_64-apple-macos`
  （**没有纯 arm64**），Intel 机上 arm64 slice 因此解析不了系统模块。
  Xcode IDE 的 Debug 构建默认 `ONLY_ACTIVE_ARCH=YES`，所以在 IDE 里一直是绿的、只有命令行会炸。
- **修复/规避**：命令行编 mac 壳显式 `-arch x86_64 ONLY_ACTIVE_ARCH=YES`
  （或 `-destination 'platform=macOS,arch=x86_64'`）。**不要**为此改代码或改 SDK 设置。
- **规约**：① 报"双壳构建"结论时必须写清**架构与 ONLY_ACTIVE_ARCH**，否则 Intel 机的
  "mac 红"会被误判成回归；② 本机（Intel）产出的任何性能/能力数字都不得当产品阈值
  （与 MEMORY 里"无 ANE/ProRes 硬编"同一条纪律）。

### P97 · `core/cq` 下存在 basename 同名头 → Pods 工程 `Skipping duplicate build file` 是无害噪音
**日期**：2026-10-09　**来源**：INFRA-024 双壳构建警告核查　**验证状态**：已确认无害（两文件均正常落位）

- **现象**：构建 iOS/mac 壳均出现
  `warning: Skipping duplicate build file in Copy Headers build phase: .../engine/core/cq/platform/gfx.h`。
- **真因**：`core/cq/gfx/gfx.h`（gfx 功能域）与 `core/cq/platform/gfx.h`（Platform 契约域）basename 相同，
  Pods 工程的 Copy Headers 阶段按 basename 判重，跳过后一个登记。
  **与 podspec 是否显式写 `private_header_files` 无关**（删与不删，警告都在）。
- **实测结论**：`Pods/Headers/Private/CChuanqiCut/` 下两个文件各自 symlink 到
  `gfx/gfx.h` 与 `platform/gfx.h`，**不互相覆盖、不影响编译**（C++ 侧一律用全路径
  `#include "cq/gfx/gfx.h"` / `"cq/platform/gfx.h"`，无歧义；唯一 public 头仍是 `cq_sdk.h`）。
- **规约**：看到这条警告**不要**去改 podspec 或乱改头文件名消警告；
  同理，删掉 `private_header_files` 也消不掉它（删它只是去掉与 `source_files` 的重复声明）。

### P1 · XCFramework 合并报 `Unknown header: 0xb17c0de`（真因是 LTO，不是 ENABLE_BITCODE）
- 现象：`tools/build/build_core_apple.sh --config=Release` 能编出三个切片，但
  `xcodebuild -create-xcframework` 失败：
  `unable to find any architecture information in the binary at ios-device/ChuanqiCut.a: Unknown header: 0xb17c0de`
- 根因：`cmake/CompileOptions.cmake` 开了 `CMAKE_INTERPROCEDURAL_OPTIMIZATION_RELEASE=ON`。
  Release + LTO 时 clang 产出 **bitcode-only 目标文件**（头部 magic `0x0b17c0de`，紧跟
  `BC\xc0\xde` 的 LLVM IR），**不是 Mach-O**。`xcodebuild` 因此读不到任何架构信息。
  **与 ENABLE_BITCODE / `-fembed-bitcode` 完全无关。**
- 影响范围：所有 Release 配置的 Apple 静态库打包；Debug 不受影响（不开 IPO）。
- 排障步骤：
  1. `xxd -l 32 <.a>` 看头部 —— 是 `!<arch>` / `cafebabe`，说明 ar/fat 外壳正常，问题在内部成员
  2. `xcrun otool -l <.a>` —— 若每个成员输出 `is an LLVM bit-code file`，即确认为 LTO bitcode
  3. `ar -x <.a>` 抽单个 `.o`，`xxd -l 8` 看是 `dec0170b`(bitcode) 还是 `cffaedfe`(Mach-O 64)
  4. 反查来源：`grep -rn INTERPROCEDURAL cmake/`
- 修复：给项目加显式开关 `option(CQ_ENABLE_LTO_RELEASE ... ON)`，打包脚本传 `-DCQ_ENABLE_LTO_RELEASE=OFF`。
  Release 的 `-O3` 保留，只丢跨模块内联。
- 防复发规则：
  - **不能用 `-DCMAKE_INTERPROCEDURAL_OPTIMIZATION_RELEASE=OFF` 覆盖**——原写法是
    `set(... CACHE BOOL ... FORCE)`，`FORCE` 每次 configure 都会写回 ON，命令行 `-D` **静默失效**
    （实测：传了 OFF，`CMakeCache.txt` 里仍是 `ON`，`.o` 还是 bitcode，且产物该厂商数与之前完全一致）。
    凡遇到 `FORCE` 的 cache 变量，必须走项目自己的 option 开关。
  - 合并前加预检断言（`otool -l | grep 'is an LLVM bit-code file'`），把隐晦报错提前拦成明确根因。
- 副作用提醒：分发的静态库带 LTO bitcode 会强制消费者 linker 版本匹配，属分发陷阱，
  即使将来 `xcodebuild` 支持了也不建议在分发产物上开 LTO。
- 日期 / 来源 / 验证状态：2026-09-29 / HANDOFF-002 遗留问题 / **verified**（三切片 `.o` 头已从
  `dec0170b` 变为 `cffaedfe`，`file` 报 `Mach-O 64-bit object arm64`，xcframework 三个切片生成成功）

### P2 · 冻结接口只有头文件、实现缺失，编译期 `static_assert` 会把它掩盖成"全绿"
- 现象：`core/include/cq/platform/capabilities.h` 冻结的 `SetCapabilitiesBackend` /
  `QueryCapability` **长期只有声明、没有定义**。CTest 一直 22/22 全绿。
- 根因：全仓库唯一引用是 `tests/unit/platform/platform_headers_compile.cpp` 里的 `static_assert`
  （校验返回类型）。**`static_assert` 是编译期检查、不链接** —— 只要声明对就能过，
  实现存不存在它管不着。
- 影响范围：任何「接口冻结」类任务都可能这样静默断掉。这是 CORE-006 当时
  「编译验证 7/7 全绿但接口是断的」的**同型复发**，只是触发机制换成了 static_assert。
- 排障步骤：对可疑符号 `grep -rn <符号>`，若**只出现在头文件与 static_assert 里**、
  没有任何 `.cpp/.mm` 定义，即为断接口。
- 修复：CORE-007 补上实现（`core/src/platform/capabilities.cpp` + `platform/apple/capabilities.mm`）。
- 防复发规则：**冻结接口后必须补一个「链接并运行」的最小用例**，
  `static_assert` / 头文件编译验证**不能**作为"接口可用"的证据。
  本轮已落的样例：`tests/unit/platform/test_capabilities.cpp`（注入后端后真查询）。
- 日期 / 来源 / 验证状态：2026-09-29 / CORE-007 / **verified**（24/24，其中 2 个新用例
  链接并运行了这两个函数；Apple 后端查询结果与本机已知硬件事实交叉吻合）

### P3 · 静态门禁硬编码「要扫哪些目录」，新增目录会被静默漏掉
- 现象：`tools/platform/check_platform_headers.py` 原先写死 `scan_dirs = [cq/"platform", cq/"gfx", cq/"media"]`。
  CORE-008 新增的 `core/include/cq/session/` **不在列表里**，两个新头文件完全不受
  「零平台类型 / 零 FFmpeg 类型 / 禁 throw / 禁裸 double」约束。
- 危害（这是它阴险的地方）：**不报错、CTest 全绿、`git status` 也看不出来**。
  门禁看着在跑（16 个头、0 violation），实际覆盖面在悄悄缩水。
  同型问题：`.gitignore` 里裸 `build/` 把 `tools/build/` 一并忽略，导致三个构建脚本
  自建库以来从未入库（2026-09-29 修，见 MEMORY.md「产物打包约定」）。
- 排障步骤：凡是脚本里出现**目录白名单**，先问一句「下次新增目录它会自己更新吗？」
- 修复：改为 `os.walk(cq_inc)` **递归遍历全部目录**，用 `EXCLUDED_DIR_NAMES={"base"}`
  只做例外。
  ⚠️ 为什么必须排除 base：一度试过直接全扫，`base/time.h` 的显式 `ToSeconds()`
  会命中 double 规则。但 CORE-001 禁止的是**隐式** `operator double`，
  显式命名的转换方法是允许的 —— 所以不是门禁该放宽，是扫描范围该精确。
- 防复发规则：**目录白名单要等价于"自动 discovered + 显式例外"，不能是"手工枚举"**。
  例外的理由必须写成注释（如此处的 base/time.h），否则后人不敢动也不知道为什么。
- 日期 / 来源 / 验证状态：2026-09-29 / CORE-008 / **verified**（扫描数 16 → 19，
  新增两个 session 头自动纳入，仍 0 violation）

### P5 · 静态库名缺 `lib` 前缀 → 所有 `-lNAME` 工具链静默失效
- 现象：SwiftPM `swift test` 链接报 `ld: library 'ChuanqiCut' not found`；
  `swiftc -L <dir> -lChuanqiCut` 同样找不到。但 `swift build` **全绿**。
- 真因：`-lNAME` 只匹配 `libNAME.a` / `libNAME.dylib`。本项目打包出的库叫
  `ChuanqiCut.a`（Xcode 工程里直接拖文件所以没暴露问题），缺 `lib` 前缀。
- 危害：`swift build` 对 library target **只编译不链接**，所以这一步是绿的；
  要等 `swift test` 链接可执行宿主时才炸。又一次「绿灯 ≠ 可用」。
- 修复：`tools/build/build_core_apple.sh` 输出改为 `libChuanqiCut.a`。
- 防复发规则：**交付给外部工具链的静态库一律用 `lib<Name>.a` 命名**。
  判断某个 `-l` 找不到时，先 `ls` 库文件是不是 lib 开头 —— 不要去调 -L 路径。
- 日期 / 来源 / 验证状态：2026-09-30 / BIND-002 / **verified**（改名后
  `swift test` 7/7 通过，`run_smoke.sh` PASSED）

### P6 · SwiftPM 集成 C 静态库 XCFramework 的三道坎
1. **C target 必须有源文件**：只有头文件 + modulemap 时 SPM 不生成 module，
   消费方报 `no such module`。加一个 `shim.c` 即可。
2. **binaryTarget 的静态库不会自动链接**：需在依赖它的 target 上写
   `linkerSettings: [.linkedLibrary("ChuanqiCut")]`。
3. **本机 SPM 沙箱**：要写 `~/.swiftpm/security`，被拦时报
   `sandbox-exec: sandbox_apply: Operation not permitted`；加 `--disable-sandbox`。
   另：`swiftc` 默认 target 是 macOS 15.0，链接 15.4 部署目标的库会对每个 .o
   报 "built for newer macOS version"，用 `-target <arch>-apple-macosx15.4` 消除。
- 日期 / 来源 / 验证状态：2026-09-30 / BIND-002 / **verified**

### P4 · CMake `LANGUAGES` 没启用 C → `.c` 源文件被**静默忽略**
- 现象：BIND-001 新增 `tests/unit/abi/test_c_abi.c`（用于机器校验 cq_sdk.h 是纯 C），
  根 `CMakeLists.txt` 写的是 `project(... LANGUAGES CXX)`。构建日志里
  **没有任何 `Building C object` 行**，直接 `Linking CXX executable`，
  报 `Undefined symbols: _main`。
- 根因：CMake 未启用 C 语言时，**不会编译** `.c` 源文件，也**不报错**——
  它只是把该文件排除在编译集之外，直到链接期才以"缺 main"的形式暴露。
- 危害：这道校验会**假绿**。如果没有链接步骤（比如只做编译检查的 target），
  它会彻底静默，让人以为"纯 C 校验一直在跑"，实际什么都没编译。
- 修复：`LANGUAGES C CXX`。
- 防复发规则：新增一种语言的源文件（`.c` / `.m` / `.mm` / `.S`）时，先确认
  `project(LANGUAGES ...)` 里有它。**判据是构建日志里出现对应的
  `Building <LANG> object` 行**，不是"没报错"。
- 归类：这是本项目**第三次**同类静默缺口 ——
  ① `.gitignore` 裸 `build/` 忽略 `tools/build/`；
  ② 门禁硬编码目录列表漏掉 `session/`；
  ③ 本次 `LANGUAGES CXX` 漏掉 `.c`。
  共同模式：**"配置没覆盖新东西"不报错、不显示，纯靠人记得加。**
- 日期 / 来源 / 验证状态：2026-09-29 / BIND-001 / **verified**
  （改后日志出现 C 编译步骤，27/27 通过；并反向验证 —— 往 cq_sdk.h 插入
  `std::string` 后 C TU 立即 `fatal error: 'string' file not found`）

### P7 · SPM 本地包身份是**目录名**，不是 Package.swift 里的 `name`
- 现象：UIA-002 在 SharedUI 包里写
  `.product(name: "ChuanqiCut", package: "ChuanqiCut")` 引用
  `bindings/swift` 本地包，报
  `unknown package 'ChuanqiCut' in dependencies of target 'SharedUI';
  valid packages are: 'swift' (at .../bindings/swift)`。
- 根因：`.package(path:)` 的身份取**路径末段目录名**（`bindings/swift` →
  `"swift"`），与包内 `Package.swift` 的 `name: "ChuanqiCut"` 无关。
  且 tools-version ≥ 5.2 后 `.product(name:package:)` 的 `package` 参数
  **必填**（省略写法在 5.2+ 直接不可用）。
- 危害：报错信息会列出"valid packages"，照着写目录名即可解；但若包目录名
  与产品名一致就不会暴露此坑，一旦有人重命名目录就会突然断链。
- 修复：`.product(name: "ChuanqiCut", package: "swift")`。
- 防复发规则：本地包引用一律以**目录名**为准写 `package:` 参数；给绑定包
  目录改名 = 破坏性变更，须全仓同步（现落点 `ui/SharedUI`，INFRA-031 上提）。
- 日期 / 来源 / 验证状态：2026-10-01 / UIA-002 / **verified**
  （改后 `swift build` + `swift test` 4/4 通过）

### P8 · `StateObject(wrappedValue:)` 是非 throwing 自动闭包，包不住 `try`
- 现象：UIA-002 App 入口写
  `do { _editor = StateObject(wrappedValue: try EditorViewModel()) } catch { fatalError(...) }`，
  编译报 `call can throw, but it is executed in a non-throwing autoclosure`，
  且 catch 块被警告 unreachable。
- 根因：`StateObject.init(wrappedValue:)` 的参数是**非 throwing autoclosure**，
  `try` 无法穿越；错误发生在 App init（`@MainActor` 上下文本可用），纯属
  API 形态问题，与并发无关。
- 修复：先把可抛调用落到局部变量，再包进 StateObject：
  `let vm = try EditorViewModel(); _editor = StateObject(wrappedValue: vm)`。
- 防复发规则：所有 `*State(wrappedValue:)`（StateObject/ObservedObject/
  State 等）都一样——**自动闭包不抛错**，可抛构造一律"先建值、后包装"。
- 日期 / 来源 / 验证状态：2026-10-01 / UIA-002 / **verified**
  （改后 macOS target BUILD SUCCEEDED，真机启动冒烟 4s 存活）

---

### P9 · pod 声明 `time.h` 同名头 → headermap 按基名劫持系统 `<time.h>`
- 现象：pod 化 ChuanqiCut（INFRA-009）后 macOS 构建报
  `core/include/cq/base/time.h:31: 'cstdint' file not found`，且
  CoreFoundation/Foundation/Darwin 等系统模块全体级联
  `could not build module`。错误链显示 `CoreFoundation.h:37: #include <time.h>`
  落到了**我们自己的 C++ 头**上。
- 根因：CocoaPods 为 target 生成 headermap（hmap），把**所有声明过的头按文件
  基名**映射到路径（public/private/project 三档都进 own-target-headers.hmap）。
  `core/include/cq/base/time.h` 一旦进 `source_files` 或任何 `*_header_files`，
  pod 内所有编译（含 Swift 的 clang 模块构建）的 `#include <time.h>` 就先命中
  它 → ObjC module 上下文里没有 C++ 标准库 → `<cstdint>` 不可见 → 崩。
  `-I` 搜索路径**没有**这个问题：只按路径前缀匹配，`#include <time.h>` 不会
  命中 `cq/base/` 子目录里的同名文件。
- 修复：Source subspec 的 `source_files` 只声明 `*.cpp` / `*.mm`，**头文件一律
  不声明**（不进任何 build phase），C++ 编译靠 `HEADER_SEARCH_PATHS` 的 -I 发现。
- 防复发规则：给 pod 加任何名字与系统头相同的头（time/log/string/…）之前，
  确认它**没有被声明**进 podspec 的任何文件集；C++ 库 pod 的头默认全部走
  搜索路径，不走 CocoaPods 头管理。
- 日期 / 来源 / 验证状态：2026-10-02 / INFRA-009 / **verified**
  （移除声明后 macOS BUILD SUCCEEDED）

### P10 · 在含 Swift 源码的 podspec 上设 `s.module_map` → 消费方 `import` 断裂
- 现象：2026-09-30 的 podspec 在根 spec 设了
  `s.module_map = .../CChuanqiCut/include/module.modulemap`（内容是
  `module CChuanqiCut`），当时未验证。INFRA-009 实测发现：CocoaPods 会把
  自定义 modulemap **当作 pod 自身的 module**（残留产物
  `ChuanqiCut-iOS.modulemap` 即 `module CChuanqiCut`），App 侧
  `import ChuanqiCut` 将无 module 可导。
- 根因：一个 pod target 只有一个 modulemap；`s.module_map` 是整体替换不是
  追加。Swift 源码 `import CChuanqiCut` 与消费方 `import ChuanqiCut` 需要
  **两个** module，一个 podspec 的 module_map 只能满足其一。
- 修复：不设 `s.module_map`（让 CocoaPods 生成名为 ChuanqiCut 的 pod module），
  CChuanqiCut module 经 `pod_target_xcconfig.SWIFT_INCLUDE_PATHS` 指向与 SPM
  共用的 `bindings/swift/Sources/CChuanqiCut/include/` 暴露给 Swift 编译期。
- 防复发规则：pod 内需要「C module + Swift 包装 module」双 module 时，C module
  一律走 SWIFT_INCLUDE_PATHS + 独立 modulemap 文件，不碰 `s.module_map`。
- 日期 / 来源 / 验证状态：2026-10-02 / INFRA-009 / **verified**

### P11 · pod 的 Swift 公开 API 引用 C module 类型时，**消费方**也要能看到该 module
- 现象：ChuanqiCut pod 编译通过后，SharedUI（pod 消费方）报
  `AppEntry.swift:14: missing required module 'CChuanqiCut'`；App target
  `import ChuanqiCut` 同理会报。
- 根因：ChuanqiCut 的 Swift 公开 API 签名里含 `CChuanqiCut` 的 C 类型，
  Swift 在消费方 import 该 module 时要求其依赖的 clang module 同样可见。
  `pod_target_xcconfig` 只作用于 pod 自身；`user_target_xcconfig` 只作用于
  App target，**两者互不覆盖对方的覆盖面**。
- 修复：三处显式声明同一路径——ChuanqiCut.podspec 的
  `pod_target_xcconfig`（自身编译）+ `user_target_xcconfig`（App target，
  锚定 `$(SRCROOT)/../../../`）；SharedUI.podspec 的
  `pod_target_xcconfig`（pod 消费方，锚定 `$(PODS_TARGET_SRCROOT)/../../../../`）。
- 防复发规则：SDK pod 的公开 API 触及非 umbrella C module 时，必须同时给
  pod 自身、pod 消费方、App target 三类编译者提供 SWIFT_INCLUDE_PATHS；
  新增 pod 消费方时同步检查。
- 日期 / 来源 / 验证状态：2026-10-02 / INFRA-009 / **verified**
  （SharedUI + MacApp 改后 BUILD SUCCEEDED）

### P12 · 无 lock 时 bundler 解析到 CFPropertyList 3.0.9 → Ruby 3.4 不兼容
- 现象：新建 Gemfile（无 Gemfile.lock）跑 `bundle install`，报
  `CFPropertyList-3.0.9 requires ruby version < 3.2, which is incompatible
  with the current version, 3.4.11`。
- 根因：镜像上 CFPropertyList 最新版 3.0.9 声明了 `required_ruby_version < 3.2`；
  之前根目录 Gemfile.lock 钉住的 3.0.8 无此约束。lock 一旦缺席，bundler 就
  重新解析"最新可用集"，锁文件的保护即刻失效。
- 修复：从 git HEAD 恢复已知良好的 Gemfile.lock 作为起始 lock，bundler 按
  lock 安装、不重解析。
- 防复发规则：**Gemfile.lock 必须与 Gemfile 同步入库**（INFRA-009 起
  apps/apple/{ios,mac}/ 各持一份）；新建项目目录时先复制已知 lock 再
  bundle install，不要裸解析。
- 日期 / 来源 / 验证状态：2026-10-02 / INFRA-009 / **verified**

### P13 · 平台差异分支从未编译过 = 带病潜伏；iOS 分支 opaque 类型不匹配首爆
- 现象：INFRA-009 首次对 iOS SDK 编译 SharedUI，报
  `EditorLayout.swift:53: branches have mismatching types 'some View'`
  （`iosLayout` 的 if/else 返回 verticalLayout / horizontalLayout 两个不同的
  opaque 类型）。macOS 侧一直编译绿，因为 macOS 分支走的是 `macLayout`。
- 根因：裸 `some View` 计算属性里 if/else 两分支必须是**同一个**具体类型；
  `#if os(iOS)` 分支自 UIA-002 以来从未被编译过（真机不可用即跳过 iOS 验证），
  潜伏 1 天即被首次 iOS 构建抓出。
- 修复：属性加 `@ViewBuilder`（if/else 变 `_ConditionalContent<A,B>`，两分支
  可为不同类型），行为不变。
- 防复发规则：① 平台差异分支（`#if os` / sizeClass if-else）涉及**不同布局
  类型**时一律 `@ViewBuilder`；② 「真机不可用」不等于「iOS 不验」——Swift
  侧改动至少要用 `-sdk iphoneos18.4` legacy target 模式跑一次编译
  （destination 需要 platform runtime 包，legacy `-sdk` 不需要，见
  ui-apple.md 验证节）。
- 日期 / 来源 / 验证状态：2026-10-02 / INFRA-009 / **verified**
  （改后 ChuanqiCut + SharedUI + ChuanqiCutApp arm64 全链 BUILD SUCCEEDED）

### P14 · 产出裸 opaque 句柄却没给释放途径 = core 侧必然泄漏（预览首次真实使用暴露）
- 现象：`INativeImageImporter::Import` 返回裸 `TextureHandle`（`CqTexture*`），
  而 `CqTexture` 在 core 是**不完整类型**，core 侧既不能 `delete` 也不能
  `Destroy()`。唯一能释放的是 Apple 内部辅助 `cq::apple::DestroyTexture`，
  但 core 调它就引入平台依赖 → 预览每帧导入一张纹理，**每帧泄漏一张**
  （还额外锁住解码帧的 IOSurface）。
- 根因：接口设计时只考虑了「产出」，没考虑「谁回收」。这与 P2 同源——
  **头文件能编译、接口能跑通 ≠ 生命周期闭环**。
- 修复：按「谁产出谁回收」给 `INativeImageImporter` 加 `ReleaseTexture(TextureHandle)`；
  core 的 `PreviewRenderer` 逐帧释放上一帧的导入纹理。
- 防复发规则：**任何返回裸 opaque 句柄的工厂 / 导入接口，必须同时提供配对的
  释放入口**，且释放入口要在**同一抽象层**（不能只在平台内部辅助里）。
- 日期 / 来源 / 验证状态：2026-10-02 / BIND-003 子步骤 4 / **verified**
  （`preview_renderer` 用例连续 12 帧渲染，导入/释放循环无错无崩）

### P15 · 「所有权没人接」的注入式接缝：裸指针注入 + 堆对象装配 = 悬垂隐患
- 现象：`SystemFrameProvider(PlatformPtr<IMediaDemuxer>, IFrameDecoder*)` 明确
  **不接管** decoder。单测里 decoder 是栈对象没问题；但 Platform 装配时
  `VideoToolboxDecoder` 是 `new` 出来的，装配方必须自己想办法让它与 provider
  同生命周期——很容易漏，且漏了不一定立刻崩。
- 修复：给 `SystemFrameProvider` 加 `AdoptDecoder(unique_ptr<IFrameDecoder>)`，
  并给 `CreateSystemFrameProvider` 加一个接管所有权的重载；Platform 装配走重载版本。
- 防复发规则：注入式接缝若真实使用场景下被注入者是**堆对象**，就要提供
  所有权接管入口，不能只留裸指针版本。
- 日期 / 来源 / 验证状态：2026-10-02 / BIND-003 子步骤 4 / **verified**

### P16 · 静态素材下「像素正确」不能证明「取对了帧」，必须断言帧 pts
- 现象：golden `gf_1080p_h264.mp4` 是 smptebars **静态**彩条，t=0.5s 与 t=2.0s
  渲染出的像素完全相同 → 「中心像素 == 真值」这条断言**无法**区分
  「精确 seek 生效」与「反复复用同一帧」。
- 修复：`PreviewRenderer` 暴露 `LastFramePts()`（实际解码帧 pts），
  单测断言帧 pts ≈ 请求时间（容差 40ms）且两次请求的 pts 不同。
  实测 t=1.0s → pts=120000（偏差 0 ticks）。
- 防复发规则：**验收断言要能证伪**。用静态素材做时间相关验证时，必须额外断言
  一个随时间变化的量（pts / 帧序号），不能只靠像素。
- 日期 / 来源 / 验证状态：2026-10-02 / BIND-003 子步骤 4 / **verified**

### P17 · core 要调 Platform 工厂时，**必须隔离在独立 TU**（否则污染所有下游链接）
- 现象：BIND-003 子步骤 5 要做预览的 C ABI，装配需要平台能力（图形设备 /
  blit pass / 帧提供器）。但既有惯例是 **core 从不调 Platform 工厂**（全库 grep：
  调用只发生在 tests/ 与 platform/），因为 cq_core 若引用 Platform 符号，没有 Platform 后端的
  平台（当前 Android / ohos）就会链接失败。
- 解法：① 需要平台能力的实现**单独成 TU**（`platform_frame_provider.cpp` /
  `cq_sdk_preview.cpp`）；② 静态库按 **archive member 粒度**拉符号，
  只有真正引用了该 TU 符号的目标才会把它链进来 —— 隔离成立。
- 实证：`cq_tests_c_abi` 只链 `cq_core`、**不链** `cq_platform_apple`，
  仍链接通过并运行成功。若把预览代码并进 `cq_sdk.cpp`，该测试会立刻链接失败。
- 防复发规则：新增「core 调 Platform 工厂」的代码前，先确认它在**专属 TU** 里，
  并留一个不链 Platform 的目标做回归验证。
- 日期 / 来源 / 验证状态：2026-10-02 / BIND-003 子步骤 5 / **verified**

### P18 · 「必然由平台原生实现」的抽象，定义层要放对（放错会被依赖方向反噬）
- 现象：`IBlitPass` 初版定义在 `core/include/cq/gfx/`（GFX 层），实现在
  platform/apple。可它由**平台原生 shader**（MSL）实现，按红线 #6 只能落在
  platform/<platform>/；而 Platform 不能反向 include GFX 头 —— 依赖方向直接冲突。
- 修复：`IBlitPass` + `CreateBlitPass` 移到 **`platform/gfx.h`**；GFX 侧需要把
  Platform 编码器传给 Platform 层 pass，故给 `IGfxEncoder` 补 `PlatformEncoder()` 逃生口
  （与既有的 `IGfxDevice::PlatformDevice()` 同一套路）。
- 防复发规则：判断抽象该放哪层，看**实现必然落在哪**。若实现只能用平台原生
  能力（shader 源码 / 平台 SDK），抽象就该在 Platform；放上层会导致反向依赖。
- 日期 / 来源 / 验证状态：2026-10-02 / BIND-003 子步骤 5 / **verified**
  （`preview_renderer` 35 项 + `c_abi_preview` 32 项全绿）

### P19 · Platform `CreateFrameProvider` 悬空 7 天（第 5 次「只有声明无实现」）
- 现象：`platform/media.h:231` 的 `CreateFrameProvider` 自 CORE-006（2026-09-25）
  起只有声明，从未实现。上一轮我已把它标为风险但未处理。
- 同类问题已发生 5 次：`cq_build_anchor` / 能力查询实现 / BIND-001 实现 /
  `test_media_decode_apple.cpp`（在磁盘但没接入 CMake）/ 本次。
- 修复：BIND-003 子步骤 5 落地（platform/apple/frame_provider_apple.mm，
  内部用 MEDIA-020 SystemFrameProvider + PALA-011 VideoToolboxDecoder）。
- 防复发规则：**看到「只有声明」的工厂，要么实现、要么删掉**，不要留着。
  留着的下场是某天有人按声明去调，撞链接错误才被发现。
- 日期 / 来源 / 验证状态：2026-10-02 / BIND-003 子步骤 5 / **verified**

### P20 · C ABI 承诺「reinterpret 为 id<MTLTexture>」，Platform 却返回 CqTexture* 包装 —— 首个真实消费方即崩
- 现象：UIA-003 Swift 侧首次把 `cq_preview_render_frame` 的 out_texture
  reinterpret 成 MTLTexture，`objc_msgSend` 打在 C++ 对象（`CqTexture`）上，
  段错误。绑定层测试只断言句柄非空，**没有消费句柄**，所以是绿的。
- 根因：`CqRenderTarget::GetColorTexture()` 惰性创建 `CqTexture*` 包装返回，
  而 `cq_sdk.h` / `preview_renderer.h` 的契约写明「中性句柄，UI 侧 reinterpret
  为 MTLTexture」。**契约与实现不符**，且没有任何跨层测试消费过这个句柄。
- 修复：Apple 实现改为返回 `(__bridge TextureHandle)color_tex_`（裸
  MTLTexture），删除包装；`platform/gfx.h` 把「导出给 UI 显示」与「可送
  SetTexture 的包装」两种句柄语义写清（与 PALA-001 的 `Handle()` 修复同一
  「首次真实使用暴露」模式）。
- 防复发规则：**凡契约里写了 reinterpret 的句柄，必须有跨层测试真的
  reinterpret 并消费它**（本任务已补 SharedUI 像素级用例）。
- 日期 / 来源 / 验证状态：2026-10-03 / UIA-003 / **verified**（Debug 34/34 +
  SharedUI 像素级用例全绿；旧实现下该用例必崩）

### P21 · 本机（Intel Mac + AMD GPU / macOS 15.4）`MTLTexture.getBytes` 读不到 GPU 写入内容
- 现象：渲染 pass（哪怕只有 clear）写入纹理后，`getBytes` 返回**全零**
  （覆盖测试预填的非零值 —— 说明读到了内存、只是内容是旧的/空的）。
  `.shared` 与 `.managed` 存储一致复现；`waitUntilCompleted` + `error==nil`。
- 已知可行路径：**blit 到 Shared MTLBuffer → 读 `contents()`**
  （C++ 侧 `ReadRenderTargetPixels` 从一开始就是这个形状——原因当时没写明，
  现在补上：这就是它存在的理由之一）。Swift 测试已改用同一路径。
- 防复发规则：读回 GPU 产物**只走 blit→Buffer→contents**，不要用
  `getBytes` 直读渲染目标；跨驱动行为不可假设。
- 日期 / 来源 / 验证状态：2026-10-03 / UIA-003 SharedUI 测试 / **verified**
  （三种存储/读回组合对照实验，getBytes 三路全零、Buffer 路径正确）

### P22 · 新 SDK 的 SwiftUI 也导出 `Preview` 类型 —— 无前缀 Swift 类型名会撞车
- 现象：绑定层类型名 `Preview` 在任何同时 import SwiftUI 的模块里报
  "'Preview' is ambiguous for type lookup"（SwiftUI 有自己的 `Preview`）。
  SharedUI 全部 UI 文件都同时 import 两者，必然撞。
- 修复：绑定类型改名 **`Previewer`**（对应 CQPreview 的「预览器」语义），
  并在 Preview.swift 头注明原因。
- 防复发规则：绑定层「不带 CQ 前缀」的命名惯例要过一遍**消费方会 import
  的系统模块**（SwiftUI/UIKit/AppKit/SwiftData…）做撞名检查。
- 日期 / 来源 / 验证状态：2026-10-03 / UIA-003 / **verified**

### P23 · xcframework 静态库拉入媒体/预览 TU 后，Swift 侧必须显式链接系统框架 + libc++
- 现象：`swift test` 链接测试包报 `VTDecompressionSession*` /
  `kCMTimeInvalid` 等 undefined symbols。此前一直绿，因为**没有任何 Swift
  测试引用过预览 TU**；新增 Previewer 测试后 `cq_sdk_preview.o` 被拉入 →
  传递拉入 Platform 媒体/图形 TU → 需要 VideoToolbox / CoreMedia / Metal /
  AVFoundation / CoreVideo / CoreGraphics / AudioToolbox / QuartzCore /
  IOSurface(macOS only) + libc++。
- 修复：`bindings/swift/Package.swift` 两个 target 的 linkerSettings 与
  `run_smoke.sh` 链接清单都补齐（与 `ChuanqiCut.podspec` 的 ss.frameworks
  对齐；IOSurface 用 `.when(platforms: [.macOS])`）。
- 防复发规则：内核静态库的**系统框架依赖清单只有一处真源**（podspec），
  SPM 与 smoke 脚本的链接清单必须与之同步改；「编译绿 ≠ 能链接」。
- 日期 / 来源 / 验证状态：2026-10-03 / UIA-003 / **verified**

### P24 · 预览诊断量 `last_frame_pts` 的初值语义（空隙帧后也是 kOk）
- 现象：空时间线渲染（kIoNotFound）后查 `cq_preview_last_frame_pts` 返回
  kOk + 内核初值 `{0, 1}`——Swift 侧把它包成 Optional（无帧时 nil）是
  **错误抽象**：内核没有「无记录」信号。
- 约定：`lastFramePts` 返回非 Optional；「有没有帧」一律看
  `lastHitClip`。
- 日期 / 来源 / 验证状态：2026-10-03 / UIA-003 / **verified**

### P25 · macOS 的 `NSView.setNeedsDisplay` 要传 rect，iOS 无参 —— MTKView 跨平台重绘要封装
- 现象：Swift 6 下在共享的 MTKView 子类里直接调 `setNeedsDisplay()`，
  macOS 分支报 missing argument（NSView 版本要 `NSRect`）。
- 修复：封装 `requestRedraw()`（macOS: `needsDisplay = true`；iOS:
  `setNeedsDisplay()`），`enableSetNeedsDisplay=YES` 时即触发一次 draw。
- 日期 / 来源 / 验证状态：2026-10-03 / UIA-003 / **verified**

### P26 · 新 ABI 的返回值语义必须单一（错误码 XOR 数据），混用会被自己的封装层误判
- 现象：`cq_session_query_tracks` 初版返回值既当「写入条数」（成功）又当错误码
  （失败）。Swift 封装按 `cq_status_is_ok` 判断 → 填充查询成功返回条数 1，
  被当错误码拒绝，查询永远空，且 C 侧测试（按条数断言）还是绿的。
- 修复：契约改为「返回值 = 状态码；条数一律走 out_count」（趁无外部消费方）。
- 防复发规则：**新 ABI 的返回值语义必须单一**；同类既有 API（changes_since
  返回条数）不动，但新函数一律走「状态码 + out 参数」。
- 日期 / 来源 / 验证状态：2026-10-03 / UIA-009 子步骤 1 / **verified**
  （Swift 封装 16/16 + C TU 36/36 全绿；修改前 Swift 查询必空）

### P27 · 文件改名后，所有引用该文件名的脚本必须重跑验证
- 现象：UIA-003 把 Preview.swift 改名 Previewer.swift 在**最后一次 smoke 之后**，
  run_smoke.sh 里的文件引用没同步 —— 提交后 smoke 一直是坏的（swiftc 找不到
  输入文件），直到本轮才暴露。与 E10 同族：「改了 A 忘了引用 A 的 B」。
- 防复发规则：**mv/rm 源文件后，立即 grep 仓库内的文件名引用**并重跑受影响脚本。
- 日期 / 来源 / 验证状态：2026-10-03 / UIA-009 子步骤 1 / **verified**
  （引用已修正，smoke 重跑 PASSED）

### P28 · 本机 libc++（Xcode 16 / x86_64）未实现 C++20 atomic<shared_ptr>
- 现象：`std::atomic<std::shared_ptr<T>>` 编译期即报
  "_Atomic cannot be applied to ... not trivially copyable"（P0718 未实现）。
- 处置：共享快照发布点改用 mutex 保护的 shared_ptr（持锁 = 指针拷贝，纳秒级，
  命令频率下无竞争压力）。已写入 editor_model_state.h 注释。
- 日期 / 来源 / 验证状态：2026-10-03 / UIA-009 子步骤 1 / **verified**

### P29 · 内核私有头跨构建系统（CMake/pod）的 include 必须用相对路径
- 现象：`cq_session_impl.h` 放 core/src/，CMake 里加了 PRIVATE include 目录
  编译全绿；pod 路径（现场编译 core/src/**/*.cpp，无该 search path）构建失败
  "'cq_session_impl.h' file not found"。**CMake 绿 ≠ pod 绿**（P9~P13 同族：
  只有两套构建定义都真编译过才算过）。
- 修复：消费者（cq_sdk_preview.cpp）用相对路径 `#include "../cq_session_impl.h"`，
  CMake 的 PRIVATE 目录对同目录的 cq_sdk.cpp 不需要特殊处理。
- 防复发规则：**私有头被跨目录 include 时一律写相对路径**，不依赖任何构建
  系统的 search path。
- 日期 / 来源 / 验证状态：2026-10-03 / UIA-009 子步骤 2 / **verified**
  （双门禁 + pod 构建 App 全绿）

### P30 · #filePath 上溯层数手写必错（同一会话内连踩两次）
- 现象：定位仓库根的 `#filePath` 上溯链，TimelineTests 先写成 4 层（错），
  改成 6 层（仍错，正确 5 层）；MediaImportTests 又写成 6 层（正确 7 层）。
  每次都靠「夹具缺失」的失败信息反推。**上溯链的层数无法目测**——测试文件
  嵌套多深取决于它所在包的结构，猜必错。
- 修复：建共享 helper **唯一真源**——`bindings/swift/Tests/ChuanqiCutTests/
  TestPaths.swift`（5 层）与 `apps/apple/packages/SharedUI/Tests/SharedUITests/
  RepoPath.swift`（7 层），全部测试改转发。
- 防复发规则：**新测试不得手写 #filePath 上溯链**，一律 `TestPaths.root` /
  `RepoPath.root`；新包要建自己的 helper 时，层数必须用「打印一次实际结果」
  验证后写死，并带上逐层注释。
- 日期 / 来源 / 验证状态：2026-10-03 / UIA-009 子步骤 3 / **verified**
  （helper 化后双包 17+13 全绿）

### P31 · 异步提交的测试同步点：基准版本号必须在提交**前**读，且目标要算上「预期成功条数」
- 现象（同一轮在两个包里各错一次）：
  1. C 侧 `Drain()` 提交哨兵后只等 `version >= before+1`，而 `before` 是**提交哨兵之后**读的
     —— 队列里还压着未执行的提交（register/add_track 尚未落地），
     `query_tracks` 拿到空时间线，**19 条断言集体失败**（首版 61 checks / 19 failures）。
  2. Swift 侧改成「提交后才读基准」同样错：异步任务可能已落地，基准偏大 ⇒
     目标版本号永远达不到 ⇒ 5s 超时失败。
- 根因：**「等版本推进」不等于「队列排空」**。提交是异步的，被拒的提交还不推进版本。
- 正确写法（哨兵法）：
  * `base` = **这批变更提交之前**读到的版本号；
  * 提交 X（可能失败）→ 提交必定成功的哨兵 → 等 `version == base + k + 1`，
    其中 `k` = 这批里预期**成功**的条数（预期被拒的不计）。
  * session 队列 FIFO ⇒ 哨兵落地就证明此前所有提交（含被拒的）都已执行完；
    而「+1」正好是**失败语义的判据**：X 被拒时版本只推进哨兵那一次。
- 防复发：**不要用 sleep 赌时长**，也不要无参数地「等一次推进」。
  参考实现：`tests/unit/abi/test_c_abi_edit.c::DrainAfter(s,k)`、
  `bindings/swift/Tests/ChuanqiCutTests/TimelineTests.swift::drain(_:from:expecting:)`。
- 日期 / 来源 / 验证状态：2026-10-03 / UIA-005 / **verified**
  （C 61/61、Swift 绑定 18/18、SharedUI 18/18）

### P32 · 裁剪预览不能让位移同时作用于起点和时长
- 现象：`ClipDrag.previewStart` 无条件返回 `max(0, originStart + delta)`，
  于是**裁剪**（region == .trimEnd）拖过左边界时起点被夹成 0 —— 视觉上片段
  自己跳到时间线开头。SharedUI 测试 `testDragClampsNegativeStartAndTinyDuration`
  抓出（0.0 ≠ 0.5）。
- 修复：`previewStart` 在非 move 时直接返回 `originStart`（位移只作用于时长），
  与 `previewDuration` 对称。
- 防复发：**夹取规则必须逐 region 分支**，不要写成"统一公式"。
  这类边界（负起点 / 零时长）是 UI 侧必须夹住的 —— 内核 `MoveClip` **不校验
  负 start**（只校验重叠），UI 不夹就会把语义外的片段提交进去。
- 日期 / 来源 / 验证状态：2026-10-03 / UIA-005 / **verified**

### P33 · MediaImportTests 偶发失败（flaky，约 50%）→ 根因定位（AVAsset 加载终态/超时）
- 现象：`importMedia` 返回 `7000 (kInvalidArgument)`，素材库为空，随后
  `mediaLibrary[0]` 越界 → Fatal error → 整个 xctest 进程以 signal 4 退出。
  **单独跑 `--filter MediaImportTests` 全绿；全量跑时约一半概率失败。**
- **根因链（2026-10-04 定位，三层叠加）**：
  1. `AppleDemuxer::Open` 用 `loadValuesAsynchronouslyForKeys` + 信号量收敛
     同步，但 completionHandler **只 signal 不查状态** —— 它对所有 key 到
     **终态**时触发，终态含 **Failed/Cancelled**。加载失败时
     `[asset duration]` 返回 invalid。
  2. invalid CMTime 经 demuxer `ToRational` 变 **`{0, 1}`**——timescale=1
     骗过 probe 的 `timescale <= 0` 检查 → **probe 以 kOk 返回 value=0**
     （hypothesis 证实，机制如上）。
  3. Swift `importMedia` 在 `duration.value > 0` 处失败 → 导入失败、素材库空
     → 测试越界崩溃。
- **排障中的新发现（比 flaky 更危险）**：加载失败后**重建 AVURLAsset 重试，
  其 completion 可能永不触发**（同 URL 的 AVFoundation 进程级加载状态被污染，
  实测：新实例 5s 内无回调）——原代码 `DISPATCH_TIME_FOREVER` 无限等会让
  probe **挂死**（比返回错误严重得多）。首版修复（重试 + 无限等）即被
  `testImportInvalidFileFailsCleanly` 抓到挂死（xctest 10 分钟无响应）。
- **修复**：① completion 后逐 key 查 `statusOfValue`（Failed/Cancelled 诚实
  失败）；② 信号量 wait 改 **5s 有限超时**（正常加载 40~400ms ×10 余量），
  超时/失败返回 kIoError；③ 文件已不存在（stat）跳过重试（确定性失败省 5s），
  存在的文件才重建 asset 重试一次；④ probe 补 `value <= 0` → kDecodeError。
- 教训：**「completion 触发」≠「加载成功」**（终态三义性）；**任何
  DISPATCH_TIME_FOREVER 等 AVFoundation 回调都是挂死隐患**（回调可能不触发）。
- **⚠️ 第二层根因（2026-10-04 新会话实证，同签名 7000 的另一来源）**：
  `importMedia` 等 addTrack 落地的判据是「session 版本号 > versionAtStart」，
  但 **registerAsset 也发布快照推版本**（editor_model_state.cpp RegisterAsset
  会 Publish）—— 版本差值无法区分是哪条命令落地。在途 registerAsset 先应用
  → 等待提前通过 → 此刻查询还没有视频轨 → `videoTrack == nil` → importMedia
  假失败 7000。诊断实锤：`track wait: version 0 -> 2, elapsed=10μs, tracks=1`
  （循环 10μs 即退出；前后两次 queryTracks 看到不同版本）。负载越重窗口越大
  —— **前一轮「内核修复后 ×3 全绿」不可复现**（新会话复跑 6/3/0 失败）。
  教训：flaky 的「N 次全绿」只是概率证据，必须配合失败签名闭环。
- **修复 2**：等待判据改为**轮询目标效果本身**（`queryTracks` 出现视频轨，
  10ms 间隔 / 5s 上限；查询是纳秒级快照读，轮询安全、语义直接），
  并在三个失败分支补正式日志（registerAsset/addTrack/addClip 的 raw 状态码）。
- **验证（2026-10-04，修复 2 后）**：SharedUI 全量 ×3 连续 **20/20 全绿**
  （4.2~4.9s；此前失败用例要烧满 5s 超时，套件时长 9.9~14.8s —— 时长本身
  回归正常也是修复有效的旁证）；Debug 门禁 42/42。
  真机（iPhone 17 Pro）导入路径待传哲验证。
- 日期 / 来源 / 验证状态：2026-10-03 UIA-010 发现 / 2026-10-04 定位（缺陷 1 + 缺陷 2）/
  **verified（双层根因 + 修复 + 全量 ×3 + 失败签名闭环）**

### P34 · CocoaPods 工程看不到新增的 Swift 源文件 → 需重新 pod install
- 现象：给 `bindings/swift/Sources/ChuanqiCut/` 新增 `Player.swift` 后，
  App（CocoaPods 源码集成）编译报 `cannot find type 'Player' in scope`，
  而 SPM 路径（swift test）完全正常。
- 原因：Pods 工程的文件引用是 `pod install` 时生成的**快照**，新增文件不会
  自动进入；SPM 是目录扫描，所以两条消费路径表现不同。
- 规则：**往绑定层新增文件后必须重跑 `bundle exec pod install`**（mac/ios 两个
  工程各自跑），否则 App 侧必挂，而 SPM 测试全绿会给出"没问题"的假象
  （又一次「绿灯 ≠ 可用」）。
- 日期 / 来源 / 验证状态：2026-10-03 / UIA-010 / **verified**

### P35 · Xcode 升级后 iOS 切片的 CMakeCache 会残留已消失的 SDK 路径
- 现象：`build_core_apple.sh` 报 `no such sysroot directory:
  .../iPhoneSimulator18.4.sdk`（该 SDK 已不存在，现为 26.5）。此前同脚本刚成功过。
- 原因：`CMakeCache.txt` 里缓存了**绝对 SDK 路径**，Xcode 更新后旧路径消失，
  CMake 复用缓存 → `-Wmissing-sysroot` + `-Werror` 直接失败。
- 处理：删掉对应切片的 `CMakeCache.txt` + `CMakeFiles/` 让 CMake 重新解析
  （脚本里已有同类"脏 cache 自愈"逻辑，可扩成检测 SDK 路径是否存在）。
- 日期 / 来源 / 验证状态：2026-10-03 / UIA-010 / **verified**

### P36 · 消费端持锁期间调 `PreviewPump::Request` → 死锁
- 现象：`test_preview_pump.cpp` 第一版挂在 `[5] 消费锁` 段：主线程 `Lock()` 之后
  又调 `pump.Request()`，进程卡死（无任何输出，只能被外部 kill）。
- 原因：`Request` 也要拿同一把 `mtx_`；消费锁与它是**同一把锁**，自锁即死锁。
- 规则：**先 Request，再 Lock → blit → Unlock**。已写进 `preview_pump.h` 的
  「消费协议」注释与用例注释。同类：持锁期间也不要 `waitUntilCompleted`
  （会把泵线程一起堵住）。
- 日期 / 来源 / 验证状态：2026-10-04 / UIA-010 子步骤 5 / **verified（已复现并修）**

### P37 · 跨 MTLCommandQueue 访问同一纹理没有顺序保证 —— 共享队列是刚需不是优化
- 现象（推演后按文档定论，未做"随机花屏"复现实验）：把取帧渲染挪到泵线程后，
  泵线程写离屏 RT、主线程读它若各用一条队列，Metal **只保证同一条队列内**按
  commit 顺序执行，跨队列必须显式 `MTLSharedEvent` / `MTLFence`。
- 处理：`gfx_device.cpp` 由「每帧 `CreateCommandQueue`」改为按设备复用一条；
  新增 `ICommandQueue::NativeHandle()` + `IGfxDevice::SharedQueueHandle()` +
  `cq_preview_shared_queue()`，UI 侧 blit 强制走这条队列。
- 副作用（收益）：顺带去掉了每帧新建 `MTLCommandQueue` 的无谓开销。
- 日期 / 来源 / 验证状态：2026-10-04 / UIA-010 子步骤 5 / **设计定论 + 链接/功能测试通过；
  "不共享会花屏"未做对照实验**

### P38 · 顺序播放每帧都精确 seek → 每帧重解一个 GOP（预览帧率的真瓶颈）
- 现象：连续递进请求（每帧 +40ms）时单帧 `acquire` 均值 **93ms**（128x128、
  Release），占单帧总耗时 94%；而孤立请求同一素材约 5~8ms。App 侧 1s 播放
  只产出 **14 帧**（Release XCFramework；Debug 为 3）（1280x720，Debug XCFramework）。
- 原因：`SystemFrameProvider::AcquireFrame` 见 `seek_target_ != req.at` 就
  `Seek()`（demuxer seek + decoder Flush），随后 `AcquireExact` 从关键帧解码到
  目标 —— 顺序播放时每帧都付一遍整个 GOP 的解码。
- 状态：**已修（2026-10-04，MEDIA-021 / ADR-0017）**。顺序快路径 +
  自适应阈值（实证学习），同口径实测 14.8~22.8x；过程中暴露 P39/P40/P41。
- 教训：修"帧率"之前先量各阶段耗时 —— 本次若不埋点，会误以为是"渲染太慢"
  而去做 GPU 侧优化，方向全错。
- 日期 / 来源 / 验证状态：2026-10-04 / UIA-010 子步骤 5 → MEDIA-021 / **verified（已修，实测通过）**

### P39 · 平台解码器按**完成序**回调，不是显示序（B 帧必错帧）
- 现象：`media_sequential_real` 逐帧 pts 断言失败；VT 输出实测 145/300 非单调
  （模式 I → P+4帧 → B…），且乱序弹出的帧 duration 为**负值**（-8000）。
- 原因：`media_decode.h` 原注释「VideoToolbox 已在显示序回调」是错误假设——
  VT 回调按解码完成序（≈dts 序），B 帧在其参考 P 帧之后完成；且旧「弹不出才喂」
  循环在 B 尚未喂入时只能弹 P，任何重排判据都无信息可用。
- 处理：① 编排层三个 Acquire* 循环改「先喂后弹」（ADR-0017 D3）；
  ② decoder `PopFrame` 按「显示序连续性」重排：队列最小 pts 帧可弹当且仅当
  `pts == 上一弹出帧 pts + duration`，不匹配时等在途帧或返回 kIoNotFound
  让 provider 继续喂（ADR-0017 D4）——无需知道 B 帧深度，对 VFR 成立。
- 教训：**"解码器输出什么序"必须实测，不能信文档注释/直觉**；逐帧 pts 断言
  是唯一能抓住这类问题的验收手段（静态彩条看不出差一帧）。
- 日期 / 来源 / 验证状态：2026-10-04 / MEDIA-021 / **verified（已修，120/120 断言过）**

### P40 · 首帧时长兜底用「喂入包 pts 差」→ B 帧素材首帧区间报宽 (bframes+1) 倍
- 现象：顺序请求严格递增只有 31/120（≈ 每 4 个请求推进 1 帧）；「区间归属」
  120/120 假绿（区间太宽怎么都"包含"）。
- 原因：`VideoToolboxDecoder::Feed` 用前两个**喂入包**的 pts 差估
  `nominal_duration_`。喂入是**解码序**：B 帧文件前两个包是 I 和其后的参考帧，
  pts 差 = (bframes+1) 帧（golden bframes=3 → 4 帧宽）。首帧区间 [P, P+16000)
  使 kExact 在关键帧上提前命中，画面差 1~3 帧。
- 处理：改用 **dts 差**（CFR 下解码序相邻 dts 间隔 = 一帧，与 B 帧排布无关）。
- 教训：**区间归属（FrameContains）的正确性完全依赖 duration 报准**；
  duration 是元数据不是噪声，任何"兜底估算"都要过 B 帧场景的测试。
- 日期 / 来源 / 验证状态：2026-10-04 / MEDIA-021 / **verified（已修）**

### P41 · decoder Flush 后旧在途回调帧污染新序列首弹
- 现象：Seek(124000) 后首弹弹出**旧 GOP 的 128000**（step1 复现），后续请求
  交付漂移（甚至回到流首 8000）。
- 原因：VT 异步回调可能在 `Flush()` 之后才到达；Flush 清队列但拦不住**之后**
  落地的旧帧，而 Flush 后首弹无显示序约束，旧帧直接被当新序列首帧交付。
- 处理：`Flush()` 先 `VTDecompressionSessionWaitForAsynchronousFrames` 等
  在途帧全部落地，再清队列/pending（provider 串行调用 Flush/Feed，无并发）。
- 教训：**异步解码器的"清空"要分两步——先等在途落地、再清**；只清缓冲等于
  没清。连带修好了一个 AVAssetReader 频繁重建的异常源（读 1 包即尽）。
- 日期 / 来源 / 验证状态：2026-10-04 / MEDIA-021 / **verified（已修）**

---

## 已修正的历史错误（供参考，避免重犯）

| # | 错误 | 事实 | 日期 |
|---|---|---|---|
| E1 | SoundTouch 被标为 MIT | 实为 **LGPL v2.1-or-later**；已改用 signalsmith-stretch (MIT) | 2026-09-23 |
| E2 | 项目文件时间用浮点秒 | NTSC 帧率精度丢失；已改为有理数 `RationalTime` | 2026-09-23 |
| E3 | "SwiftUI 一个 target 跑 iOS + Mac" | 实为两个 target + 共享 package | 2026-09-23 |
| E4 | "AVAsset 解封装由 Media Engine 硬件加速" | 无官方依据，容器解析在 CPU | 2026-09-23 |
| E5 | 以 Intel Mac 为开发基线 | 无 ANE / 无 ProRes 硬编 / 无 UMA 优势；已改为 Apple Silicon 基线 | 2026-09-23 |
| E6 | manifest 中多个依赖版本号为编造值（signalsmith-stretch "1.0"、SPIRV-Cross "1.3.296.0"、oboe "1.9.2"） | 上游根本不存在这些 tag；signalsmith-stretch 与 SPIRV-Cross 上游 0 个 tag，oboe 只有 1.9.0/1.9.3。**版本号必须 `git ls-remote` 核对，不得凭印象写**，否则清单看着可审计实则不可信 | 2026-09-24 |
| E7 | `parser.py::_validate_artifact()` 引用未定义常量 `E_BAD_VALUE` | 非法 artifact.platform 会抛 NameError 而非给出校验错误；已改为 `E_INVALID_VALUE` | 2026-09-24 |
| E8 | 「CVPixelBuffer(32BGRA) → `MTLPixelFormatBGRA8Unorm` 纹理，采样后需手动把 R/B 交换成 RGBA」 | **错误**。`BGRA8Unorm` 在 Metal 中是「按 BGRA 该厂商序存储、但逻辑通道仍是 .r=红/.b=蓝」的格式；采样返回的已经是逻辑 RGBA，无需交换。错误地写成 `float4(c.b,c.g,c.r,c.a)` 会让 R/B 反掉——绿条等 R==B 区域看不出，但彩条其余通道会暴露（PALA-002 初版即被底部采样检查抓出）。PALA-011 解码输出为 32BGRA，importer 必须用 BGRA8Unorm 才能直接复用其 IOSurface，且着色器直接 `return c` | 2026-09-26 / PALA-002 / verified |
| E10 | HANDOFF-003 §1 把「BIND-003 子步骤 3 纹理导入（零拷贝）」标为**下一步** | **已做过**：PALA-002（2026-09-26，commit 76fce6b）已完成零拷贝导入，`platform_apple_native_image` 用例含 IOSurface ID 一致性（源 193==纹理 193）、零拷贝/CPU 退化耗时代差（0.0033ms vs 4.5788ms ≈ 1407×）、真实解码帧渲染读回。**交接文档的任务状态要对着 commit 历史核，不能照抄上一版** | 2026-10-02 / BIND-003 / verified |
| E9 | 「XCFramework 合并失败是 bitcode 段导致，加 `-fno-embed-bitcode` 可解」（HANDOFF-002 §3 的遗留推测） | **根因判错**：是 Release **LTO/IPO** 产出 bitcode-only `.o`，与 ENABLE_BITCODE 无关；`-fno-embed-bitcode` 该 clang 不识别且方向错误。教训：`0xb17c0de` 这个 magic 既可能来自 embed-bitcode 也可能来自 `-flto`，**必须抽 `.o` 看实际内容再定论**，不能靠 magic 字面猜。另：那次尝试的脏 flag 残留在 `build/apple/ios-device/CMakeCache.txt` 里未被发现，CMake 会持续复用——**CMakeCache 是隐式状态，撤销改动时不要只撤销源码** | 2026-09-29 / PALA XCFramework 打包 / verified |

### P42 · 开发机换到 macOS 13.7 / Xcode 15.2（AppleClang 15）后既有代码编译失败
- 现象：同一仓库在原机（macOS 15.4 / AppleClang 17，见各 baselines 条目）全绿，
  本机（macOS 13.7 / Xcode 15.2 / AppleClang 15，`xcodebuild -version` 确认）连
  既有 core 都编不过：① `core/src/base/log.cpp` 的 `std::va_list` 在旧 libc++
  不存在；② `tests/unit/base/test_perf.cpp` 的 volatile 复合赋值触发
  `-Wdeprecated-volatile`（C++20 P1152，AppleClang 15 更早把该警告拉进 -Werror 集）。
- 处理：① log.cpp 改用全局 `::va_list` + `<cstdarg>`（新旧工具链都成立）；
  ② `acc += i` → `acc = acc + i`。均为语义不变的兼容修复。
- 教训：**「本机实测」结论绑机器**。之前 baselines 里 macOS 15.4 的实测数字
  全部来自另一台机器（cmake 默认路径是 /Users/zhuning/... 可证）；本机复核或
  引用数字时先核对环境。ADR-0010 §6 的"性能基线须标注采集机型"由此更重要。
- **补充（同日，P42b）**：`build_core_apple.sh` 的 ios-device 切片在 Xcode 15.2
  （iOS 17.2 SDK）编不过 —— `kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder`
  / `kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder` 在 17.4 代际
  才进 iOS 头文件，`@available` 救不了"标识符不存在"。macOS 切片与桌面全量测试
  不受影响（macOS 头自 10.9 就有）。**结论：iOS 切片/xcframework/Swift 测试宿主
  需要 Xcode 16+ 的机器**；若确需旧 Xcode 支持，给两处 VT 探针加 SDK 代际守卫
  （`__IPHONE_OS_VERSION_MAX_ALLOWED`），语义退化为既有 kDegraded——独立小任务，勿顺手改。
- 日期 / 来源 / 验证状态：2026-10-04 / CAM-001 / **verified**（修复后 40/40 全绿）

### P43 · 构建脚本 CMAKE_BIN 默认路径指向他人 home，且本机无 cmake
- 现象：`build_core.sh` 默认 `CMAKE_BIN=/Users/zhuning/...`，本机不存在；
  本机也无 brew/cmakes（`which cmake` 空）。
- 处理：`pip3 install --user cmake`（装到 ~/Library/Python/3.9/bin），构建时
  `export CMAKE_BIN=$(ls ~/Library/Python/*/bin/cmake | head -1)`。ctest 同目录自动推导。
- 备注：若脚本要长期在多机使用，可把默认值改为"PATH 中找 cmake，找不到再落绝对路径"。
- 日期 / 来源 / 验证状态：2026-10-04 / CAM-001 / **verified**

### P44 · `AVCaptureMultiCamSession` 是 iOS 专属，macOS 编译直接 unavailable
- 现象：capabilities.mm 无条件引用 `AVCaptureMultiCamSession.isMultiCamSupported`
  在 macOS 切片报 `'AVCaptureMultiCamSession' is unavailable: not available on macOS`。
  （调研时误记为"macOS 10.15+ 可用"——那是文档里别的类的可用性，核验不严。）
- 处理：Platform 内 `#if TARGET_OS_IPHONE` 吸收平台差异，macOS 分支如实返回 kNo。
  core 头仍零平台分支（红线 #3 不受影响——运行时查询的是能力**结果**，
  Platform 内部怎么拿到结果是 Platform 的实现自由）。
- **后记（同日）**：ADR-0014 转向后该实现随 CAM-001 契约一并回退，但 API 事实
  不变，未来在 macOS 上做相机相关代码仍会撞。
- 日期 / 来源 / 验证状态：2026-10-04 / CAM-001 / **verified**

### P45 · 本机（Mac mini 2014）工具链与 HANDOFF 门禁环境不符 —— 验证命令会以 "tools version" 失败
- 现象：SharedUI `swift test` 报 `package is using Swift tools version 6.1.0 but the
  installed version is 5.5.0`。本机（Mac mini 2014 低配机：i5-4278U 双核 2.6GHz / 8GB / macOS 12.7.6）/usr/bin/swift 来自 Xcode 13.1，
  SDK 只有 iOS 15 / macOS 12；HANDOFF-003 描述的 Xcode 26.x / Ruby 3.4 / CocoaPods /
  xcodegen / 已构建内核（build/）在当前机器**全部不存在**（2026-10-04 盘点：工作区是
  当天 18:52 整体落盘的，无任何本地构建产物）。
- 影响：本机只能做 `swiftc -parse` 语法级检查与读码审阅；**类型检查与全部门禁必须
  在真实构建机上跑**。PhotosPicker（UIA-011）等 iOS16/macOS13+ API 在本机 SDK 里
  根本不存在，连 `-parse` 以外的验证都做不了。
- 规则：换机器 / 新会话接手时，先 `swift --version` + `xcodebuild -showsdks` 核对
  环境，再决定 HANDOFF 里的验证命令哪些本机可跑；否则会把"环境跑不了"误判成
  "代码有问题"（反之亦然）。附注：Swift 5.7 简写（`if let x {}`）在 5.5 下报
  "requires an initializer" —— 是工具链旧，不是代码错。
- 关联：P42（开发机 macOS 13.7 / Xcode 15.2）同样跑不了 SharedUI swift test
  （其 P42b：Swift 测试宿主需 Xcode 16+）—— UIA-011 的 swift test 与 CAM 的
  Swift 验证同桶，都等「有 Xcode 16+ 的机器」。
- 日期 / 来源 / 验证状态：2026-10-04 / UIA-011 / **verified**
### P46 · SharedUI 包在本机（Swift 5.9.2）连包清单都解析不了 + 可用的替身验证技法
- 现象：`apps/apple/packages/SharedUI/Package.swift` 声明 `swift-tools-version:6.1`，
  本机 Xcode 15.2 的 Swift 5.9.2 直接拒绝解析（工具链代际门槛，先于依赖解析失败）。
  加上 bindings xcframework 在本机不存在（P42b：ios-device 切片需 Xcode 16+），
  **SharedUI 的 `swift build`/`swift test` 在本机双重死锁**——CAM-002~005 当时只跑
  `swiftc -parse` 兜底，而 **-parse 不做类型检查**，API 拼错全放行。
- 本卡（CAM-011）实证：`-typecheck` 立刻抓出 4 个 -parse 查不出的真错误——
  ① 不存在 `VNAnimalObservation` 类（`VNRecognizeAnimalsRequest.results` 是
  `[VNRecognizedObjectObservation]`）；② `VNConfidence` 是 Float 不是 Double；
  ③ iOS 17 专属类型出现在无门控作用域；④ 动物关节名是 `nose`/`leftEarTop`
  （无 `snout`/裸 `ear`）。
- **替身验证技法（本机可用，比 -parse 强得多）**：
  1. SharedUI 纯函数文件编成同名 stub 模块：
     `xcrun swiftc -emit-module -module-name SharedUI -sdk $(xcrun -sdk iphonesimulator -show-sdk-path) -target x86_64-apple-ios16.0-simulator <纯函数文件>.swift -o <dir>/SharedUI.swiftmodule`
  2. iOS 文件全量类型检查（含 @available 门控验证）：
     `xcrun swiftc -typecheck -sdk <同上SDK> -target x86_64-apple-ios16.0-simulator -I <dir> <文件...>`
  3. 纯函数数学真实执行：macOS 宿主 `xcrun swiftc main.swift <纯函数文件>.swift`
     编译运行（多文件时顶层语句必须叫 **main.swift**）。
  4. 断言写 1e-12 容差，**禁止 CGRect/CGFloat 精确相等**（0.5+(0.1−0.5)≠0.1 的
     机器精度假失败，XCTAssertEqual(CGRect) 默认精确相等，一样会踩）。
  5. 测试文件本身也能 typecheck：stub 模块 emit 时加 `-enable-testing`
     （`@testable` 要求），再 `-I "$PLAT/Developer/usr/lib" -F "$PLAT/Developer/Library/Frameworks"`
     解析 XCTest（PLAT=`xcrun -show-sdk-platform-path`）。本卡由此抓出
     `XCTAssertEqual(CGFloat?, CGFloat?, accuracy:)` 不成立——accuracy 重载要求
     非可选 FloatingPoint，可选分量要自行解包比较，否则新机器 swift test 必挂。
- 日期 / 来源 / 验证状态：2026-10-04 / CAM-011 / **verified**（typecheck 0 错 +
  harness 19/19；API 形状以 iphonesimulator 17.2 SDK 头文件 grep 对表为准）
- 日期 / 来源 / 验证状态：2026-10-04 / CAM-012 / **verified**（探针 + harness 实跑）

### P47 · iOS 17.2 SDK 的 CI Metal kernel 全套 API 事实（与常见文档记忆不符）
1. **CIKernel 没有源码串初始化器**：`CIKernel(functionName:from:)` 不存在，
   只有 `CIKernel(functionName:fromMetalLibraryData:)`（iOS 11+）。CI kernel
   必须 build 期用 `metal -fcikernel` 编成 metallib 入包，运行时从 bundle 取
   Data 加载；**不能**走 `MTLDevice.makeLibrary(source:)`（那是普通 Metal，
   coreimage::sampler 不可用）。
2. **`metal -c` 出 .air 再 `metallib` 链接在本机工具链（Xcode 15.2）得到 96 字节
   空库**——必须一步 `metal -fcikernel x.metal -o x.metallib`。两步法是网上常见
   写法，本机实测丢函数。
3. **`CIContext.render(_:to: CIRenderDestination)` 同步重载在 iOS 17.2 SDK 不存在**
   （只有 startTaskToRender 异步任务 + toMTLTexture/toCVPixelBuffer/toBitmap 同步
   变体）。toMTLTexture 变体的 colorSpace 参数**非可选**（CGColorSpace），
   macOS 上试传 nil 会编译错。
4. `CVPixelBufferPoolCreatePixelBuffer` 在本 SDK 桥接为 **3 参**
   （allocator, pool, &out）——头文件里的 auxAttributes 参数被 Swift 导入器吞掉；
   `CVPixelBufferPoolCreateBuffer` 不存在（-parse 查不出这种错，见 P48）。
5. coreimage::sampler 只有 `sample(float2)`（无自定义 sampler state），
   边界行为未定义 → kernel 内手动 clamp 到 `extent().xy ~ xy+zw-1`。
- 日期 / 来源 / 验证状态：2026-10-04 / CAM-012 / **verified**（typecheck 抓出后逐条修复）

### P48 · A 期相机代码从未 typecheck 过，存量 7 处编译错误（-parse 的代价清单）
CAM-012 首次对相机模块做全量 `-typecheck`（P46 技法），一次抓出 7 处 -parse
放行的真错误（已全部修复）：
1. CameraRenderer：用了 MTKView/MTKViewDelegate 但没 `import MetalKit`；
2. CameraRenderer：`private var latest` 与 `func latest()` 同类型内重声明；
3. CameraRenderer：`render(_:to: CIRenderDestination)` 不存在（P47-3）；
4. CameraRecorder：`sourceBufferAttributes:` 应为 `sourcePixelBufferAttributes:`；
5. CameraRecorder：`CVPixelBufferPoolCreateBuffer` 不存在（P47-4）；
6. CameraView：iOS 17 起的两参 `.onChange(of:)` 用于 iOS 16.0 部署目标（同 P46-③
   的"iOS 17 API 未门控"类型）；
7. CameraViewModel：缺 `import UIKit`（UIImage）；wireCallbacks 闭包里
   recorderBox 隐式 self——已改局部 let 捕获（顺便消掉潜在保留环）。
**规则**：相机模块新文件合入前必须过 iphonesimulator SDK 全量 -typecheck
（-parse 只验语法不验类型/API/可用性）；harness 已是固定工具。

### P49 · App 目标（ChuanqiCutApp）从未整体编译过，HomeView 首页三连错（Swift 6.1 语言模式）
用户在构建机报"主分支首页编译不通过"。App 目标 SWIFT_VERSION=6.1（Swift 6 语言
模式严格并发），而既有验证（-parse / 默认模式 -typecheck）都查不出语言模式错误。
本轮静态审查（无编译机，未实测编译，**hypothesis→构建机验收**）定位并修复：
1. HomeView.swift：用了 `ChuanqiCut.version` 但缺 `import ChuanqiCut`（SharedUI
   无 @_exported 转发，Swift 不允许传递依赖取符号）→ `cannot find 'ChuanqiCut'
   in scope`，正中"首页编译不通过"；
2. CameraManager.applyPortraitOrientation：`isVideoRotationAngleSupported(90)`
   （iOS 17+）在 `#available(iOS 17.0,*)` 门控之前调用——编译错，且 iOS 16 真机
   unrecognized selector 运行时崩溃；已改为门控内各分支自查支持性；
3. CameraViewModel.capturePhoto：`var processed` 被 `Task { @MainActor in }`
   （@Sendable）捕获 → `reference to captured var in concurrently-executing
   code`；改 `let` 确定初始化；
4. CameraManager（普通 final class NSObject）被 4 处 `DispatchQueue.async`
   @Sendable 闭包捕获 → Swift 6 必报 non-sendable capture；类标
   `@unchecked Sendable`（队列独占纪律担保），capturePhoto 的 onDone 经
   PhotoRelay（@unchecked Sendable，新增 deliver()）转交，@Sendable 闭包不再捕获
   非 Sendable 的 onDone。
5. SharedUI `AlbumPickerScreen.PickerFeedback`：nonisolated static func 的
   `#if canImport(UIKit)` 分支里用 UIImpactFeedbackGenerator / UIApplication.shared
   （全部 @MainActor）→ iOS 编译路径必报 main actor-isolated call；macOS 走
   AppKit 分支（NSWorkspace 无整类标注）故 swift test 从未暴露。enum 标
   @MainActor（调用点全在 View 内，零改动）。SharedUI 其余 20 文件 iOS 16 视角
   静态审查无可编译级问题。
**规则**：App 目标级 typecheck 必须带 `-swift-version 6` 跑（与 SWIFT_VERSION=6.1
一致），否则严格并发错误全部放行；**且 `#if canImport(UIKit)` 分支是 macOS
验证的盲区，iOS-only 代码至少做一次 iOS 目标 typecheck**。
本批修复只过了 -parse（本机 Swift 5.5 无 iOS 16 SDK），类型级验证待构建机。
- 日期 / 来源 / 验证状态：2026-10-05 / 双机集成修复（用户报首页编译失败）/
  **未实测**：静态审查 + -parse；-typecheck/xcodebuild 待构建机


### P50 · bash 3.2（macOS 自带）下 `$var` 紧跟全角字符 = unbound variable
- 现象：run_gate.sh 首版在步骤失败的分支报
  `line 52: rc…: unbound variable`，而 `rc` 上一行刚 `local rc=$?` 赋值。
- 根因：bash 3.2 把紧跟 `$rc` 之后的全角该厂商（`）——`）解析进变量名；
  macOS 自带 bash 是 3.2，`#!/usr/bin/env bash` 命中的可能就是它。
  `bash -n` 查不出来（语法合法，扩展期才炸）。
- 排障步骤：报错行号 → `sed -n 'Xp'` 看该行 → 注意行内 `$var` 后第一个字符。
- 修复：脚本里变量引用一律 `${var}` 花括号形式，输出文案里的全角字符与
  变量之间用花括号隔离。
- 防复发规则：**仓库脚本（echo 带中文）里 `$var` 一律写 `${var}`**；
  失败分支必须真跑一次（本例首跑即炸）。
- 日期 / 来源 / 验证状态：2026-10-05 / INFRA-010 首跑 / **verified**
  （修后 deps 失败分支正常打印 tail + 摘要并 exit 1；通过分支见 run_gate 实跑）

### P54 · Xcode 工程是生成产物却没人重新生成 → 源码全在仓库、target 里一个都没有
- 现象：`ChuanqiCutApp.swift:23: cannot find 'HomeView' in scope`。第一反应是
  "HomeView 没提交"，但 `git ls-files` 与磁盘 11 .swift + 1 .metal **完全一致**，
  `git status` 干净。
- 根因：`apps/apple/ios/ChuanqiCut.xcodeproj/project.pbxproj` 是 UIA-002 时期的
  陈旧生成产物（`LastUpgradeCheck = 1430` ≈ Xcode 14.3），只引用了
  `ChuanqiCutApp.swift` —— **12 个源文件里 11 个从未进过任何编译**。
  仓库约定是"xcodeproj/xcworkspace 不入库"，但本机没有 brew / xcodegen / mint，
  clone 后**没有任何路径能重新生成**，于是陈旧产物一直用到现在。
- 排障步骤：`git ls-files <dir>` 对比 `find <dir> -name '*.swift'`（排除"没提交"）
  → `grep -oE '[A-Za-z0-9_]+\.swift' project.pbxproj`（看工程实际收录哪些）
  → 两者不一致即为工程产物陈旧，不是源码缺失。
- 修复：装 xcodegen（GitHub Release 二进制，见 project.yml 头部注释）重新
  generate + `bundle exec pod install`；xcodegen 按 project.yml 自动收录全部 12 个。
- 防复发规则：**"cannot find X in scope"先查工程引用，不要先怀疑没提交**；
  xcodegen 装法必须写进 project.yml（本机无 brew，不能写 `brew install xcodegen`）。
- 日期 / 来源 / 验证状态：2026-10-05 / HomeView 编译不过排障 / **verified**
  （generate 后 12/12 引用齐全；simulator + device 双端 BUILD SUCCEEDED）

### P55 · CIKernel 的 metallib：编译和链接都得 -fcikernel，`xcrun metallib` 会产出能用的**空壳**
- 现象：`beauty_bilateral.metal`（CoreImage kernel）走 Xcode 内建 Metal 阶段时
  `air-lld: symbol(s) not found for target 'air64_v25-apple-ios16.0.0-simulator'`
  （`coreimage::sampler` 的 sample/coord/extent）。
- 根因：`coreimage::sampler` 是 CoreImage **运行时**解析的符号，必须以
  CoreImage kernel 模式编译。
- ⚠️ 二次陷阱（这个更贵）：只给编译阶段 `-fcikernel`、链接用 `xcrun metallib`，
  **链接成功、退出码 0、产出 96 字节 metallib**，但里面只有 `MTLB`+`ENDT`，
  没有任何函数符号 —— 运行时 `CIKernel.kernelNames(fromMetalLibraryData:)`
  查不到 → `BeautyKernel.init?` 返回 nil → **静默回落默认实现，编译全绿**。
- 修法：编译与链接**都**用 `metal -fcikernel`（不是 `metallib`）：
  `metal -fcikernel -target <triple> -isysroot <sdk> -c k.metal -o k.air`
  `metal -fcikernel -target <triple> -isysroot <sdk> -o k.metallib k.air`
  正确产物 8.4KB，`strings` 可见 `cq_beauty_down_h` / `cq_beauty_up_v_mix`。
- 顺带：Xcode 内建阶段不可用（它的链接用 metal 驱动且不带 -fcikernel），
  故该 .metal 要从 Sources 排除，改由 `postBuildScripts` 编译并直写
  `$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/`（签名在所有 phase 之后）。
- 防复发规则：**产出 metallib 后必须 `strings` 检查 kernel 名**；
  "链接退出码 0" 不构成证据。大小也要看（96B = 空壳）。
- 日期 / 来源 / 验证状态：2026-10-05 / CAM-012 首次编译 / **verified**
  （产物与手工链接的 8399B 样本 `cmp` IDENTICAL；simulator/device 双端均有）

### P56 · xcodegen 2.46 三个不显然的行为（PRODUCT_NAME / excludes / metal flags）
- （a）**不写 `PRODUCT_NAME`**：生成的工程缺该设置，Xcode 解析出空产品名，报
  `Multiple commands produce '.../Build/Products/Debug-iphonesimulator/.app'`
  （注意路径里 `.app` 前是空的）。→ project.yml 的 `settings.base` 必须显式写
  `PRODUCT_NAME: "$(TARGET_NAME)"`。
- （b）**`excludes` 要用 glob**：写 `iOSApp/Camera/Effects/beauty_bilateral.metal`
  （相对工程根）**不生效**，文件照样进 Sources；必须写 `**/beauty_bilateral.metal`。
- （c）**Metal 编译 flag 塞不进去**：`MTL_OTHER_FLAGS = -fcikernel` 在
  `xcodebuild -showBuildSettings` 里看得到，但**不会出现在 metal 命令行**；
  source 级的 `compilerFlags` 也不落地（PBXBuildFile 无 settings 段）。
  → 真要给 .metal 加 flag，别指望 build setting，用脚本自己编（见 P55）。
- 排障：`xcodebuild ... -showBuildSettings | grep MTL_` 能确认设置存在，但
  **存在 ≠ 生效**；要回到编译日志里 grep 实际命令行验证。
- 日期 / 来源 / 验证状态：2026-10-05 / HomeView 排障（工程重建三次）/ **verified**
  （每步都重新 generate + pod install + build 实测）

### P51 · 同日并行会话各取 ADR-0016 —— fetch 核号防不住，只有发号器能防住
- 现象：2026-10-05 收口时发现 `ADR-0016-预览取帧的线程归属`（编码侧，早、被
  HANDOFF/模块文档引用）与 `ADR-0016-智能成片与大模型接入边界`（智能成片侧，
  当日 17:01 提交）并存；同批还带来 AIEDIT-000~011 任务线与 UIA-019 Spec。
- 根因：两个会话都在 main 上工作，各自建号前都"没撞上已提交历史"——
  **同一工作日内互相看不见对方的未推送/未合并取号**，fetch 核号只防跨日、
  不防同日并行。
- 处置：按编号纪律"改动面小的一侧让位"——智能成片侧刚提交、引用面小，
  改号（当时误取 ADR-0019，第四轮与文档分层 ADR 再撞，**终定 ADR-0020**，见下方
  第四轮实例）；引用按主题精确清扫（智能成片侧 0 残留，预览侧引用原样保留）。
- 防复发规则：**取号不走 fetch 兜底，一律走集成机发号器**（PLAN-三线并行 §2：
  每线一次领 5 个号，登记即占号）；号段表已更新（ADR 新号从 0022 起）。
- 日期 / 来源 / 验证状态：2026-10-05 / CODE-001 收口 / **verified**
  （grep 全仓：智能成片侧 ADR-0016 残留 0，预览侧 5 处引用完整保留）
- 第四轮实例（2026-10-05 晚）：即便有本条，双机仍各产出一版 ADR-0019（智能成片 vs
  文档分层）与 pitfalls P49 双份（App 编译修复 vs skill/文档脚本）。处置：编号采纳
  集成机方案，本机侧让位改号（智能成片→ADR-0020、skill 条目→P58），引用按主题清扫。
  **再次证明：fetch 核号防不住并发取号，唯一解 = 集成机发号器串行发号**（PLAN-三线并行 §2）。

### P57 · Swift 6 严格并发：UIKit 交互要显式 @MainActor，注入闭包签名必须带 @Sendable
- 现象：SharedUI 相册 5 条警告 —— `UIImpactFeedbackGenerator.impactOccurred()` /
  `UIApplication.shared.open()` 在 nonisolated `static func` 里调用被拒（456/463）；
  `PHPhotoLibrary.requestAuthorization` 的 handler 收非 Sendable 闭包被拒（49）。
- 根因：Swift 6 把 UIKit 的这些类型标成 `@MainActor`；`requestAuthorization` 的
  handler 参数本身是 `@Sendable`，注入式依赖的**闭包签名必须与之完全一致**。
- 修法：`PickerFeedback` 两个方法标 `@MainActor`（让调用点由编译器校验，不是静音），
  `PermissionGuideView.onOpenSettings` 同步标 `@MainActor`；
  `AlbumPermissionModel.request` 的注入签名改为 `@escaping @Sendable (PHAuthorizationStatus) -> Void`。
- 验收：改注入签名必须重跑 `swift test`（71/71 绿才能证明测试注入点没被破坏）。
- 防复发规则：**Swift 6 下"只是警告"的 main-actor 隔离违规，在严格模式是运行时
  风险**，不能因为编译过就放着；注入式依赖改签名 = 改 API，必须连带跑测试。
- 日期 / 来源 / 验证状态：2026-10-05 / SharedUI 相册优化 / **verified**
  （5 条警告清零；SharedUI swift test 71/71；iOSApp 构建 0 error 0 项目警告）

### P58 · skill/文档描述"目标态"脚本不存在 —— 新会话照文档跑必失败
> ⚠️ 2026-10-05 编号更正（双机合并收口）：本条原编 P49，与集成机同号条目（App 目标从未整体编译）撞号，按让位纪律改号 P58。
- 现象：`cq-build-test` skill 引用 `tools/ci/run_gate.sh`、`tools/qa/golden_compare.sh`、
  `tools/shaders/build.sh`、`tools/build/clean.sh`，四个全不存在（`tools/compliance/`、
  `tools/shaders/` 只有 .gitkeep）；新会话按 skill 执行直接报错，此前无人发现
  因为没人真照着跑过。
- 根因：skill 写的是设计目标态（BACKLOG 的 INFRA-006/QA-002 未落地），文档没区分
  "现状 / 目标"。
- 修复：`run_gate.sh` 已落地（INFRA-010，2026-10-05）；golden 命令改指真实的
  `tests/golden/verify.py`；shader / clean 显式标注未实现。
- 防复发规则：**文档/skill 里出现的每个命令路径必须真实存在**；引用未实现脚本
  必须标"（未实现，BACKLOG <ID>）"。已写进 `docs/CODESTYLE.md` §5 与
  cq-code-review 巡检清单。
- 日期 / 来源 / 验证状态：2026-10-05 / CODE-001 全库巡检 / **verified**（脚本逐个 ls 核实）

### P59 · 合并标记残留进库 —— 远端把未解完的 `<<<<<<<` 块直接提交到 main
ADR-0020 文件头带着完整冲突块（`<<<<<<<< HEAD ... ======== ... >>>>>>>> origin/main`，
且七箭头畸形）被提交进远端 main，`# ADR-0019` 旧标题与"改号 0019"叙述一并入库。
**本机 `git diff main origin/main` 看不出来**——那是提交间差异，标记在提交内部；
能抓住它的是**提交前 `git grep -l '^[<=>]\{4,\}'` 与合并后的全库编号巡检**（本轮靠后者发现）。
- 防复发规则：**commit 前必跑 `git grep -n "^<<<<<<<\|^>>>>>>>" -- '*.md'`**（并入
  cq-code-review 收尾清单）；编号类合并收口必须做一次全库旧号扫描。
- 日期 / 来源 / 验证状态：2026-10-05 / 双机第四轮合并本机巡检 / **verified**
  （ADR-0020 文件头已修复；全库 `<<<<<<<` 扫描 0 残留）

### P60 · CI 渲进 MTKView drawable 静默失败 —— `framebufferOnly` 与 `ShaderWrite` 的坑
> 日期 / 来源 / 验证状态：2026-10-05 / 相机预览每帧报错（运行时日志实证）/ **verified**
> （usage 位图本机实测；blit 进 usage=0x04 drawable 无 error；根因机制闭环）

- 现象：控制台每帧刷这两行，画面不动（黑），但帧计数一路涨：
  ```
  -[CIRenderDestination initWithMTLTexture:commandBuffer:] texture usage must include MTLTextureUsageShaderWrite.
  -[CIContext(CIRenderDestination) _startTaskToRender:toDestination:...] The destination is nil.
  ```
- 根因：`MTKView.framebufferOnly = true`（**默认**）时 drawable 纹理**只有 `renderTarget` usage**
  （Apple 文档原话："you may not sample, read from, or write to those textures"）；
  而 `CIContext.render(_:to:commandBuffer:bounds:colorSpace:)` 内部要构造
  `CIRenderDestination(mtlTexture:commandBuffer:)`，**要求 usage 含 `ShaderWrite`**
  → init 返回 nil → 这一帧什么都没画。
- 本机实测 usage 位图（`CAMetalLayer.nextDrawable()`，AMD Radeon Pro 5300M / macOS 26.5 SDK）：
  `framebufferOnly=true` → `0x04 (RenderTarget)`、`texture.isFramebufferOnly=true`；
  `false` → `0x17 (ShaderRead|ShaderWrite|RenderTarget|PixelFormatView)`。
- 两个必须记住的子事实：
  1. **`renderTarget ≠ shaderWrite`**（Apple `MTLTextureUsage.shaderWrite` 文档明确二者不等价）。
     CI 写纹理走的是 shader write，不是 render pass attachment。
  2. **`framebufferOnly` 禁的是 shader read/write，不禁 blit / render pass 写入** ——
     实测 `MTLBlitCommandEncoder.copy` 进 usage=0x04 的 drawable，commit 后 `error=nil`。
     这就是「渲到中间纹理再 blit」这条路成立的前提。
- 伪绿陷阱：`render(_:to:commandBuffer:...)` **非 throws**，且 destination nil
  **不会落到 `commandBuffer.error`**。旧代码依赖「看命令缓冲错误」+「draw 末尾无条件计数」
  → 黑屏也能报满帧率。**计数类埋点必须绑定「真的出了效果」**，不能绑定「代码走到了这一步」。
- 修复（TASK-CAM-015）：CI 渲进自建中间纹理（usage 含 ShaderWrite，storage=private）
  → blit 进 drawable；计数改由 command buffer 完成回调按成功/失败分流，并加 os_log 摘要。
- 防复发规则：**任何把 CI 渲到 drawable 的代码，先核对 drawable 的 usage；新加帧率/耗时计数器时，
  先问「这个计数在彻底失败时会不会照样涨」**。

### P61 · 编译验证选错 scheme —— `-scheme ChuanqiCut` 其实只编 Pods 静态库 target
> 日期 / 来源 / 验证状态：2026-10-05 / TASK-CAM-015 验证踩到 / **verified**
> （canary 语法错误 seeded 后该 scheme 仍 BUILD SUCCEEDED；换 `-scheme ChuanqiCutApp` 才编译）

- 现象：`xcodebuild -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCut ... build`
  **BUILD SUCCEEDED、退出码 0、零警告**，但改动过的 App 源文件压根没被编译
  （中间产物 `.o` 时间戳停在几小时前）。
- 根因：workspace 里有四个 scheme（`xcodebuild -list` 可见）——
  `ChuanqiCut` 是 **Pods 生成的静态库 target**（编 `bindings/swift` 的封装），
  `ChuanqiCutApp` 才是 iOS App 目标。依赖图日志里 `Target dependency graph (1 target)`
  就是线索：**只有 1 个 target 时，编的一定不是 App**。
- 假绿等级：这是「编译通过也不作数」的极端形式 —— 连 `-Werror` 警告都没有，因为根本没编译。
- 防复发规则（两条一起用）：
  1. iOS App 验证固定命令：
     `xcodebuild -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutApp -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath <隔离路径> build`
  2. **改完 Swift 不确定有没有被编译 → 先塞一个必然报错的 canary（`1 + "x"`）跑一次，
     确认它真炸了再拿掉**。呼应 P46/P48：`-parse`/挑错 scheme 这类"轻检查"多次放过真问题。

### P63 · 用任务体里的 flag 做同步点 —— TaskRunner 计数在任务返回后才自增
> 日期 / 来源 / 验证状态：2026-10-05 / 门禁 core-dbg `core_thread_model` 失败 / **verified**
> （根因代码定位 + 复现率实测：空载 1/20、CPU 负载 1/30、单跑 5/5 绿）

- 现象：`tools/ci/run_gate.sh` core-dbg 42 条里只有 `core_thread_model` 红，
  失败断言「执行计数为 1」；Release 配置同msgid 100% 绿，单跑 5/5 绿。
- 根因（`core/src/session/task_runner.cpp` WorkerLoop）：
  ```cpp
  task();                                    // 任务体末尾执行 finished.store(true)
  executed_.fetch_add(1, std::memory_order_release);   // ← 任务**返回之后**才自增
  ```
  测试却在轮询到 `finished == true` 之后**立刻**读 `ExecutedCount()`。
  「任务体结束」和「执行计数自增」中间有一个窗口，负载抢占时被放大 → 计数仍为 0 → FAIL。
- 这不是 TaskRunner 的语义错误（"已执行完"自增在任务体之后是对的），**是测试选错了同步点**。
- 修复口径（**core 不在本次 CAM-015 写集内，未改，等拍板**）：把等待条件改成等
  `ExecutedCount()` 本身
  （上限轮询），再断言 == 1；不要拿任务体自己的 flag 当作「runner 已记账」的证据。
- 防复发规则：**跨线程测试的等待条件必须等「被断言的那个量」本身**，
  等一个相邻信号 = 埋了一颗负载相关的 flaky（同族：P31 哨兵法要盯目标效果本身）。
- 附带发现（门禁脚本）：`run_gate.sh` 的摘要会把**上一轮**的日志尾部一并打印
  （core-rel / swift / sharedui 的日志时间戳停在上一跑），一票否决后可能被人误读成"本次也过了"。
  看摘要必须同时看 `PASS/FAIL/SKIP` 计数与 `build/gate-logs/*.log` 的时间戳。




### P62 · App target 没有 DEBUG 编译条件 —— `#if DEBUG` 代码被静默剥掉
> 日期 / 来源 / 验证状态：2026-10-05 / TASK-UIA-032（原 UIA-015，2026-10-07 让位改号）走查踩到 / **verified**
>（`CQ_AUTO_ROUTE` 钩子在模拟器上不生效；补 SWIFT_ACTIVE_COMPILATION_CONDITIONS 后生效）

- 现象：App 源码里 `#if DEBUG` 的启动钩子编译后**不存在**（行为上直进编辑器失败），
  构建零警告零错误。
- 根因：CocoaPods 会给 **Pods 目标**默认注入 `SWIFT_ACTIVE_COMPILATION_CONDITIONS
  = DEBUG`，但 **App target** 的 xcodegen 生成的工程里原本没有这条 —— App 代码的
  `#if DEBUG` 全部被剥掉。之前 App target 没有 `#if DEBUG` 代码，所以从没暴露。
- 防复发规则：
  1. 双端 project.yml 已补 `settings.configs.Debug.SWIFT_ACTIVE_COMPILATION_CONDITIONS: DEBUG`
     （生成产物 pbxproj 中可 grep 验证）。
  2. App 侧新增 `#if DEBUG` 功能后，验证必须**跑行为**（模拟器启动实测），
     不能只看 BUILD SUCCEEDED —— 与 P61（scheme 假绿）、P48（-parse 假绿）同族：
     「编译通过」对**被预处理剥掉**的代码毫无约束力。


### P64 · 真机 UI 测试 runner「exit 74 before establishing connection」—— 锁屏即挂，手动拉起正常
> 日期 / 来源 / 验证状态：2026-10-05 / 启动基线测量会话（tools/perf/launch_bench 首次上真机）/ 
> 现象 **verified**（两轮复现）；根因=锁屏为 **hypothesis**（未解锁复测前不下结论）

- 现象：`xcodebuild test` 对真机（iPhone 17 Pro / iOS 26.6.1）跑 UI 测试，runner 安装成功但
  `Early unexpected exit ... exited with code 74 before establishing connection`，连续两轮；
  同一工程同时刻对模拟器全绿。
- 对照证据：`xcrun devicectl device process launch --terminate-existing` **手动拉起 runner 成功**
  （安装、签名、profile、Developer Mode 都没问题）——只有 XCTest 引导握死。
- 已耗掉时间的弯路，防复发：
  1. 真机 UI 测试挂 exit 74，先怀疑**锁屏**，解锁后重跑；别先去折腾签名/entitlements
     （手动 launch 成功 = 签名链路是好的）。
  2. `xctrace record --template 'App Launch'` 对真机**能录**，但 CLI 导出的只有裸 kdebug 表
     （0x31,0xca / thread-narrative 全进程 60MB），**导不出 GUI 里的 Process Lifecycle 里程碑**
     ——别试图用 xctrace XML 替代 `XCTApplicationLaunchMetric`，直接用 LaunchBench 那套 UI 测试。
  3. 同 bundle id 覆盖安装 Debug/Release 时注意 Xcode 26 的 sim Debug 是
     **ENABLE_DEBUG_DYLIB** 形态（代码在 `*.debug.dylib`，主二进制只有 25KB），
     与 Release（代码全在主二进制）包结构不同，比对包大小/符号时别拿错对象。


### P65 · blit 写 framebufferOnly drawable —— 无校验层的「实测无 error」不算证据
> 日期 / 来源 / 验证状态：2026-10-05 / TASK-CAM-015 真机 DEBUG 调试 SIGABRT /
> 现象 **verified**（校验层下第一帧必炸、100% 复现）；修后 SDK typecheck 通过，
> 真机复验归传哲（未实测帧率）

- 现象：`CameraRenderer.draw` 的 `encoder.copy(from: scratch, to: drawable.texture)` 在
  DEBUG（Metal API Validation 开启 / GPU 抓帧）下：
  `MTLDebugBlitCommandEncoder ... failed assertion 'Copy From Texture Validation
  destinationTexture must not be a framebufferOnly texture.'` → SIGABRT。
- 根因：Metal 规范**禁止对 framebufferOnly 纹理做 blit**（源/目标都禁；该纹理只允许当
  render pass 的 colorAttachment）。P60/CAM-014 记录的「blit 写入合法（本机实测无 error）」
  是**无校验层运行**下的未定义行为放行，不算证据。
- 与 P61 同族升级：不止「scheme 开关改变编译对象」，**校验层开关改变运行时合法性**。
- 修复（CAM-015 翻案）：`CameraVideoView` 改 `framebufferOnly = false`（blit 合法化，
  中间纹理保留作 CI 落脚点），CameraRenderer 两处错误注释勘误。真机帧率不达标时的
  出路是 blit 换 render pass，**不是改回 true**。
- 防复发规则：Metal/图形 API 的行为结论必须在**校验层开启**（DEBUG scheme 的 Metal
  API Validation、GPU 抓帧）状态下实测；引用「实测无 error」必须注明校验层开关状态。

### P66 · VT 解码器只认 'hvc1' —— 'hev1' 格式描述建会话必 -12906
> 日期 / 来源 / 验证状态：2026-10-05 / TASK-MEDIA-022 / **verified**
>（golden 'hev1' 文件复现 -12906；重建 'hvc1' 后 150 帧全解）
> ⚠️ 编号更正：原编 P63 与并行会话（CAM-015 TaskRunner 条目）撞号，按
> 「改动面小的让位」（PLAN-三线并行 §2-3）改为 P66。

- 现象：`VTDecompressionSessionCreate` 对 ffmpeg 产出的 HEVC MP4 返回
  **-12906 kVTUnsupportedDecompressionErr**，即使文件是普通 8-bit 4:2:0。
- 根因：VT 的 HEVC 解码器按 **'hvc1'** subtype 注册；'hev1'（ffmpeg 默认 tag）
  与 'dvh1'/'dvhe'（杜比视界）的格式描述匹配不到解码器。文件本身没问题
  （AVFoundation 能解析、AVAssetReader 能 passthrough）。
- 修法：用**同一份 hvcC**（参数集该厂商完全相同）`CMVideoFormatDescriptionCreate`
  重建 subtype='hvc1' 的格式描述再建会话。iPhone 实拍本来就是 'hvc1'，不受影响。
- 防复发规则：
  1. 媒体测试断言不要只覆盖 Apple 工具链产物 —— golden 里必须有 ffmpeg tag 的
     'hev1'（现有 `gf_1080p_hevc.mp4` 即是，别删）。
  2. VT 相关排障先打印 **OSStatus + codec fourcc + hvcC chroma/bitDepth**
     （`VideoToolboxDecoder` 失败分支已内置该诊断打印）。
  3. 运维注意：**两轮 run_gate.sh 并发会互踩**（prepare 替换 XCFramework 的瞬间
     另一轮的测试在读）→ 门禁一律串行独占跑。

### P67 · 三个「方向」枚举的 landscape 命名互换 + 没有 scene 级方向通知
> 日期 / 来源 / 验证状态：2026-10-06 / TASK-CAM-016 / **verified**
>（SDK 头文件原文引用，见 UIOrientation.h / AVCaptureSession.h）

1. `UIInterfaceOrientationLandscapeLeft = UIDeviceOrientationLandscapeRight`
   （UIOrientation.h 原文注释），且 AVCaptureVideoOrientation 头文件注释：
   LandscapeRight =「home button on the right」⇒ **UI ↔ AVCapture 的 landscape
   名字互换**：UI.landscapeLeft（home 在右）→ AVCaptureVideoOrientation.landscapeRight。
   **同名直映会在真机上横屏 180° 反接** —— CAM-016 首版即犯了同名直映，头文件核源后纠正。
2. iOS SDK **不存在** scene 级方向变更通知（`UIWindowScene.interfaceOrientationDidChange*`
   不存在，swiftinterface/头文件双确认）；触发源只有 `UIDevice.orientationDidChangeNotification`，
   且它**早于** scene 提交转场 —— 立即读 `scene.interfaceOrientation` 可能拿旧值。
   CAM-016 取值侧分 0/200/500ms 三次采样取终值（消费方同值去重，重复采样无害）。
3. `AVCaptureVideoOrientation` 自 iOS 17 整体弃用（指向
   AVCaptureDeviceRotationCoordinator）；新代码用 `connection.videoRotationAngle`
   {portrait:90, landscapeLeft:0, landscapeRight:180}，iOS 16 才走旧 API。
- 防复发规则：**涉方向/方位映射先 grep SDK 头文件注释，不凭记忆**（三套枚举命名
  各说各话）；映射表必须收敛在一处（CameraManager.rotationAngle / videoOrientation），
  注释里带头文件证据。

### P68 · macOS CLI 上 CIContext.render(to MTLTexture) 静默写零 —— 本机探针判不了 iOS 行序
> 日期 / 来源 / 验证状态：2026-10-06 / TASK-CAM-016 行序探针 / **verified**（本机矩阵实验）

写「CI 行序探针」（CVPixelBuffer 红顶蓝底 → render → 纹理读回）在 macOS 26 CLI 下：
private/shared/managed × 各 usage **全组合输出全零**、`commandBuffer.error = nil` ——
`render(_:to:commandBuffer:bounds:colorSpace:)` 在 macOS 脚本环境整体静默 no-op
（同输入走 createCGImage 正常出图）。⇒ **该 API 的 iOS 行为不能用 macOS 探针判定**
（P60 同族：非 throws API 的失败无处落）。另：CIRenderDestination 版 render 在
Swift 下经 `toDestination:` 标签也找不到（ObjC selector `renderImage:toDestination:` 未按预期导入）。
- 防复发规则：Metal/CI 行为探针先跑「自检基准」（如 CGImage 路径）确认环境有效再信
  结果；宿主 OS ≠ 目标 OS 的探针结论只算 hypothesis，iOS 行为必须模拟器/真机实证。

### P70 · 真机自动测量基建的三个坑（stdout 全缓冲 / xcodebuild 段错误 / Debug XCFramework）
> 日期 / 来源 / 验证状态：2026-10-06 / TASK-MEDIA-023 阶段 0 剖面 / **verified**
> ⚠️ 编号更正：原编 P67 与并行会话（CAM-016 方向枚举条目）撞号，按「改动面小的
> 让位」（PLAN-三线并行 §2-3）改为 P70（当日已有 P69）。

1. **`std::printf`/Swift `print` 走 stdout = 全缓冲**：`devicectl device process
   launch --console` 管道下诊断行永远憋在缓冲区（本轮连坑三次）。诊断输出一律
   `std::fprintf(stderr, …) + fflush(stderr)`（stderr 无缓冲）；Swift 侧同理。
2. **xcodebuild 对 'platform=iOS' 目的地偶发 SIGSEGV（exit 139，Xcode 26.6 自身
   bug，objc respondsToSelector 空指针）**：清 derivedData 无效；换
   `-sdk iphoneos -destination 'generic/platform=iOS'`（门禁同款）绕开。
3. **App 的 core 代码来自预构建 XCFramework（podspec vendored）**：改 core/*.cpp
   后必须 `build_core_apple.sh --config=Debug && bindings/swift/prepare.sh` 再
   xcodebuild，否则设备跑旧 core；门禁建的是 **Release（NDEBUG）**——`#ifndef
   NDEBUG` 的仪器/日志在设备上全部静默消失，真机剖面必须 Debug 配置重建。
   另：Xcode 26 的 Debug 产物是 **ChuanqiCutApp.debug.dylib**（非主二进制），
   strings/nm 验证要查对文件。

### P69 · AVAssetWriterInputPixelBufferAdaptor.pixelBufferPool 在 startWriting 前是 nil
> 日期 / 来源 / 验证状态：2026-10-06 / TASK-CAM-017（真机「录制无效」根因）/ **verified**
>（macOS 探针：startWriting 前 pool=nil、startWriting+startSession 后=有、取缓冲成功）

- 现象：真机录制「无效」—— `CameraRecorder.setupIfNeeded` 在 `startWriting` **之前**
  抓 `adaptor.pixelBufferPool`（nil），`appendVideo` 的池守卫又排在
  `startSessionIfNeeded` 之前 ⇒ 每帧在守卫处丢弃 ⇒ writer 永不 startWriting ⇒
  死锁 + 空产物。
- 修法（CAM-017）：序改「setup → startSession（首帧）→ 懒取池+缓存（取不到
  CVPixelBufferCreate 直配兜底）→ 渲染 → append」；`markAsFinished` 仅 `.writing`
  态可调（未知态调它 = NSInternalInconsistencyException）；收尾 0 帧 → 显式
  `.nothingWritten` 失败，不产空文件假成功（P60 族：计数必须绑定真出了效果）。
- 防复发规则：**依赖「系统在某状态后才有”的资源（池/连接/格式），取用点必须
  排在该状态达成之后，且有「未达成」路径的行为定义**；跨状态资源禁止在 setup
  阶段预取缓存。

### P71 · iOS 26 SDK 起 UIDevice 整体 @MainActor 隔离 —— 后台队列读 orientation 直接告警
> 日期 / 来源 / 验证状态：2026-10-06 / TASK-CAM-017 / **verified**（编译告警实证）
> ⚠️ 编号更正：原编 P70，与先取号的「真机测量基建」（P67 撞号让位而来）重号，
> 按「先入库保留」让位为 P71。

- `UIDevice.current` / `.orientation` 在 iOS 26 SDK 被标 @MainActor；sessionQueue 等
  非主线程上下文直接读 = "main actor-isolated class property 'current' can not be
  referenced from a nonisolated context"（本仓 Swift 6.1 下是 warning，更严配置即 error）。
- 修法（CAM-017）：**主线程入口显式传位姿** —— `configureAndStart(devicePose:)` /
  `switchPosition(devicePose:)`，ViewModel（@MainActor）读 `UIDevice.current.orientation`
  传入，manager 存 `devicePose` 供 sessionQueue 侧的方向标定用。
- 防复发规则：UIKit 高频对象（UIDevice/UIApplication/UIWindowScene）按 iOS 26 口径
  全部视作 MainActor 专属；后台线程需要的信息由主线程入口作为**值参数**带下去，
  不要在后台闭包里现读。

### P72 · RotationCoordinator 新建即读 = 拿到未初始化的 0 —— 把对的改成错的
> 日期 / 来源 / 验证状态：2026-10-06 / TASK-CAM-017 二修（后摄方向回归）/ **verified**
>（真机双现象反推定案：CAM-017 版本前摄 0° 正确 + 后摄 0° 横躺）

- 现象：CAM-017 用 `AVCaptureDevice.RotationCoordinator` 在 addInput 时同步读
  `videoRotationAngleForHorizonLevelPreview` 折算安装偏移，结果**后摄竖屏从正确
  （90°）变成横躺**——新建的 coordinator 该值依赖传感器数据、KVO 异步生效，
  同步初读拿到 0，偏移被算成 270° 叠给了后摄。
- 事故的正面价值：**恰好实证了前摄正确角度 = 0°**（前摄 90+270=0 显示正确、
  后摄 90+270=0 横躺 ⇒ 前后摄安装差 = 270° 常量，iPhone 族）。
- 终态：砍掉 coordinator，`videoRotationAngle = 静态表(P67) + (front ? 270 : 0)`，
  snap 90° 栅格。iOS 16 旧 API 是语义方向（系统内处理安装差），**不加**偏移。
- 防复发规则：**依赖传感器/motion 的 API（RotationCoordinator 角度、位姿）新建后
  同步初读不可信**——要么 KVO 等首个有效值，要么用无时序依赖的常量/查表。
  用它之前先问：这个值此刻真的已经算出来了吗？

### P73 · AVCapturePhotoSettings 默认走 HEIF 文件管线 —— photo.pixelBuffer 恒 nil
> 日期 / 来源 / 验证状态：2026-10-06 / TASK-CAM-017 二修（拍照无效根因）/ verified
>（API 契约：非 pixel-buffer 格式的 photo 不带 pixelBuffer；真机复验归传哲）

- `AVCapturePhotoSettings()` 默认 HEIF/JPEG 编码管线，回调里 `photo.pixelBuffer`
  为 nil —— PhotoRelay deliver(nil) →「拍照失败：未取到照片数据」= 真机「拍照无效」。
- 修法：`AVCapturePhotoSettings(format: [kCVPixelBufferPixelFormatTypeKey:
  kCVPixelFormatType_32BGRA])` 显式要 pixel buffer（与预览/录制链同口径，WYSIWYG）。
- 防复发规则：用 `photo.pixelBuffer` 前必须确认 settings format 是 pixel-buffer 类；
  「回调成功但数据字段 nil」是静默失败一族（P60/P69 同族），遥测要打数据字段本身。

### P74 · 收尾回调在主线程直读跨队列计数 —— 脏读 0 把成功录制判成失败删文件
> 日期 / 来源 / 验证状态：2026-10-06 / TASK-CAM-017 二修（池修复后录制仍无效的残余）/ verified（代码审查 + 锁修复）

- `finish()` 在主线程直读 `appendedFrames`（videoQueue 在 +=），脏读到 0 时
  `writtenFrames > 0` 不成立 → `.nothingWritten` → **删除已成功落盘的文件**。
  P69 修复后录制链路已通，这层把成功结果又吞了。
- 修法：自增与读全部收进锁；帧数改在 `finishWriting` 回调内经锁取（此刻
  isFinished 已挡新帧）。
- 防复发规则：跨队列状态判定成败时，**判定依据的读取必须与写入同一同步原语**；
  「成功条件里的计数」读到 0 与「真的没做」必须区分（0 也可能是读早了）。

### P71 · 同一 AVAsset 并发建 AVAssetReader → NSInternalInconsistencyException 崩溃
> 日期 / 来源 / 验证状态：2026-10-06 / TASK-MEDIA-026 后台扫描方案 / **verified**（真机崩溃复现 + 回退后消失）

后台线程给 `asset_`（与播放路径共享的 AVURLAsset）另建 AVAssetReader + TrackOutput，
与播放路径的 reader 操作并发 → `*** -[AVAssetReader addOutput:] cannot add an output
that has already been added to another AVAssetReader`（signal 6）。AVAsset 同 URL 的
并发 reader 操作不可靠。防复发：**同一文件的 demux 生命周期内只允许一个 AVAssetReader
实例**；需要并行读（索引/预览缩略图）时用独立的 AVURLAsset 实例。

### P72 · VT 静默丢帧 + `VTDecompressionSessionWaitForAsynchronousFrames` 永久阻塞 —— 播放 ~5s 冻结真因
> 日期 / 来源 / 验证状态：2026-10-06 / TASK-MEDIA-026 / **根因 verified**（成对日志：
> PopFrame enter 后无 exit，且无任何单次慢调用警报——卡在 VTWait 内部）；修复本机全绿，
> 真机复测待重签

- 现象：播放 ~5s 后 rendered/s=0（泵停转），请求照流（180/s）、t 正常推进、无单次
  慢调用警报。成对日志（enter/exit）定位：`PopFrame` 进入后**永不返回**。
- 根因：PopFrame 空队列分支的 `VTDecompressionSessionWaitForAsynchronousFrames`
  在 VT **静默丢弃**某帧（既不完成也不回调错误）时**永久阻塞**；解析式警报
  （析构时打印）对"永不返回"的调用天然失明，此前多轮警报未响即此故。
- 修复：PopFrame 内以 **2ms 轮询**替代 VTWait（回调异步入队），配最老 pending
  （含提交时刻表）>1s 的丢帧超时——超时清 pending + has_prev_ 失效 + kIoNotFound，
  上层重新 seek，播放自恢复。⚠️ Flush 内的 VTWait 同风险暂保留（Seek 路径触发，
  provider Seek 警报可见）。
- 防复发规则：**凡是"等异步回调"的等待一律禁止无上界阻塞**——要么轮询+超时，
  要么事件句柄；析构式（RAII）警报必须配合成对 enter/exit 日志才能抓"永不返回"。

### P75 · 解码输出队列「只进不出」→ 3.4GB → jetsam signal 9（播放 5 秒后永久冻结的真身）
> 日期 / 来源 / 验证状态：2026-10-06 / TASK-MEDIA-027 / **根因 verified**（真机两次
> 逐该厂商级复现：footprint=3375.0MB + `App terminated due to signal 9`；修复后本机
> ctest 42/42）。**修复后真机复验未做**（设备锁定，见 TASK-MEDIA-027 §5）

- 现象：真机（iPhone 17 Pro，相册 4K60 HDR MOV，解码输出 1080x1920 BGRA）播放前 4 秒
  正常（rendered/s=131→116），第 5 秒起 `rendered/s=0` 且**再不恢复**；Watchdog
  「卡在 provider+acquire」1174ms→8226ms 单调增长；DEBUG 剖面行 `footprint=3375.0MB`；
  进程被 signal 9 杀掉（jetsam，不是崩溃）。
- 根因：`VideoToolboxDecoder::PopFrame` 显示序连续性判据的第三条分支 ——「无在途帧且
  队列最小 pts ≠ 期望」时**原样返回 kIoNotFound 且不弹出**。期望值与队列最小帧都不变，
  下次 PopFrame 判定完全相同 → 无限重复；调用方 `AcquireExact` 收到 kIoNotFound 继续
  Feed → VT 继续解码入队 → 队列单调增长。8.3MB/帧 × 约 400~500 帧 = 3.4GB，与实测吻合。
  触发源：①**VFR**（iPhone 实拍常见）—— 「期望」由上一帧 duration 外推，帧长一变就
  永远对不上；②VT 静默丢帧。
- 排查手法（有效，可复用）：**把内存足迹并进周期性剖面行**（`task_vm_info.phys_footprint`），
  否则「卡死 + signal 9」无法区分 jetsam 与纯解码追赶失败。真机 `devicectl --console`
  抓 stderr 即可。
- 修复：①连续 8 次（`kMaxMismatchStreak`）等不到期望即判定缺口 → 交付队列最小帧并重锚
  `has_prev_=false`；②队列超 12 帧（`kMaxQueuedFrames`）跳过重排判据强制交付（不依赖
  判据正确性的内存闸门）；③`Flush()` 的 VTWait 换为轮询 + 1s 超时（P72 的债，每次 Seek
  都走，等于慢路径的永久阻塞入口）；④`OutputCallback` 改为**先入队后登记**
  （原顺序让「pending 空」不蕴含「帧已入队」，旧 GOP 帧会漏进新序列）。
- 排障踩到的反例（务必记住）：**首版修复「一见到不匹配就按缺口放行」把
  `media_sequential_real` 打挂**（fast=128000 / slow=116000，提前 3 帧）—— B 帧重排下
  「无在途帧且不匹配」是**常态**（参考 P 先到，其 B 帧在其后才喂入），必须按**连续次数**
  而非单次判定区分「重排窗口」与「缺口」。
- 防复发规则：**①任何"等某个条件成立"的重排/同步判据，都必须有一条不依赖该判据的
  内存上界闸门**；②判据失败分支必须区分「还没来」与「永远不会来」，且后者的放行阈值
  要按 B 帧重排窗口给余量，不能取 1；③回调内「登记完成」必须在「交付数据」**之后**，
  否则等待方的完成判据不蕴含数据可见。

### 编号纪律提醒（2026-10-06）
> P72 被两个来源各占一次：CAM-017 二修（RotationCoordinator 未初始化）与 MEDIA-026
> （VTWait 永久阻塞）。取号前必须 `grep -n "^### P" .ai/memory/pitfalls.md` 核水位，
> 不能只看当日日志里的号。

### P76 · Debug-only 的诊断设施在 Release 包里等于不存在 —— 本次排障赖以取胜的两个工具都是
  **日期**：2026-10-06　**来源**：MEDIA-027 → CORE-010　**验证状态**：已定位并修复（本机门禁 PASS=9/FAIL=0；core-dbg 43/43、core-rel 43/43）

- 现象：MEDIA-027 定位成功之后回头看，当时起到决定性作用的两处设施在**真机 Release 包里
  一条日志都不会留**：①`SlowCallAlarm`（>500ms 告警）在 **4 个文件里各抄一份**且全部是
  `#ifndef NDEBUG`（media_decode.mm / media_demux.mm / preview_pump.cpp /
  system_frame_provider.h，其中 pump 那份阈值还是 1000ms —— 同一工程两套阈值）；
  ②`WatchdogLoop`（报出「RenderFrame 卡在 'provider+acquire' 8226ms」的那个）连同它依赖的
  `DebugStage()`/`DebugStageSinceNanos()` 与 6 个 `DebugStageGuard` 全在 NDEBUG 块里。
- 为什么这是坑而不是取舍：**Release 才是真机使用的常态**，而冻结/内存类故障恰恰不会在
  Debug 包上发生。辛苦攒出来的诊断，只在「已经能复现的人」手里有用 —— 而排障现场
  往往正是那个还没复现出来的人。
- 同类衍生（本次踩到 3 次）：把一处的 `#ifndef NDEBUG` 解开后，**它依赖的成员变量/计数器
  仍留在 NDEBUG 块里** → Debug 通过、Release 编译失败。发生在
  `preview_renderer.h` 的 `debug_import_logs_`/`debug_reuse_logs_`、
  `system_frame_provider.h` 的 `debug_finalize_logs_`/`debug_chase_iters_`、
  `media_decode.h` 的 `debug_order_stall_*`/`debug_queue_cap_*`。
  **本机 Debug 全绿发现不了，只有 Release 构建才会炸。**
- 修复（CORE-010）：①`SlowCallAlarm` 收到 `core/base/perf.h` 成统一设施，带 workflow、
  默认阈值 500ms、Release 可用；②看门狗与阶段跟踪提到 Release（其余开销仅一次 relaxed
  atomic store + 一次 steady_clock）；③所有本来收进 NDEBUG 的**成员/计数器**同步解开。
- 防复发规则（见 [TASK-CORE-010](../../docs/tasks/TASK-CORE-010.md)）：
  **改完任何依赖 NDEBUG 的代码，必须 Debug + Release 双向编译验证**，不能只跑 Debug；
  判断某诊断「该不该进 Release」的标准是 —— **它报的是「系统在偏离正轨」还是「我想看细节」**，
  前者（降级发生、上界命中、慢调用、看门狗）一律 Warn 且 Release 可见，后者才留 Debug/Trace。
### P60 · 无锁 freelist 边写边定并发模型 —— 初版 Acquire 逻辑不自洽，靠自审在提交前抓住
AUDIO-001 的 AudioBlockPool 初版把「Treiber 栈」写成了一半：没有 per-slot next 数组，
CAS 弹栈后无处取后继，且注释里临时反悔换方案，逻辑闭合不上（自审发现，未进 commit）。
- 根因：并发容器**边写边设计**。CAS 期望值参数还必须是非 const（CAS 会写回），const 局部变量编译期才暴露。
- 防复发规则：**无锁数据结构动手前，先在代码注释/任务卡里定死并发模型**——谁 push/pop、
  防 ABA 手段（tag）、双重释放防护（per-slot 状态位）、内存序（acq_rel/acquire）四要素齐全才开写。
  本任务最终形态 = tag 索引 Treiber 栈 + per-slot 状态 CAS 双保险，见 `core/src/audio/pcm_pool.cpp`。
- 日期 / 来源 / 验证状态：2026-10-05 / AUDIO-001 实现 / **verified**
  （Debug+Release 全量 44/44 通过，含 4 线程×2 万次并发与 20 万序号 SPSC 压测）

### P61 · 测试等「早事件」断言「晚事件」—— core_thread_model 门禁抖动
`test_thread_model` 等 `finished`（任务体内置位，worker 先做）后立刻断言
`ExecutedCount()==1`，但 worker 是任务**返回后**才 fetch_add 计数——存在
「store 已见、自增未到」窗口。平日 invisibility（100ms 任务 + 空闲机器），
run_gate.sh 负载下实测抖出（Debug 43/44，"执行计数为 1" FAIL）。
- 修复：等待对象换成更晚的 `ExecutedCount`（超时 5s 护栏），再断言两者。
- 防复发规则：**并发测试的等待对象必须是断言链上最晚发生的事件**；
  时序断言在满负载门禁下会暴露，空闲单跑不绿≠稳定。
- 日期 / 来源 / 验证状态：2026-10-05 / run_gate.sh 首跑（AUDIO-001 轮）/
  **verified**（修复后连跑 5 次 50/50，重跑门禁见当日日志）

### P80 · harness 定标域 ≠ 真机运行域 —— CI 工作空间色彩管理让参数语义漂移
> ⚠️ 曾号 P62（2026-10-07 撞号让位：与并行会话「App target DEBUG」条目撞号，本条目后入库让位）。
CAM-012 磨皮 σr 在宿主 harness 用**未标记 BGRA**定标（默认 CIContext 下未标记输入
不做色彩匹配，kernel 看到的是 gamma 域亮度）；真机 `CIContext(mtlDevice:)` 默认
workingColorSpace=线性，带色彩标记的相机帧先被匹配到线性域 → 同一 σr 下皮肤边缘
亮度差放大 ~1.5-2× [E]，双边权重塌陷 → 保边失效 + 皮肤逐帧沸腾（用户报"画面开闪"）。
TASK-CAM-012 剩余风险栏其实预判了（"若真机上 CI 工作空间表现不同"），但真机验收
未做，坑存活到真机首验。
- 防复发规则：**凡 harness/宿主上定标的 CI 参数，必须同时在代码里显式钉死真机
  运行域**（`CIContext(options: [.workingColorSpace: sRGB])`），并保证两者一致；
  新 CI 消费方禁止依赖默认工作空间的隐式域。harness 与真机行为差异列任务卡
  剩余风险时，必须配一条真机验收项，否则等于没防。
- 日期 / 来源 / 验证状态：2026-10-06 / 真机验收反馈（CAM-018，曾号 CAM-015）/ 根因链
  **verified**（代码+注释+任务卡证据闭环）；修复有效性**待真机**（不闪/保边归传哲）。

### P81 · 宿主脚本先行可抓 CIImage DAG 假设错（两个实锤：坐标运算符与蒙版 extent）
> ⚠️ 曾号 P63（2026-10-07 撞号让位：与并行会话「TaskRunner 同步点」条目撞号，本条目后入库让位）。
写 FaceMask.swift 时先跑了宿主临时脚本（Swift 5.5 + macOS CoreImage 实渲染采样），
两个 API 假设错在进 commit 前被抓：① `CGPoint + CGVector` 在 CG Swift overlay 里
**不存在**（Foundation 的 AttributedString 重载还会来搅局报误导性错误）——写
`CGPoint(x:maxY:)` 显式构造；② `CIRadialGradient` 输出 extent **有限**（非无限），
`cropped(to:)` 只做**交集**——椭圆不叠底则"蒙版 extent = 椭圆矩形"，CIBlendWithMask
对越界蒙版采样透明黑才凑巧正确。叠 `CIImage(color:.black).cropped(to: extent)` 底
把语义显式化（全黑=直通）。
- 防复发规则：**新增 CIImage DAG（自定义几何/渐变/合成）时，宿主临时脚本实渲染
  采样先行**（宽容差断言白/黑/翻转方向），再落正式单测——DAG 构造 API 的 extent
  与坐标语义靠猜必踩。`guard let x` 简写（SE-0345）本机 Swift 5.5 **parse 不过**，
  宿主脚本须改写显式绑定，产物代码按构建机 5.9+ 口径不受影响。
- 日期 / 来源 / 验证状态：2026-10-06 / CAM-019（曾号 CAM-016）实现 / **verified**（脚本 14/14 后
  才落盘 FaceMaskTests；两处修复均回写进生产代码）。

### P77 · 「回调可能在另一线程完成」的注释只让我补了顺序，没让我补互斥 —— Feed() 无锁写 pending map 写坏红黑树，SIGSEGV @0x0
**日期**：2026-10-06　**来源**：MEDIA-027 验证期门禁 core-dbg 失败　**验证状态**：已定位并修复（A/B 对照 未修复 5/14 崩 vs 修复 0/14）

- 现象：`media_sequential_real` 在门禁 core-dbg 里 SIGSEGV（EXC_BAD_ACCESS @0x0）。本机单独重跑
  连绿 4 次，一度被当成 flaky。真堆栈（DiagnosticReports .ips）：
  `Feed()` → `std::map<int64_t,RationalTime>::operator[]` → `__tree_balance_after_insert` →
  `__tree_is_left_child` 解引用空节点。
- 根因：`pending_dts_pts_` / `pending_submit_nanos_` 的**全部 17 个访问点里，只有 `Feed()` 的
  两处插入是无锁的**；另一侧写入方是 VT 输出回调（`OutputCallback` → `Enqueue`/`MarkDecoded`，
  CoreMedia 线程，持 `queue_mutex_`）。异步硬解下「喂第 N+1 包」与「第 N 包回调」天然并发 ——
  两头并发写同一棵 `std::map`，红黑树被写坏。
- **引入点不是本次改动**：`pending_dts_pts_` 的无锁插入来自 `437bc16e`（2026-10-04，MEDIA-021
  重排登记）。当时的注释已经写明「回调可能在另一线程**立即完成并 erase**」——作者为了解决
  **顺序**（必须先登记后提交）而把它前移，却没意识到这句话本身就在告诉你**有第二个线程**，
  于是漏了互斥。MEDIA-027（`63c5100a`）在同一处加了第二笔无锁插入 `pending_submit_nanos_`，
  把竞态窗口扩大一倍，才在今天炸出来。
- **教训（一句话）**：**顺序对了 ≠ 互斥对了。** 只要注释里出现「回调/另一线程/异步」字样，
  顺手必须问一句「那把锁是谁？」并处理=无锁=的默认假设。
- 修复（`platform/apple/media_decode.mm`）：两处插入收进 `queue_mutex_`，且**必须在
  `VTDecompressionSessionDecodeFrame` 之前释放** —— 回调要抢同一把锁，持锁提交会自锁死。
  同时在 `media_decode.h` 成员处写明「受 `queue_mutex_` 保护」的不变量。
- **验证方法（关键，别只报连绿）**：并发故障不能用「跑几次没崩」结案。本次做法是
  **A/B 同源代码单变量对照** —— 只差这一把锁编两个二进制，12 核各挂 2 个 `yes` 制造负载，
  交错各跑 8 轮：未修复 3/8 崩（合并前一轮 2/6），修复 0/8；合计 5/14 vs 0/14。
  按 p≈0.36 计，「修复后 14 次全过是巧合」的概率 ≈ 0.2%。
- 防复发规则：**给共享容器加字段时，先 `grep` 该字段的每一个访问点并逐个指认守卫互斥量**；
  跨线程容器的不变量要写在**头文件成员旁**（代码会留下来，对话不会）。

### P78 · 另一会话用 `swiftc -parse` 当 SharedUI 验收标准 —— 38 处类型错误 + 一个从未提交的类型进了主干
**日期**：2026-10-06　**来源**：合并 `origin/main`（17 个远端提交）跑门禁发现　**验证状态**：**已修复**（2026-10-07：SharedUI 128 用例全绿 + iOS App BUILD SUCCEEDED 且项目代码 0 告警；详见 P79）

- 现象：门禁 `apple-sharedui` FAIL，`apps/apple/packages/SharedUI/Sources/SharedUI/Player/`
  下 10 个文件、38 个唯一编译错误站点。核 dgb/rel（45/45）与 Swift 绑定不受影响。
- 两类硬错误：①`PlayerViewModel.swift` 引用 **`PlayerZoomMath`，而这个类型在整个仓库历史里
  从未存在** —— 提交 `cc7267a`（UIA-024/017 进阶版 Batch B）的 message 里写明了它的规格
  （1x–3x 钳制 / 回弹阈值 1.15 / 拖移边界半幅×(scale-1)），但实现文件**压根没进 commit**；
  ②`SubtitleParser.swift` 缺 `import SwiftUI`（`Alignment`/`HorizontalAlignment` 全部 not in scope）、
  `guard let x = <Double>`、`text` 是 `let` 却被赋值、`current` 未定义 —— 全是**类型检查级**错误。
- 根因：该会话的验证命令是 `for f in Player/*.swift; do swiftc -parse "$f"; done`（写在其任务卡
  `verification` 里），而 **`-parse` 只做语法，不做类型检查** —— P46/P48/P49 已经踩过三次同一个坑，
  这次是它第一次把主干打红。**构建机 / 门禁从未在那一侧跑过。**
- 归属判定方法（可复用）：`git diff --cached origin/main -- <dir>` 显示该目录只有我这侧
  `AppEntry.swift` 的改动 → 13 个 Player 文件与 origin/main 逐字一致 → **不是我合并错了**；
  `git log --all -S <缺失符号>` 能找到「提到它但没实现它」的那个提交。
- 防复发规则：①**`-parse` 绿不是绿**，Swift 必须 `-typecheck`（SharedUI 侧还要带
  `-swift-version 6`）；②外部会话的产物进主干前，**必须在合并侧跑一次完整门禁**，
  不能因为「对方自称验证过」放行（远端的"已验证"按未验证处理，见 CLAUDE.md 委托小节）；
  ③任务卡 `verification` 里出现 `-parse` 应直接驳回。

### P79 · 「从未编译过」的代码不是「没 bug」，是「bug 全没被发现」—— 修完 38 处编译错误后，行为 bug 成批浮出
**日期**：2026-10-07　**来源**：P78 的修复过程　**验证状态**：已修复（SharedUI 128 用例全绿；iOS App BUILD SUCCEEDED + 项目代码 0 告警）

- 事实：`SharedUI/Player/` 那一批代码**从未被编译过**，所以第一次真编译（P78）暴露 38 处错误；
  修到能编后第一次真跑测试（128 例），又暴露 **5 处行为 bug**。每一处都不是我能猜到的，
  全是测试 ⇄ 实现的口径差：
  1. `Dialogue` 行 `split(separator:",", maxSplits: 8)` 只切出 9 段，而守卫是 `fields.count >= 10`
     → **所有字幕行被静默丢弃**（`guard ... else { continue }` 吞得毫无声息）。
  2. `PlayerRecentStore` 里 `urlString` 存的是 `absoluteString`（`file:///...`），却拿去喂
     `FileManager.fileExists(atPath:)` → 恒 false → **每次装载把全部本地条目清空**，
     「跨会话最近播放」名存实亡。
  3. `didSet` **在 init 里不会触发** —— 从 UserDefaults 恢复的倍速没有推给引擎，
     「记忆读出来了但速率还是 1x」。
  4. 循环/Double-tap 分支调了 `engine.play()` 却没同步 `isPlaying`，UI 停在暂停态。
  5. `String(data: encoding: .utf16)` 对「只有 BOM / 长度不足」会**成功返回空串**，
     导致坏文件被判成 `.empty` 而不是 `.unsupportedFormat`。
- 教训：**「编译过了」只代表语法与类型自洽，不代表行为成立。** 一个模块若能编却从未跑过测试，
  它的 bug 密度等于「没写过测试」的模块。补的时候唯一有效的抓手是**先让既有测试跑通顺** ——
  这五处全部是被测试直接指出的，没有一处靠肉眼审查发现。
- 方法沉淀（可复用）：**修复别人的半成品时，按「编译 → 单测 → 平台编译」三级推进，每级只修本级暴露的问题**，
  不要试图一次性读懂全部意图；测试是唯一权威的规格说明书。
- 顺带清掉的假注释：源码里写着「本机 SDK 验证无弃用标记」—— 实际 iOS 编译报两条弃用告警
  （`chapterMetadataGroups` / `AVMetadataItem.stringValue`，iOS 16 起）。**没编译过的验证结论一律作废。**

### P82 · 双机并行执行同一份 TODO 清扫 / 管理文档改动 —— 结论同向、编号照样分叉，一半返工
**日期**：2026-10-07　**来源**：撞号归一轮（本机 4f0aa67 与远端 14f9ec9 同日各执行 TODO-1 撞号清扫）　**验证状态**：已沉淀为规则（ADR-0029：待办池 append-only + 管理文档单写者）

- 现象：本机与远端在同一天各自执行同一份「撞号清扫 TODO」。裁定方向完全一致
  （编辑器线让位），但新号分配各自为政：本机发 UIA-028/029，远端发 UIA-032/033 并已
  推送嵌入 PLAN 预占体系 —— 本机半成品弃用重做，纯文档轮白烧一轮。
- 教训：**裁定结论可以两台机器共识，写操作只能单方执行。** 编号/池/告警头/文档清扫类
  改动是多写者冲突区，`git fetch` 核对防不住同日并行（P51「双会话同取 ADR-0016」同款
  根因在文档层的重演）。
- 防复发规则（ADR-0029 固化）：①`TODO-POOL-门禁真机待办池.md` 开发机**只追加
  （append-only）**，清扫/关闭/编号只归集成机；②开发机对既有文档的编号/告警头改动一律
  改为「向集成机提案」；③模块级撞面靠归属表事前避免（PLAN-三线并行 §1a），
  不再靠事后裁定。

### P83 · `kCVPixelBufferColorSpaceKey` 进了主干 —— 美颜合并轮的相机代码在 App target 首次真编译即炸（凭记忆写 API 案底第 5 次）
**日期**：2026-10-07　**来源**：壳工程 Pod 拆分阶段 0/1 双壳构建验证（首次对 9da6270 美颜合并轮跑 iOS App target 编译）　**验证状态**：已修复（`kCVImageBufferCGColorSpaceKey`；iOS/mac 双壳 BUILD SUCCEEDED）

- 现象：iOS `-scheme ChuanqiCutApp` 构建失败：`CameraRecorder.swift:130 cannot find 'kCVPixelBufferColorSpaceKey' in scope`。文件 `import CoreVideo` 齐全，怀疑点不在 import。
- 根因：**SDK 里没有这个常量**。实锤方法：`grep -rn ColorSpaceKey $(xcrun --show-sdk-path --sdk iphonesimulator)/System/Library/Frameworks/CoreVideo.framework/Headers/` —— 全部 CoreVideo 头文件只有 `kCVImageBufferCGColorSpaceKey`。美颜合并轮（9da6270，远端）凭记忆写了"看起来合理"的常量；该轮自述验证 = `swiftc -parse` 对照（只查语法不查类型），且该文件此前从未被 App target 真编译过 —— P46/P48/P49/P78 同一坑第 5 次。
- 修复：改用 `kCVImageBufferCGColorSpaceKey`（iOS 4.0+，值 = CGColorSpaceRef；CVPixelBuffer 继承 CVImageBuffer 的附件键语义）。CAM-018「预览 vs 录制颜色一致性」真机验收点依赖这个 sRGB 标记，修复后按池 [2] 执行真机项。
- 防复发规则：①**合并快检必须含 App target 真编译**（`xcodebuild -sdk iphonesimulator build` + mac Debug build，增量约 2~5 分钟）——`-parse` 对照不构成证据，已写进 ADR-0030 快检清单；②写 AVFoundation/CoreVideo 常量前先 grep 本机 SDK 头文件定名，不凭记忆、不上网猜。

### P84 · 新建包的 `.build/` 被 `git add -A` 收进提交 —— 产物入库零容忍，逐包登记 ignore 的模式失效
**日期**：2026-10-07　**来源**：ChuanqiCutPlayer Pod 迁移提交（7e626d7 原始版带 45 个 .build 产物文件，推送前抓回修正）　**验证状态**：已修复并固化为门禁步骤（artifacts 检查，PASS 基线 10→11）

- 现象：`git add -A && git commit` 把 `apps/apple/packages/ChuanqiCutPlayer/.build/`（SPM
  编译产物：build.db、debug.yaml、描述文件等 45 个文件）收进提交。根因 = `.gitignore` 的
  SPM 忽略规则是**逐包登记**的（`apps/apple/packages/SharedUI/.build/`、`bindings/swift/.build/`），
  新建包没有条目，而传哲规则本就要求「构建产物禁止提交」（AGENTS 红线级），漏网纯属工具性疏忽。
- 修复（三件套，2026-10-07）：①`.gitignore` 改**通配规则** `apps/apple/packages/*/.build/`
  + 顶层 `/.build/`，新建包不再逐包登记；②`run_gate.sh` 新增 **artifacts 检查**（2b 步）：
  `git ls-files` 命中 `.build/`、根 `build/`、`DerivedData/`、`.xcuserstate`、`.DS_Store`
  即一票否决——规则不再靠自觉，靠门禁兜底；③**临时编译统一目录**：SPM 全部
  `swift test --disable-sandbox --scratch-path "$ROOT/build/spm/<包名>"`（门禁已改），
  仓库内临时编译产物只落 `/build/` 一个地方，包目录保持干净。
- 教训（一句话）：**新增可构建目录 = 必须同时确认 ignore 覆盖 + 门禁有兜底检查**；
  `git add -A` 提交前 `git status` 甄别产物是每次提交的固定动作（与「8 项自检」同等级）。

### P85 · 相机 Pod 迁移的三个「BUILD SUCCEEDED/FAILED 假象」—— .metal 进内建 Metal 阶段 / script_phase 产物到不了 App / scheme 住 xcuserdata
**日期**：2026-10-07　**来源**：INFRA-018 ChuanqiCutCamera Pod 迁移双壳验证　**验证状态**：已修复并有正向证据（metallib 8431B + kernelNames 齐全 + 双壳 BUILD SUCCEEDED）

1. **`.metal` 写进 podspec `source_files` → CocoaPods 把它挂进 Xcode 内建 Metal 编译阶段**
   （无 `-fcikernel`）→ air-lld 报 `symbol(s) not found: coreimage::Sampler::sample/coord/extent`
   （正是 ADR-0021 明令禁止的路径）。修：`source_files` 只收 `.swift`，`.metal` 仅作为
   构建脚本的输入。
2. **静态库 Pod 的 `script_phase` 产物到不了 App bundle**：script 输出进 Pod 资源暂存
   目录，而 Copy Pods Resources 只拷 **install 期声明**的资源 → 构建期生成的 metallib
   永远不会出现在 .app；且 script_phase 未声明 inputs/outputs 时**增量构建被跳过**。
   我一度拿 App 里残留的旧产物当成功（P65「实测无 error 不算证据」同款）。修：管线
   **留在壳工程**（iOS project.yml postBuildScripts，`SRC` 指向 Pod 内 .metal 源；
   xcodegen 管理）——源归 Pod、资源装配归壳（ADR-0031 哲学）。
3. **scheme 住在 xcuserdata**：旧 `ChuanqiCutApp` scheme 是 Xcode 自动建的（用户态），
   `xcodegen generate` 重新生成工程后即丢；xcodebuild 自动补的 "ChuanqiCut" scheme
   不含 App target → 「BUILD SUCCEEDED 但 App target 零 phase」的假成功。修：
   `project.yml` **显式声明 `schemes:`**（ios + mac），不再依赖本机 xcuserdata 状态。
4. 附：pod-依赖-pod 时 `CChuanqiCut` module 可见性要在**依赖方 podspec** 自行注入
   `SWIFT_INCLUDE_PATHS`（SharedUI.podspec 2026-10-02 案底的复现，ChuanqiCutCamera
   已按同款配置）——凡依赖 SharedUI 的 Pod 一律照抄。

### P86 · 同机双会话并行开发——一方未提交的工作被另一方 `git add` 吞进无关提交
**日期**：2026-10-07　**来源**：本机并行会话（UIA-037/038 编码轮 × 引擎收拢/Pods 导航器轮）　**验证状态**：已发生（案底：UIA-037/038 源码与卡混入 ced6a00..8c726c9「Pods 导航器」提交；规约自本轮起执行）

- **现象**：会话 A 编码中（源码 + 新卡落盘未提交），会话 B 在同仓库推进并提交
  （ced6a00..8c726c9），A 的全部产出被 B 的提交顺带收走——提交信息与内容不符
  （缩略图/居中播放头源码躺在「Pods 导航器」提交里），"任务状态对着 commit 历史核"
  直接核不上。
- **危害**：①一个提交混两条线，revert/审查/溯源全废；②A 的未验证代码被 B 的
  提交动作"洗白"成已入库状态，验证状态更难追踪（远端代码默认没编译过 + 混入即失真）。
- **规约（同机多会话三条）**：①开工先 `git status` 甄别在途变更归属——不属于本
  任务的（含暂存区 rename）不碰、不提交、不 restore；②提交前 staged diff 逐文件
  过目，发现非本写集文件立即剔出（`git restore --staged <file>`）而不是顺手带走；
  ③同机并行各自声明写集、错峰提交，高冲突文件串行。
- **关联**：P82（双机同改管理文档分叉）的同机变体；P84（git add -A 产物入库）同族
  ——提交前 status 甄别是与八项自检同级的固定动作。

### P89 · 跨会话半成品接线——引用从未实现的符号，整个 Pod 编不过（且违反本卡明文约束）
**日期**：2026-10-08　**来源**：上一工具会话在 ChuanqiCutCamera 的 CAM-027 接线 vs 本机收口轮（HANDOFF-017 / 池 [9]）　**验证状态**：已修（回退接线 + 全仓 grep 归零）；构建机编译仍待验

- **现象**：`CameraRenderer.process` 里写了
  `beauty.apply(to: image, faces: faces, skinMask: PortraitSemantics.skinMask(for: image))` ——
  `PortraitSemantics` 全仓只在 `TASK-CAM-027.md` 的 write_set 里出现过、**没有一行实现**；
  `CameraBeautyParams` 也只有 `apply(to:faces:)` 一个签名，**没有 `skinMask:` 重载**。
  两个符号同时不存在 → **ChuanqiCutCamera Pod 整包编译失败**（不是"跑起来错"，是过不了编译）。
- **为什么没被当场发现**：本机 Xcode 13.1 / Swift 5.5.1 编不了这个 iOS Pod（部署目标 iOS 16、
  代码已经用了 Swift 5.7 的 `if let x {` 简写），而 SPM 侧 `swift-tools-version:6.1` 在
  swiftpm 5.5 下也解析不了 —— **没有任何一条本机能跑的验证路径**覆盖到这处改动（见 P90）。
- **第二条错误更值得记**：这段接线**违反了它自己的任务卡约束**。CAM-027 卡白纸黑字写着
  「消费方调用零改动、API 形状保持 `apply(to:faces:)` 不变、内部升级」。写的人是给调用方
  **加了个参数**，把复杂度甩给了每一个调用方。
- **规约（三条）**：
  1. **收工时把自己这次新引用的符号逐个 grep 一遍定义**（类型名 / 方法重载 / 静态成员），
     尤其是「跨会话、跨工具交接」来的改动 —— grep 不到定义 = 一定是编译错误，不用等构建机。
  2. **动手前重读本卡 acceptance 与"实现要点"的反面约束**（"API 不变""调用方零改动""只追加不动既有段"之类），改动形状与卡冲突时，冲突的是改动。
  3. **本机验证不了 ≠ 可以留半成品**：验证不了就**回退到上一个可编译状态**并把缺口写进池，
     半吊子接线留在树里只会让下一个接手人先花半天拆雷。
- **关联**：P86（同机多会话 git add 互吞）—— 都是"多个生产者在同一个工作区里交接"的代价；
  P78（`-parse` 绿不是绿）—— 同族的验证幻觉。

### P90 · 交接记录里必须写「本机工具链能力」，否则"待构建机验证"会永远挂空
**日期**：2026-10-08　**来源**：HANDOFF-017 收口轮核环境　**验证状态**：已修（MEMORY §17 加漂移注记 + HANDOFF 明写能力边界）

- **现象**：`.workbuddy/memory/MEMORY.md` §17 把本机登记成「macOS 26.7.1 / Xcode 26.6」，
  实测是 **macOS 12.7.6 / Xcode 13.1 / Swift 5.5.1 / iPhoneSimulator SDK 15.0，
  且无 cmake、无 ninja、无 brew**。几份近期文档里出现的「待构建机」「本机 X 均值」因此
  失去了归因依据——不知道那些数字和结论到底是在哪台机器上产出的。
- **危害**：① 接手人按旧记录以为本机 `swift test` / `build_core.sh` 能跑，第一步就撞墙；
  ② baselines 里的"本机实测"数字如果是另一台机器（另一条工具链）产的，拿来当验收阈值
  就是错数据（项目硬规则：引用 baselines 必须带机器环境）。
- **规约**：① 任何 HANDOFF / 任务卡「进度」涉及验证时，**先写三行**：系统版本、Xcode 版本、
  有/无 cmake·ninja·brew；② 结论要么标明机器代号（§17 的 A/B/C），要么写「未实测」；
  ③ 发现旧记录与实际不符就地改并留日期，**不要沿用**。
- **待办**：§17 机器表需要一次归口核对——把基线里每条"本机实测"回填到它的真实机器代号下。

### P91 · `CIImage.cropped(to:)` 是**交集**不是外扩 —— 拿「画面 extent」必须合成，不能裁
**日期**：2026-10-08　**来源**：构建机首次跑 Camera 测试，`MakeupMaskTests.testRadialMaskExtentIsCroppedBack` 失败　**验证状态**：已修（radialMask 改 `composited(over:)` 黑底画布）

- **现象**：`CIRadialGradient` 输出 extent 有限（P81 已实锤），于是代码用
  `.cropped(to: extent)` 指望「夹回画面」——实测 `irisMask` extent 仍是 **(43,43,14,14)**
  而不是 (0,0,100,100)：**cropped 做的是两个矩形的交集**，有限矩形 ∩ 画面 = 有限矩形自己，
  它永远不会把 extent 变大。
- **正确形状**：先把渐变**合成到同尺寸黑底画布**上（`output.composited(over: CIImage(color: .black).cropped(to: extent))`），
  再 `.cropped(to: extent)` 兜底。合成才有「并集/铺满」语义。
- **连带教训（同一条测试）**：`polygonMask` 的羽化 `featherRadius × extent.height` 在 100px
  单测画布上 = 2px，足以把 20px 小三角的**形心采样**压到 195（阈值 200）。按比例取羽化没问题，
  但**断言要取真正的内部点**，且羽化半径要有 1px 下限——否则小画布上「有羽化」这件事测不出来。
- **另修**：`triangleMask` 位图原先按局部坐标写、产物 extent 从 (0,0) 起算 → 画布 origin 非零点原时
  几何整体平移。改成像素绝对坐标 = `extent.origin + 局部`，产物再 `transformed(by:)` 平移回 origin。

### P93 · `AVCaptureMultiCamSession` 不支持 `sessionPreset` —— 设了直接抛异常崩溃（不是返回 false）
**日期**：2026-10-09　**来源**：iPhone 17 Pro 真机进相机页即闪退（NSInvalidArgumentException: `AVCaptureSessionPreset1920x1080 is not a supported preset`）　**验证状态**：已修（multiCam 走逐设备 activeFormat），**真机复验待传哲**

- **现象**：`CameraManager.makeSession()` 在 `AVCaptureMultiCamSession.isMultiCamSupported` 为真时
  **永远**建 MultiCam 实例（不管双摄开关有没有开），而 `configureLocked` / `setCaptureQuality`
  又无条件 `session.sessionPreset = ...` → iPhone 15/17（isMultiCamSupported 恒 true）上一进
  相机页就崩。**这不是边界机型，是默认路径。**
- **为什么门禁没抓到**：纯编译期类型检查看不出来——`sessionPreset` 是 `AVCaptureSession`
  的合法 API，multiCam 是它的子类，只是**运行时拒绝**；SPM/macOS 侧根本跑不到这段代码
  （相机实现层 iOS 专属不进 SPM target）。这是 P83/P48 同族的"凭记忆写 API"第 6 次。
- **正确形状**（Apple 口径：multi-cam 必须逐设备设 `activeFormat`）：
  1. 分流：`session is AVCaptureMultiCamSession` → **不碰 preset**，改对每个 video input 的
     device 选 format（在覆盖当前 fps 的候选里取分辨率最接近档位目标的一个），
     设完 `activeFormat` 必须**重放帧率**（换 format 会重置帧率范围）。
  2. 普通 Session 仍走 `canSetSessionPreset` → `sessionPreset`。
  3. **新建 input 也要重放档位**（`addVideoInputLocked`），否则新设备走默认 format。
- **规约**：① 任何对 `AVCaptureSession` 的设置，先问"MultiCam 子类会不会拒绝"；
  ② 崩溃签名是 `NSInvalidArgumentException` 而不是返回值失败时，**别指望 canSet* 能拦**，
  走类型分流；③ 相机实现层 iOS 专属，**真机是唯一能验的路径**，编译过 ≠ 能跑
  （这次就是门禁 PASS=14 全绿之后真机一开就崩）。

### P92 · CocoaPods 路径不会自动拾取新文件 —— Pods.xcodeproj 陈旧 = 几十条 `cannot find type in scope`
**日期**：2026-10-08　**来源**：iOS 壳 `-scheme ChuanqiCutApp` 首次真编译（Pods 工程为 2026-10-07 产物）　**验证状态**：已修（`pod install` 重生成）

- **现象**：Camera Pod 新增 4 个 Swift 文件后，SPM 侧 `swift test` 立刻能编（Package.swift 按目录收），
  但 iOS 壳构建报 **42 条 `cannot find type 'MakeupParams' / 'PortraitSkinMask' / 'MetalFXScaler' in scope`**。
  根因不是代码：`Pods/Pods.xcodeproj` 是 `pod install` 那一刻生成的**文件清单快照**，新文件不在工程里，
  同模块内的类型自然"不存在"。
- **规约**：① podspec 用通配 `source_files` **不等于**免登记——**新增/删除文件后必须在两端跑 `pod install`**
  （ios / mac 各自一份）；②「SPM 测试绿」不能外推到「App 构建绿」，这两条是**两条独立的源文件清单**；
  ③ 报一片 `cannot find type in scope` 时先 `grep` 新文件名在不在 `Pods.xcodeproj` 里，别先去查代码。
### P98 · backlog 写集路径整体过期 —— `core/src/*` 在 INFRA-022 后已迁至 `engine/core/cq/*`
**日期**：2026-10-10　**来源**：RESEARCH-010 编辑功能现状核验，backlog §3.4/§3.6/§4.3 与实际布局比对　**验证状态**：已确认（事实核对，非修复）

- **现象**：`TASK-BACKLOG.md` 里 EXPORT-001/002/003、EDIT-001~006、PROJ-001~004、MODEL-003 等
  未开工卡的**写集一律写 `core/src/export/*`、`core/src/model/*`、`core/src/effect/*`**。
  但 INFRA-022（2026-10-07）已把引擎源收拢到 `engine/`，实际编译单元清单在
  `engine/core/CMakeLists.txt:17-84`，路径形如 `engine/core/cq/...`。`core/src/` 现在只剩 `.gitkeep`。
- **为什么没人早发现**：全局册（BACKLOG）自规划后再未被系统维护；而所有引用它的卡都是**未开工**状态，
  没人按写集去建文件，于是"路径错"长期不表现为任何错误。**这是隐性过载，不是显性故障。**
- **规约**：① 领 backlog 里的老卡时，**先核写集路径再动手**，以 `engine/core/CMakeLists.txt` 为准，
  不以 backlog 表格为准；② 若某卡结论已被近期 INFRA/ADR 推翻，**先提案改卡再开工**，不要复活过期形状；
  ③ 每季度做一次「BACKLOG 写集 vs 真实布局」的一致性清扫，别等开工才发现。

### P99 · 门禁绿 ≠ 功能可用 —— 「完成」口径里缺少用户可见性这一栏
**日期**：2026-10-10　**来源**：RESEARCH-010 §3.3；用户反馈「编辑没啥功能，跟没做差不多」　**验证状态**：口径建议未采纳（待传哲拍板）

- **现象**：门禁 = `build_core.sh`（编译）+ `ctest`（单测）+ golden 齐备性，三项全 PASS（PASS=14/FAIL=0）
  的情况下，编辑页实际只有 9 项可用，底部「音频/文字/特效」三个按钮是 `enabled:false` + 空闭包，
  **且全仓 `Sources/` 下搜不到任何 `TODO`/`FIXME`** —— 项目用"显式置灰 + 空闭包"表达未就绪，
  这类占位在编译和单测里**完全静默**。
- **为什么门禁抓不到**：置灰按钮是合法 Swift，`enabled:false` 不会让 `-Werror` 报警；
  没接出来的 C ABI 函数没人调用，链接期也不报错；缺失的导出功能根本没有代码，**没有可失败的对象**。
- **规约**：① 新增交互式功能的验收，必须在任务卡里写「用户操作路径 → 可观察结果」的走查证据
  （截图/日志），**仅编译绿 + 单测绿不得标记完成**；② 按钮/入口若本期为占位，**必须在任务卡写明"占位"
  并在验收表列出**，禁止用空闭包静默表达；③ 报"某模块完成"时，一并给出该模块的**用户可见能力清单**，
  而不是只给 PASS 数字。这条建议改 `AGENTS.md`「验证」节 —— 真源改动需传哲拍板后才落地。

### P100 · Edit 对含 markdown 表格的长片段替换可能报 success 却不落盘
**日期**：2026-10-10　**来源**：修订 RESEARCH-010 §5/§6 时连续两次大段替换丢失　**验证状态**：已规避（换写法）+ 事后 Grep 结构核验通过

- **现象**：对一段含多个 markdown 表格的长文本调用 Edit，工具返回成功，但随后 `Grep '^## '`
  发现章节结构仍是旧的 —— **替换没有真正写入**。同一文件此前已有一处成功的 Edit（纯文本行），
  说明不是文件权限问题，而是**长片段 + 表格**的组合。观察到表格会被写后钩子重排列宽
  （`| a |` 变成对齐的多个空格），推测钩子在读改写过程中使用了格式化前的底稿。
- **危害**：静默失败，且工具返回的仍是 success。**凭工具返回值判断成功是错的。**
- **规约**：① 任何涉及 markdown 表格的大段改动，**改用 `python3` 按行号截断 + 尾部重写**
  （`lines[:idx]` + 新内容），不要依赖长字符串匹配；② 改完必须用 `Grep '^## '` 或读文件
  核实章节/内容真的变了，把"工具说成功"降级为待验证信号；③ 写完后顺手再读一遍关键段落，
  尤其是表格相邻的标题层级有没有串号。

### P101 · 商用 SDK 竞品调研的取数坑 —— 中文文档抓不到、源码仓库拖不动
**日期**：2026-10-10　**来源**：RESEARCH-011（该厂商 其创作 SDK × 阿里云 UGSV 竞品调研）　**验证状态**：已确认（两条迂回路径均实测奏效）

- **现象**（两个独立的坑，都会让「去查一下竞品」直接卡死）：
  1. **该厂商云服务中文文档是 JS 动态渲染**：`WebFetch https://docs.该厂商云服务.com/docs/6839/1535345`
     返回**空内容**（不是 403，是正文根本不存在于响应里 —— 内容只在浏览器里渲染出来）。
  2. **阿里云 UGSV iOS demo 仓库 132 MB**：`git clone --depth 1` 与 `codeload` tarball 均在
     **4 分钟无进展后超时失败**。为核一眼功能清单去拖 132 MB，性价比极差。
- **迂回路径（实测奏效）**：
  1. 该厂商 → 走**海外同产品的 该厂商海外品牌 英文文档站**（`docs.byteplus.com/docs/video-editor-sdk/*`，
     同产品、公开可访问、正文是静态的），以及**搜索引擎摘要**（结果片段常直接含正文原句，
     等于变相拿到渲染后的内容）。中文页被索引到的"错误产品 ID 路径"（如 `/docs/6408/1582522`）
     内容也是真的，能用。
  2. 源码 → **不下载，改用 GitHub tree API**：
     `curl "https://api.github.com/repos/<org>/<repo>/git/trees/main?recursive=1"`
     （本次 2.0 MB JSON / 5693 条目）。按**文件名关键字**做能力核验（如 `split`/`undo`/`redo`/`draft`
     命中数 = 0 即为没有），再按目录列功能矩阵 —— 快、可复现，且比读文档宣称更硬。
- **规约**：① 竞品/第三方技术调研**先假设官网抓不到**，直接找该产品的**海外站 / 镜像站 / 搜索引擎摘要**，
  别在渲染型页面上反复重试；② 需要"某某功能存不存在"这类**布尔结论**时，优先用
  **仓库 tree API + 文件名检索**，不要为一个布尔值拖整个仓库；③ 结论里必须区分
  「文档宣称」与「源码/实测」—— 本次阿里云官方文档称支持草稿箱，源码 0 命中，二者不一致。
- **顺带的事实结论**（对选型有用）：**商用剪辑 SDK 的 UI 源码基本不给** —— 该厂商明确"SDK 暂不公开提供，
  需联系技术支持"，给的是 UI 标注文档；阿里云是**少见的 UI 源码 MIT 开源**，但引擎仍闭源 + 需 License。
- **追加（2026-10-10 22:40，传哲指出「阿里云应该看 iOS 端」才发现的第二个坑）**：阿里云 iOS 侧
  **有两个仓库，别核错** —— 官方 Demo 页（`help.aliyun.com/zh/apsara-video-sdk/demo-for-mediabox-sdk`）
  **直指的是 `aliyunvideo/MONE_demo_opensource_iOS`**（一体化 App：播放器 / 短视频 / 直播 / RTC 四条线 +
  AUIBaseKits，短视频在 `AlivcUgsvDemo/`，**比独立仓库多出剪同款全套与多轨编辑条**）；
  而 `MediaBox-Demos/amdemos-ios-ugsv` 是官方「短视频 SDK Demo 源码下载」页指向的**裁剪版**（只有 UGSV）。
  **规约**：核验某能力「有/无」之前，先确认官方入口页指向的是哪个仓库 —— 拿裁剪版当全集会漏功能、
  也会让负结论站不住。本次的负结论（无 split / undo / redo / draft）是**两个仓库都核过**才下的。

### P102 · 找商用 SDK 资料的第三条路：公开 podspec 仓库 + CDN 直链（比官网和"源码"都好使）
**日期**：2026-10-10　**来源**：RESEARCH-012 §1.5，传哲线索「看智能创作SDK / Creation Kit / CK 与
`该厂商云服务/其公开 spec 仓库` 里的 其轨道 UI 组件库.podspec」　**验证状态**：已确认（4 个 zip 均实测下载解包）

- **现象**：该厂商 SDK 概览明确写「暂不公开提供」，文档又是 JS 渲染抓不到（P101）——
  按常理就该收工判定"该厂商什么也拿不到"。**这个结论只对了一半。**
- **第三条路**：该厂商有公开 podspec 仓库 `github.com/该厂商云服务/其公开 spec 仓库`（**MIT**，
  63 个组件 / 2192 个 podspec / 9071 条目，2026-10-10 仍在更新）。podspec 里 `s.source` 是**公开 CDN 直链**：
  `https://sf3-ttcdn-tos.pstatp.com/obj/该厂商云服务/<Name>/<Version>/<Name>.zip`，实测全部 HTTP 200：
  `其轨道 UI 组件库@0.1` 7.4 MB、`其编辑语义层@17.5.0.14` 7.2 MB、`其媒体引擎层@9.6.2.1-D` 40 MB、
  `其创作 SDK 包@1.1.0` 92 MB。解包得到 **`Headers/*.h`（接口层）+ 资源 bundle（配置 JSON）**，
  没有实现源码，但对"看架构 / 接口 / 信息架构"已经够用，**且全程不需要任何商务流程**。
- **两个操作坑**：
  1. podspec 的 source 常写成 `{ :http => ".../#{s.name}/#{s.version}/#{s.name}.zip" }` **插值**，
     直接拿这串字面量去 curl 会 **403**（我第一次就打到了目录根）。**必须按组件名+版本手工展开**再请求。
  2. **名字会骗人**：`其示例工程`（Gitee `该厂商云服务/其示例工程`，公开 MIT）名字像 Video Editor，
     实际是该厂商 SDK 全家桶（BDHotfix/RangersAPM/其编辑器组件/其编辑器组件/其编辑器组件/其编辑器组件/Timor），
     495 条目里**没有任何编辑模块**。白花时间。
- **规约**：找商用/闭源 SDK 的资料，按四级找，别停在"官网说不公开"就收工 ——
  ① 官网文档 → ② 海外站（该厂商海外品牌 类）+ 搜索摘要 → ③ **公开包管理仓库**
  （podspec / maven / npm / pub；`trunk.cocoapods.org/api/v1/pods/<名>` 一查便知）→
  ④ **包内头文件 + 资源 JSON**（接口与配置往往就在这里）。
- **合规边界**：podspec 的 license 字段不一致（`其轨道 UI 组件库`/`其媒体引擎层` 写 MIT，`其编辑语义层`/
  `其创作 SDK 包` 是自定义块）。**头文件/JSON 用于研究可以，二进制集成进产品属商用授权范畴**，
  与 FFmpeg LGPL 同类，**需法务/商务拍板，不由 AI 代决**（已在 RESEARCH-012 §1.5.6 写明）。
- **追加（二进制层面还能再挖一层，2026-10-10 23:00 实测）**：拿到 `.a` / `.framework` 之后，
  **元数据层**仍有大量可读信息，命令就三个：
  ① `lipo -info` → 架构与体积（本次 armv7+x86_64+arm64，20 MB）；
  ② `nm -arch arm64 -gU` → **类名 + 实例变量(IVAR) + 协议 + C 函数**
     （本次 108 类 / **546 个 IVAR** / 34 协议）；
  ③ `strings` → selector 候选与配置 key（本次 2604 候选、`dve_ui_*` 18 个）。
  **其中 IVAR 是头文件里完全没有的内部结构** —— 例如 `其多轨控制器` 的
  8 个「按片段类型划分的 ViewModel」、`其缩略图管理器` 的
  `_operationQueue/_lock/_tasks/_loaders/_handlers`，都是靠 IVAR 才看出来的。
  **踩坑**：OC 方法名**不在** `nm -gU` 里（不是外部符号），本次 grep `[-+]\[Class xxx\]` 命中 0；
  要拿方法名得走 `__objc_methname` 段（`otool -s __TEXT __objc_methname`）或 `otool -ov`，
  且 `.a` 需先 `ar -x` 解出 `.o`。
- **边界（再次强调）**：**不二进制分析、不反编译、不还原实现逻辑**。商业 SDK 的 EULA 普遍禁止
  reverse engineering，此问题与 FFmpeg LGPL 同类，**需法务/商务拍板，AI 不代决**。
  元数据观察仅限架构与信息架构研究，本次未链接、未集成、未运行。


### P103 · 全仓机械替换必须显式排除 append-only 文件（2026-10-10 23:40 实测踩）

- **现象**：INFRA-022 的 `pal` → `platform` 改名做全仓正则替换时，把
  `docs/reports/LEDGER-W42.md` 一并扫进去，结果台账里 24 处被改写 ——
  历史条目中的 `PAL` 变成 `Platform`，**违反 ADR-0034「台账 append-only、禁止改写历史条目」**。
- **更隐蔽的一种破坏**：描述变更本身的行被改成了 `A → A`。例如
  「`engine/core/cq/pal` → `cq/platform`」被改成
  「`engine/core/cq/platform` → `cq/platform`」，**旧名丢失、语义归零**；
  同理 `pal.h`→`platform.h` 变成 `platform.h`→`platform.h`。
  这类错 grep 计数看不出来（行数不变、仍含关键词），只能逐行读。
- **根因**：替换脚本按「目录 + 扩展名」圈定范围，**没有按文件的可写性质分类**。
  同一个 `docs/` 下混杂三类文件：① 可改的设计文档；② append-only 台账；③ 日期日志。
- **定则**：
  1. 任何全仓机械替换，先列**排除清单**：`docs/reports/LEDGER-*.md`、
     `.workbuddy/memory/YYYY-MM-DD.md`、`.zcode/plans/*`、其它声明 append-only 的文件；
  2. 替换后**必须复核**「旧名 → 新名」成对出现的行是否仍成立（专门 grep `→`）；
  3. 历史条目里被引用的原话（传哲原话、当时的概念名）**一个字都不能改**，
     新条目才用新名 —— 台账的作用是复盘，不是保持一致。
- **补救**：本次 24 处已按行号精确修复（历史条目还原 `PAL`，23:38 新条目保留旧名以描述变更），
  并在台账中登记。修复脚本用 `assert old in line` 逐行断言，避免二次误伤。


### P104 · FFmpeg 静态库「编译过 ≠ 链接得过」：裁剪档位必须跑链接闭合冒烟（2026-10-11~12 实测踩，DEPS-012）

- **现象**：demux 档（--disable-everything + parser/bsf 白名单）产物体积/符号/GPL 扫描全绿，
  **第一次真实链接进可执行文件时连环炸**，三层问题叠加：
  1. **上游 Makefile parser 不闭合**：FFmpeg 9.0.2 的 `libavcodec/Makefile` 里
     `hevc_parser.o` / `opus_parser.o` **不在任何 OBJS 规则中**，但 parser 注册表
     （avcodec_parsers.o）引用 `ff_hevc_parser` / `ff_opus_parser` ——
     `--enable-parser=hevc,opus` 后链接必炸；`mpeg4video` parser 则显式拉
     mpeg4videodec/ituh263dec，其引用的 `ff_set_qscale` 等又被 decoder 宏裁掉，
     静态链接同样炸。
  2. **同库同名 .o**：`libavutil.a` 内有**两份** `cpu.o`（通用 `cpu.c` + 平台 `x86/cpu.c`），
     ar 成员允许重名，原始 archive 是完整的；但 `ar x` 平铺解包**静默覆盖**，
     通用版 `av_cpu_count` 定义丢失 → `Undefined _av_cpu_count`。
     （baselines 记录的「跨库同名」只是第一层坑，**同库同名**是第二层，2026-10-12 补录。）
  3. **DEPS-010 产物从未被链接**：2026-09 的验收只测了体积/符号数/GPL 扫描，
     全是 archive 级检查，链接级缺口埋了近一个月才被冒烟单测暴露。
- **修复**（`tools/build/build_ffmpeg_demux.sh`）：
  1. PARSERS 裁掉 hevc / mpeg4video / opus（容器 demux 不依赖，容器内 hevc/opus 流不受影响）；
  2. 合并改**逐成员 `ar x` + 序号化重命名**（`avutil_00001_cpu.o` 式），同名成员全保留，
     `__.SYMDEF` 符号表成员过滤；
  3. 脚本内置**链接闭合冒烟**：clang++ C++ 消费者（extern "C" 包头，引用 demux 全部对外
     入口）链接合并库，失败禁止出货。
- **定则**：凡静态库裁剪档位，「体积/符号/GPL 扫描」三绿**不构成**可用证据；
  **必须有一次真实链接**（最小消费者可执行文件）才算产物合格。
  验证状态：✅ 2026-10-12 macosx-x86_64 闭合通过后 5 slice 全量复绿。

### P105 · FFmpeg 9 Apple 集成三小坑（2026-10-11~12 实测，DEPS-012）

1. **公共头无 `extern "C"`**：FFmpeg 9 的 avformat.h/avcodec.h/avutil.h 已不再自带
   C++ 包裹（老版本有），C++ TU 必须自己 `extern "C" { #include ... }`，
   否则 C++ mangling 链接全炸（报错 NOTE: declaration possibly missing 'extern "C"'）。
2. **hwcontext 不受 --disable-hwaccels 控制**：产物含 `avutil_hwcontext_videotoolbox.o`
   （avutil 级组件），链接器会递归拉入并索要 CoreVideo/CoreMedia/VideoToolbox/
   **CoreFoundation** 框架符号。处置：cq_ffmpeg target 挂 INTERFACE_LINK_LIBRARIES
   传递给所有消费者；App Pod 侧本就链这些框架，无感。
3. **arm64 交叉编译必须显式 `--arch=arm64`**：缺省时 configure 按本机 arch（x86_64）
   走，转而要求 nasm（本机无）→ configure 直接失败。报错文案会误导人去装 nasm。
- **补（2026-10-12 上午）—— 第三层坑：`ar rcs` 对已存在 archive 是「插入或替换」**：
  OUT 目录残留上一轮（甚至旧裁剪清单）的 libffmpeg.a 时，`ar rcs` 不重建而是把新成员
  塞进旧 archive —— arm64 闭合失败即因 v1 旧裸名 parsers.o（16 个引用含 hevc/opus）
  先被链接器拉入。合并前必须 `rm -f "$OUT/libffmpeg.a"`，且**验收产物必须核对
  「成员总数 + 裸名成员 = 0」**（序号化合并下不应有任何无序号成员）。
- **补 2（2026-10-12）—— bash `ar x lib member` 对同名成员只取第一个**：
  序号化改名救不了同名成员（两次提取拿到的是同一份），第二份 cpu.o（平台版）仍丢，
  `ff_get_cpu_flags_x86` 继续 undefined。**正确做法 = python 按 ar 格式逐偏移提取**
  （同名全保留；注意两种魔数：系统 ar `! <arch>\n`（带空格）vs FFmpeg `$(AR)` 的
  `!<arch>\n`（无空格），解析器都要认；BSD 长名 `#1/<len>` 存于成员体前 N 该厂商）。
  最终干净产物：301 成员全保留，macosx-x86_64 demux 档 2.66MiB，闭合冒烟通过。

### P106 · iOS 26 SDK 音频/媒体 API 三处与记忆不符——一处弃用、一处改名、一处返回类型收窄
> 日期 / 来源 / 验证状态：2026-10-11 / AUDIO-002 平台层（Intel 机全量构建 + iOS arm64 slice 编译）/ **verified**

1. `[AVAsset tracksWithMediaType:]` 在 macOS 15+/iOS 16+ **弃用**（-Werror 必炸）；
   `tracks` 属性未标弃用（media_demux.mm 同款可用）→ 用 `[asset tracks]` +
   `isEqualToString:AVMediaTypeAudio` 过滤（mediaType 是 NSString，**禁止指针比较**）。
2. `AVAudioFormat` **没有** `initWithStandardFormatWithSampleRate:channels:interleaved:`——
   标准格式初始化器只有不带 interleaved 的 `initStandardFormatWithSampleRate:channels:`；
   要 interleaved 参数用 `initWithCommonFormat:sampleRate:channels:interleaved:`
   + `AVAudioPCMFormatFloat32`（没有 `AVAudioCommonFormatPCMFloat32` 这个名字）。
3. `CMBlockBufferGetDataLength` 返回 **size_t**（收窄成 int 会吃 -Wshorten-64-to-32 → -Werror）。
- 防复发规则：P83/P48 同族再 +1——**平台 API 落笔前先 grep 本机 SDK 头文件**（Xcode 26.6 全有）；
  ObjC selector 凭记忆写 = 构建机必炸，且只有 -Werror 全量才抓得住。

### P107 · synchronized groups 两个格式坑：sourceTree 大小写敏感 + Info.plist 必须成员例外
> 日期 / 来源 / 验证状态：2026-10-11 / ADR-0037 台阶 2（app target 转 buildable folders）/ **verified**

1. **`sourceTree = "<Group>"`（大写 G）= 同步组解析失败**：Xcode 构建系统按大小写匹配
   sourceTree，工程既定 casing 是小写 `"<group>"`；写错 → 组解析不到 → Sources 零文件 →
   链接 `_main` undefined（报错完全看不出是大小写问题）。xcodeproj gem 不校验该值。
2. **同步组会自动把目录内 Info.plist 收进资源**：与 INFOPLIST_FILE 的处理产物冲突 →
   `Multiple commands produce .../Info.plist`。解法 = `PBXFileSystemSynchronizedBuildFileExceptionSet
   { target, membership_exceptions = ["Info.plist"] }` 挂到同步组的 exceptions。
- 防复发规则：动 PBXFileSystemSynchronizedRootGroup 一律先核全工程 sourceTree casing；
  含 Info.plist 的目录转同步组时**默认**配成员例外。
3. **复现案例（2026-10-11 收口轮）——新文件后只刷一端 Pods = 另一端符号消失**：
   B-02 批新增 DebugOverlayView.swift，iOS Pods 刷过、mac Pods 旧快照（0 引用）→
   mac 壳 `EditorView.swift:52 cannot find 'DebugOverlayView' in scope`（报错点在
   引用处不在缺失文件，极难联想到 Pods 陈旧）。双端 pod install 是新文件的固定动作，
   不是只刷要跑构建的那一端。

## P108（2026-10-11，TASK-INFRA-025 收尾，集成机）壳工程 Pods 远程依赖三件缺失 = 假绿之源

- **现象**：清 DerivedData 后 mac 壳必炸——构建图只剩 App 1 个 target（"Target dependency
  graph (1 target)"），Pod 模块 map 全 not found；而增量构建一直"成功"。
- **根因（两层）**：①冻结壳工程（ADR-0037）对 Pods 只写了 xcconfig/manifest 脚本，
  **containerPortal / PBXContainerItemProxy / PBXTargetDependency 三件被剥**（0 引用），
  Pods 目标从未进构建图；②CocoaPods 1.17 把聚合 target（Pods-<App>）放进 **Pods 工程**
  （非用户工程），用户工程的远程依赖缺失时 pod install 照样静默 no-op。此前所有
  "BUILD SUCCEEDED" 都是旧 DerivedData 产物假绿（P85 假绿家族新形态）。
- **修法**：`tools/build/edit_project.rb` 新增 **add-remote-dependency** 子命令（幂等，
  写 portal+proxy+dependency 三件），双壳各补一条 → 聚合 target 进图，Pods 真构建。
- **验证口径（防复发）**：①凡是"构建成功"结论，必须来自 **清过 DerivedData 的干净构建**
  （增量成功不算数）；②pod install 后核 app 工程 `grep containerPortal project.pbxproj`
  应 ≥1；③本机 mac 验证用 `-destination 'platform=macOS,arch=x86_64' ARCHS=x86_64
  ONLY_ACTIVE_ARCH=YES`（通用双 arch 会被 CP 1.17 的 Swift Compatibility Header
  共享路径坑——见池 [14]）；④iOS 设备验证用 `-destination 'generic/platform=iOS'`。

## P109（2026-10-11，TASK-INFRA-025，集成机）发号水位必须现场 ls，台账/记忆水位永远落后

- **现象**：凭"HANDOFF 下一号 = 015"的记忆立了 HANDOFF-015，实际 015~018 已被并行
  会话当日占用（编辑域收口 / AIEDIT-001 / 两线收口 / INFRA-022 整改），撞号。
- **规则**：HANDOFF / TASK / ADR / 池 / pitfalls **任何发号动作前必须 `ls` 现场目录
  取真实下一号**，记忆里的"下一号"只作参考——并行会话同机节奏下，水位在会话进行中
  就会前进（今天一天 ADR 从 0038 走到 0039、HANDOFF 从 014 走到 019）。
- **处置惯例**：撞号方（后入库）让位改号并全文替换引用（本次 015→019，TASK 卡同步），
  与 P63/P67/P70「先入库保留、后入库让位」一致。

## P117（2026-10-11，CAM-033 真机批，集成机）AVCaptureMetadataOutput 装配三坑 + outputRectConverted 语义陷阱

- 来源：CAM-033 metadata 人脸框接入，真机远程验证批（SOP 见 tools/probe/README.md）。
- **坑①（P0 崩溃）**：`setMetadataObjectTypes` 必须在 `addOutput` **之后**——未连接
  会话时 available 集合为空，直接设 [.face] 抛 NSInvalidArgumentException（模拟器/
  单测抓不到，真机 launch 即崩，探针日志 30 秒定位）。
- **坑②（时序）**：`availableMetadataObjectTypes` 在 **startRunning 之前仍为空**
  （addOutput 后立即读也是空）→ types 设置延后到 startRunning 之后
  （activateMetadataFacesIfNeededLocked，幂等）。
- **坑③（坐标语义）**：`outputRectConverted(fromMetadataOutputRect:)` 实测输出与
  文档"归一化"语义不符（像素级 + 旋转错位，height≈1248）。**跨输出坐标转换结果
  未对照验证不得消费**——映射未定标前 metadata 框不进蒙版（标定闸门
  metadataFacesCalibrated=false，回退 Vision faceRectangles 兜底）。
- **方法论沉淀**：真机远程验证（tools/probe/ SOP）30 秒内抓出①，且性能快照
  （cam-stats 2Hz）直接给出健康基线——"自己加日志跑起来回传分析"是真机验证的
  默认路径，人工项（脸框标定受控数据/手点复现）才找传哲。
- 验证状态：**verified**（iPhone 17 Pro 真机三轮）。

## P118（2026-10-11，CAM-033 真机批二，集成机）检测队列回调里的 MainActor 隔离断言 = SIGTRAP 无消息崩

- 来源：CAM-033 美颜开（探针 CQ_CAM_BEAUTY）必现 signal 5，CrashProbe 信号处理器
  （tools/probe 沉淀）抓栈 + atos 定位：onResult 闭包（检测队列，非隔离上下文）里
  的统计打印段（print/String(format:) 组合）触发 `dispatch_assert_queue` SIGTRAP。
- **规则**：`VisionDetector.onResult`/`CameraManager.onVideoFrame` 等采集/检测队列
  回调体内**零打印、零 MainActor 隔离访问**——任何统计取证移到主线程 Timer
  （cam-stats 同源读 detector 属性天然安全）。iOS 26 Swift 6 下 print/String
  interpolation 的并发检查在非隔离上下文触发 brk，且 fatal 消息走 os_log 异步流
  **不进 devicectl console**（stderr 探针抓不到，crash report 延迟落盘）——
  **信号处理器 backtrace 是唯一即时取证手段**（CrashProbe，CALIB 模式自装）。
- 附：devicectl console 会话会引发 scenePhase 抖动 → onChange(.active) →
  resumeIfNeeded 二次 configureAndStart（trace 栈实证）——探针环境特有，真机
  手持场景不受影响，但 resumeIfNeeded 应视为可重入设计。
- 验证状态：**verified**（iPhone 17 Pro D3~D13 十一轮，删段后 signal 5 归零）。

## P116（2026-10-11，壳工程图标/启动图，集成机）synchronized groups 自动编 xcassets ≠ 图标生效——ASSETCATALOG_COMPILER_APPICON_NAME 必须显式写

> ⚠️ 原误记 **P110**，与录制死锁 P110 撞号；按 P109 惯例后入库方让位，2026-10-11
> 收口轮改号 P116。历史文档中"图标语境的 P110"读作本条。

- **现象**：353d1e0 已提交全套 AppIcon.appiconset，真机桌面仍显示默认白图标。
- **根因**：壳工程（ADR-0037 手工源文件）target 级 buildSettings 只有
  `INFOPLIST_FILE`/`TEAM`/`BUNDLE_ID` 四件，**缺 `ASSETCATALOG_COMPILER_APPICON_NAME`**。
  synchronized groups 会自动把 Assets.xcassets 进 Resources（car 照编），但无此
  setting 时 actool 收不到 `--app-icon`，构建产物 Info.plist **没有 CFBundleIcons** →
  SpringBoard 用默认图标。xcassets 编译成功与图标生效是两件事。
- **修法**：`edit_project.rb set-setting <project> <target> ASSETCATALOG_COMPILER_APPICON_NAME AppIcon base`
  双壳各一条；顺带修了该脚本 `base` 模式的 ArgumentError（原写
  `target.build_settings[key]`，xcodeproj gem 此方法需配置名参数 → 改为遍历
  build_configurations 落到每个配置）。
- **验证口径（防复发）**：①`xcodebuild -showBuildSettings | grep APPICON` 应有值；
  ②`xcrun actool --compile … --app-icon AppIcon --output-partial-info-plist …`
  产物 partial.plist 必须含 `CFBundleIcons/CFBundlePrimaryIcon`；③真机旧安装会缓存
  图标，验收需删除重装。后续 ADR-0033 project.yml 迁移时此 setting 要进模板，
  新 target 一律走 edit_project.rb 而非裸编 pbxproj。

### P110 · appendVideo 的 .writing 守卫排在 startWriting 之前 = 录制完全坏 + 停止即崩
> 日期 / 来源 / 验证状态：2026-10-11 / B-02 真机自动探针（CQ_CAM_PROBE）/ **verified**

1. df2a672（CAM-030）给 appendVideo 加的 `writer.status == .writing` 守卫排在
   `startSessionIfNeeded`（内含 startWriting）**之前**——writer 初始状态 .unknown
   永远过不了守卫 → startWriting 永不执行 → **0 帧录制**；stop 时
   `finishWriting` 对状态 0 抛 NSInternalInconsistencyException → App 崩溃。
   自 10-07 起录制在真机上从未成功过（该批真机验证挂池未跑）。
2. 修：守卫放行 `.unknown`（首帧必须走到 startSession）；finish 只对 .writing
   调 markAsFinished/finishWriting，未知/失败态走显式失败路径（不碰 writer）。
3. 防复发规则：①「拦截已失效状态」的守卫别误伤初始态——状态机守卫枚举合法
   目标态，而不是排除单个坏态；②B-02 起 CameraRecorder 有真机探针
   （CQ_CAM_PROBE），录制回归先跑探针再上问卷。

### P111 · iOS 26 photoOutput 交付未旋转 buffer + 方向在元数据；前摄 270° 偏移只属于 videoDataOutput
> 日期 / 来源 / 验证状态：2026-10-11 / B-02 真机自动探针（三轮回放定案）/ **verified**

1. **photoOutput（iOS 26）**：连接 videoRotationAngle=90 实际生效（actual=90），
   但交付 buffer 仍为横向原生（1920×1080），方向在
   `photo.metadata[kCGImagePropertyOrientation]`（后摄=6，前摄=4）。
   消费管线必须 `CIImage.oriented(exif)` 摆正——忽略元数据 = 存出横躺照片。
   ⚠️ 元数据值装箱形态不赌（NSNumber/String 双形态兼容）；前摄（连接镜像）
   metadata 4 的有效值为 6（数据驱动表在 CameraViewModel，横持未测挂池）。
2. **P72 的前摄 270° 偏移只属于 videoDataOutput**：photoOutput 前摄用后摄同款
   语义（90=竖屏）。拍照路径角度用 photo 语义、镜像仍按真实摄位——两件事
   分开传参（applyOrientation(photoOutputSemantics:)）。
3. 防复发规则：①拍照/录制产物验收必须**拉文件看尺寸**，预览正确 ≠ 产物正确；
   ②photoOutput/videoDataOutput 的方向语义分开验证，不互相外推；③排障日志打印
   实际生效值（actual），光打印计算值会被 supported=false 静默跳过骗掉。

### P114 · finish 完成回调 [weak self] + 录制器提前析构 = 成功录制被判 0 帧删除
> 日期 / 来源 / 验证状态：2026-10-11 / B-02 真机探针（finish status=2 frames=0 现场抓包）/ **verified**

- **链路**：stopRecording 先 `recorderBox.set(nil)`（唯一强引用消失）→ finish()
  返回 → recorder 在 finishWriting 的**异步完成回调执行前析构** → `[weak self]`
  为 nil → `writtenFrames = self?.... ?? 0` 读出 0 → status=.completed 的成功
  录制被判 nothingWritten → **删文件 + 报「没有录制到任何画面」**。
- **间歇性**：回调与析构赛跑——探针（finish 后立马上传，checkpoint 多）赢过、
  用户手点输过；这也是「修了池仍然录制无效」（P74）悬案多年的真正同族。
- **修**：完成回调 `[self]` 强持有（writer 完成回调一次性执行后即释放，无保留环）；
  修复后 finish frames=90×2 段全对（探针实测）。
- 防复发规则：①异步完成回调里要读「对象终态」的，闭包一律强持有或提前把终值
  拷进局部——weak self + 可选链 `?? 默认值` 是把竞态伪装成默认值的毒药；
  ②「计数为 0 = 没发生」的断言必须先证明「读数者活着」。

## P119：SplitClip 右半时长写成左半的 delta（2026-10-11，EDIT-007 编码轮，已修）

- **现象**：`SplitClip` 首版 `right.duration = delta`（delta = at − start 是**左半**时长），
  单测「右半占据 [at, end)」「分割不改变总时长」当场红。
- **根因**：一条命令同时算 4 个有理数量（左 dur / 右 dur / 右 source_in / 右 source_dur），
  变量同名就近取用，`delta` 语义歧义没在命名上区分。
- **修**：`right_duration = end − at` 独立命名计算（chq_timeline.cpp SplitClip）。
- **验证状态**：已修，ctest model_timeline/model_command/c_abi_edit 6/6 绿（2026-10-11）。
- **防复发规则**：分割/裁剪类改动里，「时长」变量一律按**语义**命名
  （left_duration / right_duration / delta），禁止一个 `delta` 到处塞；四字段联动
  的操作必须有一条「右缘不动（end 恒等）」或「总时长不变」的恒等式断言兜底。

## P120：并行会话全量 add 把编辑线改动卷进相机提交（2026-10-11，EDIT-007 编码轮，待收口）

- **现象**：本会话在 engine/ 内核写 EDIT-007/008 期间，并行相机会话提交
  `d31e6b8`（CAM-035）把工作区里**未完成的**内核改动（含两个已知缺陷）与两个
  测试文件一并卷入；留下 HEAD=带缺陷版本、修复散在工作区的状态。
- **根因**：全量 add 扫提交（P84 同族）；双机/双会话同一工作区时「别人的半成品
  就在你面前」，无 staging 纪律必然串写集。
- **验证状态**：待收口——修复 + test_c_abi_edit.c + 文档需单独提交（清单见
  HANDOFF-021「提交事故」节）；收口后 model_timeline/model_command/c_abi_edit
  回绿（修复后本机已实测 48/48）。
- **防复发规则**：①双会话共用工作区时提交只允许 `git add <逐个文件>`，提交前
  `git status --short` 逐行认领；②发现 HEAD 非自己基点时先 `git log` 对账再写文件；
  ③跨线文件出现在自己 diff 里 = 立即停手回报，不许「顺手一起提交」。

## P121：分割/移动类「双变量取错」三犯（2026-10-12，UIA-040 编码轮，已修）

- **现象**：MoveClipToTrack 跨轨路径 `ChqClip moved = *clip`（旧起点），应为
  `= candidate`（新起点）——与 P119（SplitClip 右半时长误用 delta）同族，且累计
  **第三次**同类错误。
- **根因**：「candidate（新值工作副本）/ origin（旧值快照）」并存时，就近取用
  `*clip` / `delta` 在编译器眼里全部合法，靠人眼守不住。
- **修**：moved = candidate（chq_timeline.cpp MoveClipToTrack）。
- **验证状态**：已修，model_timeline/model_command/c_abi_edit 4/4 绿（2026-10-12）。
- **防复发规则**：①凡是「candidate（新值）/ origin（旧值）」并存的操作，**禁止**从
  模型指针取值构造目标实体——目标实体只能由 candidate 派生；②单测必须同时断言
  「新值生效 + 旧值还原」两个方向（只测还原测不出 moved 取错）。

## P122：Platform 工厂 `CreateMediaDemuxer` 内部含全量 Open，吃掉 OpenLight 优化（2026-10-12，真机导入日志，已修）

- **现象**：真机导入相册视频，`[import] probe 970ms`，日志
  `慢调用 demuxer Open(含 ScanKeyframes) took 967ms（阈值 500ms）`，且整段跑在
  **主线程**（Thread Performance Checker 报 User-interactive 等 Default QoS 的优先级反转）。
  但 MEDIA-026 明明已经把探测改成 OpenLight 了。
- **根因**：`CreateMediaDemuxer()`（media_demux.mm）在工厂内部就 `d->Open(src)`
  —— 建 AVAssetReader + `ScanKeyframes()` 逐样本扫全文件。core 层的
  `cq_media_probe_duration` 拿到手的 demuxer **已经全量打开过了**，之后再调
  `OpenLight` 只是第二次加载 duration，省时为 0。**core 层看不到工厂内部的代价**
  ——这是本坑的可怕之处：ABI 代码读起来完全正确。
- **影响范围**：任何「只要时长」的调用方；本地小素材（本机无大文件）永远测不出来。
- **修**：新增 `CreateMediaDemuxerLight(src, out)`（chq_media.h 声明 + media_demux.mm
  实现 = 构造 + `OpenLight`，不 Open），probe ABI 改用它；单测钉死
  「轻量 demuxer 的 `GetStreamCount()==0` 且不可读包」（= 没建 reader）。
- **验证状态**：已修，待门禁 + 真机回填导入耗时。
- **防复发规则**：①**Platform 工厂不是零成本的构造函数** —— 凡是「工厂 + 再调用一个
  轻量方法」的组合，必须先读工厂实现确认它没做重活；②「轻量」语义要在**工厂层**
  就分叉，不能只在实例方法层（否则代价已经付过了）；③真机大素材的耗时只有真机
  日志能暴露，本地毫秒级的结论不能当验收。

## P123：CIWarpKernel 首参必须是 `coreimage::destination`，裸 `float2` 不算（2026-10-12，真机日志，已修）

- **现象**：真机 `Warp kernel function 'cq_face_warp' does not have a coreimage:destination
  argument.` → `CIWarpKernel(...)` 返回 nil → 美型**诚实跳过**（日志写得很清楚，但
  此前两轮都把「跳过」当成了成功路径之外的既成事实）。
- **根因**：CAM-033 只把 v1 的 `coreimage::sampler src` 换成了裸 `float2 dest_coord`。
  CI 是靠**参数类型上的 coreimage 标记**识别 destination 的，裸 `float2` 没有标记
  —— sampler 的错误没了，destination 的错误来了。两次都是「凭 CI 会帮我注入坐标
  的直觉写签名」。
- **影响范围**：全部 `CIWarpKernel`；**编译期与模拟器都不报错**，只有真机加载那一行
  notice/error 能证明（metallib 里函数存在 ≠ kernel 可加载）。
- **修**：`float2 cq_face_warp(coreimage::destination dest, ...)` + `dest.coord()`。
- **验证状态**：已修，待真机确认 `warp engine INSTALLED` 出现。
- **防复发规则**：①CI kernel 签名**照抄 CoreImage.h 的 coreimage 类型**，不写裸向量；
  ②改完 shader 必须以「真机日志里出现 INSTALLED」为完成判据 —— 编译绿、bundle 里
  有 metallib、函数能 grep 到，**这三条全是伪绿**（P60 同族第三击）；
  ③`BeautyKernel`/`FaceWarp` 的 FALLBACK 分支是 error 级日志，真机日志批要专门扫。

## P124：`drawable.texture.pixelFormat` 可能是 `MTLPixelFormatInvalid`(0)（2026-10-12，真机崩溃日志，已修）

- **现象**：真机长跑后连续 3 次
  `-[MTLTextureDescriptorInternal validateWithDevice:] failed assertion
  MTLTextureDescriptor has invalid pixelFormat (0)`，随后
  `Debug session ended with code 9: Terminated due to signal 9`（jetsam SIGKILL）。
- **根因**：`CameraRenderer.draw` 直接拿 `drawable.texture.pixelFormat` 去建 scratch /
  MetalFX 纹理。MTKView 的 drawable **不保证**格式有效（视图脱离窗口 / 资源紧张时
  给出退化 drawable），格式 = 0 时 Metal 校验层直接断言。
- **影响范围**：相机预览；Metal 校验开启的 Debug 构建必崩，Release 是 makeTexture 返回
  nil 后静默黑屏（更糟）。
- **修**：draw 入口先校验 `drawableW/H > 0 && pixelFormat != .invalid`，退化则**跳过本拍
  并打 error 留痕**（不是静默 return —— 静默等于没发生过，P60）。
- **验证状态**：已修，待真机确认不再出现该断言。
- **防复发规则**：①凡是「从别的对象的纹理/格式派生自己的资源」的地方，格式与尺寸
  都当成**不可信输入**先校验；②`signal 9` 在 iOS 上首先怀疑 **jetsam（内存）**，
  Metal 断言往往是内存吃紧的下游症状 —— 不要只修断言就宣布修好崩溃。

## P125：podspec 加 `script_phases` 后不重跑 pod install = 生成头缺失，报错点骗人（2026-10-12，SHADER-001 壳接线，已修 verified）

- **现象**：`ChuanqiCutCore.podspec` 加了 `script_phases`（构建期跑
  `tools/shaders/build_shaders.py` 生成 `blit_msl.h`），`pod install` 未重跑 →
  mac 壳 `blit_pass.mm` 编译失败：`'blit_msl.h' file not found`。报错点在
  **include 那一行**，与 podspec/script phase 毫无字面关联。
- **根因**：`Pods.xcodeproj` 是 podspec 的**快照**（P107 的文件清单维度 + 本条新增的
  **script phase 维度**）。podspec 改文件清单或改 script_phases，两端都必须重跑
  `bundle exec pod install`，否则 Xcode 侧跑的是旧构建阶段表。
- **影响范围**：凡走 Pods 的 Apple 壳；CMake 侧**不受影响**（custom command 当场生效），
  所以会呈现"core 单测全绿 + 壳构建红"的割裂形态。
- **修**：iOS/mac 两端 `bundle exec pod install` 后重建 → 均 SUCCEEDED，script phase
  实际执行（日志可见 `[shaders] 生成 .../blit_msl.h`）。
- **防复发规则**：①podspec 任何改动（文件 glob / script_phases / 依赖 / 搜索路径）
  都视为**必须双端重跑 pod install** 的变更，没有例外；②"CMake 绿 ≠ Pods 绿"，
  壳构建结论必须来自 pod install 之后。

## P126：搜索工具里写 `\|` 会静默 0 命中 —— 多模式搜索假阴性（2026-10-13，RESEARCH-016，已证实 verified）

- **现象**：用 Grep 工具搜 `processors\|collectProcessNodes`，返回 **0 命中**；
  而这两个符号就明明白白写在 `其编辑语义层/Headers/其时空节点模型+iOS.h:117-119`。
  差点据此在调研文档里写成「该机制不存在 / 语义不明」。
- **根因**：Grep 工具底层是 **ripgrep**，正则语法是 **Rust regex** —— `\|` 是**转义后的字面竖线
  字符**，不是「或」。于是实际搜的是字符串 `processors|collectProcessNodes`，自然 0 命中。
  多模式交替在 ripgrep 里应当直接写 `|`（不转义）。
- **更正（2026-10-13 晚，第三次复发后查明，之前的"补充实测"结论是错的）**：
  本机 shell 里的 `grep` **根本不是 BSD grep**，而是 **toybox 0.8.13**，路径
  `/Applications/WorkBuddy.app/Contents/Resources/app.asar.unpacked/cli/vendor/shim/brokered-bin/grep`。
  toybox grep **不支持 `\|` 交替**。之前那条实测写"支持"，是**实验设计无区分力**导致的假阳性：
  当时用样本 `printf 'a|b\nfoo\n' | grep "a\|b"`，无论 `\|` 是交替还是字面竖线都会命中第一行。
  **有区分力的实验**应该是（验后者不会被前者的字面含义掩饰）：
  `printf 'aa\nbb\nhitTest\n' | grep -n "hitTest\|nonexistent"` → toybox 返回 **exit 1（不命中）**，
  而 `grep -nE "hitTest|nonexistent"` → 正常命中。**结论：一律用 `grep -E`。**
- **影响范围**：任何"用多关键词搜代码确认某机制**是否存在**"的判断。
  危险点在于它是**静默**的 —— 0 命中看起来和"确实没有"一模一样。
- **防复发规则**：①凡得出「仓库里没有 X」的**否定性结论**，必须换一种写法
  （`grep -E "X|Y"` 或 `grep -rl "X"` 单模式各搜一次）**交叉复核**再落笔；
  ②跨工具时不要凭记忆套正则语法，先拿一个**已知必然命中的样本**验一次语法
  （本次就是靠"文件里明明有"才发现的）。

### P126 复发记录 · 第三次（同一晚，Bash 里，UIA-041 U0 验收核验时）

做「双实现是否真的消除」的验收核验时，在 Bash 里跑
`grep -n "hitTest\|dropTrackRow\|deltaSeconds" UIKit/EditorTimelineUIView.swift` → **零命中**，
差点据此宣布验收通过。改用单关键词 `grep -n "hitTest"` 才发现 L414 还在。
同一个晚上连续踩了两次（第 2 次 → 第 3 次），两次都差点带进交付结论。

**由此确认的最稳写法**（本机一律如此，不要再用记忆里的 BSD 语法）：
```
grep -nE "pat1|pat2|pat3" file      # 多模式：一律 -E
grep -rn  "single" dir              # 单模式：无所谓
python3 逐行扫                       # 关键否定结论的兜底复核手段（最可靠）
```

### P126 复发记录（第二次，2026-10-13 晚，RESEARCH-017 → UIA-041 开工前捞出）

**这次不只是惊吓，是污染了交付物**：RESEARCH-017 §2 的对照表里被写成
「S3 选中态视觉 ❌ 无选中视觉层（grep selected/handle 零命中）」。
而事实两侧都有实现：

- UIKit  `TimelineContentView.applySelectionBorder()`（EditorTimelineUIView.swift L330-340）
- SwiftUI `EditorTimelineView.draw()`（EditorTimelineView.swift L362-372）

二者都用 `Theme.primaryText`（= 白）lineWidth 2。真正缺的只有**左右把手**和**片段中央时长数字**。

**为什么第二次才抓到**：第一次 (RESEARCH-016) 是靠"我知道那里明明有符号"反向发现的；
这次是对**自己仓库**做"有没有"的断言 —— 恰恰是最不该信 0 命中的场景，却没交叉复核。
而且这个假阴性没有任何人察觉，直接跟着调研文档进入了排期与任务卡的依据里。

**修订防复发规则（在原①②基础上加③）**：
③ 对**自己仓库的现状盘点**（写「现状 vs 目标」对照表、写任务卡验收项这类），
   **每个否定结论必须至少两个独立关键词各搜一次**，且在文档里标上行号来源；
   拿不到行号支撑的「❌ 没有」，一律降级写成 `[待核]`，不许写成确定结论。
   本次就是因为「没有行号」也照样通过了 review。

## P127：合并快检在本机的三个环境事实（2026-10-13，B0 提交轮，已证实 verified）

在集成机跑「合并快检」时连续踩到三个**环境事实**（不是代码问题，但会让人误判成失败）：

1. **`ctest` 不在 PATH** → 直接敲 `ctest` 报 `command not found: ctest`。
   本机 cmake 装在 `~/.workbuddy/binaries/cmake/CMake.app`，须用全路径：
   `/Users/zhuning/.workbuddy/binaries/cmake/CMake.app/Contents/bin/ctest --test-dir build`
   （`cmake` 自己是否在 PATH 也一并确认，别想当然。）
2. **SharedUI 包没有 Tests 目标** → `swift test` 编译成功后报
   `error: no tests found; create a target in the 'Tests' directory`。
   这是**包结构如此，不是失败**。所谓"SharedUI `swift test` 窄检"在本仓实际只能验证**编译**，
   报告时必须如实写成「编译 PASS，该包无测试目标」，不能写成「测试通过」。
3. **SPM 在本会话沙箱里跑不起来** → 报 `sandbox-exec: sandbox_apply: Operation not permitted`
   （沙箱嵌套）。加 `--disable-sandbox` 即可正常跑，**不必**为此禁用整个会话沙箱。

- **影响范围**：任何「合并快检」结论。三条都会让"其实是通过的"看起来像失败，
  尤其第 2 条会让人误报"SharedUI 测试通过"。
- **防复发规则**：①跑 ctest 一律带全路径；②SharedUI 窄检的结论措辞固定为
  「编译 + 无测试目标」；③SPM 命令默认带 `--disable-sandbox`。

## P128：本会话模型不支持读图——截图类需求不能"看图说话"（2026-10-13，RESEARCH-017，已证实 verified）

传哲给了 6 张对标 App iOS 真机截图（IMG_2636/2637/2638/2639/2640/2641），逐张调用读图工具，
**全部返回 "the current model does not support images. Content filtered."** —— 不是路径错、
不是文件损坏，是**当前会话所用模型本身不具备读图能力**。

- **踩法**：拿到 `image_local_path` 就直接读，失败后容易误判成"路径写错/文件没落地"而去反复改路径，
  白白烧几轮。
- **正确处置**：
  1. **第一次读图失败就停**，不要换姿势重试（模型能力问题，重试无意义）；
  2. **立即如实告知传哲**：我没能实际看到图，下面的规格表是"文字转述"不是"视觉核验"；
  3. 规格改为**从用户的话术 + 既有调研 + 代码现状**三方推导，并在文档里显式标注
     「截图证据为视觉转述，验收以走查清单为准，不承诺逐像素一致」；
  4. **反向索取可文本化的替代材料**：录屏（可抽帧后仍需读图，故优先要"参数/尺寸/层级"的
     文字描述）> 放大截图 > 原图。最有效的是让传哲**用文字说尺寸与层级**。
- **影响范围**：任何"看截图/看录屏/看 UI"的需求。RESEARCH-017 §1 的 S1~S12 规格表即在此前提下产出，
  其中把手尺寸 `[E]` 8pt 是估算，必须等真机问卷校准。
- **防复发规则**：涉及图像的交付，**结论里必须带一句能力声明**，不得让传哲误以为我看过图。

## P129：本机 macOS 的 `swift build/test` **完全跳过 `#if os(iOS)` 里的文件** —— UIKit 侧改动 SPM 全绿也是伪证（2026-10-13，UIA-041 U1，已证实 verified）

UIA-041 做 U1 时改了 `UIKit/EditorTimelineUIView.swift`（469 行，整文件包在 `#if os(iOS) … #endif` 里）。
`swift build --disable-sandbox` 每次都报 **Build complete**，但实际一次都没编译过这个文件 ——
iOS 壳构建一把把这**10 个错误**全抖了出来：

```
cannot assign value of type 'CGColor' to type 'UIColor'      // UIView.backgroundColor 要 UIColor
cannot find 'trackHeaderLayers' in scope                     // 成员加进了错误的类（内容视图 vs 外层）
cannot find 'buildTrackHeaders' in scope
value of type 'Any' has no member 'count'                    // CATextLayer.string 是 Any?，要 `as? String`
cannot convert value of type 'CGPoint' to expected argument type 'CGSize'
cannot find 'TimelinePalette' in scope                       // podspec 文件清单快照过期
```

**四条各自独立的教训**：

1. **`swift build` 的 "Build complete" 不等于这个文件被编译过。**
   凡是整文件在 `#if os(iOS)` 里（本仓：`UIKit/Editor*UIView.swift`、`EditorViewController.swift`），
   本机 macOS 的 SPM 构建会**整文件跳过**。改了这些文件，**唯一有效验证是 iOS 壳构建**：
   `cd apps/apple/ios && xcodebuild -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutApp -destination generic/platform=iOS build`
2. **iOS 与 macOS 是两个独立的 Pods 工程**，各自有自己的 `Pods.xcodeproj` 文件清单快照。
   在 `apps/apple/ios` 跑 `bundle exec pod install` **不会影响** `apps/apple/mac`。
   podspec 增删/改名文件后必须**两端各跑一次**（本次 mac 端就因漏跑报 `cannot find 'TimelinePalette' in scope`）。
3. macOS 壳的 destination 写法：`-destination generic/platform=macOS` 会报
   "destination implies architecture, architecture must not also be specified"（配 `-arch`），
   而 `generic/platform=macOS,arch=x86_64` 报 "Unable to find a device"。
   **可用写法是不带 destination**：`xcodebuild -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutMacApp -arch x86_64 ONLY_ACTIVE_ARCH=YES build`。
4. **`UIView.backgroundColor` 要 `UIColor` 不是 `CGColor`** —— 与 `CALayer.backgroundColor`（要 CGColor）
   正好相反，同一份 palette 必须同时提供两种取值（见 `TimelinePalette.RGBA.uiColor` / `.cgColor`）。

- **影响范围**：任何 Apple 端 UI 改动。`swift test` 数字**不能替代**壳构建结论。
- **防复发规则**：改了 `ui/**/UIKit/**` 或任何 os(iOS) 文件后（INFRA-031 前该路径为 `apps/apple/packages/**`），
  ① 必跑 iOS 壳构建；② 若动过 podspec 涉及的文件集合，两端 `bundle exec pod install` 都要跑；
  ③ 改了共享的配色/几何常量，两端壳都要编一遍。

## P130：Auto Layout 两类最易踩的「不可见 / 冲突」坑（2026-10-14，UIA-042 红框修复，已证实 verified）

UIA-042 修预览选中红框（`previewSelectionBorder`，U1 S11）时，一次踩中 Auto Layout 的两类独立坑，
根因清晰、复发率高，单列一条。

### P130·a —— `NSAutoresizingMaskLayoutConstraint` 冲突：子视图忘了关 autoresizing mask

日志特征：`Unable to simultaneously satisfy constraints`，冲突方之一是
`NSAutoresizingMaskLayoutConstraint`（形如 `minX==0 / width==0 / height==0`）。
**根因**：往父视图 `addSubview` 后没设 `translatesAutoresizingMaskIntoConstraints = false`，
系统自动把 view 的 autoresizing mask 翻译成约束，与手写约束抢同一批属性 → 互不满足。

- **根治**：统一用 SnapKit（`snp.makeConstraints` / `snp.remakeConstraints`），它**自动把
  `translatesAutoresizingMaskIntoConstraints` 置 false**，从机制上消除漏关 mask 这一整类 bug
  （见 ADR-0041，编辑器 UIKit 布局已全量迁 SnapKit）。
- **若必须裸写 NSLayoutConstraint**：每个被加约束的子视图，`addSubview` 后立刻
  `translatesAutoresizingMaskIntoConstraints = false`，且约束与该赋值要在同一次装配里完成。

### P130·b —— 布局欠定：只给 center + 比例约束、不给定尺约束 → 视图实为 0×0

`previewSelectionBorder` 原来只有 `centerX/centerY` + `width == 0.5625*height` 的比例约束，
**没有一组定尺约束**（width/height 具体值，或 edges 拉伸）。系统即便比例算得对，也把尺寸解成
0×0 —— 红框「存在但不可见」，U1 S11 等于假功能，且因 0 尺寸连冲突都未必报。

- **铁律**：任何自定义覆盖层 / 边框 / 角标，**必须至少给一组定尺约束**：
  - 想贴合某视图：`$0.edges.equalTo(参考视图)`（四边定死尺寸）；或
  - 想按比例：`$0.center.equalTo(参考)` + `$0.height.equalTo(参考)` + `$0.width.equalTo($0.height).multipliedBy(比例)`
    （高先定，宽由高派生——**定尺约束必须在场**，比例只是派生）。
- 比例/乘数（`multiplier`）一旦创建**不可变**：画布比例变化等场景，用 `snp.remakeConstraints`
  整体重建，不要试图改旧约束的乘数。

- **影响范围**：任何手写 / SnapKit 的 Apple 端 UI 布局。两条合起来正是「约束冲突 +
  功能不可见」这对孪生故障的标准成因。
- **防复发规则**：给覆盖层加约束时自检——① 该视图 `translatesAutoresizingMaskIntoConstraints`
  已被约束框架接管（或手动关）；② 约束集里**至少有一组定尺**（edges / 具体 width·height），
  比例只能作为派生，不能作为唯一尺寸来源。

### P131 —— 全清 UIView 的 backing layer：把子视图的 layer 一起拔掉 → 真机 SIGSEGV（2026-10-14 实测）

**症状**：进编辑页**必现** SIGSEGV（signal 11）。栈（已用设备符号符号化）：

```
CA::Transaction::flush_as_runloop_observer → CA::Layer::perform_update_
 → -[UIView(CALayerDelegate) _performPreLayoutUpdateOfLayer:]
 → -[UIView _updateTraitCollectionAndProcessChangesWithBehavior:]
 → -[UIView _wrappedProcessTraitChanges:] ×9（沿层级下钻）
 → -[UIView _updateCachedTraitCollectionIfNeeded] → _parentTraitCollection
 → _parentTraitEnvironment → -[UIView(UIKitManual) superview]
 → CALayerGetSuperlayer + 72   ← SIGSEGV
```

栈只有 42 帧且收敛到 `main` → **不是栈溢出**，是 `superview` 读到坏指针。
（⚠️ 在 Xcode 里"暂停"看会是同一条栈但表现为"卡住"，很容易误判成死锁/无限递归。）

**根因**：`TimelineContentView.rebuild` 用 `layer.sublayers?.forEach { $0.removeFromSuperlayer() }`
全清自绘层。而 `layer` 是 UIView 的 backing layer —— **子视图（主轨右端「+」按钮）的 layer
也挂在它的 sublayers 里**，于是被一起从树上拔掉：UIKit 的 `subviews` 仍持有该 view，
但它的 layer 已不在层级中。CA 首次提交事务走到这个「有 view / 无 layer」的畸形状态
→ `_parentTraitEnvironment → superview → CALayerGetSuperlayer` 解引用野指针 → 崩。

**二分结论（真机实测，6 组对照）**：摘时间线视图 → 不崩；摘 `addButton` → 不崩；
`rebuild` 不执行 → 不崩；用裸 UIView 顶替按钮 → **照崩**（证明不是按钮特有，
是「contentView 有子视图」+「rebuild 清层」两者同时成立才触发）。

- **铁律**：**自绘图层不要挂在 UIView 的 backing layer 上**。在自绘 UIView 里建一层专用
  容器层（`private let canvasLayer = CALayer()`，init 里 `layer.addSublayer(canvasLayer)`，
  `layoutSubviews` 里 `canvasLayer.frame = bounds`），自绘层全挂它，清空只清
  `canvasLayer.sublayers` —— 子视图层永不被触碰。
- **同类禁写**：`layer.sublayers = nil` / `layer.sublayers?.forEach { $0.removeFromSuperlayer() }`
  出现在 UIView 子类里即为高危信号（全仓已 grep，仅此一处）。
- **影响范围**：任何「 UIView + 自绘 CALayer 混排」的视图（时间线、波形、标尺等）。

### P132 —— devicectl 启动的进程崩溃不落 .ips，lldb `device process attach` 也取不到栈（2026-10-14 实测）

排查真机崩溃时两条外部通道都失效：

1. `xcrun devicectl device process launch` 启动的 App 崩溃后，**CrashReporter 不写 .ips** ——
   `devicectl device copy from --domain-type systemCrashLogs` 反复拉都没有新日志。
2. `lldb`：`device process attach -n <name> -w` 抢不上（崩溃在 1s 内）；按 pid attach 能挂上
   （`process status` 报 running），但后续 `continue` / `thread list` 一律
   `error: Process must be launched` —— 拿不到可用 Process 对象。
   （`--start-stopped` 起挂起态 → `device process list` 取 pid → attach，仍如此。）

- **可用通道**：进程内自取 —— DEBUG 装 `sigaction(SIGSEGV/SIGBUS/SIGABRT)`，
  回调里把 `Thread.callStackSymbols` 打到 **stderr**（stdout 全缓冲会丢），
  `devicectl ... --console` 直接可见。本次即靠它拿到栈（见 `DebugCrashDumper.swift`）。
- **符号化**：`~/Library/Developer/Xcode/iOS DeviceSupport/<版本>/Symbols` 有系统库符号；
  先由「地址 - 文件内偏移」算出镜像基址（UIKitCore = 0x197ca0000），再
  `atos -o <镜像> -l <基址> <地址>` 即可把 UIKitCore/QuartzCore 全部符号化。
- **无 `timeout` 命令**：本机 macOS 无 GNU coreutils，用 `nohup ... &` + `sleep N` 控制时长。

### P131·补 —— 治理工具与实证（2026-10-15）

- **门禁规则**：`tools/compliance/check_uiview_layer_hygiene.py`，已接入 `tools/ci/run_gate.sh`
  步骤 **2c（layer-hygiene）**。
  - R1（FAIL）：`layer.sublayers = nil/[]`、`layer.sublayers?.forEach { … removeFromSuperlayer() }`、
    `?.removeAll()`、`map/filter { … removeFromSuperlayer() }`，含 `xxx.layer.sublayers` 形态。
  - R2（WARN，不阻断）：同文件 `layer.addSublayer(` ≥2 次 = 自绘与 backing layer 混排。
  - 逃逸阀：行内 `cq-allow: backing-layer-clear`（须能说出「该 UIView 确认无子视图」）。
  - 扫描 `apps/apple` 下 `.swift/.m/.mm`，排除 `Pods/.build/build/vendor/third_party`；
    **匹配前先剔除注释**（本仓库注释里写了反例文本，不剔除必误报）。
- **实证（2026-10-15 实测）**：当前 `apps/apple` **116 文件 PASS（R1 违规 0）**；
  喂修复前版本（`git show HEAD:…EditorTimelineUIView.swift`）→ **FAIL，精确命中第 321 行**
  + R2 告警混排 ×8；喂「注释反例 / 容器层写法 / 逃逸阀标记」探测文件 → **零误报**。
- **效力边界**：只拦「清空 backing layer sublayers」这一族写法；拦不住
  `sublayers?.last?.removeFromSuperlayer()`、单独移除子视图 layer、跨文件间接引用、
  ObjC 运行时动态操作。**能阻止复发，不能证明零缺陷** —— 真正兜底的是容器层约定 + 真机取证。

### P133 —— 本机 BSD grep 不支持 BRE 的 `\|` 转义：`grep "a\|b"` 静默零命中（2026-10-15 实测）

- **症状**：自查命令 `grep -rn "makeSpacer\|setUndoEnabled\|setRedoEnabled" <dir>` 返回空，
  于是我据此报出「零命中（OK）」—— **假阴性**。实际文件里有 12 处命中（Grep 工具复核）。
- **根因**：macOS 自带的是 BSD grep，BRE 模式下 `\|` **不是**或运算符（GNU grep 才是），
  模式被当成字面量 `a|b` 匹配，自然零命中，且**不报错、不退出非 0** —— 静默失败。
- **影响面**：任何「或条件」自查都会假绿；更危险的是它会**反向认证**一个错误结论
  （我以为某个旧写法已经清零，其实还在）。同类：`grep -E` 才是 ERE。
- **规避**：批量/或条件自查一律用仓库自带的 **Grep 工具**（ripgrep，语法一致）；
  非用 shell 不可时必须 `grep -E "a|b"` 或 `grep -e a -e b`。
- **验证状态**：已实测复现（本机 macOS 26.7.1，`grep --version` 为 BSD 系）。

### P134 —— CocoaPods 会解析 `s.ios.dependency`：UIKit-only 依赖必须靠**子 spec** 隔离（2026-10-15 实测）

- **症状**：`ChuanqiCutEditor.podspec` 加了 `s.ios.dependency 'TimelineKit'`（本地 UIKit-only
  Pod）后，**macOS 端** `bundle exec pod install` 直接失败：
  `Unable to find a specification for TimelineKit depended upon by ChuanqiCutEditor`；
  把 `pod 'TimelineKit', :path => ...` 补进 mac Podfile 则报
  `The platform of the target ChuanqiCutMacApp (macOS 15.4) is not compatible with TimelineKit … does not support macOS`。
  → mac 端连 Pods 工程都生成不出来，随后「删除旧文件」会让 stale 的 mac Pods 工程指向不存在的文件，
  mac 壳构建随之失败。
- **根因**：`s.ios.dependency` **不会**在解析期按平台过滤。实证：同一个 spec 的
  `s.ios.dependency 'SnapKit'` 就出现在 **mac Podfile.lock** 的 ChuanqiCutEditor 依赖里
  （mac Podfile 从不声明 SnapKit，SharedUI/Player/Import/Camera 也都没声明）。
- **规避（已落地）**：拆子 spec —— 默认子 spec `Core`（两端共用，无 TimelineKit 依赖）+ iOS 专属
  子 spec `TimelineKitTrack`（含适配层/容器/调试预览 + `ss.ios.dependency 'TimelineKit'`）。
  iOS Podfile 引 `ChuanqiCutEditor/TimelineKitTrack`，mac Podfile 引默认 `Core`。
  ⚠️ 拆子 spec 后：`Core` 必须 `exclude_files` 掉那几个文件，否则两端都编；
  新加 iOS-only 文件必须**同时**改 `Core.exclude_files` 和 `TimelineKitTrack.source_files`
  （漏一处 = macOS 编译到 UIKit 代码）。
- **验证状态**：已实测 —— 两端 `bundle exec pod install` 均成功，
  iOS 壳（`generic/platform=iOS`）与 mac 壳（`-arch x86_64 ONLY_ACTIVE_ARCH=YES`）均 BUILD SUCCEEDED。

### P135 —— 「返回」类按钮：目标态必须由**当前层**推导，不能由**业务状态**推导（2026-10-15 实测）

- **症状**：选中片段 → 底栏切到 `clipSelected` 条 → 点「返回」**完全无反应**（无报错、无日志）。
- **根因**：`EditorViewModel.closePanel()` 原写
  `toolbarMode = (selectedClipId != nil) ? .clipSelected : .primary` —— 目标态由「有没有选中片段」
  推导而来。而 `clipSelected` 条上的「返回」恰恰是在**有选中**时点的 → 推导结果 = `.clipSelected`
  = 当前值 → `EditorToolbarUIView.setMode` 的 `guard newMode != mode else { return }` 直接 return，
  整条底栏一动不动。
- **一般形态**：**同值守卫 + 目标态由状态推导** 这一组合，会让「退出当前层」的按钮**静默失效**。
  比 P130（布局欠定导致不可见）更隐蔽 —— 按钮看得见、能点、有回调，只是算出来的新值等于旧值。
- **规避**：分层 UI 的「返回」= 按**当前层**逐层退出（`switch toolbarMode { case .drawer: …; case .clipSelected: … }`），
  目标态永远比当前层浅一层；同值守卫保留（防无谓重建），但**不能靠它表达「不变」**。
- **验证状态**：已修（本仓 `closePanel()` 改为 `switch` 分层）；iOS 壳 BUILD SUCCEEDED，真机待传哲复验。

### P136 —— 「播放中不抢播放头」的守卫：把用户手势变成静默失效，且去掉守卫也不生效（2026-10-15 实测）

- **症状**：播放中拖轨道区没有任何反应；用户要的是「拖轨道 = 定位播放位置」。
- **根因（两层）**：
  ① `EditorViewController` 的 `onScrub` 有 `guard let self, !self.viewModel.isPlaying else { return }`
     —— 播放中直接吞掉回调；
  ② 仅去掉守卫**不够**：播放循环持续推进 `playhead`，这一次 `setPlayhead` 落下即被下一 tick 覆盖。
- **规避**：播放中操作轨道区 = **先暂停再执行**（`pausePlayback()` 幂等，未在播则 no-op），
  然后才 seek / 提交编辑。编辑类 Intent 同理（`TrackIntent.isEditing` 判定；选中不算，播放中点片段不打断）。
- **验证状态**：已修（`onScrub` 先 `pausePlayback()` 再 `setPlayhead`；`apply(intents:)` 对
  `.commitEdit` 先暂停）；iOS 壳 BUILD SUCCEEDED，真机待传哲复验。

### P137 —— 同功能 DEBUG 钩子加两处会**互相抵消**（2026-10-15 实测，`CQ_AUTO_PLAY`）

- **症状**：加了 `CQ_AUTO_PLAY=1` 自动起播钩子后，真机日志 `[hook] … auto_play=true`
  （说明起播成功），但 `[tk:perf]` 一行都不出 —— 播放态剖面取不到数。
- **根因**：`EditorScreen`（SwiftUI 壳）**早已**有同功能钩子（`installDemoClipFromEnvironment`
  之后 `togglePlayback()`）；我在 `EditorViewController` 的 `reloadTimeline` 里又加了一个
  「片段一装载就 `togglePlayback()`」—— 第二次 toggle 把第一次刚开起的播放**关掉**。
  `togglePlayback` 是**取反**，不是「置为播放」；两个「开播」钩子 = 开→关。
- **一般形态**：任何 **toggle 语义**的自动化钩子，重复挂载不会「更保险」，只会抵消。
  且现象极具误导性：状态日志显示 true（钩子各自都成功），实际状态是关。
- **规避**：① 加自动钩子前先 `grep` 同名环境变量（本仓已收口在 `EditorScreen`，
  `[hook]` 那行就是它的状态输出）；② 幂等动作优先做成「置位」而非「取反」
  （如 `pausePlayback()` 幂等 vs `togglePlayback()`），见 P136 的同款取向。
- **验证状态**：已修（删掉 EditorViewController 里重复的那个，原地留注释警告）；
  实测删掉后 `[tk:perf]` 正常出数：`playhead n=168 avg=1.17ms`（2s 窗口）。

### P138 —— 挂在「当前平台不渲染的槽位」里的 UI = 静默死代码（2026-10-15 实测，`DebugOverlayView`）

- **症状**：DEBUG 诊断浮层在 iPhone 编辑页**从来不显示**（`CQ_DEBUG_OVERLAY=1` 也不显示）；
  macOS / 原 iPad 横屏能看到。
- **根因**：浮层挂在 `EditorView` 的 **`preview:` 槽位**（`.overlay(alignment: .topLeading) { DebugOverlayView }`）。
  而 iOS 走的是 `EditorLayoutContainer` 的 **`compact()` 槽位**（UIKit 三件套容器）——
  `preview/transport/timeline/toolbar` 四个槽位在 iOS 上**一个都不渲染**。ADR-0024 之后
  iPhone 如此，2026-10-15 我把 iPad 也统一到 compact 之后，iPad 也一起没了。
- **危害形态**：这不是编译错误、不是运行时告警、不是布局问题 —— 视图**存在且合法**，
  只是它的宿主分支永不执行。CR 只看 diff 完全看不出来，只有真机能发现。
- **规避**：① 往布局容器的槽位里挂东西前，先确认**该槽位在当前平台真的被渲染**
  （本仓：iOS 只有 `compact()`，macOS 才有 `preview/...`）；② UIKit 容器里要挂就
  **挂进 UIKit 容器**（本例改为 `EditorViewController` 里 `UIHostingController` 承载）。
- **验证状态**：已修（浮层改挂 UIKit 容器，只钉 top/leading + 宽度上限，高度交给
  SwiftUI intrinsic —— 钉四边会把内容压成 0，P130·b 同款）；iOS 壳 BUILD SUCCEEDED，
  **真机未复验**（设备锁屏，启动被拒 `Unable to launch … because the device was … Locked`）。

### P139 —— 把播放头**回推**给组件会打断 UIScrollView 惯性（2026-10-15 传哲反馈「滑动后没有惯性」）

- **症状**：轨道区手指一离屏滚动**立刻停死**，没有减速滑行；同一个组件在
  **TimelineKit 调试页**里惯性正常。
- **根因（差异点就是线索）**：调试页只 `sink { describe(event) }`，**从不回推**；正式接入
  有一条反馈环 —— 用户滑 → 组件 `scrollViewDidScroll` → `store.setCurrentTime(userScrub)`
  → 宿主 `onScrub` → `VM.setPlayhead` → `$playhead` → `updatePlayhead` → `kitView.setCurrentTime`
  → 组件 `scrollToTime` → **`timelineScrollView.setContentOffset(...)`** → 惯性动画被取消。
  每滑动一帧就拽一次，减速根本跑不起来。
- **一般形态**：「播放头恒在视口中央」的轨道范式里，播放头位置本来就由 contentOffset 决定，
  **不需要宿主反过来告诉组件它在哪**；凡是把「组件告诉我的状态」原样灌回组件，都要先问
  「会不会引起一次强制布局/滚动」。
- **规避**：scrub 期间（含减速）一律不回推；抑制由 `.timeChanged(final: true)` /
  `.timeScrollEnded` 解除，并配**独立超时上界**（0.5s）兜底 —— 结束事件没来也不能把
  播放跟随永久吞掉（ADR-0034：异步等待必须同时有超时和上界）。
- **验证状态**：已修（`EditorTimelineKitView.isUserScrubbing`）；iOS 壳 BUILD SUCCEEDED，
  **惯性需传哲真机手感确认**（无法脚本化）。

### P140 —— `vendored_libraries` 给 `.xcframework` 目录：CocoaPods 静默无痕，链接行少一个库却照样 BUILD SUCCEEDED（2026-10-15 修）

- **症状**：`engine/ChuanqiCutCore.podspec` 写了 `s.vendored_libraries = 'vendor/libffmpeg.xcframework'`，
  pod install 0 错误，双壳 BUILD SUCCEEDED，真机也能跑 —— 但 App 聚合 xcconfig 的
  `OTHER_LDFLAGS` 里**没有 `-l"ffmpeg"`**，`LIBRARY_SEARCH_PATHS` 无 vendor/XCFrameworkIntermediates
  路径，`Pods.xcodeproj` 里 grep `vendor` **0 命中**。FFmpeg 从 2026-10-11 起一直是「编了头文件、
  没链库」的空转。ADR-0038 §验证却记着「App 聚合 xcconfig 含 `-l"ffmpeg"`」，与实测不符（已勘误）。
- **根因**：CocoaPods 只按 `File.extname(framework) == '.xcframework'` 识别 xcframework，且只认
  **`vendored_frameworks`**（`sandbox/file_accessor.rb` 的 `vendored_xcframeworks`；
  `target/build_settings.rb` 对 `build_type.static_library?` 生成 `-l"ffmpeg"` +
  `xcframework_intermediate_dir` 搜索路径）。`vendored_libraries` 期待的是 `*.a` 文件/通配，
  喂它一个目录 glob 到目录本身，后续筛选全部落空且**不报任何 warning**。
- **为什么没人发现**：静态库是**按需拉成员**的，当时全仓唯一调用 `FFmpegProbeFile` 的是单测，
  App 没人调用 → archive 成员不拉取 → 链接器根本不找 `libffmpeg.a`，缺 `-l` 也绿。
  **「无人消费」把「接线失效」完全掩盖了**（与 P135「宿主分支永不执行」同构）。
- **一般形态**：凡是「接线写了但没证据证明它生效」的依赖，都要在**有人消费之前**单独验证，
  否则构建绿只是「还没人碰它」。
- **规避/验证手法**：
  ① 判据落到**产物**上，不看 podspec 字面：`python3` 逐项解析 App 聚合 xcconfig 的
  `OTHER_LDFLAGS` / `LIBRARY_SEARCH_PATHS`（本机 toybox grep 在管道里对含引号项**会假阴性**，
  本次 `-l"ffmpeg"` 就是 grep 漏、python 复核才看到）；
  ② 构建后查 `XCFrameworkIntermediates/<Pod>/libffmpeg.a` 是否出现并用 `lipo -info` 验架构
  （本次 iOS=arm64 2.8M、macOS=x86_64+arm64 fat 5.4M，slice 选择正确）；
  ③ 真链接实证：`xcrun -sdk iphoneos clang` 编一个只调 `avformat_open_input` 的 TU +
  `-l"ffmpeg"` + App 现有 framework 集合 → 链出可执行文件，`nm` 数到 775 个 `_av*` 符号，
  且**不需要额外补 -lz/-lbz2/-liconv**（MEDIA-021 开工时的链接依赖结论）。
- **验证状态**：已修（`s.vendored_frameworks = 'vendor/libffmpeg.xcframework'`）；双端
  `bundle exec pod install` 0 错误；iOS generic device 与 macOS x86_64 双壳 **BUILD SUCCEEDED**；
  **真机未跑**（本批只动链接行，App 仍无人调用 FFmpeg 符号，运行时行为无变化）。

## P141：孤立 doc 注释伪装成函数头 —— Edit 匹配到它会吞掉 `#if DEBUG` 并造出重复函数（2026-10-16，P142 scrub 修复，已证实 verified）
- 现象：`AppEntry.setPlayhead` 的 doc 注释（653-656）**孤立存在**——真正的函数在 749 行，
  中间隔着整个 `#if DEBUG ... #endif` 块（`toggleDebugOverlay` 等）。两者长得像「注释紧跟函数」，
  按「注释 + `func`」做锚点 Edit 会：① 把紧随其后的 `#if DEBUG` 当成函数体的一部分吞掉；
  ② 在注释处造出一个**重复的半截函数**；③ 原函数残留 → 一个文件里两个 `setPlayhead`。
- 代价：`#if DEBUG`/`#endif` 失衡 + 重复定义，编译期报错点还**指向错误的行**（我第一次
  报的 3 个 error 里有两个是它的连带），排查极易被带偏。
- **纪律**：改一个函数前，先 `Read` 一次**函数的真实签名行号**（grep `func 名`），
  确认「注释—函数」是否相邻；文件里有 `#if` 块把两者隔开时，锚点必须含真实签名。
- 修复手法：按原样还原被吞的 `#if DEBUG` 与重复函数，再只改真函数；改完 Read 回读确认配平。

## P142：Platform 接缝反向 include core 头会成环 —— 跨层枚举用中立 int32_t 透传（2026-10-16，scrub 快速 seek，已证实 verified）
- 背景：`chq_frame_provider.h`（core）已经 `#include "cq/platform/chq_media.h"`。所以
  **不能**在 `chq_media.h` 里 include `chq_frame_provider.h` 来把 `ChqSeekPolicy` 带进
  Platform 接口 —— 直接成环，编译炸。
- 做法：Platform 接缝（`ChqIFrameProvider::Seek/AcquireFrame`）用**中立 `int32_t seek_policy=0`**
  携带 core `ChqSeekPolicy` 的底层值（0/1/2），只在 core 层（已 include core 头的
  `ChqSystemFrameProvider` / 预览渲染器）`static_cast<ChqSeekPolicy>` 转回。
- 配套：`RenderFrame` 的新参数放**末位**并给默认值，保住既有 3 参调用（渲染器直接调用、
  C ABI 同步路径、几十处测试）。放中间会让 `RenderFrame(pts, out, token)` 类型不匹配。
- 坑中坑：改纯虚函数签名时，**override 必须匹配 arity** —— 测试 fake 即使参数不用也要
  补上，否则 `-Werror,-Wunused-parameter` 直接失败编译；顺手把该参数记进 fake 字段，
  正好当「策略确实透传」的断言点（本轮就是这么加的第 9 组测试）。

## P143：跨文件契约改动被切进两笔提交 —— 提交的单棵树编译不过，本地构建却一路绿（2026-10-16，#21 收尾，已证实 verified）
- 现象：`c5d4bf5`（P142 内核批）提交了 `chq_preview_renderer.{h,cpp}` 里 `Acquire(..., uint32_t* out_rotation, ...)`
  的**实现**，但声明所在接口 `engine/core/cq/render/chq_frame_source.h` 的同一改动**留在工作树未提**。
  结果 `origin/main` 单棵树编译不过：`error: non-virtual member function marked 'override' hides virtual
  member function`（基类 8 参 vs 派生 9 参）。本地 `build_core.sh`/双壳一路 BUILD SUCCEEDED 全是**假证**
  —— 它们编的是「已提交部分 + 未提交部分」混合的工作树，永远看不到这个洞。
- 为什么会漏：写集切分按**文件归属批次**做（"这两个文件算 TimelineKit WIP，不提"），没按**编译依赖闭包**做。
  `chq_frame_source.h` 名义上属 #21，实际与 c5d4bf5 的 renderer 改动是**同一处接缝的两半**。
- **纪律**：提交任何改了虚函数/接口签名的笔之前，跑一次**纯 HEAD 树**的语法检查（不需要全量构建，秒级）：
  `git archive HEAD engine tests | tar -x -C /tmp/x` 后
  `clang++ -std=c++20 -fsyntax-only -I/tmp/x/engine/core -I/tmp/x/engine/platform <被改 TU>.cpp`。
  工作树越脏（多批混提）越必跑 —— 只有它能区分「我提的树」与「我机器上的树」。
- 同类预防：接缝签名改动尽量**接口 + 实现 + 调用点 + 假实现（tests/unit/fake）同笔**，
  跨批次拆分时把接口文件归到**最早**那笔，而不是留给后续批。
- 修复：`b471b8c` 补齐接口与剩余链路。

## P144：`.gitignore` 的两种**静默失效**写法 —— 规则看着在、实际一条没挡（2026-10-16，INFRA-027 收口，已证实 verified）
- 现象一（行内注释）：写成 `/vendor/   # bundler gems 缓存` 之后，`git check-ignore vendor/x` 返回**未忽略**。
  gitignore 不把行内 `#` 当注释：整串（含空格与"说明"）被当成**路径的一部分**，规则变成一条永不匹配的模式。
  同批一起失效的还有 `/build/`、`/prebuilt/`、`third_party/prebuilt/` —— 一次改写漏掉 4 条，
  而且 `git status` 立刻冒出 `?? build/`、`?? vendor/`、`?? third_party/prebuilt/` 三个大目录，
  才被人眼抓到。**注释必须单独成行。**
- 现象二（含斜杠≠任意层级）：`shaders/generated/` 这种**模式里带斜杠**的条目是**锚定到 .gitignore 所在目录**的，
  只匹配仓库根的 `shaders/generated/`，不匹配 `engine/shaders/generated/`。
  INFRA-033 要把 shader 挪进 `engine/` 时，旧规则就盖不住新落点了。
  对比：`tmp*/`、`vendor/`（无斜杠）才是真·任意层级。要两头都盖必须**各写一条**，或用 `**/`。
- 防复发（本仓口径）：改 `.gitignore` 之后固定三条取证，不接受"看起来对了"：
  1. `git ls-files | wc -l` 改前后相同（防误伤已入库源码）；
  2. `git status --porcelain | grep '^??'` 只剩本次预期新增（防漏网产物现形）；
  3. 对每条关键规则打一个**存在性探针**：`git check-ignore -v <该目录>/x`，逐条核对返回的规则行号。
     本轮就是靠探针把 4 条静默失效规则当场抓出来的。
- 关联：裸模式误忽略的历史案底见本文件"三个构建脚本从未入库"那条（顶部注释亦引用）；
  INFRA-027 的验收条款 3 即本坑的固化版本。

## P145：门禁摘要会**替没跑过的步骤背书** —— 失败即退出时 `print_summary` 读的是上一次的同名日志（2026-10-16，INFRA-029 首跑，已证实 verified）
- 现象：`tools/ci/run_gate.sh` 在 `core-rel` 段 FAIL 后走 `print_summary; exit 1`，**apple 五个包段根本没执行**。
  但摘要仍打出 `apple-swift-bindings: Test Suite ... passed`、`apple-player` / `apple-camera` /
  `apple-import` / `apple-editor` 共 10 行"通过"，看着像全跑过。真相在时间戳：`grep` 的是
  `build/gate-logs/*.log`，文件是 **2026-10-12 12:04** 写的，被当作本次结果打印。照抄这段摘要 = 拿四天前的数字给今天的改动验收。
- 根因：`run_gate.sh:46-60` 的 `print_summary()` 只判断 `[ -f 日志 ]`，不判断该日志是否本次产出。
- 防复发（本仓口径，固化进 INFRA-034）：
  1. 读摘要前先看**门禁是否跑到该段**——本次日志 mtime 必须晚于启动时间，或直接看有没有对应的
     `==> [apple-*]` 起始行；没有起始行的"通过"一律按**未验证**处理。
  2. `run_gate.sh` 应在每个 step 开头把日志截断（`: > "$log"`）或给文件名加运行时间戳；
     `print_summary` 只统计本次 `PASS=` 计数里的 step。
- 同批第二个坑（同一根因的另一面）：**搬家不得与门禁并发**。本次 `git mv` 夹具时 Release 段 ctest 正在跑，
  旧目录被清空 → `ai_edit_plan` 报 `FAIL: manifest 非空 / 总 0`。这是假失败，但长得跟真丢夹具一模一样。
  收口顺序固定为：**门禁跑完（或明确 kill）→ 再动文件 → 再跑门禁**。
- 关联：INFRA-029 的 risk 条款；远端"已验证"按未验证处理的同源纪律见 AGENTS「双机分工」节。

## P146：`core-dbg`/`core-rel` 走 macOS 切片，**编不到 iOS-only 代码** —— `-Werror` 破坏可以带着"门禁绿"入库（2026-10-16，INFRA-029 批暴露，已修复 verified）
- 现象：同一次门禁里 `core-dbg`、`core-rel` **PASS**，紧随其后的 `apple-xcframework` **FAIL(rc=2)**：
  `engine/platform/apple/media/audio_engine.mm:252:65: error: unused parameter 'note' [-Werror,-Wunused-parameter]`。
  两条 step 编译的是同一份源，结论相反。
- 根因：`RegisterSessionObservers()` 整段在
  `engine/platform/apple/media/audio_engine.mm:212-271` 的 `#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE` 里；
  `build_core.sh --platform=apple` 只出 macOS 切片，这段被预处理掉 → 该 step 永远绿。
  真编它的只有 `build_core_apple.sh`（ios-device / ios-sim / macos 三切片）。
  引入者是 b471b8c（#18 音频打断恢复），当时只跑了 `build_core.sh` 窄检就入了库。
- 防复发（口径，非自动化）：**动过 `engine/platform/apple/**` 里任何 `#if … TARGET_OS_IPHONE` 包裹的代码，
  窄检必须加跑 `tools/build/build_core_apple.sh --config=Release`**（含 consumer smoke-link），
  不能只看 `build_core.sh --platform=apple --test` 的 52/52。
  把 ios 切片纳入 `build_core.sh` 的默认覆盖面属门禁改造，归 INFRA-034 一并评估。
- 本次修复：block 形参改匿名 `^(NSNotification* /* note */) {`（与同文件 :239 那个 block 的写法一致），
  重跑 `build_core_apple.sh --config=Release` → exit 0，`ChuanqiCut version = 0.1.0`，产物 4.5M。

## P147：全量 ctest 里 `platform_apple_decode` 的**负载相关假失败** —— 1s 丢帧判据在机器被打满时会真触发（2026-10-16，INFRA-029/035 批复跑门禁，已复现取证 verified；根因未修）
- 现象：`run_gate.sh` 的 `core-dbg` 段 `98% tests passed, 1 tests failed out of 52`，
  唯一失败 `45 - platform_apple_decode`（**44.38s**，而基线单跑 **6.92s**，慢 6 倍）。
  用例内部报 3 条 FAIL：`解码帧数 = 150` / `= demux 视频包数` / `pts 集合 == demux pts 集合`，
  实际 `解出帧数 = 147`。前一条同族记录是 P143（当时 148/150，我并发跑了第二个 ctest）。
- 触发链（代码级，已核实）：`engine/platform/apple/media/media_decode.mm:681-698` 的 `PopFrame`
  在输出队列空时轮询 pending，**最老一笔提交 >1s（`1'000'000'000ull` ns）即判"丢帧超时"并放弃等待**，
  日志形如 `丢帧超时：dts=588000 等 1832ms 未完成，放弃等待（重新 seek 恢复）`。
  这条 1s 判据是 2026-10 为修「VT 静默丢帧时 VTWait 永久阻塞」加的**固定值**，不随负载自适应；
  机器忙时 VideoToolbox 回调确实能压过 1s → 内核主动丢 3 帧 → 单测"无丢帧"断言必挂。
- 判定方法（**遇到这条就用它，别当回归**）：单独重跑三次
  `ctest --test-dir build -R '^platform_apple_decode$'`。
  本次实测 3/3 全过（9.82 / 9.33 / 9.55 s），而全量段 44.38s 失败 → 判为负载抖动，非布局搬家引起
  （该用例读 `tests/golden/frames/*.mp4` 与 `CQ_SOURCE_DIR` 注入宏，本批两处都没动）。
- 防复发：
  1. 门禁口径：**同一用例单跑绿 + 全量红**才允许记作 flake，且必须写清两边的秒数与帧数，不得只写"重跑过了"。
  2. 门禁期间**本机不得再起构建/ctest**（P143 同条纪律，这条是它的第二次实证）。
  3. CI（INFRA-034）不得把该用例直接放进 workflow：要么 `--exclude-regex platform_apple_decode`
     并在本机阶段批跑，要么给整段 ctest 加一次重试且**重试必须写明是重试**。
- 未做（本期明确不动，属内核媒体线债务）：把 1s 固定判据改成随负载自适应
  （或 demux 排空后按 pending 数等待）。要改须走 `cq-media-pipeline` 分析并挂 AUDIO/MEDIA 线的真机一趟。

## P148：Editor 包在 **mac 宿主**上 4 天没跑过 —— 一个裸 `import UIKit` 把两条红一起藏住（2026-10-16，全量门禁 run2 的 apple-editor 段，已修复 verified）
- 背景：`run_gate.sh` 的五个包段都是 `swift test`（**在 macOS 宿主机上跑**，`Target Platform: x86_64-apple-macos14.0`）。
  上一次 apple-editor 绿是 **2026-10-12**；10-15/10-16 两天都在改编辑页（UIA-043/044/045），
  验证口径走的是 iOS 真机与 iOS 壳构建，**没人跑过 mac 侧的包测试**。
- 第一条（编译）：`ui/ChuanqiCutEditor/Sources/ChuanqiCutEditor/DebugOverlayView.swift:15`
  无条件 `import UIKit` + `UIScreen.main.bounds`（:79-80）→ mac 侧 `error: no such module 'UIKit'`，
  **整个包编不过**，于是第二条红根本没机会露头。
  本包既有约定是「iOS-only 文件整体 `#if os(iOS)` 守卫」（`Sources/ChuanqiCutEditor/UIKit/` 5 个文件皆如此），
  这个新文件在包根目录、没进 UIKit 子目录，也就没守。
  修法 = `#if canImport(UIKit)` 守 import + 把屏幕尺寸收进 `panelSize` 计算属性，mac 退固定 380×320。
- 第二条（断言过期）：`Tests/ChuanqiCutEditorTests/TimelineInteractionTests.swift:190`
  `testToolbarModeTransitions` 断言「closePanel 后仍有选中 → `.clipSelected`」，
  但 `closePanel` 在 **2026-10-15 有意改过语义**（AppEntry.swift:523-526 注释写明：
  旧写法导致「选中条上点返回，底栏一动不动」），现在 `.clipSelected` 态收起 = 退出选中 → `.primary`。
  实测失败信息 `("primary") is not equal to ("clipSelected")`。
  **判定"是测试过期还是产品回归"的依据**：源码里有带日期与动机的显式修复注释 → 测试跟新；
  没有 → 按产品回归走。另外原用例把 drawer 分支（有选中收起→回选中条）挤掉了，
  修时补了一条从 `.drawer` 态进入的断言，两条语义都保住。
- 顺带纠一条我自己的**错判**：看到 `apple-sharedui` 段日志里没有 `Executed N tests`，
  我判断"门禁漏跑了 SharedUI 的 88 个用例"。实跑 `swift test` → `error: no tests found`，
  且 `run_gate.sh:158` 本来就是 `swift build` —— SharedUI 的测试早在 INFRA-014~019 就拆进各功能 Pod 了，
  包段 build-only 是对的。**教训：门禁覆盖面判断要先读 step 命令再下结论**（"88" 是 2026-10-07 的历史数字）。
- 当前 mac 侧包用例基线（2026-10-16 实测，INFRA-031 搬家后必须逐段对上）：
  bindings **26** / player **52** / camera **77** / import **16** / editor **81**（+ SharedUI build-only）。
- 防复发：改编辑页 Swift UI 时，除真机一趟外**必须**跑
  `(cd ui/ChuanqiCutEditor && swift test --disable-sandbox --scratch-path "$ROOT/build/spm/ChuanqiCutEditor")`；
  新增 iOS-only 视图文件一律进 `Sources/<包>/UIKit/` 或自带 `#if os(iOS)` 守卫
  （机器化检查归 INFRA-034 的 `check_repo_hygiene.sh`：包根目录出现裸 `import UIKit` 即报）。

## P149：`pod install` **不会**重写 pbxproj 里 run-script 的路径字面 —— 搬家批的"靠重生成兜底"假设不成立（2026-10-16，INFRA-031，已取证 verified）

- 现象/背景：INFRA-031 把 `apps/apple/packages/` 上提为顶层 `ui/`。卡面初稿写的是
  「pbxproj 禁止手改，路径变化靠 `pod install` 重生成 + Xcode 里核对」—— **这条假设是错的**：
  ADR-0037（2026-10-11，传哲拍板）已退役 XcodeGen，把 `ChuanqiCut.xcodeproj` 冻结为
  **手工维护的唯一真源**，`pod install` 只重写 `Pods/` 与自己注入的 integration 段，
  **不碰**工程里人写的 `shellScript` 字符串。
- 具体雷：iOS 工程的 `[CAM] metallib CIKernel` 编译阶段内嵌 **3 处**
  `$PROJECT_DIR/../packages/ChuanqiCutCamera/Sources/…/*.metal`（beauty_bilateral / face_warp / beauty_guided）。
  不改 → 整壳构建红；改了 pod install 也不会帮你，**任何"搬家批不用碰 pbxproj"的默认假设都要先 `grep` 一次**。
- 取证口径（比"构建过了"更强）：脚本 `set -euo pipefail` + metal 源文件缺失即报错 → **失败是响的**，不会假绿；
  正确性用**产物**证明：三个 `.metallib` 时间戳为本次构建且体积 **9215B / 5792B / 8118B**（非 ADR-0021 案底的 96B 空壳）。
- 改动纪律：pbxproj 是 plist 单行巨串，`sed` 只替换路径子串，改完必须
  `git diff --stat` 核到 **1 insertion / 1 deletion**（本批实测如此，mac 工程 0 改动）——
  行数一旦大于 1 就说明换行或结构被动过，立即回滚重来。
- **防复发规则**：以后凡涉及目录搬家（INFRA-032 `api/swift`、INFRA-033 `engine/shaders`），
  验收清单里必须有一条「`grep -rn "<旧路径片段>" apps/apple/*/*.xcodeproj/project.pbxproj` 零命中」，
  并把「双壳构建 + 相关 run-script 的产物体积/时间戳」当作通过证据，而不是只看 `BUILD SUCCEEDED`。

## P150：`podspec` 的 `source_files` 是 **pod 根相对** —— 搬家时做全局路径替换会把源文件静默丢光（2026-10-16，INFRA-032，已拦下 verified）

- 现象：`engine/bindings/swift` 外提为 `api/swift` 后，`ChuanqiCutEngine.podspec` 的
  `s.source_files = 'bindings/swift/Sources/ChuanqiCut/**/*.swift'` 若按"路径字面替换"改成
  `'api/swift/Sources/ChuanqiCut/**/*.swift'`，glob 是相对**新 pod 根 `api/swift/`** 解析的 →
  实际指向不存在的 `api/swift/api/swift/Sources/...` → **匹配 0 个文件**。
- 为什么危险：CocoaPods 对 0 匹配**不报错**（`pod install` exit 0、"Installing ChuanqiCutEngine 0.1.0"照打），
  Pods 工程里该 target 的 Sources phase 变空、`libChuanqiCutEngine.a` 只剩桩；消费侧要到
  **链接期**才炸 —— 与 2026-10-07「pod 根外源文件静默丢弃 → 空目标」是同一个雷的第二次触发。
- 正确写法：去掉前缀 = `s.source_files = 'Sources/ChuanqiCut/**/*.swift'`（路径永远相对 pod 根）。
- 取证口径（三层，逐层变强）：
  ① `python3 -c` 读 `Pods/Local Podspecs/ChuanqiCutEngine.podspec.json` 的 `source_files`；
  ② `grep -oE "path = Sources/ChuanqiCut/[A-Za-z]+\.swift" Pods/Pods.xcodeproj/project.pbxproj | uniq -c`
     = **8 个文件各 1 次**；
  ③ App 二进制 `nm -a ChuanqiCutApp | grep -c ChuanqiCutEngine` = **1838**（mac 壳 **1842**）——
     只有链接产物里有门面符号，才算"装得上且用得上"。
- **防复发规则**：凡改 podspec 路径（搬家、拆 Pod、换 pod 根），验收必须含 ②③ 两条；
  `pod install` 成功与 `BUILD SUCCEEDED` 都**不能**单独证明 Pod 里编进了源码。

## P151：相对符号链接跟着 `git mv` 一起搬走但**目标不会自动改写**（2026-10-16，INFRA-032，已修 verified）

- 现象：`api/swift/Sources/ChuanqiCutCore/include/cq_sdk.h` 是指向内核真源的**相对符号链接**
  （`120000` blob）。旧值 `../../../../../core/cq/cq_sdk.h` 从 `engine/bindings/swift/...` 上溯 5 层
  落在 `engine/`；搬到 `api/swift/...` 后同样上溯 5 层落在**仓库根** → 悬空。
- git 表现易误判：`git status` 显示为 `D` + `A` 成对（不是 `R`），rename 检测配对不上；
  **只看 `git diff --stat` 会以为"搬家纯度被破坏了"**，实际是链接目标必须重写。
- 改法：目标改为 `../../../../../engine/core/cq/cq_sdk.h`（层数不变、加 `engine/` 前缀）。
  `ln -sfn` 之后**必须** `test -f <link>` 实证解析，别只信 `readlink` 的字符串。
- 附带发现（本批重跑生成器时暴露）：`docs/api/engine-api.md` 已过期 4 天多 ——
  符号 **76 → 103**（新增 24 个函数 + 3 个 struct：`cq_session_split_clip`/`remove_clip`/
  `set_canvas`/效果参数系列/`cq_audio_preview_*`），文件行数 406 → 516，**且没有任何符号消失**。
  根因：`tools/docs/gen_api_reference.py --check` **不在 `run_gate.sh` 的 15 步里**，接口文档无人校验。
  → 归 INFRA-034 把它做成门禁步骤（同 P146 的"覆盖面盲区"族）。

## P152：目录搬家后 SPM **增量缓存仍钉死旧绝对路径** —— 未受影响包照样红（2026-10-16，INFRA-032 全量门禁 run1，已修 verified）

- 现象：门面 `engine/bindings/swift` → `api/swift` 之后，单包窄检全绿（bindings 26、editor 81、
  SharedUI build 过），但全量门禁第 12 步 **apple-import FAIL**：
  ```
  error: couldn't build build/spm/ChuanqiCutImport/x86_64-apple-macosx/debug/libChuanqiCut.a
         because of missing inputs:
         /…/engine/bindings/swift/Frameworks/ChuanqiCut.xcframework/macos-arm64_x86_64/libChuanqiCut.a
  ```
- 根因：`build/spm/<包>/workspace-state.json` + 各 `.d`/`.swiftdeps` 里存的是**依赖的绝对路径**。
  `ChuanqiCutImport` 自己不引用门面（它只引 `../SharedUI`），但**传递依赖**把旧路径带了进来。
  所以"我改的包我重跑过"不足以证明门禁会绿 —— **搬家批必须清的是所有消费方包的 scratch，不只被搬的那个**。
- 判据（可机器验，清理前先取证）：`grep -rl "<旧路径>" build/spm/` 命中即说明还有缓存钉着旧根；
  清理后该 grep 必须零命中，且门禁从**空 scratch** 一趟跑到 PASS=15。
- 处置：`rm -rf build/spm/*`（全在忽略的 `/build/` 产物根内，非源码）后重跑全量。
  顺带发现 `build/spm/ChuanqiCutDebug`（10-11 留下、对应包已不在树里）= 死 scratch，
  属 INFRA-034 `check_repo_hygiene.sh` 该管的"产物根残留"一类。
- **防复发规则**：凡是 `git mv` 顶层/二级目录的批次（032 门面、033 shader、以后任何搬家），
  收口流程固定为「`grep -rl <旧路径> build/` 取证 → `rm -rf build/spm/*` → 全量门禁一趟到底」，
  **不得**用"相关包窄检已过"替代全量重跑。

## P153：`linkcheck_docs.py` 把「叙述里提到的死路径」也当链接 —— 治理卡越写越红（2026-10-16，INFRA-032 收口时发现，**未修 → 归 INFRA-034**）

- 现象：INFRA-035 收口时实测断链 **6** 条；本次收口重跑变成 **9** 条。多出的 3 条全是
  `docs/tasks/TASK-BACKLOG.md:567`、`TASK-INFRA-034.md:90`、`TASK-INFRA-035.md:70` 指向
  已改名的 `docs/specs/PAL-接口契约.md` —— **而这正是那几张卡"登记待清理死链"的清单本身**。
- 根因：`tools/ai/linkcheck_docs.py:22` `BACKTICK_PATH = re.compile(r"`([^`\s]+\.md)`")`
  对**所有**反引号内的 `*.md` 字面做存在性检查，不区分"可导航的链接"与"作为讨论对象的路径"。
- 后果（不止是数字难看）：判据"断链数 < 6"**永不可达** —— 卡片要描述这个死链就必须写出它，
  写出来就+1。这类"判据会被自己的文档触发"的 checker，最后一律被人加 `|| true` 废掉（同 P146 教训）。
- 处置方向（二选一，由 INFRA-034 定并写进 checker 注释）：
  ① checker 按域豁免 append-only 叙述域 `docs/{tasks,reports,handoff}`；
  ② 收紧 `BACKTICK_PATH`：只在反引号路径出现在指路语境（或干脆只查 `[..](..)` 链接语法）时判定。
- 通用规则：**新写任何"存在性检查"类工具时，先问它扫不扫讨论该问题的文档本身**；
  扫就要给叙述域开豁免，否则这个门禁是自反的。

## P154：构建脚本里的**散文残片**能穿过两次全量门禁静默存活 —— CMake 不校验未知关键字参数（2026-10-16，INFRA-033 改 `add_custom_command` 时发现，已修 verified）

- 现象：`engine/platform/apple/CMakeLists.txt` 的 SHADER-001 块第 72 行是
  `    其编辑器组件)` —— 一段中文散文后面跟个右括号，**本应是 `VERBATIM)`**。
  它由 `6ccf29b`（2026-10-13 "B0"，本块首次入库）引入，在仓库里活了 3 天。
- **为什么没人发现**：CMake 对 `add_custom_command` 的未知关键字**不报错也不警告**，
  裸词 + `)` 恰好把括号闭合，`-- Configuring done` 照打；而门禁的编译段（`-Werror`）、
  单测段（ctest 52/52）、golden 段都在**下游**，抓不到 configure 阶段的垃圾。
  全量门禁跑过两次（INFRA-031 / 032）全绿。
- **不是脱敏批干的**（先怀疑过，已排除）：`git show 488129f 脱敏 -- engine/platform/apple/CMakeLists.txt` = 空 diff，
  且 `6ccf29b` 是该块的新增提交 → 残片与原文都出自 B0 那次写入。**原词不可考**，
  只能按 CMake 惯例补 `VERBATIM)`，靠行为验证而不是靠猜原文。
- 补完后的等价取证（缺一不算改对）：
  ① `rm -rf build/generated` 后重跑 `build_core.sh --platform=apple --test` → exit 0、
  `error:` 0 行、ctest **52/52**、`[27%] SHADER-001` 步骤真实执行；
  ② 产物字节对比搬家前：`spv` **960/548B**、`msl` **418/410B** **逐字节相等**；
  ③ 剥离注释后的 GLSL md5 与 `HEAD:shaders/src/*` 相同 → 变的只有 banner。
- 通用规则：
  1. **改构建脚本（CMakeLists / podspec / 脚本）时，目视读被改动函数块的整块内容**
     （`git diff -U20`），不要只看 diff 的 +/- 行 —— 残片是"未被改动的那一行"，diff 里根本看不见。
  2. 门禁绿色的覆盖面**不等于** configure/generate 阶段正确：该阶段的静默容忍项只能靠**步骤日志逐条对**
     （本案是 `SHADER-001: …` 这行有没有出现、产物是不是新字节）来验。
  3. 发现"原词不可考"的残片时，**补最符合该语言惯例的那个写法**并用行为等价证明它，
     同时在卡面明写"原词不可考"，不要伪造一段来历。

## P155：`git ls-files` 不带 `-z` 会把**非 ASCII 路径加引号转义**，逐行遍历 = 中文文件名整批静默漏检（2026-10-16，INFRA-034 活文档旧路径扫描，verified）

- 现象：旧路径残留扫描第一版用 `for f in $(git ls-files)` 逐文件 `grep`，报 **40 处命中**；
  换成 `git ls-files -z` + 按 `\0` 分记录后同一判据变成 **60 处**（多出的 20 处全在
  `docs/specs/UIA-011-相册素材导入.md` 这类**中文名文件**里）。
- **为什么会漏**：`git ls-files` 默认按 `core.quotepath=true` 输出，非 ASCII 路径被打成
  `"docs/specs/UIA-011-\347\233\270\345\206\214..."` 这种**带引号的八进制转义串**。
  该串既不是真实路径（文件打不开 → `grep` 报 No such file 或被 `2>/dev/null` 吞掉），
  也不匹配任何以真实路径写的判据 → **漏检是静默的**，命令退出码还是 0。
- 与 P153 是同一条纪律的两面：**判据只认入库文件**（`git ls-files`，不是裸 `grep -r`），
  且**必须 `-z` 分记录**（不是逐行）。两条合起来才是"既不误报本机产物、又不漏报中文文件"。
- 落地：`tools/ci/check_repo_hygiene.sh` 的四条判据全部走 `git ls-files -z`
  （旧路径扫描、产物入库、editorconfig 四条件、clang-format 统计），并把这条写在脚本头部。
- 自查配方（任何"扫全库"的脚本上线前先跑一次）：
  `git ls-files | wc -l` 与 `git ls-files -z | tr -d '\0' | wc -l` 的**命中数必须相同**；
  再单独数一遍非 ASCII：`git ls-files | grep -c '"'` 应远大于 0 才算真的存在被转义的路径。

## P156：批量路径回填的脚本替换会**二次改写「原 xxx」标注行**，把历史说明改成反向错误（2026-10-16，INFRA-034 `docs/specs/` 重写，verified）

- 现象：`docs/specs/ARCH-005-UI层策略与工程结构.md` 里搬家批**故意**留的两行标注
  `api/swift/ …（原 engine/bindings/swift/）`、`ui/<Module>/ …（原 apps/apple/packages/）`
  被本轮的同一条替换规则再吃一次 → 变成 `（原 api/swift/）`、`（原 ui/*）`，
  即**把"从哪里搬来"改成了"搬到哪里去"**，语义反转且看不出是错的。
- 根因：替换脚本按"旧路径字面量 → 新路径"全局匹配，而标注行**同时含旧路径与新路径**，
  一遍替换无法区分"这行是指路"还是"这行是案底"。
- 规则（本批的处置口径，后续搬家批照此）：
  1. 批量路径回填**必须先按行分类再替换**：含迁移标记（`原 ` / `已迁` / `当时在` / `→` / `作废` …）
     的行**整行跳过**——这正是 `check_repo_hygiene.sh` 里 MARKER 豁免集合的由来，
     判据与写入用同一套标记，不能两边各写一份。
  2. 替换完成后**必须抽查标注行**：`grep -rn "原 .*" <本次改过的文件>`，逐条确认"原"后面跟的是**旧**路径。
  3. 脚本改动一律先 `git diff --stat` 对照**预期文件数**，再 `git diff` 看**具体行**；
     只有 stat 就动手 = 把语义反转带进 commit。

## P157：**未提交大改批里对单文件跑 `git checkout -- <file>` = 直接销毁本批未提交工作**（2026-10-16，INFRA-034，verified + 已恢复）

- 现象：为修 P156 造成的标注行反转，对 `docs/specs/ARCH-005-…md` 跑了
  `git checkout -- <file>`。该文件带着 **INFRA-030/031/032 批的 38 insertions / 15 deletions**
  （§6 工程结构树按 ADR-0044 整段重写过），checkout 把它们**一并抹回 HEAD**，
  而 HEAD 版本里根本没有新布局树 → 该文件对整批布局整改变成"文档没跟上"。
  发现时已经丢了，靠事前的保险提交才拿回来。
- **为什么本批特别危险**：INFRA-026~034 全程**未 commit**（传哲要求收口后统一提交），
  所以索引里既有 032 的改名又有 033/034 的在途编辑；此时 `git checkout --` 恢复到的是
  **HEAD 而非"本批开始时的状态"**，中间三批的文档工作全在射程内。同类地雷：`git restore`、
  `git stash`（共享 worktree 里还违反 ADR 约束）、`git reset --hard`。
- 恢复路径（本次实际用的）：
  `git ls-tree 11152db1b51c70a2eedbcfb5fa95f4146bdd064b -- "<file>"` → blob `2a9d12d8`；
  `git show <insurance>:<file> > <file>` → 172 行、两处「原 」标注都在，
  与 HEAD 版 153 行对比只剩 §6 那一整段重写。**判据：恢复后 `grep -c "原 "` = 2、行数 172。**
- 规则：
  1. **长批次开工先建保险提交**（本次是 `11152db1` "pre-032 insurance"）。保险提交不推远端、
     不作为交付，只作为"最坏情况下能回到哪儿"的锚点；收口时用 `git reset` 或 squash 处理。
  2. 修单个文件的局部错误**禁止 `git checkout --`**：改用"从保险提交取回 + 只重放我要改的那几行"，
     或先 `cp <file> /tmp/<file>.bak` 再动手（本次最初就该这么做，代价 30 分钟与一次风险敞口）。
  3. `git diff` 有三个比较对象（worktree/index/HEAD）。在混合暂存状态的批里，任何恢复类命令前
     先跑 `git status --porcelain <file>` + `git diff --cached --stat <file>`，
     看清"索引里是本批工作还是 HEAD"，再决定恢复到哪儿。

## P158：`if cmd; then …; fi` 之后读 `$?` 恒为 0 —— 负向测试会"看起来红、实际绿"（2026-10-16，INFRA-034，verified）

- 现象：`check_ios_compile.sh` 写成 `if "${CMAKE_BIN}" --build …; then echo PASS; exit 0; fi` +
  紧跟一行 `rc=$?`。注入负向探针后打印的是 `FAIL（rc=0）` —— **退出码 0 被当成"编译失败但原因未知"**，
  而真实失败码（cmake 的 2）已经在进入 `fi` 时被 if 语句自身覆盖（bash：`if` 无 `else` 分支时，
  整个语句的退出码是 0，不是条件命令的退出码）。
- 为什么会踩：shell 里两种写法都常见，`if …; then …; fi; rc=$?` 与 `cmd; rc=$?; if [ $rc -ne 0 ]` 看起来等价。
  差别只在**有没有 else**：有 else 时 `$?` 仍是条件命令的码，无 else 时被 if 归零。
- 影响面不止这个脚本：任何"失败分支里要打印/上报退出码"的门禁脚本（`run_gate.sh` 的 `run_step` 用的是
  `if "$@"; then … else local rc=$?`，**有 else 所以是对的**）都可能被后续改动写成无 else 形式。
- 规则：
  1. 需要退出码时**先取码再判**：`cmd; rc=$?` 紧跟，然后 `[ "${rc}" -eq 0 ]` 显式测试；
     或保留 `if …; then …; else rc=$?; …; fi` 形态（else 不能省）。
  2. 负向测试的判据必须包含**具体码值**（`FAIL（rc=2）` 而非只要求非零）；只验"红/不红"的脚本
     自身就可能是恒绿（同 P154：解析器匹配不到 ≠ 规则不存在）。

## P159：非交互 shell **没有 `LANG`** → `bundle exec pod install` 在 Ruby 的 `unicode_normalize` 处崩（2026-10-16，INFRA-034，verified）

- 现象：agent/CI 类非交互环境里 `LANG` 与 `LC_ALL` 都是 unset，CocoaPods 1.17 在
  `Pod::Config#installation_root`（`config.rb:167`）对路径做 `unicode_normalize` 时抛
  `Encoding::CompatibilityError: Unicode Normalization not appropriate for ASCII-8BIT`，
  紧接着自己再崩一次（`ErrorReport.markdown_podfile` 同一路径），日志里只看到 ruby 栈、
  **看不到"编码"两个字** —— 第一反应容易误判成 Podfile 或本地 Pod 路径写错。
  实测两端 `pod install` 各 `rc=1`、日志 61 行全是栈。
- 判据（先花 5 秒排除环境而不是查 Podfile）：`echo "LANG=${LANG:-unset}"`；
  或看 CocoaPods 日志开头那段 `WARNING: CocoaPods requires your terminal to be using UTF-8 encoding`。
- 修复：脚本里显式 `export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8`（本仓双壳 SOP 已按此跑通）。
- 规则：**任何调 CocoaPods/Ruby 工具链的非交互脚本必须自带 locale**，不依赖调用方环境；
  同类地雷还有 `git`（中文文件名，见 P155）与 `xcodebuild`（`-quiet` 下告警语言随 LC 变）。

## P160：**构建期第三方工具只存在于本机暖缓存**，仓库里没有产出它的脚本 → 清 build / 新克隆 / CI 全数编不出内核（2026-10-16～17，INFRA-034 CI 复现，verified）

- 现象（本机实测，不是推测）：按 workflow 顺序复刻 CI 的 core 段并真的清空 `build/`，构建停在
  ```
  [ 27%] SHADER-001: glslang → SPIR-V → spirv-cross → MSL (blit)
  error: shader 工具链不可用（试过：…/build/tools/glslang/StandAlone/glslang）
  make[2]: *** [generated/shaders/blit_msl.h] Error 1
  ```
  随后 `ctest rc=8`、`2% tests passed, 50 tests failed out of 51`，失败原因全是
  `Could not find executable …/build/bin/cq_tests_cxx20_smoke` —— **50 个红是 27% 那一个红的下游噪声**，
  第一眼看成"单测大面积崩"会走错方向。
- 根因：`tools/shaders/build_shaders.py` 在**编译期**硬要两个二进制
  （`build/tools/glslang/StandAlone/glslang`、`build/tools/spirv-cross/spirv-cross`），
  而**仓库里从来没有任何脚本能产出它们**。逐条核过（判据只认入库文件）：
  `tools/deps/deps.py` 只有 validate/lock/check/selfcheck，**没有 build 子命令**；
  `tools/CMakeLists.txt` 是占位；`third_party/CMakeLists.txt` 只处理 ffmpeg；`git log` 搜不到产出脚本。
  本机那套是历史会话手搓的，源码树 `third_party/src/` 与产物 `build/tools/` 又都在 `.gitignore` 里。
- 为什么藏了这么久：17 步门禁从不删 `build/tools/`，所以"编译期第三方工具"这一层**从未进入判据**。
  这正是 P147/P151 那类"暖缓存假绿"的加强版：**只要判据只在暖缓存上跑，缺依赖就等于不存在**。
- 修复（已入库）：`tools/build/build_shader_toolchain.sh` ——
  pin 从 `third_party/manifest.toml` 读（脚本自己不写死 commit，避免同一判据两份真源，红线 #10）；
  源码缺失按 `pin_ref` 浅 fetch 并校验 `HEAD == pin`，本机非 git 树则只做版本级核对并**明打"commit 级不可校验"**；
  产物齐备后 `--version` 自检 + 端到端真转一遍 SHADER-001（复现 `blit_msl.h` = **1689 B**，
  与基线同一判据）。`.github/workflows/ci.yml` 增加装配步，并把它写成第 4 条约束
  （**必须在 `build_core.sh` 之前**：`--clean` 会把刚装好的 `build/tools/` 一起清掉）。
- 规则：
  1. **任何构建期依赖必须有一个入库脚本能从零产出它**；只有"本机能跑"的证据 = 该依赖不存在。
     新增构建期依赖时，交付判据里必须包含"清空产物目录后重跑"，不能只交暖缓存门禁。
  2. 复现 CI 就用真破坏性动作（`rm -rf build` / `--clean`）。增量复现只会复述已知的绿。
  3. 看到"大面积 ctest 红 + 找不到可执行文件"，先回到**构建日志最早的那条 error**，
     不要开始查测试（本次 50 个失败里 0 个是测试自身的问题）。
  4. 同一次干净复现还顺手抓到新脚本自己的第二个"只在暖目录上成立"缺陷：
     日志重定向写到 `build/tools/<name>.configure.log`，而 `rm -rf build` 后该目录不存在，
     于是真实失败被 `No such file or directory` 盖掉（修法：装配前 `mkdir -p build/tools`）。
     **凡"创建目录 + 重定向日志"的脚本都要显式建父目录**，不能假设产物树已经存在。
  5. **大小写陷阱**（同一批干净复现抓到的第三个）：脚本第一版把产物写到 `build/tools/SPIRV-Cross/`
     （跟随源码树的大写目录名），而 `tools/shaders/build_shaders.py:111-113` 的默认路径是全小写
     `build/tools/spirv-cross/spirv-cross` —— **本机不报错**，因为 APFS 默认大小写不敏感。
     换到大小写敏感的卷（Linux runner / 区分大小写的 APFS 宗卷）就是"工具链装好了但脚本说找不到"。
     修法：`build_tool` 的第二个参数显式传产物目录名（`glslang` / `spirv-cross`），不再由源码目录名推导。
     **凡是"两侧各自拼路径"的构建期约定，判据必须在一台大小写敏感机上跑过**，本机绿不算。
- 可复用排障：`tools/build/build_shader_toolchain.sh --check-only`（只验产物在不在、能不能跑，rc 可见）；
  判据 `ls -l build/tools/glslang/StandAlone/glslang build/tools/spirv-cross/spirv-cross`
  （⚠️ 小写，与 `build_shaders.py` 默认路径逐字一致；写大写在 macOS 上"碰巧也能过"，见规则 5）。

## P161：改了 `-D` 重跑仍复现同一 FATAL_ERROR —— **失败的 configure 已经把 CMakeCache 落盘**，旧值锁死新默认（2026-10-17，INFRA-034 P160 修复过程，verified）

- 现象：第一版 `build_shader_toolchain.sh` 给 SPIRV-Cross 传了 `-DSPIRV_CROSS_ENABLE_GLSL=OFF`，
  configure 死在 `CMake Error at CMakeLists.txt:305: Must enable GLSL support to enable MSL support.`。
  把 flag 删对之后重跑，**打印同一条 305 行错误**，看起来"我的修改没生效"。
  真因：`build/tools/SPIRV-Cross/CMakeCache.txt` 里留着 `SPIRV_CROSS_ENABLE_GLSL:BOOL=OFF` ——
  `option()` 只在 cache 缺该键时取默认值，已有 cache 值优先，重跑不会覆盖。
- 修复（脚本已含）：产物缺失即视为"上次没成功"，重配前先 `rm -rf build/tools/<name>/`，
  另给 `--rebuild` 强制清；两步都在日志里明打，避免"静默重编"和"静默复用"两种误读。
- 规则：
  1. 幂等的装配/构建脚本必须自带**残骸清理判据**（"产物不存在 ⇒ 缓存不可信"），
     否则它的失败模式是"改对了也红"，把后续排查引到源码上去。
  2. 诊断顺序：改 flag 重跑复现同一条 CMake 错误时，先 `grep <OPTION> <build目录>/CMakeCache.txt`，
     再看 `CMakeLists.txt`。
- 顺带记两条外部事实，省得重踩：
  - `spirv-cross` 的 **CLI** 在 `CMakeLists.txt:429-456` 硬要求 GLSL/HLSL/MSL/CPP/REFLECT/UTIL/STATIC
    **全开**（关任一个直接 FATAL_ERROR）；想"只留 MSL 瘦身"不可能，能省的只有 `ENABLE_TESTS` 与 install 规则。
  - `spirv-cross` **没有** `--version`（未知参数打 usage 并 rc=1，会把 `set -e` 的脚本打断），
    `--help` 首行才是版本横幅；且非 git 源码树里它的 CMake 会**向上**找到宿主仓库 `.git`，
    把 ChuanqiCut 的 HEAD 打进自己横幅（实测 `Git commit: v0.1.0-244-g5cfcdcb+`）——
    二进制自报版本**不可作为 pin 证据**，判据只能用 manifest + 端到端产物字节数。

## P162：自称"只读校验"的模式里混着 `rm -rf`，而且幂等守卫的 cache 键 grep **恒不命中** → `--check-only` 把判据现场删了（2026-10-17，INFRA-034 负向测试，verified）

- 现象（跑 P160 的排障配方时撞上，不是推测）：`tools/build/build_shader_toolchain.sh --check-only`
  在**只验产物在不在**的模式下打出 `本地补丁指纹 … 与缓存不符 → 强制重编`，随后
  `rm -rf build/tools/spirv-cross/` —— 我为了做负向测试临时挪到同目录的备份探针一起被删，
  探针与被探针的东西同归于尽，只能重编 ~90s 才恢复。
- 更根本的第二层：那条"补丁变了自动强制重编"的守卫**从未正确生效过一次**。
  cache 里实际落的行是 `SPVC_PATCH_FP:UNINITIALIZED=1794616739117`（未走 `option()` /
  `set(... CACHE)` 的裸 `-D` 一律落成 `UNINITIALIZED`），而脚本 grep 的是 `SPVC_PATCH_FP:STRING=`
  → **恒不命中** → 只要 `CMakeCache.txt` 存在就每遍误判"补丁变了"，暖跑每次都白删白重编（实测每遍多 ~65s）。
  脚本自称幂等，实际是"一遍一删"。
- 规则（三条可复用）：
  1. **凡是"只读 / 只校验 / dry-run"模式，代码路径里不能出现任何删除**，且必须在**函数入口**短路，
     不是每个副作用点各判一次 —— 逐点判漏一个就是本次这个下场。`build_tool()` 的删除分支原本写在
     `CHECK_ONLY` 早退**之前**，所以 `--check-only` + 指纹不符 的组合恰好走到删除。
  2. **grep CMake cache 键时把类型段当可选**：`grep -qE "^KEY(:[A-Z]+)?=<value>$"`。
     `-D` 落进 cache 的类型后缀取决于该键有没有被 `option()`/`set(CACHE)` 声明过，
     照"看着合理"的 `:STRING=` 写 = 一条永远不会为真的判据（与 P158 的"恒 0"同类：**判据静默失效**）。
  3. **负向测试的探针别放在被测对象有权删除的目录里**，先 `cp/mv` 到 `/tmp` 再在原位破坏；
     并且每次破坏前记下 md5，恢复后逐字节比对 —— 本次靠 md5 才确认"没丢东西"。
- 修复与取证（本机 09:3x~09:4x）：删除分支与 `FORCE_NEXT` 置位两处都加 `[ "$CHECK_ONLY" -eq 0 ]`，
  grep 改 `^SPVC_PATCH_FP(:[A-Z]+)?=`。
  - 暖态 `--check-only`：两产物均 `OK`、`spirv-cross` md5 与跑前一致（**不再删**）；
  - 暖态完整跑：`[glslang] 产物已存在，跳过编译` + `[SPIRV-Cross] 产物已存在，跳过编译`，
    **"强制重编"一行不再出现** → 幂等成立（修之前每次暖跑都会删）；
  - 负向：挪走 `build/tools/glslang/StandAlone/glslang` → `--check-only` rc=**1** 且报 `产物缺失`；
    恢复后 md5 一致；正向 rc=**0**。
- ⚠️ **判据版本说明**（别把这段当成"三遍绿作废"）：干净复现 run1~run3 跑的是修复前的脚本，
  但本次改动只碰"删除 / 强制重编"两个分支，**从 `rm -rf build` 起手的复现里这两个分支根本不会触发**
  （没有 `CMakeCache.txt` 可比）→ 三遍绿结论不受影响。交付版脚本的"连续 2 次绿"另由 run3 + run4 取证。
- **已升为 ADR-0045**（2026-10-17）：P160 的铁律 + 本条的四项幂等硬规则 + "引用门禁绿必须同时说明缓存状态"
  的口径，一起写成 `docs/decisions/ADR-0045-构建期依赖必须入库产出与门禁缓存状态口径.md`。
  没写进 `AGENTS.md` 红线（真源是热点文件，本批已因红线 #6 动过一次），边界见该 ADR 末节。

## P163：**判据脚本自己未跟踪时不进自己的射程，一 commit 就把自己判红** —— 搬家批的旧路径判据命中了自己的正则定义行（2026-10-17，INFRA-034 提交后复测，verified）

- 现象：三段提交完成、工作区 `0` 之后复跑 `tools/ci/check_repo_hygiene.sh` → **3/4 PASS（FAIL 1 项）**：
  `[legacy-paths] 活文档残留旧路径 2 行`，两行都落在 `tools/ci/check_repo_hygiene.sh:124-125` ——
  也就是 PAT 自己的定义行 `r"apps/apple/packages|engine/bindings|…|shaders/src"`。
  提交前同一命令是 **4/4 PASS**（10:2x 实测），**工作区一个字节都没变**。
- 根因（两层，缺一层都不会现形）：
  1. 该判据的扫描集是 `git ls-files`（P153/P155 立的"只认入库文件"口径），而脚本本身当时是 `??`
     未跟踪 → **判据脚本长期不在自己的扫描集里**，它的旧路径字面量从不被检查；
  2. 唯一的豁免通道是 `MARKER`（`原 |已迁|→|旧|历史`…）按**行内容**放行，而正则定义行是代码、
     不可能带迁移标记 → 提交把它放进扫描集的那一刻，判据自己红。
- 规则（新增判据脚本时同 P160"空产物根"检验并列的一条自证）：
  1. **新判据必须在"自己已被跟踪"的状态下至少跑一遍**（`git add` 之后复跑，别只在未跟踪态里自证）；
     未跟踪态的绿是**半个证据**，覆盖不了脚本自身。
  2. 判据扫描集若来自 `git ls-files`，就要显式决定**自己参不参与**：不参与 → 写 `SELF` 排除并注释原因；
     参与 → 把会被自己命中的字面量拆成不可匹配的写法。两种都行，**没有一种是"默认"的**。
  3. 这类"提交后才现形"的红，**不要用工作区复跑来代替提交后复跑**收尾；提交动作本身就是判据的输入变量。
- 修复与取证（本机 10:34）：`legacy` 段加 `SELF = "tools/ci/check_repo_hygiene.sh"` 并在循环里
  `if f == SELF or f.startswith(EXEMPT): continue`（注释写明"自己的 PAT 定义行盖不住 MARKER"）。
  `bash -n` OK → 复跑 **4/4 PASS**，`[legacy-paths] 零残留（迁移标记豁免 33 行）`，
  `[tracked-artifacts] tracked **878** 个文件，无构建产物`（提交前 856 + 本批新入库 22 = 878）。

## P164：`cd` 之后才生效的相对路径把 1.5G derivedData 写进源码树 —— **「产物只落仓库根 build/」第三次失守**（2026-10-17，INFRA-037 双壳测量趟，verified）

- 现象：新写的 `tools/ci/check_apple_shells.sh` 里 `-derivedDataPath "../../build/gate-logs/dd-ios"`，
  意图是仓库根 `build/`；实测在 `apps/` 下长出 **1.5G** 的 `apps/build/`（`?? apps/build/`，
  内含 `gate-logs/dd-ios`、`dd-mac`）。传哲当场指出「怎么又在代码文件夹里搞 build」。
- 根因（一句话）：**重定向目标的语义由写入那一刻的 cwd 决定**。脚本是
  `( cd "apps/apple/ios" && xcodebuild … -derivedDataPath "../../build/…" )`，
  子 shell 里 `../..` 从 `apps/apple/ios` 退两级 = `apps/`，不是仓库根。
  脚本头部 `cd "$ROOT_DIR"` 只管父 shell，**管不到子 shell 的参数**。
- 这是同一个坑的第三次（案底链）：
  1. `apps/` 曾堆到 5.5G（清理后 4.3M）；
  2. SPM 靠 `--scratch-path` 钉回 `build/spm/<包>` 才收住（P84/P152）；
  3. 本次 xcodebuild derivedData。**共同点**：都是"脚本里写了个相对路径给外部工具当输出根"。
- 规则：
  1. **交给外部工具当输出根的参数一律绝对**，写法固定 `"${ROOT_DIR}/…"`；
     凡是 `cd` 进子目录再传相对路径的，默认按 bug 处理。
  2. 光加注释拦不住下一次，所以补**三层机械防护**：
     脚本内路径前缀断言（`case "$dd" in "${ROOT_DIR}"/build/*) ;; *) 判红 ;; esac`）、
     跑完自查 `find apps ui api engine -maxdepth 4 -type d \( -name build -o -name .build -o -name DerivedData \)`、
     `check_repo_hygiene.sh` 新增判据 5 `scratch-dirs`。
  3. **反证要用未被忽略的文件**：判据 5 扫的是 `git status --porcelain -z` 的 `??` 记录，
     空目录、或里面全是已忽略文件（如 `*.o`）时 git 不报 —— 第一次反证用 `x.o` 得到"绿"，
     那是**假绿**；换成 `x.txt` 才判红。恒不命中的反证比没有反证更危险（接 P162）。
  4. **不要给 `apps/build/` 加 .gitignore**：忽略它等于让它从 `git status` 里消失，
     而"能被看见"正是这条判据的原料。宁红不隐。

## P165：**拿长表格行的「行首」当编辑锚点，会把该行的尾巴嫁接到新行后面**（2026-10-17，TASK-BACKLOG 落账自查，verified）

- 现象：往 `docs/tasks/TASK-BACKLOG.md` 的 INFRA 表里插两行时，`old_string` 只取了
  `| INFRA-035 | … 无新增死链 |`（该行**前缀**），`new_string` 写成「两行新表项」。替换成功后
  035 的**结果单元格**（`✅ 2026-10-16（5 / 22 / 27 …） |`）被留在最后一行新表项的尾部，
  035 整行消失 —— 表看起来是 4 行，实际只有 3 行有结果、1 行结果串错位。
- 根因：本仓的 backlog/模块册**一行就是 1~2KB**（含全部实测数字），Edit 是**精确子串替换**，
  不是"按行替换"。锚点只覆盖行首 = 只删掉行首，剩下的部分原样跟在替换文本之后。
- 规则：
  1. 改长表格行要么锚点**覆盖整行**（到行尾 `|` 为止），要么锚点选**行与行之间的边界**
     （`\n| 下一行行首`），别在行中间下刀。
  2. 落账后**必须回读一次行号表**（`grep -n "^| INFRA-0"`）：行数与顺序对不上就是被嫁接过。
  3. 复原口径 = `git show HEAD:<file> | grep "^| <ID> " > /tmp/a` 与工作区同法产物 `cmp` 逐字节比，
     比"看着像"可靠（本次 681B / 681B 一致）。

## P166：把"结构性推断"当成本机实测口径念出去 —— 全量门禁 66% 的成本其实在**单线程编译**（2026-10-17，INFRA-037 收口趟实测，verified）

**场景**：传哲问「目前的门禁都有哪些内容，为啥比较耗时」。我按步数和切片数推断，
回答里写「`apple-xcframework` 三切片是最贵的一组」「内核两趟次之」。
然后同一趟门禁跑完，用日志 mtime 反推出每步真实时长：

| 步 | 秒 |
|---|---|
| core-dbg | **379.0** |
| core-rel | **438.4** |
| Apple/Swift 六包合计 | 305.3 |
| apple-xcframework | **17.3**（暖） |
| apple-shells | 44.5（暖） |
| 其余 9 个静态/窄检步 | 各 ≤ 5.6 |

推断的那句被实测**直接推翻**：xcframework 在暖缓存下只占 17.3s，
`core-dbg + core-rel` 两步就占全程 **817s / 66%**。

**根因（这才是可优化项）**：`tools/build/build_core.sh:85` 与
`tools/build/build_core_apple.sh:178` 调 `cmake --build` 时**都没传 `--parallel`**，
生成器是 `Unix Makefiles` → 12 逻辑核的机器**全程单线程编 C++**。
全仓只有 `build_shader_toolchain.sh` 传了 `-j$(hw.ncpu)`。

- 规则：
  1. 回答"为什么慢/慢在哪"只能给**同趟实测**的分布，不给结构推断；结构推断必须显式标 `hypothesis`。
  2. 已经说出口的错误结论要在**同一轮**里按实测更正并写明"以前那句作废"，不要悄悄改掉
     （`baselines.md` 的「18 步全量门禁实测」节就是这么落的）。
  3. 门禁时长口径必须带**缓存状态**：`ios-compile` 2.5s 与 `apple-xcframework` 17.3s 是暖态，
     拿它们当"这步便宜"是错的（P160 同族）。
  4. 观测缺口顺手记下：`run_gate.sh` **不记每步时长**，只能靠日志 mtime 反推。
     要做成本优化就得先把时长记进摘要，否则每轮都在猜。

## P167：**"暖缓存 = 该步 no-op" 是猜的** —— 同一版本脚本、同一棵树，暖趟仍重编 57 个 TU（2026-10-17，INFRA-038 落地趟，**未完全定位**）

**场景**：给三个 `cmake --build` 调用点补 `--parallel` 后逐个量时长。
`build_core_apple.sh --config=Release` 的"暖"值我按上一趟门禁摘要里的 **17.3s** 念了出来，
本趟同机同树实测 = **91s**。差 5 倍，且**不是**并行与否造成的。

**取证到的部分**：`grep -c 'Building CXX\|Building C '` ——
暖趟 **57** 个 TU 重编，冷趟（`rm -rf build/apple`）150 个 TU。所以 91s 那一趟根本不是 no-op，
是"小半棵重建"。17.3s 那一趟才是接近 no-op 的状态。

**两条候选成因（都还没取证，禁止当结论引用）**：
1. `check_ios_compile.sh` 与 `build_core_apple.sh` **共用 `build/apple/ios-device`**，
   但前者不重跑 configure、后者每次都重跑并带 `-DCQ_ENABLE_LTO_RELEASE=` 等参数 ——
   若两次 configure 的 flag 串不一致，整片 TU 会因编译命令变化而全部重编；
2. 每切片都重跑 `cmake configure` 本身会刷新若干 generated 头的时间戳。

- 规则：
  1. **"暖"不是一个数，是一个状态**。引用暖值必须同时给「这一趟重编了多少个 TU」
     （`grep -c 'Building CXX'`），否则"暖"字掩盖了两种完全不同的成本。
  2. 跨趟比较时长前先问：**前一步动过同一棵树没有**。本趟我在 `build_core_apple.sh` 之前
     手动跑了 `check_ios_compile.sh`（同一目录的两个消费者），串行基线那趟两者是门禁内先后跑的，
     顺序相同但**前置状态不同**。
  3. 成因未定位就写"未完全定位"，并把标题里的数字写成事实、把解释写成候选 ——
     这是 P166 的同一条纪律，只是这次栽在"暖"这个我以为已经理解词上。

## P168：后台任务通知"completed exit 0"，实际任务**只跑到 88%**、输出文件是空的（2026-10-17，INFRA-038 计时趟，verified）

**场景**：用 `run_in_background` 跑 Debug/Release 两轮计时构建。系统推来
`<status>completed</status> <summary>exit code 0</summary>`，我按通知去读输出文件 → **空**；
读构建日志 → 停在 `[ 88%] Building CXX …`；`ps` → `build_core.sh` 还在跑（已 48s）。

**后果（这才是要紧的）**：如果把"通知=完成"当真，会用**半截日志**去写基线数字。
而半截日志的尾部恰好是若干 `Building CXX` 行、没有任何 `tests passed`，
最容易写成的数字就是"没通过数、只有墙钟"的假数。

- 规则：
  1. 后台任务的**完成通知不是验收口径**，与远端 CI 绿同一档（ADR-0030 的"远端不可信"扩到本机 harness）。
     取数字的三件套：**日志里有结束行**（`tests passed` / `done.` / `BUILD SUCCEEDED`）＋
     **`ps` 里进程已消失** ＋ **自己写在日志末尾的计时行**（本趟用
     `echo "PAR-CORE $cfg rc=$rc wall=…" >> 日志`，有这行才算跑完）。
  2. 需要连续拿多个数字时，优先**前台阻塞 + 有界超时**；确实要后台就在等待端用
     `while pgrep -f <特征> >/dev/null; do sleep 5; done` 主动收敛，而不是等通知。
