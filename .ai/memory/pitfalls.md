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
    （实测：传了 OFF，`CMakeCache.txt` 里仍是 `ON`，`.o` 还是 bitcode，且产物字节数与之前完全一致）。
    凡遇到 `FORCE` 的 cache 变量，必须走项目自己的 option 开关。
  - 合并前加预检断言（`otool -l | grep 'is an LLVM bit-code file'`），把隐晦报错提前拦成明确根因。
- 副作用提醒：分发的静态库带 LTO bitcode 会强制消费者 linker 版本匹配，属分发陷阱，
  即使将来 `xcodebuild` 支持了也不建议在分发产物上开 LTO。
- 日期 / 来源 / 验证状态：2026-09-29 / HANDOFF-002 遗留问题 / **verified**（三切片 `.o` 头已从
  `dec0170b` 变为 `cffaedfe`，`file` 报 `Mach-O 64-bit object arm64`，xcframework 三个切片生成成功）

### P2 · 冻结接口只有头文件、实现缺失，编译期 `static_assert` 会把它掩盖成"全绿"
- 现象：`core/include/cq/pal/capabilities.h` 冻结的 `SetCapabilitiesBackend` /
  `QueryCapability` **长期只有声明、没有定义**。CTest 一直 22/22 全绿。
- 根因：全仓库唯一引用是 `tests/unit/pal_headers_compile.cpp` 里的 `static_assert`
  （校验返回类型）。**`static_assert` 是编译期检查、不链接** —— 只要声明对就能过，
  实现存不存在它管不着。
- 影响范围：任何「接口冻结」类任务都可能这样静默断掉。这是 CORE-006 当时
  「编译验证 7/7 全绿但接口是断的」的**同型复发**，只是触发机制换成了 static_assert。
- 排障步骤：对可疑符号 `grep -rn <符号>`，若**只出现在头文件与 static_assert 里**、
  没有任何 `.cpp/.mm` 定义，即为断接口。
- 修复：CORE-007 补上实现（`core/src/pal/capabilities.cpp` + `pal/apple/capabilities.mm`）。
- 防复发规则：**冻结接口后必须补一个「链接并运行」的最小用例**，
  `static_assert` / 头文件编译验证**不能**作为"接口可用"的证据。
  本轮已落的样例：`tests/unit/test_capabilities.cpp`（注入后端后真查询）。
- 日期 / 来源 / 验证状态：2026-09-29 / CORE-007 / **verified**（24/24，其中 2 个新用例
  链接并运行了这两个函数；Apple 后端查询结果与本机已知硬件事实交叉吻合）

### P3 · 静态门禁硬编码「要扫哪些目录」，新增目录会被静默漏掉
- 现象：`tools/pal/check_pal_headers.py` 原先写死 `scan_dirs = [cq/"pal", cq/"gfx", cq/"media"]`。
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
- 现象：BIND-001 新增 `tests/unit/test_c_abi.c`（用于机器校验 cq_sdk.h 是纯 C），
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
  目录改名 = 破坏性变更，须全仓同步（apps/apple/packages/SharedUI）。
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
- 现象：`SystemFrameProvider(PalPtr<IMediaDemuxer>, IFrameDecoder*)` 明确
  **不接管** decoder。单测里 decoder 是栈对象没问题；但 PAL 装配时
  `VideoToolboxDecoder` 是 `new` 出来的，装配方必须自己想办法让它与 provider
  同生命周期——很容易漏，且漏了不一定立刻崩。
- 修复：给 `SystemFrameProvider` 加 `AdoptDecoder(unique_ptr<IFrameDecoder>)`，
  并给 `CreateSystemFrameProvider` 加一个接管所有权的重载；PAL 装配走重载版本。
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

### P17 · core 要调 PAL 工厂时，**必须隔离在独立 TU**（否则污染所有下游链接）
- 现象：BIND-003 子步骤 5 要做预览的 C ABI，装配需要平台能力（图形设备 /
  blit pass / 帧提供器）。但既有惯例是 **core 从不调 PAL 工厂**（全库 grep：
  调用只发生在 tests/ 与 pal/），因为 cq_core 若引用 PAL 符号，没有 PAL 后端的
  平台（当前 Android / ohos）就会链接失败。
- 解法：① 需要平台能力的实现**单独成 TU**（`pal_frame_provider.cpp` /
  `cq_sdk_preview.cpp`）；② 静态库按 **archive member 粒度**拉符号，
  只有真正引用了该 TU 符号的目标才会把它链进来 —— 隔离成立。
- 实证：`cq_tests_c_abi` 只链 `cq_core`、**不链** `cq_pal_apple`，
  仍链接通过并运行成功。若把预览代码并进 `cq_sdk.cpp`，该测试会立刻链接失败。
- 防复发规则：新增「core 调 PAL 工厂」的代码前，先确认它在**专属 TU** 里，
  并留一个不链 PAL 的目标做回归验证。
- 日期 / 来源 / 验证状态：2026-10-02 / BIND-003 子步骤 5 / **verified**

### P18 · 「必然由平台原生实现」的抽象，定义层要放对（放错会被依赖方向反噬）
- 现象：`IBlitPass` 初版定义在 `core/include/cq/gfx/`（GFX 层），实现在
  pal/apple。可它由**平台原生 shader**（MSL）实现，按红线 #6 只能落在
  pal/<platform>/；而 PAL 不能反向 include GFX 头 —— 依赖方向直接冲突。
- 修复：`IBlitPass` + `CreateBlitPass` 移到 **`pal/gfx.h`**；GFX 侧需要把
  PAL 编码器传给 PAL 层 pass，故给 `IGfxEncoder` 补 `PalEncoder()` 逃生口
  （与既有的 `IGfxDevice::PalDevice()` 同一套路）。
- 防复发规则：判断抽象该放哪层，看**实现必然落在哪**。若实现只能用平台原生
  能力（shader 源码 / 平台 SDK），抽象就该在 PAL；放上层会导致反向依赖。
- 日期 / 来源 / 验证状态：2026-10-02 / BIND-003 子步骤 5 / **verified**
  （`preview_renderer` 35 项 + `c_abi_preview` 32 项全绿）

### P19 · PAL `CreateFrameProvider` 悬空 7 天（第 5 次「只有声明无实现」）
- 现象：`pal/media.h:231` 的 `CreateFrameProvider` 自 CORE-006（2026-09-25）
  起只有声明，从未实现。上一轮我已把它标为风险但未处理。
- 同类问题已发生 5 次：`cq_build_anchor` / 能力查询实现 / BIND-001 实现 /
  `test_media_decode_apple.cpp`（在磁盘但没接入 CMake）/ 本次。
- 修复：BIND-003 子步骤 5 落地（pal/apple/frame_provider_apple.mm，
  内部用 MEDIA-020 SystemFrameProvider + PALA-011 VideoToolboxDecoder）。
- 防复发规则：**看到「只有声明」的工厂，要么实现、要么删掉**，不要留着。
  留着的下场是某天有人按声明去调，撞链接错误才被发现。
- 日期 / 来源 / 验证状态：2026-10-02 / BIND-003 子步骤 5 / **verified**

### P20 · C ABI 承诺「reinterpret 为 id<MTLTexture>」，PAL 却返回 CqTexture* 包装 —— 首个真实消费方即崩
- 现象：UIA-003 Swift 侧首次把 `cq_preview_render_frame` 的 out_texture
  reinterpret 成 MTLTexture，`objc_msgSend` 打在 C++ 对象（`CqTexture`）上，
  段错误。绑定层测试只断言句柄非空，**没有消费句柄**，所以是绿的。
- 根因：`CqRenderTarget::GetColorTexture()` 惰性创建 `CqTexture*` 包装返回，
  而 `cq_sdk.h` / `preview_renderer.h` 的契约写明「中性句柄，UI 侧 reinterpret
  为 MTLTexture」。**契约与实现不符**，且没有任何跨层测试消费过这个句柄。
- 修复：Apple 实现改为返回 `(__bridge TextureHandle)color_tex_`（裸
  MTLTexture），删除包装；`pal/gfx.h` 把「导出给 UI 显示」与「可送
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
  传递拉入 PAL 媒体/图形 TU → 需要 VideoToolbox / CoreMedia / Metal /
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
  参考实现：`tests/unit/test_c_abi_edit.c::DrainAfter(s,k)`、
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
| E8 | 「CVPixelBuffer(32BGRA) → `MTLPixelFormatBGRA8Unorm` 纹理，采样后需手动把 R/B 交换成 RGBA」 | **错误**。`BGRA8Unorm` 在 Metal 中是「按 BGRA 字节序存储、但逻辑通道仍是 .r=红/.b=蓝」的格式；采样返回的已经是逻辑 RGBA，无需交换。错误地写成 `float4(c.b,c.g,c.r,c.a)` 会让 R/B 反掉——绿条等 R==B 区域看不出，但彩条其余通道会暴露（PALA-002 初版即被底部采样检查抓出）。PALA-011 解码输出为 32BGRA，importer 必须用 BGRA8Unorm 才能直接复用其 IOSurface，且着色器直接 `return c` | 2026-09-26 / PALA-002 / verified |
| E10 | HANDOFF-003 §1 把「BIND-003 子步骤 3 纹理导入（零拷贝）」标为**下一步** | **已做过**：PALA-002（2026-09-26，commit 76fce6b）已完成零拷贝导入，`pala_native_image` 用例含 IOSurface ID 一致性（源 193==纹理 193）、零拷贝/CPU 退化耗时代差（0.0033ms vs 4.5788ms ≈ 1407×）、真实解码帧渲染读回。**交接文档的任务状态要对着 commit 历史核，不能照抄上一版** | 2026-10-02 / BIND-003 / verified |
| E9 | 「XCFramework 合并失败是 bitcode 段导致，加 `-fno-embed-bitcode` 可解」（HANDOFF-002 §3 的遗留推测） | **根因判错**：是 Release **LTO/IPO** 产出 bitcode-only `.o`，与 ENABLE_BITCODE 无关；`-fno-embed-bitcode` 该 clang 不识别且方向错误。教训：`0xb17c0de` 这个 magic 既可能来自 embed-bitcode 也可能来自 `-flto`，**必须抽 `.o` 看实际内容再定论**，不能靠 magic 字面猜。另：那次尝试的脏 flag 残留在 `build/apple/ios-device/CMakeCache.txt` 里未被发现，CMake 会持续复用——**CMakeCache 是隐式状态，撤销改动时不要只撤销源码** | 2026-09-29 / PALA XCFramework 打包 / verified |

### P42 · 开发机换到 macOS 13.7 / Xcode 15.2（AppleClang 15）后既有代码编译失败
- 现象：同一仓库在原机（macOS 15.4 / AppleClang 17，见各 baselines 条目）全绿，
  本机（macOS 13.7 / Xcode 15.2 / AppleClang 15，`xcodebuild -version` 确认）连
  既有 core 都编不过：① `core/src/base/log.cpp` 的 `std::va_list` 在旧 libc++
  不存在；② `tests/unit/test_perf.cpp` 的 volatile 复合赋值触发
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
- 处理：PAL 内 `#if TARGET_OS_IPHONE` 吸收平台差异，macOS 分支如实返回 kNo。
  core 头仍零平台分支（红线 #3 不受影响——运行时查询的是能力**结果**，
  PAL 内部怎么拿到结果是 PAL 的实现自由）。
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