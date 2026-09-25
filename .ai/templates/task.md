# TASK-<ID>：<标题>

> 模板。缺任一项不得进入编码。

```yaml
id:          TASK-<ID>
layer:       SDK | 跨平台 | UI | 基建
goal:        <一句话目标>
input:       [<Spec / 接口 / 模块文档>]
output:      [<代码 / 测试 / 文档更新>]
write_set:   <唯一写入范围，与其他任务不得相交>
read_set:    <只读范围>
deps:        [<TASK-ID>...]
acceptance:
  - <可机器判定>
  - <可机器判定>
verification:
  - <具体命令>
risk:        <主要风险与缓解>
parallel:    true | false
```

## 背景
<为什么做，链接 Spec / ADR>

## 实现要点
<关键设计，不超过一屏>

## 验收
<逐条对应 acceptance，写明如何验证>

## 回写
任务结束后必须回写：
- 架构事实 / 接口变更 → `.ai/modules/*.md` 或新增 ADR
- 故障与排障步骤 → `.ai/memory/pitfalls.md`
- 实测数据 → `.ai/memory/baselines.md`
