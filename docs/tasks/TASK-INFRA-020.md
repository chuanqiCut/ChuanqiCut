# TASK-INFRA-020：ChuanqiCutDraft Pod 骨架（草稿域占位）

```yaml
id:          TASK-INFRA-020
layer:       基建
goal:        ADR-0031 阶段 5：草稿域骨架占位（PROJ-001 落地后填肉）
input:       [ADR-0031, PLAN-壳工程与功能Pod, PLAN-素材库草稿混排多轨（PROJ-005/UIA-029）]
output:      [packages/ChuanqiCutDraft/{podspec,Package.swift,Sources/DraftDomain.swift 占位}]
write_set:   apps/apple/packages/ChuanqiCutDraft/**
read_set:    docs/tasks/PLAN-素材库草稿混排多轨.md
deps:        [TASK-INFRA-013]
acceptance:
  - 骨架 swift build 过（占位域符号 ChuanqiCutDraftDomain）
  - 暂不进任何 Podfile（无消费者；首功能落地时接线并加 Assets 依赖）
verification:
  - (cd apps/apple/packages/ChuanqiCutDraft && swift build --disable-sandbox --scratch-path <root>/build/spm/ChuanqiCutDraft)
risk:    无（占位）
parallel:    true
```

## 验收（2026-10-07 实测）
骨架占位落盘；未接线（随 PROJ-001/PROJ-005 填肉时激活）。
