# third_party/ — 第三方依赖目录（INFRA-001 占位骨架）
#
# 本期不引入任何第三方依赖（任务硬约束）。依赖治理见 ARCH-002 与
# third_party/manifest.toml（由依赖治理任务维护，非本任务写集）。
# 后续任务在此通过 FetchContent / 源码集成注册 cq_third_party_* target。
add_custom_target(cq_third_party
    COMMENT "Third-party dependencies (placeholder; none introduced in INFRA-001)")
