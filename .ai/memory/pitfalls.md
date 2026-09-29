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
| E9 | 「XCFramework 合并失败是 bitcode 段导致，加 `-fno-embed-bitcode` 可解」（HANDOFF-002 §3 的遗留推测） | **根因判错**：是 Release **LTO/IPO** 产出 bitcode-only `.o`，与 ENABLE_BITCODE 无关；`-fno-embed-bitcode` 该 clang 不识别且方向错误。教训：`0xb17c0de` 这个 magic 既可能来自 embed-bitcode 也可能来自 `-flto`，**必须抽 `.o` 看实际内容再定论**，不能靠 magic 字面猜。另：那次尝试的脏 flag 残留在 `build/apple/ios-device/CMakeCache.txt` 里未被发现，CMake 会持续复用——**CMakeCache 是隐式状态，撤销改动时不要只撤销源码** | 2026-09-29 / PALA XCFramework 打包 / verified |
