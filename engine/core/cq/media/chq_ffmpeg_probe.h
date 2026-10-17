// ChuanqiCut — FFmpeg demux 探测（DEPS-012 冒烟切片）
//
// 用途：证明 FFmpeg demux 档（libavformat + libavutil + libavcodec parser/bsf）
//   在仓库内真实可用（Pod vendored / CMake cq_ffmpeg 双集成，见 ADR-0034）。
//   MEDIA-021（FFmpegFrameProvider 完整 demux 后端）在此接缝上另行展开。
//
// ⚠️ 硬约束（MEDIA-010 / DEPS-004 同源）：
//   * 本头文件零 AV* / FFmpeg 类型 —— FFmpeg 头只允许出现在 ffmpeg_probe.cpp
//     （platform_header_gate / scan_headers 扫描红线）。
//   * TU 隔离（ADR-0011 规则 1）：静态库按 archive member 粒度拉符号，
//     本 TU 引用 FFmpeg 符号，必须独立成 TU —— 不消费 FFmpeg 的目标
//     链接 cq_core 时不会被牵出 FFmpeg 依赖；消费方须同时链接 cq_ffmpeg。

#ifndef CQ_CORE_MEDIA_CHQ_FFMPEG_PROBE_H_
#define CQ_CORE_MEDIA_CHQ_FFMPEG_PROBE_H_

#include <cstdint>
#include <string>
#include <vector>

#include "cq/base/chq_status.h"

namespace cq {

// 单流探测结果。codec_name 用字符串而非枚举：demux 档禁用了所有 decoder，
// 描述符表（avcodec_descriptor_get）是 avcodec 里独立于 decoder 开关的全量静态表，
// 能如实给出 codec 名。
struct ChqFFmpegStreamInfo {
    int32_t index = 0;
    std::string codec_name;  // 如 "h264" / "aac"；未知流为空
    std::string media_type;  // "video" / "audio" / "data" / ...
    int32_t width = 0;       // 仅视频流有效
    int32_t height = 0;
};

struct ChqFFmpegProbeResult {
    int64_t duration_us = 0;     // 容器头时长（微秒）；未知为 0
    std::string container_name;  // 如 "mov,mp4,m4a,3gp,3g2,mj2"
    std::vector<ChqFFmpegStreamInfo> streams;
};

// 打开媒体文件读容器头与流信息。仅 demux（avformat_open_input +
// avformat_find_stream_info），不触碰任何 decoder。
// 错误码：kInvalidArgument（空参数）/ kIoNotFound（打不开）/
//         kFormatUnsupported（容器可识别但流信息探不全）/ kDecodeError（流信息不一致）。
ChqStatus FFmpegProbeFile(const char* path, ChqFFmpegProbeResult* out);

}  // namespace cq

#endif  // CQ_CORE_MEDIA_CHQ_FFMPEG_PROBE_H_
