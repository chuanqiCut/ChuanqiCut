# tools/ — 构建与工具脚本目录（INFRA-001 占位骨架）
#
# 其子目录（build / shaders / ai / compliance）由各自任务实现：
#   tools/build/*      构建脚本（如 build_core_apple.sh，归 INFRA-002）
#   tools/shaders/*    shader 编译链脚本
#   tools/ai/*         上下文同步、任务模板（tools/ai/sync_context.py 已存在）
#   tools/compliance/* 协议扫描、SBOM 生成
# 此处仅注册占位 target。
add_custom_target(cq_tools
    COMMENT "Build & tooling scripts (placeholder)")
