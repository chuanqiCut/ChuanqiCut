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

# ---- 性能埋点（真机实测用；Release 下必须可用，见 test_perf.cpp 说明）----
add_executable(cq_tests_core_perf
    unit/test_perf.cpp)
target_link_libraries(cq_tests_core_perf PRIVATE cq_core)
cq_require_cxx20(cq_tests_core_perf)
apply_cq_warnings(cq_tests_core_perf)
add_test(NAME core_perf COMMAND cq_tests_core_perf)

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

# ---- MEDIA-020：SystemFrameProvider 编排逻辑单测（Mock 驱动，不依赖平台后端）----
# 用 MockDemuxer + MockDecoder 注入带 B 帧的小 GOP，验证精确 seek 编排
# （kExact 命中真正展示帧含 B 帧 / kKeyframeBefore 取关键帧 / kNearest 取最近 /
#  取消返回 kCancelled 非错误 / 显示区间归属）。平台无关，全平台可跑。
add_executable(cq_tests_media_system_frame_provider
    unit/test_system_frame_provider.cpp)
target_include_directories(cq_tests_media_system_frame_provider PRIVATE
    ${CMAKE_SOURCE_DIR}/core/include)
target_link_libraries(cq_tests_media_system_frame_provider PRIVATE cq_core)
cq_require_cxx20(cq_tests_media_system_frame_provider)
apply_cq_warnings(cq_tests_media_system_frame_provider)
add_test(NAME media_system_frame_provider COMMAND cq_tests_media_system_frame_provider)

# ---- MEDIA-011：LruFrameCache 帧缓存池（LRU + 内存上界 + lease 保护）----
# 跨平台，无平台后端。实测：插入超上界后 UsedBytes() <= 上界、LRU 淘汰最久未用、
# 借出的帧不被淘汰（move-out）、接入 SystemFrameProvider 命中缓存跳过解码。
add_executable(cq_tests_media_cache
    unit/test_cache.cpp)
target_include_directories(cq_tests_media_cache PRIVATE
    ${CMAKE_SOURCE_DIR}/core/include)
target_link_libraries(cq_tests_media_cache PRIVATE cq_core)
cq_require_cxx20(cq_tests_media_cache)
apply_cq_warnings(cq_tests_media_cache)
add_test(NAME media_cache COMMAND cq_tests_media_cache)

# ---- MEDIA-012：DecoderPool 解码器池（硬解路数上限 + 超路数降级）----
# 跨平台，无平台后端。实测：超路数返回 kResourceExhausted（不崩溃/不挂起）、释放后复用
# （同一 handle）、ActiveCount/MaxHardwarePaths 符合预期、并发借/还无挂起、接入 provider。
add_executable(cq_tests_media_decoder_pool
    unit/test_decoder_pool.cpp)
target_include_directories(cq_tests_media_decoder_pool PRIVATE
    ${CMAKE_SOURCE_DIR}/core/include)
target_link_libraries(cq_tests_media_decoder_pool PRIVATE cq_core)
cq_require_cxx20(cq_tests_media_decoder_pool)
apply_cq_warnings(cq_tests_media_decoder_pool)
add_test(NAME media_decoder_pool COMMAND cq_tests_media_decoder_pool)

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

    # ---- PALA-010：Apple 解封装后端真实文件验证 ----
    add_executable(cq_tests_pala_demux
        unit/test_media_demux_apple.cpp)
    target_include_directories(cq_tests_pala_demux PRIVATE
        ${CMAKE_SOURCE_DIR}/core/include)
    target_compile_definitions(cq_tests_pala_demux PRIVATE
        CQ_SOURCE_DIR="${CMAKE_SOURCE_DIR}")
    target_link_libraries(cq_tests_pala_demux PRIVATE cq_core cq_pal_apple)
    cq_require_cxx20(cq_tests_pala_demux)
    apply_cq_warnings(cq_tests_pala_demux)
    add_test(NAME pala_demux COMMAND cq_tests_pala_demux)

    # demux 测试直接用到的 Apple 框架（确保最终可执行链接到 CoreMedia/AVFoundation）。
    find_library(AVFOUNDATION_T_LIB AVFoundation REQUIRED)
    find_library(COREMEDIA_T_LIB   CoreMedia    REQUIRED)
    target_link_libraries(cq_tests_pala_demux PRIVATE
        ${AVFOUNDATION_T_LIB} ${COREMEDIA_T_LIB})

    # ---- MEDIA-020 真实链路冒烟：PALA-010 真实 demux + SystemFrameProvider ----
    # 半程打通：demux 真实通；解码后端（PALA-011）未实现，AcquireFrame 如实返回
    # kDecodeUnsupported，绝不 mock 伪造。仅 Apple 平台（需 PALA-010 后端）。
    add_executable(cq_tests_media_smoke_apple
        unit/test_media_smoke_apple.cpp)
    target_include_directories(cq_tests_media_smoke_apple PRIVATE
        ${CMAKE_SOURCE_DIR}/core/include)
    target_compile_definitions(cq_tests_media_smoke_apple PRIVATE
        CQ_SOURCE_DIR="${CMAKE_SOURCE_DIR}")
    target_link_libraries(cq_tests_media_smoke_apple PRIVATE
        cq_core cq_pal_apple ${AVFOUNDATION_T_LIB} ${COREMEDIA_T_LIB})
    cq_require_cxx20(cq_tests_media_smoke_apple)
    apply_cq_warnings(cq_tests_media_smoke_apple)
    add_test(NAME media_smoke_apple COMMAND cq_tests_media_smoke_apple)

    # ---- MEDIA-020 真实 B 帧文件精确 seek（mock 升级为真实文件）----
    # 用真实 PALA-010 demuxer 读 gf_1080p_h264_long_gop_bframes.mp4（300 帧 / B 帧），
    # 经「仅按 pts 网格重排」的 MockDecoder 驱动 SystemFrameProvider，验证 kExact 能在
    # 真实「解码序≠显示序」分离下正确取到 t 处的展示帧（B 帧），而非关键帧/未重建包。
    add_executable(cq_tests_media_bframe_real
        unit/test_media_bframe_real_apple.cpp)
    target_include_directories(cq_tests_media_bframe_real PRIVATE
        ${CMAKE_SOURCE_DIR}/core/include)
    target_compile_definitions(cq_tests_media_bframe_real PRIVATE
        CQ_SOURCE_DIR="${CMAKE_SOURCE_DIR}")
    target_link_libraries(cq_tests_media_bframe_real PRIVATE
        cq_core cq_pal_apple ${AVFOUNDATION_T_LIB} ${COREMEDIA_T_LIB})
    cq_require_cxx20(cq_tests_media_bframe_real)
    apply_cq_warnings(cq_tests_media_bframe_real)
    add_test(NAME media_bframe_real COMMAND cq_tests_media_bframe_real)

    # ---- PALA-002：Apple 零拷贝导入验收（CVPixelBuffer -> CVMetalTexture）----
    # 合成帧做 IOSurface 一致性 + 耗时代差证明零拷贝；并接 PALA-010+PALA-011 真实首帧
    # 经本 importer + PALA-001 渲染读回，对照真值 (0,188,0,255) 并验证 UV 原点不颠倒。
    # 测试 TU 直接调用 CoreVideo/IOSurface C API，需显式链接（避免链接期符号未定义）。
    find_library(COREVIDEO_T2_LIB CoreVideo REQUIRED)
    find_library(IOSURFACE_T2_LIB IOSurface REQUIRED)
    add_executable(cq_tests_pala_native_image
        unit/test_native_image_importer_apple.cpp)
    target_include_directories(cq_tests_pala_native_image PRIVATE
        ${CMAKE_SOURCE_DIR}/core/include
        ${CMAKE_SOURCE_DIR}/pal/apple)
    target_compile_definitions(cq_tests_pala_native_image PRIVATE
        CQ_SOURCE_DIR="${CMAKE_SOURCE_DIR}")
    target_link_libraries(cq_tests_pala_native_image PRIVATE
        cq_core cq_pal_apple
        ${AVFOUNDATION_T_LIB} ${COREMEDIA_T_LIB}
        ${COREVIDEO_T2_LIB} ${IOSURFACE_T2_LIB})
    cq_require_cxx20(cq_tests_pala_native_image)
    apply_cq_warnings(cq_tests_pala_native_image)
    add_test(NAME pala_native_image COMMAND cq_tests_pala_native_image)

    # ---- PALA-012：Apple 编码与封装验收（AVAssetWriter + PixelBufferAdaptor）----
    # 端到端：PALA-010 真实 demux + PALA-011 硬解 -> AppleVideoEncoder 写 H.264 MP4 ->
    # 重解码输出首帧中心像素对照 (0,188,0,255) + popen ffprobe 验证 codec/分辨率/帧数/时长。
    # 测试 TU 直接调用 CoreVideo C API 读像素，需显式链接 CoreVideo（经 cq_pal_apple PUBLIC 传递）。
    find_library(COREVIDEO_T3_LIB CoreVideo REQUIRED)
    add_executable(cq_tests_pala_encode
        unit/test_media_encode_apple.cpp)
    target_include_directories(cq_tests_pala_encode PRIVATE
        ${CMAKE_SOURCE_DIR}/core/include
        ${CMAKE_SOURCE_DIR}/pal/apple)
    target_compile_definitions(cq_tests_pala_encode PRIVATE
        CQ_SOURCE_DIR="${CMAKE_SOURCE_DIR}")
    target_link_libraries(cq_tests_pala_encode PRIVATE
        cq_core cq_pal_apple
        ${AVFOUNDATION_T_LIB} ${COREMEDIA_T_LIB} ${COREVIDEO_T3_LIB})
    cq_require_cxx20(cq_tests_pala_encode)
    apply_cq_warnings(cq_tests_pala_encode)
    add_test(NAME pala_encode COMMAND cq_tests_pala_encode)

    # ---- muxer 接缝：平台无关 IMediaMuxer 经工厂调用导出 H.264 MP4 ----
    # 全程只通过 core 冻结接口 IMediaMuxer + CreateMediaMuxer 完成导出（不碰 AppleVideoEncoder），
    # 证明导出能力可被上层平台无关调用；ffprobe 验证 codec/分辨率/帧数/时长 + 首帧像素。
    find_library(COREVIDEO_T4_LIB CoreVideo REQUIRED)
    add_executable(cq_tests_pala_muxer
        unit/test_media_muxer_apple.cpp)
    target_include_directories(cq_tests_pala_muxer PRIVATE
        ${CMAKE_SOURCE_DIR}/core/include
        ${CMAKE_SOURCE_DIR}/pal/apple)
    target_compile_definitions(cq_tests_pala_muxer PRIVATE
        CQ_SOURCE_DIR="${CMAKE_SOURCE_DIR}")
    target_link_libraries(cq_tests_pala_muxer PRIVATE
        cq_core cq_pal_apple
        ${AVFOUNDATION_T_LIB} ${COREMEDIA_T_LIB} ${COREVIDEO_T4_LIB})
    cq_require_cxx20(cq_tests_pala_muxer)
    apply_cq_warnings(cq_tests_pala_muxer)
    add_test(NAME pala_muxer COMMAND cq_tests_pala_muxer)

    # ---- muxer 接缝：AAC 音频轨封装验收（合成 PCM -> AAC 音轨，ffprobe 验证）----
    # 端到端验证 IMediaMuxer::AddAudioTrack / WriteAudioFrame 真能产出含 aac 音轨的 MP4，
    # 且 codec=aac / 采样率 / 声道与 AudioTrackConfig 一致。仅 Apple 平台。
    find_library(COREVIDEO_T5_LIB CoreVideo REQUIRED)
    add_executable(cq_tests_pala_muxer_audio
        unit/test_media_muxer_audio_apple.cpp)
    target_include_directories(cq_tests_pala_muxer_audio PRIVATE
        ${CMAKE_SOURCE_DIR}/core/include
        ${CMAKE_SOURCE_DIR}/pal/apple)
    target_compile_definitions(cq_tests_pala_muxer_audio PRIVATE
        CQ_SOURCE_DIR="${CMAKE_SOURCE_DIR}")
    target_link_libraries(cq_tests_pala_muxer_audio PRIVATE
        cq_core cq_pal_apple
        ${AVFOUNDATION_T_LIB} ${COREMEDIA_T_LIB} ${COREVIDEO_T5_LIB})
    cq_require_cxx20(cq_tests_pala_muxer_audio)
    apply_cq_warnings(cq_tests_pala_muxer_audio)
    add_test(NAME pala_muxer_audio COMMAND cq_tests_pala_muxer_audio)
endif()
