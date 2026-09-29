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
#
# ⚠️ 覆盖开关：CQ_ENABLE_LTO_RELEASE（默认 ON）
#   原先直接 `set(... CACHE BOOL ... FORCE)`，FORCE 会在每次 configure 时把这个
#   cache 变量写回 ON，**命令行 -DCMAKE_INTERPROCEDURAL_OPTIMIZATION_RELEASE=OFF 无效**
#   （2026-09-29 实测：传了 OFF，cache 里仍是 ON，产出的 .o 还是 LTO bitcode）。
#   所以需要能被外部关闭时，必须走本项目的显式开关，而不是直接覆盖 CMake 内建变量。
#
#   什么时候要关 LTO：打包 XCFramework 时。
#   Release + LTO 产出的 .o 是 **bitcode-only**（头部 magic 0x0b17c0de + 'BC\xc0\xde'），
#   不是 Mach-O，`xcodebuild -create-xcframework` 解析不了，报
#   “unable to find any architecture information ... Unknown header: 0xb17c0de”。
#   这与 ENABLE_BITCODE 无关，不要往 -fembed-bitcode 方向排查。
#   分发的静态库带 LTO bitcode 也会强制消费者的 linker 版本匹配，属分发陷阱。
option(CQ_ENABLE_LTO_RELEASE "Enable LTO/IPO for Release builds (ChuanqiCut)" ON)
if(CQ_ENABLE_LTO_RELEASE)
    set(CMAKE_INTERPROCEDURAL_OPTIMIZATION_RELEASE ON CACHE BOOL
        "Enable LTO/IPO for Release builds (ChuanqiCut)" FORCE)
else()
    set(CMAKE_INTERPROCEDURAL_OPTIMIZATION_RELEASE OFF CACHE BOOL
        "Enable LTO/IPO for Release builds (ChuanqiCut)" FORCE)
endif()
