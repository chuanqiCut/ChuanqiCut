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
    unit/base/cxx20_smoke.cpp)

# 链接 cq_core，顺便证明内核静态库能干净编译并参与链接。
target_link_libraries(cq_tests_cxx20_smoke PRIVATE cq_core)

cq_require_cxx20(cq_tests_cxx20_smoke)
apply_cq_warnings(cq_tests_cxx20_smoke)

add_test(NAME cq_cxx20_smoke COMMAND cq_tests_cxx20_smoke)

# ---- CORE-001 / CORE-002：base 层单测 ----
# 复用与 smoke 一致的编译/警告配置（-Werror + 项目警告集合）。
# 命名：test name 以 core_ 前缀，便于 `ctest -R core_time` / `ctest -R core_status`。

add_executable(cq_tests_core_time
    unit/base/test_time.cpp)
target_link_libraries(cq_tests_core_time PRIVATE cq_core)
cq_require_cxx20(cq_tests_core_time)
apply_cq_warnings(cq_tests_core_time)
add_test(NAME core_time COMMAND cq_tests_core_time)

add_executable(cq_tests_core_status
    unit/base/test_status.cpp)
target_link_libraries(cq_tests_core_status PRIVATE cq_core)
cq_require_cxx20(cq_tests_core_status)
apply_cq_warnings(cq_tests_core_status)
add_test(NAME core_status COMMAND cq_tests_core_status)

# ---- 性能埋点（真机实测用；Release 下必须可用，见 test_perf.cpp 说明）----
add_executable(cq_tests_core_perf
    unit/base/test_perf.cpp)
target_link_libraries(cq_tests_core_perf PRIVATE cq_core)
cq_require_cxx20(cq_tests_core_perf)
apply_cq_warnings(cq_tests_core_perf)
add_test(NAME core_perf COMMAND cq_tests_core_perf)

# ---- CORE-003：日志与帧级 trace ----
add_executable(cq_tests_core_log
    unit/base/test_log.cpp)
target_link_libraries(cq_tests_core_log PRIVATE cq_core)
cq_require_cxx20(cq_tests_core_log)
apply_cq_warnings(cq_tests_core_log)
add_test(NAME core_log COMMAND cq_tests_core_log)

# ---- CORE-010：日志 workflow（按链路筛选 + 环境变量提级）----
add_executable(cq_tests_core_log_workflow
    unit/base/test_log_workflow.cpp)
target_link_libraries(cq_tests_core_log_workflow PRIVATE cq_core)
cq_require_cxx20(cq_tests_core_log_workflow)
apply_cq_warnings(cq_tests_core_log_workflow)
add_test(NAME core_log_workflow COMMAND cq_tests_core_log_workflow)

# ---- CORE-004：内存池 / Arena / 纹理预算记账 ----
add_executable(cq_tests_core_alloc
    unit/base/test_alloc.cpp)
target_link_libraries(cq_tests_core_alloc PRIVATE cq_core)
cq_require_cxx20(cq_tests_core_alloc)
apply_cq_warnings(cq_tests_core_alloc)
add_test(NAME core_alloc COMMAND cq_tests_core_alloc)

# ---- CORE-005：并发原语 / 有界队列 / CancelToken ----
add_executable(cq_tests_core_concurrency
    unit/base/test_concurrency.cpp)
target_link_libraries(cq_tests_core_concurrency PRIVATE cq_core)
cq_require_cxx20(cq_tests_core_concurrency)
apply_cq_warnings(cq_tests_core_concurrency)
add_test(NAME core_concurrency COMMAND cq_tests_core_concurrency)

# ---- CORE-007：能力查询内核侧（注入 / 分发 / 未注入返回 kNo）----
# ⚠️ 存在的理由：CORE-006 冻结头文件后，SetCapabilitiesBackend / QueryCapability
#    长期只有声明无定义，而 platform_headers_compile.cpp 的 static_assert 是编译期检查、
#    不链接 —— CTest 一直全绿也看不出接口是断的。本用例**链接并运行**这两个函数。
#    平台无关：用 FixedBackend 注入固定值，不依赖任何真实设备能力。
add_executable(cq_tests_core_capabilities
    unit/platform/test_capabilities.cpp)
target_include_directories(cq_tests_core_capabilities PRIVATE
    ${CMAKE_SOURCE_DIR}/engine/core)
target_link_libraries(cq_tests_core_capabilities PRIVATE cq_core)
cq_require_cxx20(cq_tests_core_capabilities)
apply_cq_warnings(cq_tests_core_capabilities)
add_test(NAME core_capabilities COMMAND cq_tests_core_capabilities)

# ---- CORE-008：线程模型与队列骨架（Session Thread 骨架，ARCH-001 §6）----
# 验收核心是 ARCH-001 §6 铁律 1「主线程零阻塞」**可测**：
# 投递 100ms 任务，实测 Post() 返回耗时须 < 16ms。
# 另测：任务跑在 worker 线程、串行 FIFO、满队列返回 kResourceExhausted（背压）。
add_executable(cq_tests_core_thread_model
    unit/session/test_thread_model.cpp)
target_include_directories(cq_tests_core_thread_model PRIVATE
    ${CMAKE_SOURCE_DIR}/engine/core)
target_link_libraries(cq_tests_core_thread_model PRIVATE cq_core)
cq_require_cxx20(cq_tests_core_thread_model)
apply_cq_warnings(cq_tests_core_thread_model)
add_test(NAME core_thread_model COMMAND cq_tests_core_thread_model)

# ---- CORE-009：EditorSession 门面与快照机制（ARCH-001 §4.1「对外唯一门面」）----
# 验收「快照版本号递增，UI 可 diff」：
#   成功变更 → 版本 +1；失败/取消 → 不推进（否则 UI 会错刷）；
#   ChangesSince(v) 给出增量变更日志；主线程 Submit 实测 < 16ms；
#   变更在 session 线程串行执行；观察者在 session 线程回调。
add_executable(cq_tests_core_editor_session
    unit/session/test_editor_session.cpp)
target_include_directories(cq_tests_core_editor_session PRIVATE
    ${CMAKE_SOURCE_DIR}/engine/core)
target_link_libraries(cq_tests_core_editor_session PRIVATE cq_core)
cq_require_cxx20(cq_tests_core_editor_session)
apply_cq_warnings(cq_tests_core_editor_session)
add_test(NAME core_editor_session COMMAND cq_tests_core_editor_session)

# ---- BIND-001：cq_sdk.h 纯 C ABI（用**真正的 C 编译器**编译）----
# 硬证据：只要公共头混进任何 C++ 类型，这个 .c 就编译失败 —— 比人眼审查可靠。
# 底层实现是 C++，故链接器显式指定 CXX（否则 C++ 运行时符号解析不全）。
add_executable(cq_tests_c_abi
    unit/abi/test_c_abi.c)
set_target_properties(cq_tests_c_abi PROPERTIES LINKER_LANGUAGE CXX)
target_include_directories(cq_tests_c_abi PRIVATE
    ${CMAKE_SOURCE_DIR}/engine/core)
target_link_libraries(cq_tests_c_abi PRIVATE cq_core)
add_test(NAME c_abi COMMAND cq_tests_c_abi)

# ---- UIA-009 子步骤 1：会话级模型 C ABI（素材表 / 时间线 / 查询快照）----
# 只链 cq_core：新 ABI 全部落在内建模型状态上，**不得**引入 Platform 依赖 ——
# 这是 ADR-0011 隔离规则的回归守卫之一（session TU 不碰 Platform 工厂）。
# 异步提交语义：测试靠「轮询快照版本 + 查询」等最终一致。
add_executable(cq_tests_c_abi_session
    unit/abi/test_c_abi_session.c)
set_target_properties(cq_tests_c_abi_session PROPERTIES LINKER_LANGUAGE CXX)
target_include_directories(cq_tests_c_abi_session PRIVATE
    ${CMAKE_SOURCE_DIR}/engine/core)
target_link_libraries(cq_tests_c_abi_session PRIVATE cq_core)
add_test(NAME c_abi_session COMMAND cq_tests_c_abi_session)

# ---- UIA-005：片段编辑与撤销 C ABI（move / trim / undo / redo / can_*）----
# 同只链 cq_core。同步手法不用 sleep：提交一条必定成功的哨兵变更并等它落地
# （session 队列 FIFO ⇒ 哨兵执行完代表前面所有提交都已执行，含被拒的那些）。
add_executable(cq_tests_c_abi_edit
    unit/abi/test_c_abi_edit.c)
set_target_properties(cq_tests_c_abi_edit PROPERTIES LINKER_LANGUAGE CXX)
target_include_directories(cq_tests_c_abi_edit PRIVATE
    ${CMAKE_SOURCE_DIR}/engine/core)
target_link_libraries(cq_tests_c_abi_edit PRIVATE cq_core)
add_test(NAME c_abi_edit COMMAND cq_tests_c_abi_edit)

# ---- UIA-010：播放时钟（时刻 = 墙钟的函数，非帧数累加；帧网格量化）----
# 平台无关（只用 steady_clock + 有理数），不依赖任何 Platform / Metal。
add_executable(cq_tests_core_player_clock
    unit/preview/test_player_clock.cpp)
target_include_directories(cq_tests_core_player_clock PRIVATE
    ${CMAKE_SOURCE_DIR}/engine/core)
target_link_libraries(cq_tests_core_player_clock PRIVATE cq_core)
cq_require_cxx20(cq_tests_core_player_clock)
apply_cq_warnings(cq_tests_core_player_clock)
add_test(NAME core_player_clock COMMAND cq_tests_core_player_clock)

# ---- UIA-010 子步骤 5：预览取帧泵（并发语义；假帧源，只链 cq_core）----
# 只链 cq_core：泵是平台无关的（std::thread + mutex + condvar），不需要 Platform 后端，
# 故本用例在没有 Metal / 硬解后端的环境里也能跑 —— 这条是刻意的，别顺手加 cq_platform_apple。
add_executable(cq_tests_core_preview_pump
    unit/preview/test_preview_pump.cpp)
target_include_directories(cq_tests_core_preview_pump PRIVATE
    ${CMAKE_SOURCE_DIR}/engine/core)
target_link_libraries(cq_tests_core_preview_pump PRIVATE cq_core)
cq_require_cxx20(cq_tests_core_preview_pump)
apply_cq_warnings(cq_tests_core_preview_pump)
add_test(NAME core_preview_pump COMMAND cq_tests_core_preview_pump)

# ---- UIA-010：播放时钟 + 时间线时长的 C ABI（真正的 C TU，只链 cq_core）----
add_executable(cq_tests_c_abi_player
    unit/abi/test_c_abi_player.c)
set_target_properties(cq_tests_c_abi_player PROPERTIES LINKER_LANGUAGE CXX)
target_include_directories(cq_tests_c_abi_player PRIVATE
    ${CMAKE_SOURCE_DIR}/engine/core)
target_link_libraries(cq_tests_c_abi_player PRIVATE cq_core)
add_test(NAME c_abi_player COMMAND cq_tests_c_abi_player)

# ---- CORE-006：Platform 头文件编译期自洽验证（零平台类型 / 零 FFmpeg 类型 / base 类型契约）----
# 仅包含 Platform 头文件 + static_assert，不链接任何 Platform 实现（接口冻结阶段无实现）。
# 证明：头文件自洽（include 顺序无关）、跨层资源均为 opaque 指针（零平台类型）、
# 时间用 RationalTime、错误用 Status、长任务接受 CancelToken、资源用 PlatformPtr 生命周期。
add_executable(cq_tests_platform_headers_compile
    unit/platform/platform_headers_compile.cpp)
# 不链接 cq_core：本 TU 只验证 core/cq 下的接口头自洽，无需内核实现。
# 但需指向内核头目录，使 "cq/platform/*.h" 可被找到。
target_include_directories(cq_tests_platform_headers_compile PRIVATE
    ${CMAKE_SOURCE_DIR}/engine/core)
cq_require_cxx20(cq_tests_platform_headers_compile)
apply_cq_warnings(cq_tests_platform_headers_compile)
add_test(NAME platform_headers_compile COMMAND cq_tests_platform_headers_compile)

# ---- GFX-001：GFX 层头文件编译期自洽验证（零平台类型 / 分层边界 / base 类型契约）----
# 仅包含 cq/gfx/*.h + static_assert，不链接实现（接口定义阶段无实现）。
add_executable(cq_tests_gfx_headers_compile
    unit/gfx/gfx_headers_compile.cpp)
target_include_directories(cq_tests_gfx_headers_compile PRIVATE
    ${CMAKE_SOURCE_DIR}/engine/core)
cq_require_cxx20(cq_tests_gfx_headers_compile)
apply_cq_warnings(cq_tests_gfx_headers_compile)
add_test(NAME gfx_headers_compile COMMAND cq_tests_gfx_headers_compile)

# ---- MEDIA-010：跨平台 FrameProvider 头文件编译期自洽验证（零平台类型 / 精确 seek / 钩子）----
# 仅包含 cq/media/frame_provider.h + static_assert，不链接实现（接口定义阶段无实现）。
add_executable(cq_tests_media_frame_provider_compile
    unit/media/media_frame_provider_compile.cpp)
target_include_directories(cq_tests_media_frame_provider_compile PRIVATE
    ${CMAKE_SOURCE_DIR}/engine/core)
cq_require_cxx20(cq_tests_media_frame_provider_compile)
apply_cq_warnings(cq_tests_media_frame_provider_compile)
add_test(NAME media_frame_provider_compile COMMAND cq_tests_media_frame_provider_compile)

# ---- MEDIA-020：SystemFrameProvider 编排逻辑单测（Mock 驱动，不依赖平台后端）----
# 用 MockDemuxer + MockDecoder 注入带 B 帧的小 GOP，验证精确 seek 编排
# （kExact 命中真正展示帧含 B 帧 / kKeyframeBefore 取关键帧 / kNearest 取最近 /
#  取消返回 kCancelled 非错误 / 显示区间归属）。平台无关，全平台可跑。
add_executable(cq_tests_media_system_frame_provider
    unit/media/test_system_frame_provider.cpp)
target_include_directories(cq_tests_media_system_frame_provider PRIVATE
    ${CMAKE_SOURCE_DIR}/engine/core)
target_link_libraries(cq_tests_media_system_frame_provider PRIVATE cq_core)
cq_require_cxx20(cq_tests_media_system_frame_provider)
apply_cq_warnings(cq_tests_media_system_frame_provider)
add_test(NAME media_system_frame_provider COMMAND cq_tests_media_system_frame_provider)

# ---- MEDIA-021：顺序取帧快路径（不每帧 seek 重解 GOP）----
# P38 修复的编排层单测：多 GOP Mock（4×IPBB）驱动，逐帧 pts 断言 + seek/flush
# 计数（学习期后顺序请求不再 seek）。验收对照 TASK-MEDIA-021：顺序递进 / 同帧
# 重复 / 回退 / 超阈值跳转 / 混合序列 vs 参照实现逐帧一致 / kKeyframeBefore 不受
# 影响 / 取消恢复 / 显式 Seek 契约。平台无关，全平台可跑。
add_executable(cq_tests_media_sequential_acquire
    unit/media/test_media_sequential_acquire.cpp)
target_include_directories(cq_tests_media_sequential_acquire PRIVATE
    ${CMAKE_SOURCE_DIR}/engine/core)
target_link_libraries(cq_tests_media_sequential_acquire PRIVATE cq_core)
cq_require_cxx20(cq_tests_media_sequential_acquire)
apply_cq_warnings(cq_tests_media_sequential_acquire)
add_test(NAME media_sequential_acquire COMMAND cq_tests_media_sequential_acquire)

# ---- MEDIA-011：LruFrameCache 帧缓存池（LRU + 内存上界 + lease 保护）----
# 跨平台，无平台后端。实测：插入超上界后 UsedBytes() <= 上界、LRU 淘汰最久未用、
# 借出的帧不被淘汰（move-out）、接入 SystemFrameProvider 命中缓存跳过解码。
add_executable(cq_tests_media_cache
    unit/media/test_cache.cpp)
target_include_directories(cq_tests_media_cache PRIVATE
    ${CMAKE_SOURCE_DIR}/engine/core)
target_link_libraries(cq_tests_media_cache PRIVATE cq_core)
cq_require_cxx20(cq_tests_media_cache)
apply_cq_warnings(cq_tests_media_cache)
add_test(NAME media_cache COMMAND cq_tests_media_cache)

# ---- MEDIA-012：DecoderPool 解码器池（硬解路数上限 + 超路数降级）----
# 跨平台，无平台后端。实测：超路数返回 kResourceExhausted（不崩溃/不挂起）、释放后复用
# （同一 handle）、ActiveCount/MaxHardwarePaths 符合预期、并发借/还无挂起、接入 provider。
add_executable(cq_tests_media_decoder_pool
    unit/media/test_decoder_pool.cpp)
target_include_directories(cq_tests_media_decoder_pool PRIVATE
    ${CMAKE_SOURCE_DIR}/engine/core)
target_link_libraries(cq_tests_media_decoder_pool PRIVATE cq_core)
cq_require_cxx20(cq_tests_media_decoder_pool)
apply_cq_warnings(cq_tests_media_decoder_pool)
add_test(NAME media_decoder_pool COMMAND cq_tests_media_decoder_pool)

# ---- CORE-006：Platform 头文件「零平台类型 / 零 FFmpeg 类型」静态门禁 ----
# 纯 stdlib python3 脚本：先剥离注释与字符串字面量（避免评论/字符串误报），
# 再匹配平台类型 / 平台头文件 / FFmpeg 类型 / throw / 裸 double（time 统一用 RationalTime）。
# 违规时非零退出（EXIT=1）。已自测证明有效：临时插入 jobject 必被捕获，回退后恢复绿。
# 脚本默认扫描 engine/core/cq/platform（按脚本自身位置做路径推导），故无需额外参数。
find_package(Python3 COMPONENTS Interpreter)
if(Python3_Interpreter_FOUND)
    add_test(NAME platform_header_gate
        COMMAND ${Python3_EXECUTABLE}
                ${CMAKE_SOURCE_DIR}/tools/platform/check_platform_headers.py)
endif()

# ---- PALA-001：Apple Metal 后端离屏渲染 + 读回像素验证 ----
# 仅在 Apple 平台构建。链接 cq_platform_apple（Metal 实现）与 cq_core，证明：
#   * 用例 A：清屏红 -> 读回中心像素 = (255,0,0,255)
#   * 用例 B：全屏采样四色纹理 -> 读回四角 = 红/绿/蓝/黄（采样管线真的通）
# 测试 TU 为纯 C++，只通过 platform/apple 内部辅助（ReadRenderTargetPixels / UploadTextureData）
# 接触 Metal，不污染内核头。
if(APPLE)
    add_executable(cq_tests_platform_apple_metal
        unit/gfx/test_gfx_metal.cpp)
    target_include_directories(cq_tests_platform_apple_metal PRIVATE
        ${CMAKE_SOURCE_DIR}/engine/core
        ${CMAKE_SOURCE_DIR}/engine/platform/apple)
    target_link_libraries(cq_tests_platform_apple_metal PRIVATE cq_core cq_platform_apple)
    cq_require_cxx20(cq_tests_platform_apple_metal)
    apply_cq_warnings(cq_tests_platform_apple_metal)
    add_test(NAME platform_apple_metal_render COMMAND cq_tests_platform_apple_metal)

    # ---- GFX-002：IGfxDevice 直连 Platform（渲染结果读回断言，不只查返回值）----
    add_executable(cq_tests_gfx_device
        unit/gfx/test_gfx_device.cpp)
    target_include_directories(cq_tests_gfx_device PRIVATE
        ${CMAKE_SOURCE_DIR}/engine/core
        ${CMAKE_SOURCE_DIR}/engine/platform/apple)
    target_link_libraries(cq_tests_gfx_device PRIVATE cq_core cq_platform_apple)
    cq_require_cxx20(cq_tests_gfx_device)
    apply_cq_warnings(cq_tests_gfx_device)
    add_test(NAME gfx_device COMMAND cq_tests_gfx_device)

    # ---- PALA-010：Apple 解封装后端真实文件验证 ----
    add_executable(cq_tests_platform_apple_demux
        unit/media/test_media_demux_apple.cpp)
    target_include_directories(cq_tests_platform_apple_demux PRIVATE
        ${CMAKE_SOURCE_DIR}/engine/core)
    target_compile_definitions(cq_tests_platform_apple_demux PRIVATE
        CQ_SOURCE_DIR="${CMAKE_SOURCE_DIR}")
    target_link_libraries(cq_tests_platform_apple_demux PRIVATE cq_core cq_platform_apple)
    cq_require_cxx20(cq_tests_platform_apple_demux)
    apply_cq_warnings(cq_tests_platform_apple_demux)
    add_test(NAME platform_apple_demux COMMAND cq_tests_platform_apple_demux)

    # demux 测试直接用到的 Apple 框架（确保最终可执行链接到 CoreMedia/AVFoundation）。
    find_library(AVFOUNDATION_T_LIB AVFoundation REQUIRED)
    find_library(COREMEDIA_T_LIB   CoreMedia    REQUIRED)
    target_link_libraries(cq_tests_platform_apple_demux PRIVATE
        ${AVFOUNDATION_T_LIB} ${COREMEDIA_T_LIB})

    # ---- MEDIA-020 真实链路冒烟：PALA-010 真实 demux + SystemFrameProvider ----
    # 半程打通：demux 真实通；解码后端（PALA-011）未实现，AcquireFrame 如实返回
    # kDecodeUnsupported，绝不 mock 伪造。仅 Apple 平台（需 PALA-010 后端）。
    add_executable(cq_tests_media_smoke_apple
        unit/media/test_media_smoke_apple.cpp)
    target_include_directories(cq_tests_media_smoke_apple PRIVATE
        ${CMAKE_SOURCE_DIR}/engine/core)
    target_compile_definitions(cq_tests_media_smoke_apple PRIVATE
        CQ_SOURCE_DIR="${CMAKE_SOURCE_DIR}")
    target_link_libraries(cq_tests_media_smoke_apple PRIVATE
        cq_core cq_platform_apple ${AVFOUNDATION_T_LIB} ${COREMEDIA_T_LIB})
    cq_require_cxx20(cq_tests_media_smoke_apple)
    apply_cq_warnings(cq_tests_media_smoke_apple)
    add_test(NAME media_smoke_apple COMMAND cq_tests_media_smoke_apple)

    # ---- MEDIA-020 真实 B 帧文件精确 seek（mock 升级为真实文件）----
    # 用真实 PALA-010 demuxer 读 gf_1080p_h264_long_gop_bframes.mp4（300 帧 / B 帧），
    # 经「仅按 pts 网格重排」的 MockDecoder 驱动 SystemFrameProvider，验证 kExact 能在
    # 真实「解码序≠显示序」分离下正确取到 t 处的展示帧（B 帧），而非关键帧/未重建包。
    add_executable(cq_tests_media_bframe_real
        unit/media/test_media_bframe_real_apple.cpp)
    target_include_directories(cq_tests_media_bframe_real PRIVATE
        ${CMAKE_SOURCE_DIR}/engine/core)
    target_compile_definitions(cq_tests_media_bframe_real PRIVATE
        CQ_SOURCE_DIR="${CMAKE_SOURCE_DIR}")
    target_link_libraries(cq_tests_media_bframe_real PRIVATE
        cq_core cq_platform_apple ${AVFOUNDATION_T_LIB} ${COREMEDIA_T_LIB})
    cq_require_cxx20(cq_tests_media_bframe_real)
    apply_cq_warnings(cq_tests_media_bframe_real)
    add_test(NAME media_bframe_real COMMAND cq_tests_media_bframe_real)

    # ---- PALA-002：Apple 零拷贝导入验收（CVPixelBuffer -> CVMetalTexture）----
    # 合成帧做 IOSurface 一致性 + 耗时代差证明零拷贝；并接 PALA-010+PALA-011 真实首帧
    # 经本 importer + PALA-001 渲染读回，对照真值 (0,188,0,255) 并验证 UV 原点不颠倒。
    # 测试 TU 直接调用 CoreVideo/IOSurface C API，需显式链接（避免链接期符号未定义）。
    find_library(COREVIDEO_T2_LIB CoreVideo REQUIRED)
    find_library(IOSURFACE_T2_LIB IOSurface REQUIRED)
    add_executable(cq_tests_platform_apple_native_image
        unit/media/test_native_image_importer_apple.cpp)
    target_include_directories(cq_tests_platform_apple_native_image PRIVATE
        ${CMAKE_SOURCE_DIR}/engine/core
        ${CMAKE_SOURCE_DIR}/engine/platform/apple)
    target_compile_definitions(cq_tests_platform_apple_native_image PRIVATE
        CQ_SOURCE_DIR="${CMAKE_SOURCE_DIR}")
    target_link_libraries(cq_tests_platform_apple_native_image PRIVATE
        cq_core cq_platform_apple
        ${AVFOUNDATION_T_LIB} ${COREMEDIA_T_LIB}
        ${COREVIDEO_T2_LIB} ${IOSURFACE_T2_LIB})
    cq_require_cxx20(cq_tests_platform_apple_native_image)
    apply_cq_warnings(cq_tests_platform_apple_native_image)
    add_test(NAME platform_apple_native_image COMMAND cq_tests_platform_apple_native_image)

    # ---- BIND-003 子步骤 4：预览渲染器端到端（Timeline+素材表 → 取帧 → 零拷贝 → 离屏 RT）----
    # 验收不是「返回 kOk」而是「画面真的是时间线在该时刻的内容」：
    #   blit pass 方向（RT 顶红/底蓝）+ 真值像素 (0,188,0,255) + 零拷贝未退化 +
    #   空隙 kIoNotFound + 素材未注册 kInvalidArgument + 连续多帧导入/释放 + Resize。
    find_library(COREVIDEO_T6_LIB CoreVideo REQUIRED)
    add_executable(cq_tests_preview_renderer
        unit/preview/test_preview_renderer.cpp)
    target_include_directories(cq_tests_preview_renderer PRIVATE
        ${CMAKE_SOURCE_DIR}/engine/core
        ${CMAKE_SOURCE_DIR}/engine/platform/apple)
    target_compile_definitions(cq_tests_preview_renderer PRIVATE
        CQ_SOURCE_DIR="${CMAKE_SOURCE_DIR}")
    target_link_libraries(cq_tests_preview_renderer PRIVATE
        cq_core cq_platform_apple
        ${AVFOUNDATION_T_LIB} ${COREMEDIA_T_LIB} ${COREVIDEO_T6_LIB})
    cq_require_cxx20(cq_tests_preview_renderer)
    apply_cq_warnings(cq_tests_preview_renderer)
    add_test(NAME preview_renderer COMMAND cq_tests_preview_renderer)

    # ---- RENDER-010：变换层 GPU 恒等回归（同一帧走 blit / 走 kTransform 两路读回比对）----
    add_executable(cq_tests_layer_identity
        unit/preview/test_layer_identity.cpp)
    target_include_directories(cq_tests_layer_identity PRIVATE
        ${CMAKE_SOURCE_DIR}/engine/core
        ${CMAKE_SOURCE_DIR}/engine/platform/apple)
    target_link_libraries(cq_tests_layer_identity PRIVATE
        cq_core cq_platform_apple ${COREVIDEO_T6_LIB})
    cq_require_cxx20(cq_tests_layer_identity)
    apply_cq_warnings(cq_tests_layer_identity)
    add_test(NAME layer_identity COMMAND cq_tests_layer_identity)

    # ---- BIND-003 子步骤 5：预览 C ABI（**真正的 C 翻译单元**）----
    # 与 core 侧 test_c_abi.c 同性质：只要 cq_sdk.h 混进 C++ 类型，本 TU 就编译失败。
    # 分工：本用例验证 C ABI 契约（句柄/状态码/诊断量）；像素正确性由
    # preview_renderer（C++）用例覆盖——读回像素要用 Apple 内部辅助，C 侧做不到。
    add_executable(cq_tests_c_abi_preview
        unit/abi/test_c_abi_preview.c)
    set_target_properties(cq_tests_c_abi_preview PROPERTIES LINKER_LANGUAGE CXX)
    target_include_directories(cq_tests_c_abi_preview PRIVATE
        ${CMAKE_SOURCE_DIR}/engine/core)
    target_compile_definitions(cq_tests_c_abi_preview PRIVATE
        CQ_SOURCE_DIR="${CMAKE_SOURCE_DIR}")
    # 链 cq_platform_apple：预览 ABI 的创建路径要经 Platform 的图形设备 / blit pass / 帧提供器。
    target_link_libraries(cq_tests_c_abi_preview PRIVATE
        cq_core cq_platform_apple
        ${AVFOUNDATION_T_LIB} ${COREMEDIA_T_LIB})
    add_test(NAME c_abi_preview COMMAND cq_tests_c_abi_preview)

    # ---- PALA-012：Apple 编码与封装验收（AVAssetWriter + PixelBufferAdaptor）----
    # 端到端：PALA-010 真实 demux + PALA-011 硬解 -> AppleVideoEncoder 写 H.264 MP4 ->
    # 重解码输出首帧中心像素对照 (0,188,0,255) + popen ffprobe 验证 codec/分辨率/帧数/时长。
    # 测试 TU 直接调用 CoreVideo C API 读像素，需显式链接 CoreVideo（经 cq_platform_apple PUBLIC 传递）。
    find_library(COREVIDEO_T3_LIB CoreVideo REQUIRED)
    add_executable(cq_tests_platform_apple_encode
        unit/media/test_media_encode_apple.cpp)
    target_include_directories(cq_tests_platform_apple_encode PRIVATE
        ${CMAKE_SOURCE_DIR}/engine/core
        ${CMAKE_SOURCE_DIR}/engine/platform/apple)
    target_compile_definitions(cq_tests_platform_apple_encode PRIVATE
        CQ_SOURCE_DIR="${CMAKE_SOURCE_DIR}")
    target_link_libraries(cq_tests_platform_apple_encode PRIVATE
        cq_core cq_platform_apple
        ${AVFOUNDATION_T_LIB} ${COREMEDIA_T_LIB} ${COREVIDEO_T3_LIB})
    cq_require_cxx20(cq_tests_platform_apple_encode)
    apply_cq_warnings(cq_tests_platform_apple_encode)
    add_test(NAME platform_apple_encode COMMAND cq_tests_platform_apple_encode)

    # ---- muxer 接缝：平台无关 IMediaMuxer 经工厂调用导出 H.264 MP4 ----
    # 全程只通过 core 冻结接口 IMediaMuxer + CreateMediaMuxer 完成导出（不碰 AppleVideoEncoder），
    # 证明导出能力可被上层平台无关调用；ffprobe 验证 codec/分辨率/帧数/时长 + 首帧像素。
    find_library(COREVIDEO_T4_LIB CoreVideo REQUIRED)
    add_executable(cq_tests_platform_apple_muxer
        unit/media/test_media_muxer_apple.cpp)
    target_include_directories(cq_tests_platform_apple_muxer PRIVATE
        ${CMAKE_SOURCE_DIR}/engine/core
        ${CMAKE_SOURCE_DIR}/engine/platform/apple)
    target_compile_definitions(cq_tests_platform_apple_muxer PRIVATE
        CQ_SOURCE_DIR="${CMAKE_SOURCE_DIR}")
    target_link_libraries(cq_tests_platform_apple_muxer PRIVATE
        cq_core cq_platform_apple
        ${AVFOUNDATION_T_LIB} ${COREMEDIA_T_LIB} ${COREVIDEO_T4_LIB})
    cq_require_cxx20(cq_tests_platform_apple_muxer)
    apply_cq_warnings(cq_tests_platform_apple_muxer)
    add_test(NAME platform_apple_muxer COMMAND cq_tests_platform_apple_muxer)

    # ---- muxer 接缝：AAC 音频轨封装验收（合成 PCM -> AAC 音轨，ffprobe 验证）----
    # 端到端验证 IMediaMuxer::AddAudioTrack / WriteAudioFrame 真能产出含 aac 音轨的 MP4，
    # 且 codec=aac / 采样率 / 声道与 AudioTrackConfig 一致。仅 Apple 平台。
    find_library(COREVIDEO_T5_LIB CoreVideo REQUIRED)
    add_executable(cq_tests_platform_apple_muxer_audio
        unit/media/test_media_muxer_audio_apple.cpp)
    target_include_directories(cq_tests_platform_apple_muxer_audio PRIVATE
        ${CMAKE_SOURCE_DIR}/engine/core
        ${CMAKE_SOURCE_DIR}/engine/platform/apple)
    target_compile_definitions(cq_tests_platform_apple_muxer_audio PRIVATE
        CQ_SOURCE_DIR="${CMAKE_SOURCE_DIR}")
    target_link_libraries(cq_tests_platform_apple_muxer_audio PRIVATE
        cq_core cq_platform_apple
        ${AVFOUNDATION_T_LIB} ${COREMEDIA_T_LIB} ${COREVIDEO_T5_LIB})
    cq_require_cxx20(cq_tests_platform_apple_muxer_audio)
    apply_cq_warnings(cq_tests_platform_apple_muxer_audio)
    add_test(NAME platform_apple_muxer_audio COMMAND cq_tests_platform_apple_muxer_audio)

    # ---- CORE-007：Apple 能力后端（Metal / VideoToolbox 真实查询）----
    # 验证后端真的被装上、每项返回值合法，并打印全部结果供真机核对。
    # ⚠️ 本机 Intel Mac 无 ANE / 无 ProRes 硬编，本机结果不代表 iPhone 17 Pro。
    add_executable(cq_tests_platform_apple_capabilities
        unit/platform/test_capabilities_apple.cpp)
    target_include_directories(cq_tests_platform_apple_capabilities PRIVATE
        ${CMAKE_SOURCE_DIR}/engine/core
        ${CMAKE_SOURCE_DIR}/engine/platform/apple)
    target_link_libraries(cq_tests_platform_apple_capabilities PRIVATE cq_core cq_platform_apple)
    cq_require_cxx20(cq_tests_platform_apple_capabilities)
    apply_cq_warnings(cq_tests_platform_apple_capabilities)
    add_test(NAME platform_apple_capabilities COMMAND cq_tests_platform_apple_capabilities)
endif()
# ---- MODEL-001：时间线数据模型（Timeline / Track / Clip / Transition）----
# 先于 UIA-003 落地：没有它，预览就不知道"播放头在哪、该显示哪个片段"。
# 验收：多轨共存、跨轨重叠允许、同轨重叠拒绝、转场计入总时长。
add_executable(cq_tests_model_timeline
    unit/model/test_model_timeline.cpp)
target_include_directories(cq_tests_model_timeline PRIVATE
    ${CMAKE_SOURCE_DIR}/engine/core)
target_link_libraries(cq_tests_model_timeline PRIVATE cq_core)
cq_require_cxx20(cq_tests_model_timeline)
apply_cq_warnings(cq_tests_model_timeline)
add_test(NAME model_timeline COMMAND cq_tests_model_timeline)

# ---- MODEL-002：Command / CommandHistory（Undo/Redo）----
# 验收（BACKLOG）：100 次 undo 后回到初始态；另覆盖 6 类命令往返、
# 原 id 恢复、失败不入历史、失败不清 redo、排序不变量。
add_executable(cq_tests_model_command
    unit/command/test_model_command.cpp)
target_include_directories(cq_tests_model_command PRIVATE
    ${CMAKE_SOURCE_DIR}/engine/core)
target_link_libraries(cq_tests_model_command PRIVATE cq_core)
cq_require_cxx20(cq_tests_model_command)
apply_cq_warnings(cq_tests_model_command)
add_test(NAME model_command COMMAND cq_tests_model_command)

# ---- MODEL-003：效果属性系统（属性值/袋/栈、四条属性命令、digest 覆盖）----
# 验收：类型安全读取（不猜不转）、指纹与插入序无关、栈保序与重复拒绝、
# Do/Undo/Redo 往返（含"新建参数撤销后无幽灵"）、50 深往返指纹回初始态、
# digest 真断言（同值 set 只推进版本不变 digest）、与轨级标志正交。
# 只链 cq_core：属性是纯模型层能力，不牵出任何 Platform 依赖。
add_executable(cq_tests_model_property
    unit/model/test_model_property.cpp)
target_include_directories(cq_tests_model_property PRIVATE
    ${CMAKE_SOURCE_DIR}/engine/core)
target_link_libraries(cq_tests_model_property PRIVATE cq_core)
cq_require_cxx20(cq_tests_model_property)
apply_cq_warnings(cq_tests_model_property)
add_test(NAME model_property COMMAND cq_tests_model_property)

# ---- MODEL-004：空间与交互地基（变换/层级/变速/关键帧，B5.5）----
# 验收：默认值恒等、取值域校验（NaN/Inf/负 scale/layer 越界）、
# 改画布比例按约定同步修正（像素守恒 + 浮点反比不保证可逆的实测对照）、
# speed 整数比可逆、关键帧升序不变量与片段局部时刻、SplitClip 分箱、
# 六条命令往返（含"无幽灵空帧"）、digest 覆盖四组字段、
# 20 轮变换+画布后 40 次 Undo 指纹回初始态。
add_executable(cq_tests_model_transform
    unit/model/test_model_transform.cpp)
target_include_directories(cq_tests_model_transform PRIVATE
    ${CMAKE_SOURCE_DIR}/engine/core)
target_link_libraries(cq_tests_model_transform PRIVATE cq_core)
cq_require_cxx20(cq_tests_model_transform)
apply_cq_warnings(cq_tests_model_transform)
add_test(NAME model_transform COMMAND cq_tests_model_transform)

# ---- MODEL-003：效果属性 C ABI（真正的 C 翻译单元）----
# 与 test_c_abi_edit.c 同性质：cq_sdk.h 混进 C++ 类型即编译失败。
# 端到端覆盖：add/remove/enabled/五类参数 setter、两段式查询、
# undo 整栈还原、digest 端到端变化、失败语义与同步参数校验。
add_executable(cq_tests_c_abi_property
    unit/abi/test_c_abi_property.c)
set_target_properties(cq_tests_c_abi_property PROPERTIES LINKER_LANGUAGE CXX)
target_include_directories(cq_tests_c_abi_property PRIVATE
    ${CMAKE_SOURCE_DIR}/engine/core)
target_link_libraries(cq_tests_c_abi_property PRIVATE cq_core)
add_test(NAME c_abi_property COMMAND cq_tests_c_abi_property)

# ---- BIND-003 子步骤 1：素材表（asset_id → MediaSource）----
# 重点：验证 unordered_map 重哈希后 MediaSource.path 裸指针仍然有效（SSO 陷阱）。
add_executable(cq_tests_asset_registry
    unit/media/test_asset_registry.cpp)
target_include_directories(cq_tests_asset_registry PRIVATE
    ${CMAKE_SOURCE_DIR}/engine/core)
target_link_libraries(cq_tests_asset_registry PRIVATE cq_core)
cq_require_cxx20(cq_tests_asset_registry)
apply_cq_warnings(cq_tests_asset_registry)
add_test(NAME asset_registry COMMAND cq_tests_asset_registry)

# ---- BIND-003 子步骤 2：取帧链路真实验证（Platform + 硬解）----
# 用 golden 真实文件证明"给定素材+时间戳 → 真实解码帧"可用，
# 并断言不同时刻 pts 不同（暴露"假 seek"：反复返回同一帧）。
if(APPLE)
    add_executable(cq_tests_frame_provider_apple
        unit/media/test_frame_provider_apple.cpp)
    target_include_directories(cq_tests_frame_provider_apple PRIVATE
        ${CMAKE_SOURCE_DIR}/engine/core
        ${CMAKE_SOURCE_DIR}/engine/platform/apple)
    target_compile_definitions(cq_tests_frame_provider_apple PRIVATE
        CQ_SOURCE_DIR="${CMAKE_SOURCE_DIR}")
    target_link_libraries(cq_tests_frame_provider_apple PRIVATE cq_core cq_platform_apple)
    cq_require_cxx20(cq_tests_frame_provider_apple)
    apply_cq_warnings(cq_tests_frame_provider_apple)
    add_test(NAME frame_provider_apple COMMAND cq_tests_frame_provider_apple)

    # ---- MEDIA-021：顺序取帧快路径真实链路（P38 修复端到端验收）----
    # golden long_gop_bframes（30fps/GOP60/B帧3）顺序 120 帧：逐帧 pts 严格递增 +
    # 区间归属 + 与「每帧显式 seek」对照实例逐帧一致；输出两段 acquire 均值/最大值
    # （写回 .ai/memory/baselines.md）。性能断言宽松（fast < slow），倍数不写死。
    add_executable(cq_tests_media_sequential_real
        unit/media/test_media_sequential_real_apple.cpp)
    target_include_directories(cq_tests_media_sequential_real PRIVATE
        ${CMAKE_SOURCE_DIR}/engine/core
        ${CMAKE_SOURCE_DIR}/engine/platform/apple)
    target_compile_definitions(cq_tests_media_sequential_real PRIVATE
        CQ_SOURCE_DIR="${CMAKE_SOURCE_DIR}")
    target_link_libraries(cq_tests_media_sequential_real PRIVATE cq_core cq_platform_apple)
    cq_require_cxx20(cq_tests_media_sequential_real)
    apply_cq_warnings(cq_tests_media_sequential_real)
    add_test(NAME media_sequential_real COMMAND cq_tests_media_sequential_real)
endif()

# ---- PALA-011：Apple 硬解后端（VideoToolbox）----
# ⚠️ 本文件此前**只存在于磁盘、从未接入 CMake** —— 即它从来没被执行过，
#    属于"只声明未接入"的老毛病（等同 cq_build_anchor / 能力查询 / BIND-001 实现那几次）。
#    此处补齐注册，让它真正跑起来。
if(APPLE)
    add_executable(cq_tests_platform_apple_decode
        unit/media/test_media_decode_apple.cpp)
    target_include_directories(cq_tests_platform_apple_decode PRIVATE
        ${CMAKE_SOURCE_DIR}/engine/core
        ${CMAKE_SOURCE_DIR}/engine/platform/apple)
    target_compile_definitions(cq_tests_platform_apple_decode PRIVATE
        CQ_SOURCE_DIR="${CMAKE_SOURCE_DIR}")
    target_link_libraries(cq_tests_platform_apple_decode PRIVATE cq_core cq_platform_apple)
    cq_require_cxx20(cq_tests_platform_apple_decode)
    apply_cq_warnings(cq_tests_platform_apple_decode)
    add_test(NAME platform_apple_decode COMMAND cq_tests_platform_apple_decode)
endif()

# ---- AUDIO-001：音频缓冲池 + SPSC 无锁样本环 + AudioGraph 骨架 ----
# 验收核心是 ARCH-001 铁律 2「音频线程无锁无分配」**可测**：
# test_audio_graph 在 kAudio 标记线程上以全局 operator new 计数实测增量为 0。
# 另覆盖：池耗尽/重复归还防护、SPSC 跨线程 20 万序号压测、拓扑成环/断链拒绝。
add_executable(cq_tests_core_audio_pcm
    unit/audio/test_audio_pcm.cpp)
target_include_directories(cq_tests_core_audio_pcm PRIVATE
    ${CMAKE_SOURCE_DIR}/engine/core)
target_link_libraries(cq_tests_core_audio_pcm PRIVATE cq_core)
cq_require_cxx20(cq_tests_core_audio_pcm)
apply_cq_warnings(cq_tests_core_audio_pcm)
add_test(NAME core_audio_pcm COMMAND cq_tests_core_audio_pcm)

add_executable(cq_tests_core_audio_graph
    unit/audio/test_audio_graph.cpp)
target_include_directories(cq_tests_core_audio_graph PRIVATE
    ${CMAKE_SOURCE_DIR}/engine/core)
target_link_libraries(cq_tests_core_audio_graph PRIVATE cq_core)
cq_require_cxx20(cq_tests_core_audio_graph)
apply_cq_warnings(cq_tests_core_audio_graph)
add_test(NAME core_audio_graph COMMAND cq_tests_core_audio_graph)

# ---- AUDIO-002：预览音频混音器 ----
# 全 core 确定性用例（假引擎/假读取器/假快照）：块网格连续、命中与混音、
# source_in 映射、EOF 诚实静音、暂停 Flush / 恢复重锚、muted 轨。
add_executable(cq_tests_core_audio_preview_mixer
    unit/audio/test_preview_mixer.cpp)
target_include_directories(cq_tests_core_audio_preview_mixer PRIVATE
    ${CMAKE_SOURCE_DIR}/engine/core)
target_link_libraries(cq_tests_core_audio_preview_mixer PRIVATE cq_core)
cq_require_cxx20(cq_tests_core_audio_preview_mixer)
apply_cq_warnings(cq_tests_core_audio_preview_mixer)
add_test(NAME core_audio_preview_mixer COMMAND cq_tests_core_audio_preview_mixer)

# ---- AUDIO-004：多轨混音原语 ----
# 增益语义（含 0/负/>1）、多轨累加顺序不敏感、硬削波与非有限值处置、
# 分码纪律（拒绝即不写内存，哨兵比对）、部分区间帧偏移、
# 音频线程零分配实测（operator new 增量 = 0）。
add_executable(cq_tests_core_audio_mix
    unit/audio/test_audio_mix.cpp)
target_include_directories(cq_tests_core_audio_mix PRIVATE
    ${CMAKE_SOURCE_DIR}/engine/core)
target_link_libraries(cq_tests_core_audio_mix PRIVATE cq_core)
cq_require_cxx20(cq_tests_core_audio_mix)
apply_cq_warnings(cq_tests_core_audio_mix)
add_test(NAME core_audio_mix COMMAND cq_tests_core_audio_mix)

# ---- AIEDIT-001：EditPlan 校验器 + golden 样例集（58 例）----
# 手写 JSON 解析 + 结构/语义校验；红线 4 时间浮点机器检查。
# golden 目录通过编译宏注入（测试二进制运行时读取 JSON 夹具）。
add_executable(cq_tests_ai_edit_plan
    unit/ai/test_edit_plan_validator.cpp)
# 私有头 edit_plan_validator.h 在 core/src 下（cq_core 的 PRIVATE include 不传播）。
target_include_directories(cq_tests_ai_edit_plan PRIVATE
    ${CMAKE_SOURCE_DIR}/engine/core
    ${CMAKE_SOURCE_DIR}/engine/core/cq)
target_compile_definitions(cq_tests_ai_edit_plan PRIVATE
    CQ_EDIT_PLAN_GOLDEN_DIR="${CMAKE_SOURCE_DIR}/tests/golden/edit_plan")
target_link_libraries(cq_tests_ai_edit_plan PRIVATE cq_core)
cq_require_cxx20(cq_tests_ai_edit_plan)
apply_cq_warnings(cq_tests_ai_edit_plan)
add_test(NAME ai_edit_plan COMMAND cq_tests_ai_edit_plan)

# ---- DEPS-012 冒烟切片：FFmpeg demux 探测 ----
# 验证 vendored FFmpeg（demux 档）真实可用。cq_ffmpeg target 由 third_party/
# CMakeLists.txt 定义（binary/source 双集成，同 target）。素材路径编译期注入，
# 元数据见 tests/golden/manifest.toml [[sample]] gf_1080p_h264。
add_executable(cq_tests_media_ffmpeg_probe
    unit/media/test_ffmpeg_probe.cpp)
target_compile_definitions(cq_tests_media_ffmpeg_probe PRIVATE
    CQ_TEST_GOLDEN_H264="${CMAKE_SOURCE_DIR}/tests/golden/frames/gf_1080p_h264.mp4")
target_link_libraries(cq_tests_media_ffmpeg_probe PRIVATE cq_core cq_ffmpeg)
cq_require_cxx20(cq_tests_media_ffmpeg_probe)
apply_cq_warnings(cq_tests_media_ffmpeg_probe)
add_test(NAME media_ffmpeg_probe COMMAND cq_tests_media_ffmpeg_probe)

# ---- RENDER-001（B0）：RenderGraph 单测 ----
# 纯逻辑用例（假 frame source / 假 encoder），不依赖 GPU：
# 覆盖图结构校验（含环检测）、指纹、装配器三用途、执行器两阶段与视口决策、时钟源。
# 真机/真 GPU 的像素一致性由 preview_renderer 用例守（跑完整链路）。
add_executable(cq_tests_render_graph
    unit/render/test_render_graph.cpp)
target_link_libraries(cq_tests_render_graph PRIVATE cq_core)
cq_require_cxx20(cq_tests_render_graph)
apply_cq_warnings(cq_tests_render_graph)
add_test(NAME render_graph COMMAND cq_tests_render_graph)

# ---- RENDER-010：变换层顶点烘焙单测 ----
# 恒等回归的**逐位**判据放在这里而不是像素比对：几何由 core 算，
# 各端拿到的是同一批顶点（放 shader 就把三端一致交给了着色器实现）。
add_executable(cq_tests_layer_geometry
    unit/render/test_layer_geometry.cpp)
target_link_libraries(cq_tests_layer_geometry PRIVATE cq_core)
cq_require_cxx20(cq_tests_layer_geometry)
apply_cq_warnings(cq_tests_layer_geometry)
add_test(NAME layer_geometry COMMAND cq_tests_layer_geometry)

# ============================================================================
# 用例分档（ADR-0046 决定 3）：LABELS "heavy"
# ----------------------------------------------------------------------------
# heavy = **需要真实素材文件或硬件 codec/Metal 链路**的用例。判据是**语义**的、不是秒数 ——
# 秒数随机器变（P171：同一用例两趟实测差 2×），语义不会；按"跑得慢"打标会在换机器那天静默变味。
#
# 档间分工写死在 tools/ci/run_gate.sh：Debug 档带 `--skip-label heavy`（开发自查/L0-L1），
# Release 档不带 → **heavy 的验收覆盖点唯一 = 集成机 Release 趟**。理由：出货产物就是 Release
# （build_core_apple.sh --config=Release 出的 xcframework），硬件链路本来就该在出货配置里验。
#
# ⚠️ 两个**有意不标**的例外（加新用例时别顺手照着时长补进来）：
#   · media_ffmpeg_probe —— 依赖第三方装配但 <1s，且它是 FFmpeg 链路的唯一功能证据，
#     留在 Debug 才能让 CI 的 Debug 步也跑到（INFRA-034 传哲认可的那个补法）。
#   · core_audio_preview_mixer / core_preview_pump —— 5.4s / 4.7s 是**实时等待**造成的，
#     两者纯 CPU（无素材、无平台类型，红线 #2），按语义规则不属 heavy。
# 改这里必须同步 ADR-0046 §决定 3 与 TASK-INFRA-043 的 heavy 清单（三处不一致就是漏跑的开端）；
# **名单真源是本变量**，文档只记增量（MODEL-004「活文档去死数」同一口径）。
set(CQ_HEAVY_TESTS
    media_sequential_acquire
    platform_apple_metal_render
    platform_apple_demux
    media_smoke_apple
    media_bframe_real
    platform_apple_native_image
    preview_renderer
    layer_identity
    c_abi_preview
    platform_apple_encode
    platform_apple_muxer
    platform_apple_muxer_audio
    frame_provider_apple
    media_sequential_real
    platform_apple_decode)
foreach(_t IN LISTS CQ_HEAVY_TESTS)
    # ⚠️ 必须写成 `if(TEST ${_t})`。`if(TEST _t)` 问的是"有没有一个叫 `_t` 这个字面的用例"，
    # **恒假** → 一个标签都打不上，而 `-LE heavy` 会"成功地"跑完全部用例：
    # 分档看起来生效（还更快），实际一点没减（P172，本仓第一次自测就撞在这行）。
    # 暴露它的正是 build_core.sh 里那句"把被跳过的名单打进日志"—— 名单为空当场说破。
    # if(TEST) 需要 CMake ≥3.16，本工程 cmake_minimum_required 是 3.21。
    # Apple 专属用例在非 Apple 配置里不存在，所以这里必须有守卫（无守卫 configure 直接报错）。
    if(TEST ${_t})
        set_tests_properties(${_t} PROPERTIES LABELS "heavy")
    endif()
endforeach()
