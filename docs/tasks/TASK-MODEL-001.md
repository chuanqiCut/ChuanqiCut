# TASK-MODEL-001：时间线数据模型（Timeline / Track / Clip / Transition）

> 日期：2026-10-01
> 状态：**进行中**
> 依赖：CORE-001 ✅
> 写集：`core/include/cq/model/`、`core/src/model/`、`tests/unit/test_model_timeline.cpp`
> 验收：模型覆盖多轨 / 转场

---

## 1. 为什么先做这个

UIA-003 的预览需要"当前播放头的画面"。调研发现即使把 C ABI 渲染接口做完，
**没有时间线模型就没有"播放头在哪、该显示哪个片段"**，预览区必然是空的。
故按 1→2→3→4 顺序，先落地 MODEL-001。

## 2. 设计决策

| 决策 | 选择 | 理由 |
|---|---|---|
| 时间表示 | `RationalTime`，项目网格 timescale = **120000** | ADR-0009（修订 ADR-0006 的 60000）。禁止浮点秒 |
| Clip 语义 | **值语义**（可拷贝），Timeline 持有 `vector<Clip>` | 简化所有权；MODEL-002 的 Command 需要拷贝旧值做 undo |
| ID | `uint64_t`，由 Timeline 统一分配 | 避免调用方自造 ID 冲突 |
| 同轨重叠 | **不允许**，插入冲突返回 `kInvalidArgument` | 同轨重叠语义含糊（谁覆盖谁？），干脆拒绝 |
| 跨轨重叠 | **允许**（这才是"多轨"的意义） | 视频轨叠在视频轨之上正是合成 |
| 转场 | 挂在 **Clip 边界**（`Transition` 记录在 clip 上） | 独立转场对象会引入"转场也是时间线元素"的第二套时间语义，暂不引入 |
| 错误 | 一律 `Status`，**不抛异常** | 内核禁用异常（ARCH-001） |
| 平台类型 | 零（纯 C++20 + base 类型） | 跨平台层硬约束 |

## 3. 接口

```cpp
enum class TrackKind { kVideo, kAudio };
enum class ClipKind  { kVideo, kAudio };
enum class TransitionKind { kNone, kCrossFade, kDipToBlack };

struct MediaRef {          // 只引用媒体，不持有数据
    uint64_t asset_id = 0;
    RationalTime source_in;    // 素材内入点
    RationalTime source_duration;
};

struct Clip {
    uint64_t        id;
    ClipKind        kind;
    MediaRef        source;
    RationalTime    start;     // 时间线上的起点
    RationalTime    duration;  // 时间线上的时长（trim 后）
    TransitionKind  in_transition  = kNone;
    TransitionKind  out_transition = kNone;
    RationalTime    transition_duration;  // 转场时长（kNone 时为 0）
};

struct Track {
    uint64_t id;
    TrackKind kind;
    std::vector<Clip> clips;   // 按 start 升序，互不重叠
    bool enabled = true;
    bool muted = false;
};

class Timeline {
    Status AddTrack(TrackKind kind, uint64_t& out_id);
    Status InsertClip(uint64_t track_id, const Clip& clip, uint64_t& out_id);
    Status RemoveClip(uint64_t clip_id);
    Status MoveClip(uint64_t clip_id, RationalTime new_start);
    Status TrimClip(uint64_t clip_id, RationalTime new_duration);

    RationalTime Duration() const;                       // 所有轨道的最大结束时刻
    const Clip* FindClipAt(uint64_t track_id, RationalTime t) const;
};
```

## 4. 验收

- 多轨：≥2 条轨道（视频 + 音频）可共存
- 转场：clip 可挂 in/out 转场，`Duration()` 计算把转场时长计入
- 同轨重叠被拒绝（返回非 kOk）
- 跨轨重叠允许
- CTest 覆盖上述各点
