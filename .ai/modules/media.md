# 模块：媒体管线

**边界**：`core/src/media/`、`core/src/retime/`、`pal/<platform>/media_*`

## 职责
解封装、解码、帧缓存、Retime（时间映射）、音画同步、编码、封装的调度层。平台实现在 PAL。

## 核心抽象
```cpp
class FrameProvider {          // 语义 = 精确 seek
  Status seek(RationalTime);
  Status nextFrame(Frame&);
  Status preload(TimeRange);
};
```
三个实现：
- `SystemFrameProvider`（Apple: AVAssetReader / Android: MediaExtractor+MediaCodec）— **MVP 默认**
- `FFmpegFrameProvider` — 精确 seek / 倒放 / 速度曲线
- 选择策略由访问模式决定：顺序读取走系统，随机访问走 FFmpeg

`TimeMap(timelineTime) -> sourceTime`：恒速 / 速度曲线 / 倒放，三个实现同一接口。

## 平台差异（务必注意）
| 差异 | 处理 |
|---|---|
| Android seek 只能到关键帧 | 统一为"精确 seek 语义"，内部 seek 到关键帧后向前解码到目标帧 |
| YUV stride 对齐不同 | 在 PAL 内统一，上层无感 |
| 硬解实例数受限 | DecoderPool 调度 + 降级到软解 |
| iOS 无 FFmpeg 也能跑 | FFmpeg 是可选后端，不是必需 |

## 硬约束
1. **FFmpeg 默认 `demux` 档位**：无 decoder/encoder/muxer/filter，体积 < 3MB，绝不使用 `--enable-gpl`
2. 能力查询：`cq_has_feature(CQ_FEATURE_FFMPEG_CODEC)` 等，缺失走降级路径
3. Apple 编码 MVP 用 `AVAssetWriterInputPixelBufferAdaptor`（自建 VT session 延后）
4. 两个 FrameProvider 必须**行为一致**（同 seek 请求同结果）—— 必须写测试
5. A/V 偏差 ≤ 1 帧

## 验证
```bash
ctest -R media_frame_provider     # 两个后端一致性
tools/perf/frame_provider_bench --cases=seek,reverse,ramp
ctest -R media_sync               # 音画同步
```

## 相关
ADR-0003、ARCH-002 §3（FFmpeg 裁剪）、ARCH-004
