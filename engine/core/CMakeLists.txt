# core/ — C++20 共享内核（INFRA-002：真正可编译的静态库）
#
# 真实业务逻辑（base/model/gfx/render/media/audio/ai/project/export/session）由 CORE 系列任务实现。
# 本任务只把占位 target 升级成“能编译、能链接、能在 -Werror 下通过”的 cq_core 静态库，
# 并接入集中定义的 C++20 标准与警告集合。
#
# 编译选项集中定义在 cmake/ 下，模块里只调用函数，不散写 -std= / -Wxxx。

# 集中引入编译选项与警告集合（相对路径相对于本文件所在目录，故用 CMAKE_SOURCE_DIR）。
include(${CMAKE_SOURCE_DIR}/cmake/CompileOptions.cmake)
include(${CMAKE_SOURCE_DIR}/cmake/Warnings.cmake)

# cq_core：C++20 静态库。
# 当前仅含一个“构建锚点”翻译单元（build_anchor.cpp），
# 它不实现任何内核业务逻辑，只用于：(1) 让静态库非空、可链接；
# (2) 证明该 TU 在 -Werror 下能干净编译；(3) 给 smoke 测试提供可链接目标。
add_library(cq_core STATIC
    cq/chq_build_anchor.cpp
    cq/base/chq_status.cpp
    cq/base/chq_time.cpp
    cq/base/chq_log.cpp
    cq/base/chq_alloc.cpp
    cq/base/chq_concurrency.cpp
    cq/base/chq_perf.cpp
    cq/media/chq_cache.cpp
    cq/media/chq_decoder_pool.cpp
    cq/media/chq_system_frame_provider.cpp
    # CORE-007：能力查询内核侧实现（SetCapabilitiesBackend / QueryCapability）。
    # CORE-006 只冻结了头文件，这两个函数长期只有声明无定义；单测里的 static_assert
    # 是编译期检查、不链接，所以 CTest 全绿也看不出来。此处补上实现。
    cq/platform/chq_capabilities.cpp
    # CORE-008：线程角色体系 + 串行任务执行器（Session Thread 骨架，ARCH-001 §6）。
    # base 层的 chq_concurrency.h 明确不提供线程池，这里接住。
    cq/session/chq_thread_model.cpp
    cq/session/chq_task_runner.cpp
    # CORE-009：ChqEditorSession 门面与快照机制（对外唯一门面，BIND-001 要冻结的对象）。
    cq/session/chq_editor_session.cpp
    # BIND-001：cq_sdk.h 的 C ABI 实现。注意 BACKLOG 原写集只有头文件 ——
    # 但"只有声明无实现"是本项目踩过两次的坑，故一并补实现。
    cq/cq_sdk.cpp
    # MODEL-001：时间线数据模型（ChqTimeline / ChqTrack / ChqClip / Transition）。
    # 先于 UIA-003 落地：没有时间线模型，预览就没有"播放头在哪、该显示哪个片段"。
    cq/model/chq_timeline.cpp
    # MODEL-003：效果属性系统（属性值/属性袋/效果栈）。B0 渲染地基第二块：
    # 效果从此是数据而非硬编码分支；渲染消费归 RENDER-011，本批只立结构与撤销链。
    cq/model/chq_property.cpp
    # MODEL-002：Command 模式与 ChqCommandHistory（Undo/Redo）。
    # 红线 #5 的执行点：UI 变更全部经 Command；历史在 session 线程串行使用。
    cq/command/chq_command.cpp
    # UIA-009 子步骤 1：Session 的真实模型状态（ChqTimeline + 素材表 + 命令历史），
    # ChqISessionState 的模型层实现；每次成功变更发布不可变 ChqTimeline 快照（无锁读）。
    cq/model/chq_editor_model_state.cpp
    # BIND-003 子步骤 1：素材表（asset_id → ChqMediaSource）。
    # 补上 MODEL-001 留下的那一环：ChqMediaRef 只有 asset_id，预览要解码必须先查到媒体源。
    cq/media/chq_asset_registry.cpp
    # GFX-002 最小落地：ChqIGfxDevice / ChqIGfxEncoder 直连 Platform。
    # 不做 RenderGraph（RENDER-001）—— 预览只需要"渲染一帧"，
    # 节点图/依赖分析/pass 调度等真有多 pass 合成需求时再补。
    cq/gfx/chq_gfx_device.cpp
    # RENDER-001（B0 渲染地基）：RenderGraph —— 节点 DAG + 拓扑排序（含环检测）、
    # 装配器（预览/导出/纯音频三图同源，红线 #9 的可执行形式）、执行器（CPU 取帧 /
    # GPU 编码两阶段）、时钟源（预览=墙钟 Pull，导出=步进）。
    # ⚠️ 这四个 TU **不调任何 Platform 工厂**（只用 GFX/Platform 的接口指针），
    #    故可以安全进 cq_core，不会给不消费渲染的目标牵出 Platform 依赖
    #    （静态库按 archive member 拉符号，见 ADR-0011）。
    cq/render/chq_clock_source.cpp
    cq/render/chq_render_graph.cpp
    cq/render/chq_graph_assembler.cpp
    cq/render/chq_render_evaluator.cpp
    # BIND-003 子步骤 4：预览渲染器（ChqTimeline + ChqAssetRegistry + 取帧 + 零拷贝导入 → 离屏 RT）。
    # 平台无关：取帧走 ChqIFrameProviderFactory 接缝、绘制走 ChqIBlitPass 接缝。
    cq/preview/chq_preview_renderer.cpp
    # BIND-003 子步骤 5：把 Platform 的 ChqIFrameProvider 适配成 core 的 ChqFrameProvider。
    # ⚠️ 本 TU 是 core 中首个调用 Platform 工厂者，**必须单独成 TU**：静态库按 archive
    #    member 粒度拉符号，独立 TU 才能保证「不用预览的目标」不牵出 Platform 依赖。
    cq/media/chq_platform_frame_provider.cpp
    # BIND-003 子步骤 5：预览的 C ABI 实现。同理必须单独成 TU（同上）。
    cq/preview/chq_sdk_preview.cpp
    # UIA-009 子步骤 3：媒体时长探测 C ABI。调 Platform 工厂链路
    # （ChqPlatformFrameProviderFactory::Create），单独成 TU（ADR-0011 规则 1）。
    cq/media/chq_media_probe_abi.cpp
    # UIA-010：播放时钟 —— 时刻 = 墙钟的函数（非帧数累加），帧网格量化。
    # 平台无关（只用 steady_clock + 有理数），不碰 Platform / Metal。
    cq/preview/chq_player_clock.cpp
    # UIA-010 子步骤 5：预览取帧泵 —— 把 seek+解码+导入+离屏绘制搬到自有线程，
    # 主线程只做 blit + present。平台无关（只用 std::thread / mutex / condvar），
    # 帧源走 ChqIPreviewFrameSource 接缝，故可注入假实现做确定性并发测试。
    cq/preview/chq_preview_pump.cpp
    # AUDIO-001：音频地基 —— 预分配缓冲池（lock-free Treiber freelist）、
    # SPSC 无锁样本环、ChqAudioGraph 拓扑骨架（ARCH-001 铁律 2：音频线程无锁无分配，
    # 单测以 operator new 计数实测）。全部预分配，耗尽返回 ChqStatus 不扩容。
    cq/audio/chq_audio_graph.cpp
    cq/audio/chq_pcm_pool.cpp
    cq/audio/chq_spsc_ring.cpp
    # AUDIO-002：预览音频 —— 读取器接缝（core 契约 + 默认装配工厂）与
    # 预览混音器（时间线→PCM 编排，详见 chq_preview_mixer.h 时钟语义）。
    cq/audio/chq_track_reader.cpp
    cq/audio/chq_preview_mixer.cpp
    # AUDIO-004：多轨混音原语（float32 增益累加 + 硬削波，纯函数零分配）。
    # 预览混音器的内联求和/削波已切换到此实现 —— 全仓只有一套混音路径。
    cq/audio/chq_mix.cpp
    # AUDIO-002：音频预览 C ABI。引用 Platform 音频工厂符号的唯一 TU，
    # 单独成 TU（与 cq/preview/chq_sdk_preview.cpp 同一论证）：不消费音频
    # 预览的目标链接 cq_core 不牵出 Platform 音频依赖。
    cq/audio/chq_sdk_audio.cpp
    # AIEDIT-001：ChqEditPlan 校验器（手写 JSON 解析 + 结构/语义校验 + golden 样例）。
    # 契约头 core/cq/ai/ 与实现同域共置，通过 cq_core 的 include root 自动可见。
    cq/ai/plan/chq_edit_plan_validator.cpp
    # DEPS-012 冒烟切片：FFmpeg demux 探测。引用 FFmpeg 符号的唯一 TU，
    # 单独成 TU（ADR-0011 规则 1）：静态库按 archive member 拉符号，
    # 不消费 FFmpeg 的目标链接 cq_core 不会牵出 FFmpeg 依赖；
    # 消费方（本文件唯一 = test_ffmpeg_probe）须同时链 cq_ffmpeg。
    cq/media/chq_ffmpeg_probe.cpp)

# 版本号由 CMake 注入，不在 cq_sdk.h 里硬编码（否则必然与 project VERSION 漂移）。
target_compile_definitions(cq_core PRIVATE
    CQ_VERSION_MAJOR=${PROJECT_VERSION_MAJOR}
    CQ_VERSION_MINOR=${PROJECT_VERSION_MINOR}
    CQ_VERSION_PATCH=${PROJECT_VERSION_PATCH})

# CMake include root：保持 `#include "cq/..."`；真正对外发布的头仅 cq/cq_sdk.h，
# 由 ChuanqiCutCore.podspec / XCFramework staging 控制。
target_include_directories(cq_core PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR})
# 内核源码与内部头按功能共置在 core/cq/**；对 CMake 内部消费者维持
# `#include "cq/..."` 的稳定入口。CocoaPods 的 public/private 边界由 podspec 单独定义。

# 硬锁 C++20 + 禁 GNU 扩展；强制项目警告集合并开 -Werror。
cq_require_cxx20(cq_core)
apply_cq_warnings(cq_core)

# FFmpeg demux 档（DEPS-012/ADR-0036）：cq_ffmpeg target 由 third_party/CMakeLists.txt
# 定义（顶层已保证先于 core 注册）。PUBLIC 传递：ffmpeg_probe 消费方（如
# test_ffmpeg_probe）链 cq_core 时自动获得 cq_ffmpeg 的链接与头路径；
# 不消费 FFmpeg 的目标不受影响（静态库按 archive member 拉符号，见 ADR-0011）。
target_link_libraries(cq_core PUBLIC cq_ffmpeg)
