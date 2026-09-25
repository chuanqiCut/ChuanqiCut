# TASK-CORE-001：RationalTime 与有理数时间运算

```yaml
id:          CORE-001
layer:       跨平台（SDK 内核）
goal:        实现有理数时间类型，彻底消除浮点秒带来的帧率漂移
input:       [ADR-0006, ARCH-001 §时间模型]
output:      [core/src/base/time.*, core/include/cq/base/time.h, 单测]
write_set:   core/src/base/time.*, core/include/cq/base/time.h, tests/core/test_time.cpp
read_set:    docs/decisions/ADR-0006-有理数时间与项目文件版本模型.md, .ai/modules/core.md
deps:        [INFRA-002]
acceptance:
  - 29.97fps（timescale=30000, 每帧 1001 tick）连续步进 10000 次，与理论值偏差为 0 tick（不是"小于 epsilon"，是 0）
  - 24 / 25 / 30 / 50 / 60 / 23.976 / 29.97 / 59.94 八种帧率各自步进 10000 次零漂移
  - `RationalTime` 不提供任何到浮点秒的隐式转换；需要浮点时必须显式调用且函数名含 `ToSeconds`
  - 加减、比较、取模、缩放（retime 用）全部以有理数运算完成，中间不落浮点
  - 跨 timescale 运算有显式规则（以最小公倍数对齐 or 显式指定目标 timescale），不允许静默转换
verification:
  - ctest -R core_time --output-on-failure
risk:        最容易犯的错是"为了打印方便"加一个隐式 double 转换，
             三个月后这个转换会渗进导出时长计算。缓解：类型不定义 operator double，
             ToSeconds 只用于日志与 UI 展示，并在注释中写明禁止进入计算路径。
parallel:    true           # 与 CORE-002~005 写集不相交
```

## 背景

原调研用浮点秒表示时间。RESEARCH-001 已判定这是错误：29.97 / 23.976 这类 NTSC 帧率无法被二进制浮点精确表示，长项目累积后会出现掉帧/重复帧。见 ADR-0006。

## 实现要点

- `struct RationalTime { int64_t value; int32_t timescale; }`，项目统一 timescale = 60000。
- 存储与运算全程 int64；`value` 用 int64 是为了支持长项目（>24 小时）不溢出——**请在实现时核算溢出边界并写进单测**。
- 化简：加减后要约分，但要约到**公共 timescale**而非最简分数，否则 timescale 会漂移成奇怪的值。
- 提供 `RationalTime::Rescale(target_timescale)`，非整除时**必须**显式指定舍入方向（`Floor` / `Ceil` / `Round`），不允许默认行为。这一点对 seek 语义很关键。
- 禁止 `operator double`。

## 验收

单测需覆盖八种帧率 × 长时间步进；另需一条溢出边界用例、一条跨 timescale 舍入方向用例。

## 回写

- 若发现 timescale=60000 在某些帧率下不够用 → 立即提 ADR 修正，不要就地改数字
- 实测的溢出边界 → `.ai/memory/baselines.md`
