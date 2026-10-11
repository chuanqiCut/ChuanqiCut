# third_party/ — 第三方依赖（DEPS-012：双集成）
#
# manifest.toml 是「要什么/什么档位/什么协议」的真源（ARCH-002）；本文件把
# 依赖暴露为 CMake target。二进制集成与源码集成必须暴露**同一个 target**
# （`cq_ffmpeg`），切换只改集成模式，上层不改：
#
#   -DCQ_FFMPEG_INTEGRATION=binary  （默认）IMPORTED STATIC 指 prebuilt 产物，
#                                    产物由 tools/build/build_ffmpeg_demux.sh 产出
#   -DCQ_FFMPEG_INTEGRATION=source  ExternalProject 调**同一个**构建脚本
#                                    （configure flag 单一真源，不漂移），
#                                    编完仍指到同一产物路径
#
# 对应 manifest ffmpeg integration=auto 的语义：本地 binary（快），CI/发布 source
# （可审计）。产物目录含头文件（include/），manifest 的 artifact 记 sha256。

cmake_minimum_required(VERSION 3.21)

set(CQ_FFMPEG_VERSION "9.0.2")
set(CQ_FFMPEG_DEMUX_DIR "${CMAKE_CURRENT_SOURCE_DIR}/prebuilt/ffmpeg/${CQ_FFMPEG_VERSION}/demux")

# 桌面单测运行在 macOS host 上；产物目录名与 build_ffmpeg_demux.sh 的 <sdk>-<arch> 一致
if(NOT CMAKE_SYSTEM_NAME STREQUAL "Darwin")
    message(FATAL_ERROR "cq_ffmpeg: 当前仅有 Apple host 产物（android/ohos 见 DEPS-011，未开工）")
endif()
if(CMAKE_SYSTEM_PROCESSOR STREQUAL "arm64")
    set(CQ_FFMPEG_HOST_SLICE "macosx-arm64")
else()
    set(CQ_FFMPEG_HOST_SLICE "macosx-x86_64")
endif()
set(CQ_FFMPEG_HOST_LIB "${CQ_FFMPEG_DEMUX_DIR}/${CQ_FFMPEG_HOST_SLICE}/libffmpeg.a")
set(CQ_FFMPEG_HOST_INCLUDE "${CQ_FFMPEG_DEMUX_DIR}/${CQ_FFMPEG_HOST_SLICE}/include")

set(CQ_FFMPEG_INTEGRATION "binary" CACHE STRING "ffmpeg 集成模式: binary | source（对应 manifest integration，auto 按 binary 处理）")
set_property(CACHE CQ_FFMPEG_INTEGRATION PROPERTY STRINGS binary source)

add_custom_target(cq_third_party
    COMMENT "Third-party dependencies: ffmpeg (${CQ_FFMPEG_INTEGRATION})")

if(CQ_FFMPEG_INTEGRATION STREQUAL "source")
    # 源码集成：调同一个构建脚本（flag 单一真源）。源码树 third_party/src/ffmpeg
    # 已按 ADR-0008 checkout 到 pin_ref；脚本内部会校验 commit。
    include(ExternalProject)
    ExternalProject_Add(cq_ffmpeg_src
        SOURCE_DIR            "${CMAKE_CURRENT_SOURCE_DIR}/src/ffmpeg"
        CONFIGURE_COMMAND     ""
        BUILD_COMMAND         "${CMAKE_SOURCE_DIR}/tools/build/build_ffmpeg_demux.sh"
                              --sdk macosx --arch "${CMAKE_SYSTEM_PROCESSOR}"
                              --no-xcframework
        BUILD_BYPRODUCTS      "${CQ_FFMPEG_HOST_LIB}"
        INSTALL_COMMAND       ""
        BUILD_ALWAYS          TRUE
        USES_TERMINAL_BUILD   TRUE
        COMMENT "cq_ffmpeg source 集成：调 build_ffmpeg_demux.sh（demux 档，LGPL-2.1+，无 GPL 符号）")
    add_dependencies(cq_third_party cq_ffmpeg_src)
else()
    if(NOT EXISTS "${CQ_FFMPEG_HOST_LIB}")
        message(FATAL_ERROR
            "cq_ffmpeg binary 模式找不到产物：${CQ_FFMPEG_HOST_LIB}\n"
            "先构建：tools/build/build_ffmpeg_demux.sh --sdk macosx --arch ${CMAKE_SYSTEM_PROCESSOR}\n"
            "或改用源码集成：-DCQ_FFMPEG_INTEGRATION=source")
    endif()
endif()

# 两种集成暴露同一 target（DEPS-012 硬约束）
add_library(cq_ffmpeg STATIC IMPORTED GLOBAL)
set_target_properties(cq_ffmpeg PROPERTIES
    IMPORTED_LOCATION "${CQ_FFMPEG_HOST_LIB}"
    INTERFACE_INCLUDE_DIRECTORIES "${CQ_FFMPEG_HOST_INCLUDE}"
    # demux 档产物内含 avutil 的 VideoToolbox hwcontext 对象（--disable-hwaccels
    # 不禁 hwcontext），链接器会递归拉入其 CoreVideo 符号 → 消费方可执行文件须链
    # Apple 框架。挂 INTERFACE 传递，避免每个消费者各自补（App Pod 侧本就链这些框架）。
    INTERFACE_LINK_LIBRARIES "-framework CoreFoundation;-framework CoreVideo;-framework CoreMedia;-framework VideoToolbox")
if(CQ_FFMPEG_INTEGRATION STREQUAL "source")
    add_dependencies(cq_ffmpeg cq_ffmpeg_src)
endif()
