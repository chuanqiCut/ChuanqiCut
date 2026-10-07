# ChuanqiCut — 顶层 CMake 入口（INFRA-001 骨架）
#
# 本文件只做骨架聚合：声明 C++20 全局标准、聚合各层 CMake。
# 各层 target 名统一前缀 cq_。真实实现由各模块任务填充。
# 平台 App（Apple Xcode / Android Gradle / OHOS Hvigor）不走本 CMake 编译产物，
# 仅在此注册占位 target 以便工程能识别各端入口（见 ARCH-001 §8/§9）。

cmake_minimum_required(VERSION 3.21)

project(ChuanqiCut
    VERSION 0.1.0
    DESCRIPTION "Cross-platform video editing SDK + native app shells"
    # ⚠️ 必须同时启用 C —— 不是为了用 C 写内核，而是为了**校验 C ABI**：
    #    BIND-001 的 tests/unit/test_c_abi.c 是真正的 C 翻译单元，
    #    只要 cq_sdk.h 混进 C++ 类型它就编译不过。此前只写 LANGUAGES CXX，
    #    CMake 会**静默忽略** .c 源文件（不编译、不报错，只在链接时缺 main），
    #    校验形同虚设 —— 与 .gitignore / 门禁目录白名单是同一种静默缺口。
    LANGUAGES C CXX)

# ---- 全局 C++ 标准：锁 C++20，禁用 GNU 扩展（红线：CMAKE_CXX_EXTENSIONS OFF）----
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# 统一输出目录（骨架阶段不强约束，仅为后续任务铺路）
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)

# ---- CTest 总开关（INFRA-002：内核单测）----
# 必须在顶层 enable_testing()，否则 build/CTestTestfile.cmake 不会包含各子目录的
# 测试，导致 `ctest --test-dir build` 找不到用例。各子目录（tests/）自行 add_test。
enable_testing()

# ---- 聚合各层（按写集：core / pal / apps / third_party / tools / tests）----
add_subdirectory(engine/core)
add_subdirectory(engine/pal)
add_subdirectory(apps)
add_subdirectory(third_party)
add_subdirectory(tools)
add_subdirectory(tests)
