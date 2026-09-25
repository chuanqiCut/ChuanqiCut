# 模块：时间线模型与命令

**边界**：`core/src/model/`、`core/src/command/`、`core/src/anim/`

## 职责
Timeline / Track / Clip / Transition / EffectBinding 数据模型；Command 模式与 Undo/Redo；关键帧与插值引擎。

## 入口
- `TimelineModel` — 轨道、片段、转场、效果挂载
- `EditorCommand` / `CommandHistory` — **所有模型变更的唯一入口**
- `Keyframe<T>` / `AnimationChannel<T>` / 插值引擎 — Linear / Bezier / Hermite / Catmull-Rom

## 硬约束
1. **UI 不得直接修改模型**，一律走 `Command`。这是 Undo/Redo 与三端一致性的前提。
2. Command 只存"怎么撤销"（如 clipID + oldTime + newTime），不存数据拷贝。
3. 时间字段一律 `RationalTime`。
4. 模型序列化必须能往返（serialize → deserialize → 相等）。

## 验证
```bash
ctest -R model_command     # 100 次 undo 后回到初始态
ctest -R model_serialize   # 往返一致
ctest -R anim_interp       # 四种插值曲线正确性
```

## 相关
ADR-0006、`docs/tasks/TASK-BACKLOG.md` 的 `MODEL-0xx` / `ANIM-0xx`
