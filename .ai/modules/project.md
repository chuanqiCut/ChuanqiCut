# 模块：项目文件与序列化

> **归属**：A 线（编辑器/UI；素材库/草稿域随 A） —— 归属表见 docs/tasks/PLAN-三线并行.md §1a / ADR-0029（双机分工与门禁跑批，2026-10-07）

**边界**：`core/src/project/`

## 结构
```
Project.chuanqicut/
├── manifest.json    # schema_version, app_version, created, modified
├── project.json     # 时间线（有理数时间）
├── undo_history/    # 可丢弃
├── assets/          # 媒体（相对路径 + 资产 ID）
└── cache/           # 缩略图/波形，可丢弃重建
```

## 硬约束
1. **时间一律 `{value, timescale}`**，禁止浮点秒（NTSC 精度）
2. `schema_version` 单调递增；**迁移器链** `Migrator_vN_to_vN+1`，每个迁移器必须有旧版本样本测试
3. 打开更高版本项目必须明确报错，**不得静默降级解析**
4. 自动保存：先写临时文件，再原子替换
5. **媒体引用用相对路径 + 资产 ID**，禁止绝对路径（否则跨设备/跨端打不开）
6. 跨端兼容：字节序、路径分隔符、数值精度在 schema 中明确定义

## 验证
```bash
ctest -R project_roundtrip    # 序列化往返一致
ctest -R project_migrate      # 每个迁移器样本测试
ctest -R project_autosave     # 写入中断不损坏
```

## 相关
ADR-0006、`PROJ-0xx` 任务

---

## 模块册（ADR-0030：任务/进度/测试门禁记录按模块归口）

> 本节由归属线更新（一机一线，天然单写者）；BACKLOG / pitfalls / baselines 等
> 全局册零直写（集成机阶段批落账）。新调研/规格/审查落 docs/ 原位，但必须在此登记指针。

### 任务与进度（在飞 + 近期；全量 DAG 见 TASK-BACKLOG）

| Task ID | 标题 | 状态 |
|---|---|---|
| PROJ-001~004 | 项目序列化 | 未开工（`core/src/project/` 零实现，草稿地基） |
| PROJ-005 | 草稿箱索引与生命周期 | 预占（§13，UI 落 ChuanqiCutDraft Pod） |

### 测试与门禁记录（阶段批）

| 日期 | 阶段/范围 | 结论（数字） |
|---|---|---|
| — | 未实测（本模块无独立阶段批记录） | — |

### 调研 · 决策 · 池指针

- PLAN-素材库草稿混排多轨 · ADR-0006（时间与版本模型）
