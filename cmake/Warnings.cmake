# ChuanqiCut — 集中警告集合（INFRA-002）
#
# 本文件是项目唯一允许定义编译器警告的地方。各模块 CMake 只能调用
# `apply_cq_warnings(target)`，禁止在模块里散写 -Wxxx 或 -Wno-xxx。
#
# ╔══════════════════════════════════════════════════════════════════════╗
# ║ 红线：不允许随手关警告（禁止 -Wno-xxx / -Wno-error），只能改代码。       ║
# ║ 任何想要“临时关掉某个警告”的冲动，都必须改成修复代码或走 ADR 决策，   ║
# ║ 不允许在 CMake / 源码里加 -Wno-* 来让构建变绿。                         ║
# ║ 唯一例外：经架构评审（ADR）记录的新增警告特例，且必须带限期与理由。     ║
# ╚══════════════════════════════════════════════════════════════════════╝

# 显式启用的警告集合。Debug / Release 都生效。
# 选这些项的理由：
#   -Wall -Wextra        : 基础高信噪比警告，几乎无争议。
#   -Wconversion         : 隐式数值转换（如 int<-float、窄化）是视频管线里
#                          最隐蔽的 bug 来源之一，强制显式 static_cast。
#   -Wshadow             : 变量遮蔽在大型内核里极易引入逻辑错误。
#   -Wold-style-cast     : C 风格强转绕过类型系统，内核统一要求 C++ 风格 cast。
set(CQ_WARN_FLAGS
    -Wall
    -Wextra
    -Wconversion
    -Wshadow
    -Wold-style-cast
    CACHE STRING "ChuanqiCut explicit warning set" FORCE)

# 对指定 target 应用项目警告集合，并强制 -Werror（Debug / Release 都开）。
# 调用方：core / tests / 后续各模块 CMake。
function(apply_cq_warnings target)
    target_compile_options(${target} PRIVATE ${CQ_WARN_FLAGS} -Werror)
endfunction()
