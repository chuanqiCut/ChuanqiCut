# pal/apple — Apple 平台适配（PALA-001：Metal GFX 后端）
#
# 实现 core/include/cq/pal/gfx.h 冻结的 PAL GFX HAL（IGraphicsDevice 等 12 概念）。
# 平台类型（Metal/ObjC）只出现在本目录的 .mm / 内部头，内核头零平台类型不受影响。
#
# 编译：Objective-C++（.mm）+ ARC（-fobjc-arc）。链接 Metal / CoreVideo /
# QuartzCore / Foundation 框架（仅 macOS）。

# PALA-001 Metal GFX / PALA-010 解封装 / PALA-011 VideoToolbox 硬解。
# 新增 .mm 必须同时登记到 add_library 与下面的 set_source_files_properties（ARC），
# 否则会出现「实现已写但符号未定义」的链接错误——看不出是构建配置漏了。
add_library(cq_pal_apple STATIC
    gfx_metal.mm
    gfx_metal_internal.h
    media_demux.mm
    media_decode.mm)

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
set_source_files_properties(gfx_metal.mm media_demux.mm media_decode.mm
    PROPERTIES COMPILE_FLAGS "-fobjc-arc")

# 项目统一警告集 + -Werror（apply_cq_warnings 已含）。
apply_cq_warnings(cq_pal_apple)

if(APPLE)
    find_library(METAL_LIB       Metal        REQUIRED)
    find_library(COREVIDEO_LIB   CoreVideo    REQUIRED)
    find_library(QUARTZCORE_LIB  QuartzCore   REQUIRED)
    find_library(FOUNDATION_LIB  Foundation   REQUIRED)
    # PALA-010 解封装用 AVFoundation/CoreMedia；PALA-011 硬解用 VideoToolbox。
    # ⚠️ 新增用到系统框架的 .mm 必须在此登记，否则链接期才报「符号未定义」，
    #    且报错只显示引用位置、不直接指出缺哪个框架——排查成本高。
    find_library(AVFOUNDATION_LIB AVFoundation REQUIRED)
    find_library(COREMEDIA_LIB    CoreMedia    REQUIRED)
    find_library(VIDEOTOOLBOX_LIB VideoToolbox REQUIRED)
    find_library(COREGRAPHICS_LIB CoreGraphics REQUIRED)
    target_link_libraries(cq_pal_apple PUBLIC
        ${METAL_LIB}
        ${COREVIDEO_LIB}
        ${QUARTZCORE_LIB}
        ${FOUNDATION_LIB}
        ${AVFOUNDATION_LIB}
        ${COREMEDIA_LIB}
        ${VIDEOTOOLBOX_LIB}
        ${COREGRAPHICS_LIB})
endif()
