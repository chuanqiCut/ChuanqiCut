# tests/ — 内核单测（INFRA-002：接入 CTest）
#
# 单测在桌面（macOS/Linux）跑，不依赖真机（ARCH-001 §9 / §8 构建系统）。
# 编译选项集中定义在 cmake/ 下，模块只调用函数，不散写 -std= / -Wxxx。
#
# 说明：本任务只落地一个“有意义的占位 smoke 用例”，证明 C++20 真的生效、
# 且单测能在 -Werror 下编译运行。真正的业务单测由各 CORE 模块任务注册到这里
# （沿用 add_test + cq_require_cxx20 + apply_cq_warnings 的写法）。

include(${CMAKE_SOURCE_DIR}/cmake/CompileOptions.cmake)
include(${CMAKE_SOURCE_DIR}/cmake/Warnings.cmake)

enable_testing()

# ---- 占位 smoke 用例：断言 C++20 生效 ----
# 不发明任何业务逻辑；仅验证工具链确实按 C++20 编译（__cplusplus >= 202002L）。
add_executable(cq_tests_cxx20_smoke
    unit/cxx20_smoke.cpp)

# 链接 cq_core，顺便证明内核静态库能干净编译并参与链接。
target_link_libraries(cq_tests_cxx20_smoke PRIVATE cq_core)

cq_require_cxx20(cq_tests_cxx20_smoke)
apply_cq_warnings(cq_tests_cxx20_smoke)

add_test(NAME cq_cxx20_smoke COMMAND cq_tests_cxx20_smoke)
