# 模块：音频

**边界**：`core/src/audio/`、`core/include/cq/audio/`、`pal/<platform>/audio_*`

## 结构
```
core/include/cq/audio/     # 跨平台音频类型与接口（零平台类型）
├── audio_types.h          # AudioBuffer（可变 data，PAL 边界做 PcmBuffer 平凡适配）/ AudioGraphSpec
├── audio_graph.h          # IAudioNode / AudioGraph（Prepare 校验+拓扑 / Process 无锁遍历）
├── pcm_pool.h             # AudioBlockPool（预分配槽位 + tag Treiber freelist + per-slot 状态双保险）
└── spsc_ring.h            # SpscSampleRing（2 的幂预分配、全有或全无、SPSC 专用）
core/src/audio/            # 对应实现（.cpp 同名）
```

## 落地状态（2026-10-05）
- **AUDIO-001 ✅**：上述四件套 + 单测 `core_audio_pcm` / `core_audio_graph`。
  音频线程零分配以**全局 operator new 计数实测增量 0** 验收（kAudio 标记线程全路径）。
- **AudioGraph 拓扑限制 = 单链**（每节点入度≤1、出度≤1、必须连通）：
  多输入汇点是 AUDIO-004（混音）的扩展点，Prepare 校验框架不变。
- **未落地**：AUDIO-002/003/004/010、PALA-030（AVAudioEngine）、MEDIA-030（音画同步时钟）——
  当前预览仍是纯视频无声。AIEDIT-003（音频解码+特征）已立卡未开工。

## 时间拉伸与变声：signalsmith-stretch（MIT）
替代原方案的 SoundTouch（**LGPL v2.1，原文档误标为 MIT** —— 见 RESEARCH-001 F1 / ADR-0004）。

## 已知坑（必须规避）
1. **Apple Clang 16.0.0 + `-ffast-math` 会生成错误 SIMD 代码** → 构建配置必须规避该组合
2. Debug 构建下性能极慢（可达 10 倍）→ 该模块单独开启优化
3. 存在 inputLatency + outputLatency → **导出路径必须做延迟补偿**，否则时长有偏差
4. 时间拉伸质量在 0.75x–1.5x 区间外下降 → 超出范围需评估

## 硬约束
1. **音频线程无锁、无分配**；buffer 一律 `AudioBlockPool` 预分配，
   跨线程通道一律 `SpscSampleRing`（严格 SPSC，违规 = 数据竞争）
2. 变速后输出时长误差 ≤ 1 帧（写进测试）
3. 变声需支持 pitch 与 formant 独立控制（这正是 `AVAudioUnitTimePitch` 做不到的）
4. 三端共用同一份 C++ 音频算法代码

## 验证
```bash
ctest -R audio              # AUDIO-001：pool/ring/graph（含零分配实测）
ctest -R audio_stretch      # AUDIO-002：时长准确性（未落地）
ctest -R audio_pitch        # AUDIO-003：pitch/formant 独立（未落地）
ctest -R audio_mix          # AUDIO-004：多轨电平与溢出（未落地）
```

## 相关
ADR-0004、ARCH-002 §7（依赖清单）、ARCH-001 §6（线程模型/铁律 2）、
CORE-006 冻结的 `cq/pal/audio.h`（PcmBuffer/IAudioEngine 契约）
