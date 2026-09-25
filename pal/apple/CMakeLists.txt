# pal/apple — Apple 平台适配（PALA-001：Metal GFX 后端）
#
# 实现 core/include/cq/pal/gfx.h 冻结的 PAL GFX HAL（IGraphicsDevice 等 12 概念）。
# 平台类型（Metal/ObjC）只出现在本目录的 .mm / 内部头，内核头零平台类型不受影响。
#
# 编译：Objective-C++（.mm）+ ARC（-fobjc-arc）。链接 Metal / CoreVideo /
# QuartzCore / Foundation 框架（仅 macOS）。

add_library(cq_pal_apple STATIC
    gfx_metal.mm
    gfx_metal_internal.h)

target_include_directories(cq_pal_apple PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_SOURCE_DIR}/core/include)

target_link_libraries(cq_pal_apple PUBLIC cq_core)

# 语言标准锁 C++20（含 OBJCXX），禁用 GNU 扩展。
cq_require_cxx20(cq_pal_apple)
set_target_properties(cq_pal_apple PROPERTIES
    OBJCXX_STANDARD 20
    OBJCXX_STANDARD_REQUIRED ON
    OBJCXX_EXTENSIONS OFF)

# Objective-C++ 启用 ARC（与项目警告集共存：-Werror -Wconversion -Wshadow -Wold-style-cast）。
set_source_files_properties(gfx_metal.mm PROPERTIES COMPILE_FLAGS "-fobjc-arc")

# 项目统一警告集 + -Werror（apply_cq_warnings 已含）。
apply_cq_warnings(cq_pal_apple)

if(APPLE)
    find_library(METAL_LIB      Metal      REQUIRED)
    find_library(COREVIDEO_LIB  CoreVideo  REQUIRED)
    find_library(QUARTZCORE_LIB QuartzCore REQUIRED)
    find_library(FOUNDATION_LIB Foundation REQUIRED)
    target_link_libraries(cq_pal_apple PUBLIC
        ${METAL_LIB}
        ${COREVIDEO_LIB}
        ${QUARTZCORE_LIB}
        ${FOUNDATION_LIB})
endif()
