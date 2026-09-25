# 模块：core/base 内核基础

**边界**：`core/src/base/`、`core/include/cq/base/`、`core/include/cq/pal/`、`core/src/session/`

## 职责
时间、状态、日志、内存、并发、PAL 接口定义、EditorSession 门面。

## 入口
- `RationalTime` — **有理数时间**，禁止浮点秒。项目 timescale = 60000。
- `Status` — 跨端一致错误码。
- `Arena` / 内存池 — 支持纹理与帧缓冲预算记账。
- `CancelToken` — 长任务取消。
- `ICapabilities` / `cq_query_capability()` — **运行时能力查询**。
- `EditorSession` — 对外唯一门面，产出不可变快照 + 版本号。

## 依赖
无（本模块是最底层，不得反向依赖任何其他模块）

## 硬约束
1. PAL 头文件零平台类型 → 跨层用 opaque 句柄 `CQNativeImageHandle` 等。
2. 能力查询不得用编译期宏推断（Android 能力由机型决定，Apple 由芯片决定）。
3. 音频线程无锁、无分配；主线程零阻塞。
4. `RationalTime` 运算做 timescale 归一化并检测溢出。

## 验证
```bash
ctest -R core_base
# 关键用例：29.97fps 累计 10000 次帧步进零漂移
```

## 构建与单测入口（INFRA-002 建立）

> 本地与 CI 唯一入口：`tools/build/build_core.sh`。cmake 不在 PATH，脚本内默认回退到
> 绝对路径，可用 `CMAKE_BIN` 环境变量覆盖；ctest 同目录，可用 `CTEST_BIN` 覆盖。

```bash
# 桌面（macOS）Debug 构建 + 单测（默认 cmake 绝对路径，零警告 -Werror）
tools/build/build_core.sh --platform=apple --config=Debug --test

# Release 构建（开 LTO/IPO）
tools/build/build_core.sh --platform=apple --config=Release

# 等价手写命令（若 PATH 无 cmake）：
CMAKE_BIN=/Users/zhuning/.workbuddy/binaries/cmake/CMake.app/Contents/bin/cmake
$CMAKE_BIN -S . -B build -DCMAKE_BUILD_TYPE=Debug
$CMAKE_BIN --build build
$(dirname $CMAKE_BIN)/ctest --test-dir build --output-on-failure
```

- C++20 硬锁：`cmake/CompileOptions.cmake` 的 `cq_require_cxx20(target)`（CXX_STANDARD 20 / REQUIRED / EXTENSIONS OFF）。
- 警告集合：`cmake/Warnings.cmake` 的 `apply_cq_warnings(target)`，显式 `-Wall -Wextra -Wconversion -Wshadow -Wold-style-cast` + `-Werror`（Debug/Release 都开）。
  红线：**禁止随手 `-Wno-*` 逃逸，只能改代码**（见文件内注释；特例需 ADR 记录）。

## 相关
ADR-0006（有理数时间与版本模型）、ARCH-001 §5/§6

## 实际目录（INFRA-001 + INFRA-002 建立）

> 由 `TASK-INFRA-001` 落盘的骨架路径，供后续 CORE 任务对齐存放位置（权威树以 ARCH-001 §8 为准）。

- `core/CMakeLists.txt` — 内核 CMake 入口；`cq_core` 现为**真正的 STATIC 库**（含 `src/cq_build_anchor.cpp` 构建锚点，非业务逻辑）
- `core/include/cq/cq_sdk.h` — 对外 C ABI 伞形头（占位；红线 #7：仅 C 类型 + opaque 句柄）
- `core/src/cq_build_anchor.cpp` — 构建锚点 TU（INFRA-002 新增，可链接、零业务逻辑、证明 -Werror 下可编译）
- `core/src/` — 内核源码根，按模块分子目录：`base/ model/ gfx/ render/ media/ audio/ ai/ project/ export/ session/`（尚未创建，由对应 CORE 任务建）
- `core/tests/` — 内核单测（实际落在 `tests/unit/`，见下）
- `core/include/cq/<module>/` — 内部 C++ 头（预留，未在骨架阶段创建）

## 单测目录（INFRA-002 建立）

- `tests/CMakeLists.txt` — 启用 CTest，注册内核单测（顶层 `CMakeLists.txt` 已 `enable_testing()`）
- `tests/unit/cxx20_smoke.cpp` — 占位 smoke 用例：`static_assert(__cplusplus >= 202002L)`，证明 C++20 生效；链接 `cq_core`
- 运行：`ctest --test-dir build`（或 `build_core.sh --test`）

> 注：骨架阶段仅建占位，未创建 `core/src/<module>` 子目录与真实头文件，避免越界到 CORE 系列任务的写集。
