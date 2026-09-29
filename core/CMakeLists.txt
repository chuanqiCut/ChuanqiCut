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
    src/cq_build_anchor.cpp
    src/base/status.cpp
    src/base/time.cpp
    src/base/log.cpp
    src/base/alloc.cpp
    src/base/concurrency.cpp
    src/base/perf.cpp
    src/media/cache.cpp
    src/media/decoder_pool.cpp
    src/media/system_frame_provider.cpp
    # CORE-007：能力查询内核侧实现（SetCapabilitiesBackend / QueryCapability）。
    # CORE-006 只冻结了头文件，这两个函数长期只有声明无定义；单测里的 static_assert
    # 是编译期检查、不链接，所以 CTest 全绿也看不出来。此处补上实现。
    src/pal/capabilities.cpp
    # CORE-008：线程角色体系 + 串行任务执行器（Session Thread 骨架，ARCH-001 §6）。
    # base 层的 concurrency.h 明确不提供线程池，这里接住。
    src/session/thread_model.cpp
    src/session/task_runner.cpp
    # CORE-009：EditorSession 门面与快照机制（对外唯一门面，BIND-001 要冻结的对象）。
    src/session/editor_session.cpp)

# 公共头目录：对外 C ABI 伞形头 core/include。
target_include_directories(cq_core PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include)

# 硬锁 C++20 + 禁 GNU 扩展；强制项目警告集合并开 -Werror。
cq_require_cxx20(cq_core)
apply_cq_warnings(cq_core)
