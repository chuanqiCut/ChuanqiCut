---
name: cq-task-planning
description: 把已确认的 Spec 拆成可执行的 Task DAG，含依赖、写集、验收与验证命令。进入编码前必跑。
---

# 任务拆解

## 触发
Spec 已确认 / 有人要开始改代码但还没有任务定义。

## 流程
1. **先分类再拆 DAG**，五类节点：
   ```
   R（Research，只读）→ A（Architecture，文档/接口）
                    ↘ I（Implementation）
   I + T（Test/Eval）→ V（Review/Integration）
   ```
2. **先冻结契约**：若任务涉及共享接口（PAL、C ABI、GFX、manifest 格式），必须拆出一个独立的**契约任务**，下游任务依赖它。这是防止返工的关键。
3. **声明 write_set**，并检查：
   - 两个任务的 write_set 不得相交
   - 高冲突文件（`CMakeLists.txt`、`cq_sdk.h`、`*.pbxproj`、`build.gradle.kts`、`manifest.toml`）单独成任务或交给 Integrator
4. **每个节点补齐字段**（缺一不可）：
   `id / layer / goal / input / output / write_set / read_set / deps / acceptance / verification / risk / parallel`
5. **标注并行批次**：写集不相交的才可并行。明确列出"禁止并行"的理由。
6. **识别关键路径**：标出决定最早交付时间的那条链。

## 检查清单
- [ ] 每个任务都有可机器判定的验收标准
- [ ] 每个任务都有具体的验证命令
- [ ] write_set 不相交
- [ ] 共享接口已单独成为契约任务
- [ ] 依赖无环
- [ ] 关键路径已标出
- [ ] 涉及渲染/媒体/音频的任务已挂 `cq-media-pipeline` 的分析要求
- [ ] 涉及 shader 的任务已挂 `cq-shader-portability`
- [ ] 涉及依赖的任务已挂 `cq-dependency-governance`

## 输出
- 追加到 `docs/tasks/TASK-BACKLOG.md` 对应 Phase
- 每个实施任务单独建 `docs/tasks/TASK-<ID>.md`（模板 `.ai/templates/task.md`）
