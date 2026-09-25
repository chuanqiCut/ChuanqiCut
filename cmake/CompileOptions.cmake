# ChuanqiCut — 集中编译选项（INFRA-002）
#
# 本文件是项目唯一允许定义“语言标准 / 优化基线”的地方。各模块 CMake 只能调用
# `cq_require_cxx20(target)`，禁止在模块里散写 -std= / CMAKE_CXX_STANDARD。
#
# 说明：根 CMakeLists.txt 已经全局 set(CMAKE_CXX_STANDARD 20 / REQUIRED / EXTENSIONS OFF)，
# 这里再提供 per-target 的显式函数，保证即便某个 target 脱离了全局标准也能被强制锁死，
# 并把“C++20 + 禁 GNU 扩展”的意图集中在一处，方便后续审计。

# 强制 target 使用 C++20，禁用 GNU 扩展（红线：CXX_EXTENSIONS OFF）。
# 注意：这不是建议，是硬锁。后续任何模块不得覆盖。
function(cq_require_cxx20 target)
    set_target_properties(${target} PROPERTIES
        CXX_STANDARD 20
        CXX_STANDARD_REQUIRED ON
        CXX_EXTENSIONS OFF)
endfunction()

# Release 配置开启 LTO（IPO），以满足 ARCH-001 §10 “零 warning（含 LTO）”门禁的
# Release 侧要求。Debug 不开，保证本地迭代速度。
# 注意：-Werror + LTO 组合可能让后续任务在“编译不过”上反复卡顿（见 TASK-INFRA-002 risk）。
# 缓解手段就是 Warnings.cmake 里固定的显式警告集合 + “只能改代码”红线，不靠 -Wno-* 逃逸。
set(CMAKE_INTERPROCEDURAL_OPTIMIZATION_RELEASE ON CACHE BOOL
    "Enable LTO/IPO for Release builds (ChuanqiCut)" FORCE)
