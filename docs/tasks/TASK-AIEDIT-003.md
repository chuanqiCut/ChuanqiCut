# TASK-AIEDIT-003：音频解码扩档 + 音频特征提取（静音/响度/能量包络）

```yaml
id:          AIEDIT-003
layer:       SDK
goal:        打通"素材文件 → PCM"并提取音频特征（VAD 静音段/LUFS 响度/10Hz 能量包络），产出 FeatureReport.audio 段
input:       [AIEDIT-001 契约, SPEC §5.2, third_party/manifest.toml, .ai/modules/{audio,deps}.md]
output:      [音频解码后端, 音频特征实现, 单测, manifest 变更记录/SBOM 增量]
write_set:   core/src/media/audio_decode/*(新: audio_pcm_reader.{h,cpp})、core/src/ai/audio_analysis/*(新)、
             core/tests/test_audio_analysis.cpp(新)、third_party/manifest.toml(FFmpeg features 加 decode 档)、
             core/CMakeLists.txt(登记)
read_set:    core/include/cq/ai/feature_report.h, core/src/media/ffmpeg_impl/*, .ai/modules/deps.md
deps:        [AIEDIT-001]
acceptance:
  - manifest.toml 变更过 cq-dependency-governance（协议/体积/双端集成/SBOM 四项有结论）
  - golden 音频样本（AAC 44.1k 立体声/24k 单声/含 3 段已知静音）静音段检出边界误差 ≤ 50ms，LUFS 与 ffmpeg loudnorm 参考值差 ≤ 1 LU [E]
  - "文件→PCM"失败路径（损坏文件/无音轨/DRM）返回明确 status，不崩溃不挂起
  - ctest -R audio_analysis 全绿；build_core.sh -Werror 通过
verification:
  - ctest --test-dir build -R audio_analysis
  - tools/build/build_core.sh --platform=apple
  - tools/qa/manifest_audit.sh 或 dependency-governance 产物（按 skill 要求执行）
risk:        FFmpeg decode 档带来体积增量（[E] +2~4MB/arm64）与构建链复杂度 → 体积实测登记 baselines；若超 5MB 触发反转条件改平台解码器（AVAudioFile 前置）
parallel:    true（批次 2；manifest.toml 本批次内唯一触碰者，无并行冲突）
```

## 背景

全仓 FFmpeg 仅 demux 档，"文件→PCM"不可用（.ai/modules/audio.md 现状）。本任务是音频特征（静音剔除=Gling 级刚需，RESEARCH-003 §4.5）与后续 BGM 卡点的共同前置。

## 实现要点（挂 cq-media-pipeline：解码/线程/内存/取消）

1. `audio_pcm_reader`：demux → decode → 重采样 16kHz 单声道 f32，流式分块（整段 PCM 不驻留内存，特征器按块消费）。
2. VAD：30ms 帧能量阈值 + 滞回；LUFS：BS.1770 简化（K 加权 + 门控），C++ 纯算法实现放 `ai/audio_analysis/`。
3. 能量包络 10Hz 均方根序列输出（BGM 卡点候选，P0.5 消费）。
4. 节拍检测**不做**（SPEC §11 非目标）。

## 验收

golden 音频夹具登记 manifest；依赖变更证据（governance 结论链接）附 PR。

## 回写

baselines：体积增量/解码耗时实测；pitfalls：FFmpeg 构建链坑。
