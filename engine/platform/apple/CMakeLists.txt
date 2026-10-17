# platform/apple — Apple 平台适配（PALA-001：Metal GFX 后端）
#
# 实现 core/cq/platform/gfx.h 冻结的 Platform GFX HAL（IGraphicsDevice 等 12 概念）。
# 平台类型（Metal/ObjC）只出现在本目录的 .mm / 内部头，内核头零平台类型不受影响。
#
# 编译：Objective-C++（.mm）+ ARC（-fobjc-arc）。链接 Metal / CoreVideo /
# QuartzCore / Foundation 框架（仅 macOS）。

# PALA-001 Metal GFX / PALA-010 解封装 / PALA-011 VideoToolbox 硬解。
# 新增 .mm 必须同时登记到 add_library 与下面的 set_source_files_properties（ARC），
# 否则会出现「实现已写但符号未定义」的链接错误——看不出是构建配置漏了。
add_library(cq_platform_apple STATIC
    gfx/gfx_metal.mm
    gfx/gfx_metal_internal.h
    media/media_demux.mm
    media/media_decode.mm
    media/media_encode.mm
    media/media_muxer.mm
    base/capabilities.mm
    base/capabilities_apple.h
    # BIND-003 子步骤 4/5：预览链路的两个 Apple 装配点。
    # 两者都实现 **Platform 契约**（工厂声明在 core/cq/platform/{gfx,media}.h），
    # 故这里没有对应的 .h —— 声明在 Platform，实现在各平台。
    #   gfx/blit_pass.mm             —— CreateBlitPass
#                                   （MSL 由 SHADER-001 的 Portable 链在构建期生成，
#                                    见下方「Portable shader → MSL」段）
    #   media/frame_provider_apple.mm —— CreateFrameProvider（PALA-010 + PALA-011 → MEDIA-020）
    gfx/blit_pass.mm
    media/frame_provider_apple.mm
    # AUDIO-002：音频轨读取（AVAssetReader PCM 解码输出）+ 音频播放引擎
    #（AVAudioEngine + AVAudioSourceNode，PALA-030）。均实现 Platform 契约
    #（CreateAudioTrackReader / CreateAudioEngine，声明在 core），无独立 .h。
    media/audio_track_reader.mm
    media/audio_engine.mm)

target_include_directories(cq_platform_apple PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/base
    ${CMAKE_CURRENT_SOURCE_DIR}/gfx
    ${CMAKE_CURRENT_SOURCE_DIR}/media
    ${CMAKE_SOURCE_DIR}/engine/core)

target_link_libraries(cq_platform_apple PUBLIC cq_core)

# ===========================================================================
# SHADER-001 / SHADER-010：Portable shader（engine/shaders/portable/*.glsl）→ MSL 生成链
#
# 红线 #6：Portable 层是跨平台基线，平台特化只能来自转译或 platform/ 下的**可选**覆盖。
# 故这里在**构建期**跑 glslang → SPIR-V → spirv-cross → MSL，把每组 shader 写成一个 .h，
# 由 gfx/blit_pass.mm include。
#
# 为什么走构建期而不是运行时转译：运行时转译要把 glslang / SPIR-V-Cross 链进 App
# （体积 + 启动耗时），而 shader 集合是编译期已知的常量——没有理由付出这个代价。
#
# 产物必须在 CMAKE_BINARY_DIR 下：AGENTS 禁止提交 shader 生成产物，放 build/ 既满足
# 「不入库」，又能被 .mm 直接 include（无需运行时 IO）。
#
# ⚠️ 新增一组 shader 要改**两处**：`tools/shaders/build_shaders.py` 的 SHADER_GROUPS
#    与下面的 OUTPUTS + DEPENDS。DEPENDS 少写一个源文件 = 改了 .glsl 增量构建不重跑，
#    拿旧产物编译（假绿），比编译失败更难查（INFRA-033 就是拿这条清单防的）。
# ===========================================================================
find_package(Python3 COMPONENTS Interpreter REQUIRED)

set(CQ_GENERATED_SHADER_DIR "${CMAKE_BINARY_DIR}/generated/shaders")
set(CQ_SHADER_MSL_HEADERS "${CQ_GENERATED_SHADER_DIR}/blit_msl.h"
                          "${CQ_GENERATED_SHADER_DIR}/transform_msl.h")

add_custom_command(
    OUTPUT ${CQ_SHADER_MSL_HEADERS}
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${CQ_GENERATED_SHADER_DIR}"
    COMMAND "${Python3_EXECUTABLE}" "${CMAKE_SOURCE_DIR}/tools/shaders/build_shaders.py"
            --repo-root "${CMAKE_SOURCE_DIR}"
            --out-dir "${CQ_GENERATED_SHADER_DIR}"
    DEPENDS "${CMAKE_SOURCE_DIR}/tools/shaders/build_shaders.py"
            "${CMAKE_SOURCE_DIR}/engine/shaders/portable/blit.vert"
            "${CMAKE_SOURCE_DIR}/engine/shaders/portable/blit.frag"
            "${CMAKE_SOURCE_DIR}/engine/shaders/portable/transform.vert"
            "${CMAKE_SOURCE_DIR}/engine/shaders/portable/transform.frag"
    COMMENT "SHADER-001/010: glslang → SPIR-V → spirv-cross → MSL (blit, transform)"
    VERBATIM)

# 用中间 target 承接依赖：直接 add_dependencies 到一个 custom command 的 OUTPUT 文件
# 在部分 CMake 版本上不生效，target 形态则是明确支持的。
add_custom_target(cq_shaders_msl DEPENDS ${CQ_SHADER_MSL_HEADERS})
add_dependencies(cq_platform_apple cq_shaders_msl)

# PRIVATE 而非 PUBLIC：生成目录只被本目录的 .mm 消费，不进导出接口
# （CMake 会拒绝把 build/ 下的路径放进 INTERFACE_INCLUDE_DIRECTORIES）。
target_include_directories(cq_platform_apple PRIVATE "${CQ_GENERATED_SHADER_DIR}")

# 语言标准锁 C++20（含 OBJCXX），禁用 GNU 扩展。
cq_require_cxx20(cq_platform_apple)
set_target_properties(cq_platform_apple PROPERTIES
    OBJCXX_STANDARD 20
    OBJCXX_STANDARD_REQUIRED ON
    OBJCXX_EXTENSIONS OFF)

# Objective-C++ 启用 ARC（与项目警告集共存：-Werror -Wconversion -Wshadow -Wold-style-cast）。
set_source_files_properties(gfx/gfx_metal.mm media/media_demux.mm media/media_decode.mm
    media/media_encode.mm media/media_muxer.mm base/capabilities.mm gfx/blit_pass.mm
    media/frame_provider_apple.mm media/audio_track_reader.mm media/audio_engine.mm
    PROPERTIES COMPILE_FLAGS "-fobjc-arc")

# 项目统一警告集 + -Werror（apply_cq_warnings 已含）。
apply_cq_warnings(cq_platform_apple)

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
    target_link_libraries(cq_platform_apple PUBLIC
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
        target_link_libraries(cq_platform_apple PUBLIC ${IOSURFACE_LIB})
    endif()
endif()
