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
