# TASK-INFRA-002：内核 CMake 构建 + CTest（桌面）

```yaml
id:          INFRA-002
layer:       基建
goal:        让 C++20 内核能在 macOS 上编译、能跑单元测试，并接入 -Werror
input:       [INFRA-001 目录骨架, ARCH-001 §8 构建策略]
output:      [core/CMakeLists.txt(完整), tests/ CMake 接入, tools/build/build_core.sh, CI 本地等价脚本]
write_set:   core/CMakeLists.txt, tests/CMakeLists.txt, tools/build/build_core.sh, cmake/*.cmake
read_set:    docs/specs/ARCH-001-技术方案总纲.md, .ai/modules/core.md
deps:        [INFRA-001]
acceptance:
  - `tools/build/build_core.sh --platform=apple` 在 macOS 上零警告通过（已开 -Werror）
  - `ctest --test-dir build` 能跑通至少一个占位用例，退出码 0
  - 编译标准锁定 C++20，编译选项在 cmake/ 中集中定义，不在各模块里散写
  - 提供 Debug / Release 两套配置，Release 开 LTO
verification:
  - tools/build/build_core.sh --platform=apple
  - ctest --test-dir build --output-on-failure
risk:        -Werror + LTO 组合会让后续任务在"编译不过"上反复卡顿。
             缓解：本任务先把警告清单固定下来（显式列出启用的 warning 集合），
             后续不允许随手关警告，只能改代码。
parallel:    false          # 高冲突：几乎所有任务依赖它
```

## 背景

没有"能编译 + 能跑测试"这条基线，后面每个任务交付的都是**看起来对但没验证过**的代码。所以这个任务必须在任何内核逻辑之前完成。

## 实现要点

- C++20 硬锁定：`set(CMAKE_CXX_STANDARD 20)` + `CXX_STANDARD_REQUIRED ON` + `CXX_EXTENSIONS OFF`（禁 GNU 扩展）。
- warning 集合显式列在 `cmake/Warnings.cmake`，开启 `-Wall -Wextra -Wconversion -Wshadow -Wold-style-cast` 等，Release 加 `-flto`。
- 测试框架选型：优先 **Catch2 v3** 或 **doctest**（header-only 优先，减少依赖治理负担）。**选定后必须登记进 `third_party/manifest.toml`**（依赖 DEPS-001；若 DEPS-001 未完成，先用 FetchContent 并在 manifest 中标记待补登记）。
- `tools/build/build_core.sh` 是**唯一的本地构建入口**，CI 复用同一脚本，禁止 CI 里另写一套编译命令。
- Apple 通用二进制/多平台切片由 INFRA-003 处理，本任务只保证 macOS 桌面构建。

## 验收

逐条对应 acceptance，附命令与完整输出。

## 回写

- 构建命令、测试命令 → `.ai/modules/core.md`
- 若 warning 集合选型上有取舍 → 记录进 `.ai/memory/pitfalls.md`
- 测试框架及其版本、许可 → `third_party/manifest.toml`
