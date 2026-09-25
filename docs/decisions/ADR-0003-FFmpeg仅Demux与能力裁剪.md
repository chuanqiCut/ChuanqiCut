# ADR-0003：FFmpeg 定位为可选 demux/seek 后端，默认 demux-only 档位

- **状态**：提案（待批准）
- **日期**：2026-09-23
- **相关**：RESEARCH-001 C1/C2/F2、ARCH-002 §3

## 背景

原调研三份文档对 FFmpeg 给出三个结论：
- 技术方案决策书：**必须**，用于 demux + seek；
- 管线选型决策表：**可完全避免**，用 AVAssetReader；
- 系统 API 局限性与 FFmpeg 取舍分析：**分阶段**，MVP 用系统 API，速度曲线/倒放阶段引入。

第三份文档的分析最扎实：纯系统 API 在**速度曲线、倒放、VFR 变速**三个场景存在不可逾越的局限（`AVAssetReader` 只能向前读，重建 reader 开销 20–200ms）。而基础剪辑与恒速变速场景，系统 API 完全够用。

同时，原文档对 FFmpeg 的协议风险表述含糊（RESEARCH-001 F2 已核验：FFmpeg 默认即为 LGPL v2.1+，只有 `--enable-gpl` 或链接 GPL 外部库时才升为 GPL）。

## 决策

1. **抽象先行**：定义 `FrameProvider` 接口（`seek(time) / nextFrame() / preload(range)`），语义为**精确 seek**。上层渲染管线不关心底层实现。
2. **三个实现**：
   - `SystemFrameProvider`（Apple: AVAssetReader；Android: MediaExtractor+MediaCodec）—— **MVP 默认**，零额外依赖；
   - `FFmpegFrameProvider` —— demux + 精确 seek，自建/复用平台硬解 session；
   - 选择策略由访问模式决定：顺序读取走系统后端；速度曲线/倒放/VFR 走 FFmpeg 后端。
3. **FFmpeg 默认构建档位 = `demux`**：仅 `libavformat` + `libavutil` + `libavcodec` 的 parser 部分，**不集成 decoder / encoder / muxer / filter**，目标体积 < 3 MB（arm64）。
4. **绝不使用 `--enable-gpl`**，不链接 `libx264` / `libx265` / `libpostproc` / `librubberband` / `libvidstab` 等 GPL 外部库 → 整体停留在 LGPL v2.1+。
5. **能力可见**：`cq_has_feature(CQ_FEATURE_FFMPEG_CODEC)` 等查询接口，UI 与上层在需要前先查询，缺失走降级路径。
6. **编码与封装默认走系统 API**：Apple 用 `AVAssetWriterInputPixelBufferAdaptor`（MVP），Android 用 MediaCodec + MediaMuxer，鸿蒙用 AVCodecKit。

## 备选方案

| 方案 | 否决理由 |
|---|---|
| 完全不引入 FFmpeg | 速度曲线、倒放、VFR 精确变速无法实现或代价极大 |
| 全量引入 FFmpeg（含编解码） | 体积 ×10、协议风险升为 GPL、且平台硬编硬解更优，无收益 |
| 用 FFmpeg 做软解为主 | 功耗与性能远劣于平台硬解（原调研数据：4K H.265 软解 CPU 满载 vs VT 硬解 < 0.5W） |

## 后果

**正面**
- MVP 阶段零第三方媒体依赖，快速验证管线
- 需要时能平滑启用 FFmpeg 后端，上层无感
- 协议风险可控在 LGPL v2.1+ 面内

**负面 / 成本**
- 两套 `FrameProvider` 实现需要维护，且必须保证**行为一致**（同一 seek 请求返回同一帧）—— 这是必须写测试的点
- FFmpeg 构建脚本需为三平台分别维护（Apple universal binary、Android NDK 交叉编译、鸿蒙）
- LGPL 静态链接义务需要法务确认处置方式（目标文件归档 / 商业授权 / 动态链接），见 ARCH-002 §5.1

## 反转条件

- 实测证明系统后端 + 帧缓存能满足速度曲线与倒放的性能要求 → 可永久不引入 FFmpeg；
- 法务判定 LGPL 静态链接在目标市场不可接受且无法获得商业授权 → 必须移除 FFmpeg，速度曲线/倒放改用"预解码到内存 + 帧缓存"方案。

## 落地任务
`DEPS-0xx`（FFmpeg 构建与裁剪）、`MEDIA-0xx`（FrameProvider）
