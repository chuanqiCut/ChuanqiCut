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
    media_decode.mm
    media_encode.mm
    media_muxer.mm)

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
set_source_files_properties(gfx_metal.mm media_demux.mm media_decode.mm media_encode.mm media_muxer.mm
    PROPERTIES COMPILE_FLAGS "-fobjc-arc")

# 项目统一警告集 + -Werror（apply_cq_warnings 已含）。
apply_cq_warnings(cq_pal_apple)

if(APPLE)
    find_library(METAL_LIB       Metal        REQUIRED)
    find_library(COREVIDEO_LIB   CoreVideo    REQUIRED)
    find_library(QUARTZCORE_LIB  QuartzCore   REQUIRED)
    find_library(FOUNDATION_LIB  Foundation   REQUIRED)
    # PALA-002 零拷贝路径用到 CVMetalTexture / IOSurface（IOSurface 在 macOS 为独立框架，
    # 虽常被 CoreVideo/Metal 传递链接，这里显式登记避免「符号未定义」式链接陷阱）。
    #
    # ⚠️ IOSurface 是 **macOS 专有**框架，iOS SDK 里不存在。交叉编译 iOS 时若仍 REQUIRED，
    #    configure 阶段就会失败。故按 CMAKE_SYSTEM_NAME 区分：
    #      - Darwin(macOS)：查找并链接
    #      - iOS          ：不查找、不链接（gfx_metal.mm 内已用 TARGET_OS_IPHONE 条件编译
    #                       把 IOSurface 用法隔离，见该文件的注释）
    if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
        find_library(IOSURFACE_LIB   IOSurface    REQUIRED)
    endif()
    # PALA-010 解封装用 AVFoundation/CoreMedia；PALA-011 硬解用 VideoToolbox。
    # ⚠️ 新增用到系统框架的 .mm 必须在此登记，否则链接期才报「符号未定义」，
    #    且报错只显示引用位置、不直接指出缺哪个框架——排查成本高。
    find_library(AVFOUNDATION_LIB AVFoundation REQUIRED)
    find_library(COREMEDIA_LIB    CoreMedia    REQUIRED)
    find_library(VIDEOTOOLBOX_LIB VideoToolbox REQUIRED)
    find_library(COREGRAPHICS_LIB CoreGraphics REQUIRED)
    find_library(AUDIOTOOLBOX_LIB AudioToolbox REQUIRED)
    target_link_libraries(cq_pal_apple PUBLIC
        ${METAL_LIB}
        ${COREVIDEO_LIB}
        ${QUARTZCORE_LIB}
        ${FOUNDATION_LIB}
        ${AVFOUNDATION_LIB}
        ${COREMEDIA_LIB}
        ${VIDEOTOOLBOX_LIB}
        ${COREGRAPHICS_LIB}
        ${AUDIOTOOLBOX_LIB})
    # IOSurface 仅 macOS 有（见上面的条件查找），故单独追加，避免 iOS 下链接空变量。
    if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
        target_link_libraries(cq_pal_apple PUBLIC ${IOSURFACE_LIB})
    endif()
endif()
