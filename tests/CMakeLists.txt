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

# ---- CORE-001 / CORE-002：base 层单测 ----
# 复用与 smoke 一致的编译/警告配置（-Werror + 项目警告集合）。
# 命名：test name 以 core_ 前缀，便于 `ctest -R core_time` / `ctest -R core_status`。

add_executable(cq_tests_core_time
    unit/test_time.cpp)
target_link_libraries(cq_tests_core_time PRIVATE cq_core)
cq_require_cxx20(cq_tests_core_time)
apply_cq_warnings(cq_tests_core_time)
add_test(NAME core_time COMMAND cq_tests_core_time)

add_executable(cq_tests_core_status
    unit/test_status.cpp)
target_link_libraries(cq_tests_core_status PRIVATE cq_core)
cq_require_cxx20(cq_tests_core_status)
apply_cq_warnings(cq_tests_core_status)
add_test(NAME core_status COMMAND cq_tests_core_status)

# ---- CORE-003：日志与帧级 trace ----
add_executable(cq_tests_core_log
    unit/test_log.cpp)
target_link_libraries(cq_tests_core_log PRIVATE cq_core)
cq_require_cxx20(cq_tests_core_log)
apply_cq_warnings(cq_tests_core_log)
add_test(NAME core_log COMMAND cq_tests_core_log)

# ---- CORE-004：内存池 / Arena / 纹理预算记账 ----
add_executable(cq_tests_core_alloc
    unit/test_alloc.cpp)
target_link_libraries(cq_tests_core_alloc PRIVATE cq_core)
cq_require_cxx20(cq_tests_core_alloc)
apply_cq_warnings(cq_tests_core_alloc)
add_test(NAME core_alloc COMMAND cq_tests_core_alloc)

# ---- CORE-005：并发原语 / 有界队列 / CancelToken ----
add_executable(cq_tests_core_concurrency
    unit/test_concurrency.cpp)
target_link_libraries(cq_tests_core_concurrency PRIVATE cq_core)
cq_require_cxx20(cq_tests_core_concurrency)
apply_cq_warnings(cq_tests_core_concurrency)
add_test(NAME core_concurrency COMMAND cq_tests_core_concurrency)

# ---- CORE-006：PAL 头文件编译期自洽验证（零平台类型 / 零 FFmpeg 类型 / base 类型契约）----
# 仅包含 PAL 头文件 + static_assert，不链接任何 PAL 实现（接口冻结阶段无实现）。
# 证明：头文件自洽（include 顺序无关）、跨层资源均为 opaque 指针（零平台类型）、
# 时间用 RationalTime、错误用 Status、长任务接受 CancelToken、资源用 PalPtr 生命周期。
add_executable(cq_tests_pal_headers_compile
    unit/pal_headers_compile.cpp)
# 不链接 cq_core：本 TU 只验证 core/include 下的接口头自洽，无需内核实现。
# 但需指向内核头目录，使 "cq/pal/*.h" 可被找到。
target_include_directories(cq_tests_pal_headers_compile PRIVATE
    ${CMAKE_SOURCE_DIR}/core/include)
cq_require_cxx20(cq_tests_pal_headers_compile)
apply_cq_warnings(cq_tests_pal_headers_compile)
add_test(NAME pal_headers_compile COMMAND cq_tests_pal_headers_compile)

# ---- GFX-001：GFX 层头文件编译期自洽验证（零平台类型 / 分层边界 / base 类型契约）----
# 仅包含 cq/gfx/*.h + static_assert，不链接实现（接口定义阶段无实现）。
add_executable(cq_tests_gfx_headers_compile
    unit/gfx_headers_compile.cpp)
target_include_directories(cq_tests_gfx_headers_compile PRIVATE
    ${CMAKE_SOURCE_DIR}/core/include)
cq_require_cxx20(cq_tests_gfx_headers_compile)
apply_cq_warnings(cq_tests_gfx_headers_compile)
add_test(NAME gfx_headers_compile COMMAND cq_tests_gfx_headers_compile)

# ---- MEDIA-010：跨平台 FrameProvider 头文件编译期自洽验证（零平台类型 / 精确 seek / 钩子）----
# 仅包含 cq/media/frame_provider.h + static_assert，不链接实现（接口定义阶段无实现）。
add_executable(cq_tests_media_frame_provider_compile
    unit/media_frame_provider_compile.cpp)
target_include_directories(cq_tests_media_frame_provider_compile PRIVATE
    ${CMAKE_SOURCE_DIR}/core/include)
cq_require_cxx20(cq_tests_media_frame_provider_compile)
apply_cq_warnings(cq_tests_media_frame_provider_compile)
add_test(NAME media_frame_provider_compile COMMAND cq_tests_media_frame_provider_compile)

# ---- CORE-006：PAL 头文件「零平台类型 / 零 FFmpeg 类型」静态门禁 ----
# 纯 stdlib python3 脚本：先剥离注释与字符串字面量（避免评论/字符串误报），
# 再匹配平台类型 / 平台头文件 / FFmpeg 类型 / throw / 裸 double（time 统一用 RationalTime）。
# 违规时非零退出（EXIT=1）。已自测证明有效：临时插入 jobject 必被捕获，回退后恢复绿。
# 脚本默认扫描 core/include/cq/pal（按脚本自身位置做路径推导），故无需额外参数。
find_package(Python3 COMPONENTS Interpreter)
if(Python3_Interpreter_FOUND)
    add_test(NAME pal_header_gate
        COMMAND ${Python3_EXECUTABLE}
                ${CMAKE_SOURCE_DIR}/tools/pal/check_pal_headers.py)
endif()

# ---- PALA-001：Apple Metal 后端离屏渲染 + 读回像素验证 ----
# 仅在 Apple 平台构建。链接 cq_pal_apple（Metal 实现）与 cq_core，证明：
#   * 用例 A：清屏红 -> 读回中心像素 = (255,0,0,255)
#   * 用例 B：全屏采样四色纹理 -> 读回四角 = 红/绿/蓝/黄（采样管线真的通）
# 测试 TU 为纯 C++，只通过 pal/apple 内部辅助（ReadRenderTargetPixels / UploadTextureData）
# 接触 Metal，不污染内核头。
if(APPLE)
    add_executable(cq_tests_pala_metal
        unit/test_gfx_metal.cpp)
    target_include_directories(cq_tests_pala_metal PRIVATE
        ${CMAKE_SOURCE_DIR}/core/include
        ${CMAKE_SOURCE_DIR}/pal/apple)
    target_link_libraries(cq_tests_pala_metal PRIVATE cq_core cq_pal_apple)
    cq_require_cxx20(cq_tests_pala_metal)
    apply_cq_warnings(cq_tests_pala_metal)
    add_test(NAME pala_metal_render COMMAND cq_tests_pala_metal)
endif()
