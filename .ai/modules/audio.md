# 模块：音频

**边界**：`core/src/audio/`、`pal/<platform>/audio_*`

## 职责
音频图、PCM 缓冲、EQ/压缩/混响、时间拉伸、变声、多轨混音。

## 时间拉伸与变声：signalsmith-stretch（MIT）
替代原方案的 SoundTouch（**LGPL v2.1，原文档误标为 MIT** —— 见 RESEARCH-001 F1 / ADR-0004）。

## 已知坑（必须规避）
1. **Apple Clang 16.0.0 + `-ffast-math` 会生成错误 SIMD 代码** → 构建配置必须规避该组合
2. Debug 构建下性能极慢（可达 10 倍）→ 该模块单独开启优化
3. 存在 inputLatency + outputLatency → **导出路径必须做延迟补偿**，否则时长有偏差
4. 时间拉伸质量在 0.75x–1.5x 区间外下降 → 超出范围需评估

## 硬约束
1. **音频线程无锁、无分配**；通信用预分配 lock-free ring buffer
2. 变速后输出时长误差 ≤ 1 帧（写进测试）
3. 变声需支持 pitch 与 formant 独立控制（这正是 `AVAudioUnitTimePitch` 做不到的）
4. 三端共用同一份 C++ 音频算法代码

## 验证
```bash
ctest -R audio_stretch      # 时长准确性
ctest -R audio_pitch        # pitch/formant 独立
ctest -R audio_mix          # 多轨电平与溢出
```

## 相关
ADR-0004、ARCH-002 §7（依赖清单）
