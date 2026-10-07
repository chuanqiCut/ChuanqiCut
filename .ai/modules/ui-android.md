# 模块：Android UI（Compose）

> **归属**：A 线（编辑器/UI） —— 归属表见 docs/tasks/PLAN-三线并行.md §1a / ADR-0029（双机分工与门禁跑批，2026-10-07）

**边界**：`apps/android/app/`、`apps/android/cqbind/`

## 原则
同 Apple：UI 不共享，共享会话与命令。全部业务逻辑经 JNI 到 C++ 内核。

## 硬约束
1. UI 不得直接改模型，走 Command
2. **时间线自绘**（Compose `Canvas`），不做组件堆叠
3. 预览用 `SurfaceView` / `TextureView` + `ANativeWindow`，**不经 UI 合成**
4. 处理返回键与手势导航
5. 缩略图/波形异步，主线程不解码

## 与 iOS 的差异
- 返回键语义、手势导航、权限模型不同
- 分区存储：不能绝对路径访问
- 生命周期：配置变更与进程重建要能恢复编辑状态（依赖项目自动保存）

## 验证
```bash
./gradlew :app:testDebugUnitTest
./gradlew :app:connectedAndroidTest   # 需设备
```

## 相关
ARCH-005、`UID-0xx` 任务

---

## 模块册（ADR-0030：任务/进度/测试门禁记录按模块归口）

> 本节由归属线更新（一机一线，天然单写者）；BACKLOG / pitfalls / baselines 等
> 全局册零直写（集成机阶段批落账）。新调研/规格/审查落 docs/ 原位，但必须在此登记指针。

### 任务与进度（在飞 + 近期；全量 DAG 见 TASK-BACKLOG）

| Task ID | 标题 | 状态 |
|---|---|---|
| — | 首次落账于下一阶段批；历史状态见 TASK-BACKLOG | — |

### 测试与门禁记录（阶段批）

| 日期 | 阶段/范围 | 结论（数字） |
|---|---|---|
| — | 未实测（本模块无独立阶段批记录） | — |

### 调研 · 决策 · 池指针

- BACKLOG §5（Phase 3 Android，P1 未启动）
