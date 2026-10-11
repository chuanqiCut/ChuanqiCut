// ChuanqiCut — FFmpeg demux 探测实现（DEPS-012 冒烟切片）
//
// 全仓库唯一允许 include FFmpeg 头的 TU（DEPS-004：第三方符号不得进入公共头；
// 头文件是 ffmpeg_probe.h，零 AV* 类型）。MEDIA-021 的 FFmpegFrameProvider
// 展开时应沿用本文件的隔离模式：FFmpeg 头只进自己的实现 TU。

#include "cq/media/chq_ffmpeg_probe.h"

// ⚠️ FFmpeg 9 的公共头不再自带 `extern "C"` 保护（9.0.2 实测：avformat/avcodec/avutil.h
// 均无），C++ TU 必须**自己包**，否则链接按 C++ mangling 找不到符号（DEPS-012 实测坑）。
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
}

namespace cq {

ChqStatus FFmpegProbeFile(const char* path, ChqFFmpegProbeResult* out) {
    if (path == nullptr || path[0] == '\0' || out == nullptr) {
        return ChqStatus(ChqStatusCode::kInvalidArgument);
    }
    *out = ChqFFmpegProbeResult{};

    // FFmpeg 5.x 起无全局注册；顺手确保日志回调安静（库作为 vendored 组件不刷屏）。
    av_log_set_level(AV_LOG_ERROR);

    AVFormatContext* ctx = nullptr;
    const int open_ret = avformat_open_input(&ctx, path, nullptr, nullptr);
    if (open_ret != 0) {
        // AVERROR_EXIT/ENOENT 等统一映射：打不开 = kIoNotFound，其余按格式不支持。
        if (open_ret == AVERROR(ENOENT)) return ChqStatus(ChqStatusCode::kIoNotFound);
        return ChqStatus(ChqStatusCode::kFormatUnsupported);
    }

    // demux 档禁用了全部 decoder：find_stream_info 只靠容器头 + parser 填流参数，
    // 对 mov/mp4（stsd 内嵌 codec 描述）足以拿到 codec_id 与分辨率。
    const int info_ret = avformat_find_stream_info(ctx, nullptr);
    if (info_ret < 0) {
        avformat_close_input(&ctx);
        return ChqStatus(ChqStatusCode::kFormatUnsupported);
    }

    if (ctx->duration > 0) {
        // AV_TIME_BASE = 1e6，duration 本身就是微秒
        out->duration_us = static_cast<int64_t>(ctx->duration);
    }
    if (ctx->iformat != nullptr && ctx->iformat->name != nullptr) {
        out->container_name = ctx->iformat->name;
    }

    out->streams.reserve(static_cast<size_t>(ctx->nb_streams));
    for (unsigned i = 0; i < ctx->nb_streams; ++i) {
        const AVStream* st = ctx->streams[i];
        ChqFFmpegStreamInfo info;
        info.index = static_cast<int32_t>(st->index);
        if (st->codecpar != nullptr) {
            const AVCodecDescriptor* desc = avcodec_descriptor_get(st->codecpar->codec_id);
            if (desc != nullptr && desc->name != nullptr) {
                info.codec_name = desc->name;
            }
            info.media_type = av_get_media_type_string(st->codecpar->codec_type)
                                  ? av_get_media_type_string(st->codecpar->codec_type)
                                  : "";
            info.width = st->codecpar->width;
            info.height = st->codecpar->height;
        }
        out->streams.push_back(std::move(info));
    }

    avformat_close_input(&ctx);

    // 容器打开成功但没有任何流信息 = 解析失败（对齐 media_probe_abi 的「0 时长如实报错」）。
    if (out->streams.empty()) return ChqStatus(ChqStatusCode::kDecodeError);
    return ChqStatus::Ok();
}

}  // namespace cq
