# 模块：项目文件与序列化

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
