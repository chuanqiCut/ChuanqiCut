# TASK-AUDIO-004：多轨混音原语（电平正确 + 无溢出）

> **状态：🔧 编码完成 + 单测全绿（2026-10-13 编码轮）**。真机问卷不出（无真机可听感
> 验收路径，PALA-030 未做，见下），全量门禁 + 与 B0 并批收口须传哲同意后做 → 不标记完成。

```yaml
id:          AUDIO-004
layer:       跨平台
goal:        把「多轨 PCM 求和 + 削波」从预览混音器的内联循环提升为 core 层可复用、
             可单测的混音原语，并让预览混音器改用它 —— 全仓只有一套混音实现
input:       [TASK-AUDIO-001（pool/ring/graph 骨架，✅）, AUDIO-002 预览混音器现状,
             ARCH-001 §6 线程模型/音频线程铁律, .ai/modules/audio.md]
output:      [cq/audio/chq_mix.{h,cpp}(新)、tests/unit/test_audio_mix.cpp(新)、
             chq_preview_mixer.cpp 重构、双 CMake 登记、audio.md 更新]
write_set:   engine/core/cq/audio/chq_mix.h(新)、engine/core/cq/audio/chq_mix.cpp(新)、
             engine/core/cq/audio/chq_preview_mixer.cpp(改)、
             engine/core/CMakeLists.txt(改，登记新 TU)、
             tests/unit/test_audio_mix.cpp(新)、tests/CMakeLists.txt(改，注册 target)
read_set:    engine/core/cq/audio/{chq_audio_types,chq_audio_graph,chq_preview_mixer}.h、
             engine/core/cq/base/chq_status.h、.ai/modules/audio.md
deps:        [AUDIO-001 ✅]
acceptance:
  - 电平正确：MixAccumulateRange 按 gain 线性累加；gain=0 静音、负增益反相、
    |gain|>1 放大，多轨累加结果与顺序无关（浮点累加顺序敏感项单独断言容差）
  - 无溢出：MixClipRange 输出恒在 [-1,1]；NaN/±Inf 输入一律按 0 处置（不留无声怪物）
  - 分码纪律：channels=0 / frames=0 / 非有限 gain / acc 侧越界 → kInvalidArgument，
    且**不写任何内存**（全有或全无）
  - 音频线程纪律：原语零分配、无锁、纯函数（无静态状态、无 IO、无日志）
  - build_core.sh --platform=apple -Werror 通过；ctest -R audio 全绿（含新 core_audio_mix）
  - 预览混音器不再有内联求和/削波循环（grep 级断言写进测试注释与本次回写）
verification:
  - tools/build/build_core.sh --platform=apple --config=Debug
  - ctest --test-dir build -R audio          # core_audio_pcm / core_audio_graph / core_audio_mix
risk:        无平台后端可听感验证（PALA-030 未做）→ 本任务以数值单测为准，
             听感与真实延迟仍推迟；浮点累加顺序敏感性不追求位级一致（文档写明）
parallel:    true（write_set 与 B0 渲染/模型/shar 批次不相交；CMake 两文件为热点文件，
             由集成机串行改，改完即构建验证）
```

## 背景

AUDIO-002（预览音频全链，已提交）把「多 clip 求和 + 削波」以内联循环写在
`ChqPreviewAudioMixer::MixBlock` 里：`acc_[dst+c] += fifo[src+c]`，块末
逐样本硬削波。功能正确，但有三个结构性问题：

1. **不可单测**：混音数学埋在快照命中/FIFO 管理的大函数里，只能端到端间接验；
2. **不可复用**：导出路径（音画导出）将来也要混音，只能再抄一份；
3. **无增益概念**：模型 `ChqTrack` 只有 `enabled/muted`，没有音量字段 ——
   混音器因此连 gain 入口都没有，将来加音量要改内联循环。

本任务做「提升」：把混音数学提成 `cq/audio/chq_mix.h` 的纯函数原语，
预览混音器改为调用它。**全仓只有一套混音实现**（ADR-0014 两套渲染路径的教训，
不得在本模块复刻）。

## 范围裁决（做/不做，写下来防止范围蔓延）

**做**：
- `MixAccumulateRange(acc, acc_frames, channels, src, src_frame0, frames, dst_frame0, gain)`
  —— 把 src 的一段按增益累加进 acc 的一段。float32 交错。
- `MixClipRange(data, frames, channels)` —— 硬削波到 [-1,1]，非有限值按 0。
- 预览混音器重构：内联求和/削波 → 原语调用；增益取点显式留出。

**不做（及理由）**：
| 项 | 理由 |
|---|---|
| AudioGraph 多输入扩展（AUDIO-001 册子预留的"扩展点"） | 无消费方：预览路径不经 AudioGraph（AUDIO-002 自带编排），导出路径未立卡。给没有消费方的接口改验证框架 = 投机。届时随"图装配音频链"的卡一起做 |
| 母带限制器 / 软削波（tanh 等） | 属 AUDIO-010 fx 家族；预览 MVP 语义就是硬削波（chq_preview_mixer.cpp 原注释已写明） |
| solo | 模型无 solo 字段（mute 已有）；先不做状态机 |
| 非 float32 总线（int16/int32 混音） | 格式转换是独立节点职责（chq_audio_types.h 明示"图本身不做重采样"）；唯一消费方是 float32 |
| dB↔线性换算助手 | 无消费方（UI 侧要用时再加；且换算不在热路径，加了反而诱人逐块 powf） |
| 模型轨音量字段 | 模型线写集（chq_timeline.h 是 B0 刚动过的热点文件），不跨线直改；本卡只把 gain 取点留好 |

## 实现要点

1. **全有或全无**：越界/零值/非有限 gain 一律先校验后写内存，返回
   `kInvalidArgument` 时 acc 一个该厂商都不碰（可测：越界调用前后 acc 哨兵不变）。
2. **NaN 处置**：`MixClipRange` 把 NaN/±Inf 当 0（解码异常或累加溢出的下游保护），
   这是"无溢出"验收的可测定义 —— 输出恒在 [-1,1]，不存在 inf/NaN 穿透。
3. **零分配**：纯函数、无静态可变状态、无 IO/日志；音频线程可直接调。
   验证手段：单测里在原语调用前后对比全局 operator new 计数（复用 AUDIO-001 手法）。
4. **-Wconversion 安全**：size_t/int64 混算全部显式 static_cast。
5. **增益取点**：预览混音器调用处以命名常量 `kTrackGainUnity` + 注释标明
   "模型立音量字段后此处即唯一改点"，不留魔法数字。

## 验收

见 acceptance。数值断言全部机器判定（ctest），不听感、不依赖真机。
浮点累加顺序敏感项（多轨求和的不同顺序）用容差断言并注明理由，不追求位级一致。

## 回写

- `.ai/modules/audio.md`：结构段补 chq_mix、落地状态段、验证段补 `core_audio_mix`、
  模块册任务表补 AUDIO-004 行；**修正"多输入汇点是 AUDIO-004 扩展点"的旧预期**
  （改为"随图装配音频链的卡一起做"，理由见上表）
- `docs/reports/LEDGER-W42.md`：append 本轮条目
- `.workbuddy/memory/2026-10-13.md`：当日日志
- 本文件：状态随进度更新
