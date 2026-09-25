// ChuanqiCut — PALA-010 Apple 解封装后端（AVFoundation / AVAssetReader）
//
// 职责：实现 PAL 冻结接口 `cq::IMediaDemuxer`（core/include/cq/pal/media.h）。
// 用 AVFoundation 读取 MP4/MOV 等容器，逐包（压缩数据）吐出本项目自有的
// `MediaPacket`，全程不使用任何 FFmpeg 类型，也不把任何平台类型泄漏到 core 头。
//
// 设计要点：
//   * 走 AVAssetReader + AVAssetReaderTrackOutput，outputSettings 传 nil（passthrough），
//     这样拿到的 CMSampleBuffer 携带的是**压缩数据**（而非已解码帧），满足
//     "demux 只做容器层、不含解码" 的契约（解码是 PALA-011 的事）。
//   * 时间一律走 `RationalTime` 项目网格 120000。AVFoundation 的 `CMTime` 自带
//     timescale，必须显式 `Rescale` 到 120000，且**非整除时必须显式指定舍入方向**
//     （本文件统一用 kRound 表示时间戳、kFloor 表示关键帧锚点），绝不默认。
//   * 平台类型（AVAsset / AVAssetReader / CMSampleBuffer / __strong 等）只出现在本 .mm。
//
// 红线：零 FFmpeg 类型、零平台类型出现在 core/ 头、统一 base 类型（RationalTime/Status/
// CancelToken）、内核禁用异常、长任务接受 CancelToken。

#import <AVFoundation/AVFoundation.h>
#import <dispatch/dispatch.h>

#include <cstdint>
#include <vector>

#include "cq/base/time.h"        // RationalTime / Rescale / RoundMode / kProjectTimeScale
#include "cq/base/status.h"      // Status / StatusCode
#include "cq/base/concurrency.h" // CancelToken
#include "cq/pal/media.h"        // IMediaDemuxer / MediaPacket / StreamInfo / CreateMediaDemuxer
#include "cq/pal/common.h"       // CodecId / MediaType / PixelFormat 等枚举

namespace cq {
namespace {

// CMTime -> RationalTime（项目网格 120000），显式舍入方向（非整除也不默认）。
RationalTime ToRational(CMTime t, RoundMode mode) {
    if (CMTIME_IS_INVALID(t) || CMTIME_IS_INDEFINITE(t)) {
        return RationalTime{0, 1};
    }
    RationalTime src{static_cast<int64_t>(t.value), static_cast<int32_t>(t.timescale)};
    RationalTime out = src;
    // 非整除必须显式舍入方向；Rescale 在指定 mode 下只会在溢出时失败。
    Status s = Rescale(src, kProjectTimeScale, mode, out);
    if (!s.IsOk()) {
        // 溢出兜底：退回原始（非项目网格）值，保证不丢信息。
        out = src;
    }
    return out;
}

// 视频/音频 FourCharCode -> 本项目 CodecId（与 FFmpeg 解耦，映射在 PAL 内）。
CodecId VideoCodecToCq(FourCharCode c) {
    switch (c) {
        case kCMVideoCodecType_H264:
            return CodecId::kH264;
        case kCMVideoCodecType_HEVC:
        case kCMVideoCodecType_HEVCWithAlpha:
            return CodecId::kHevc;
        case kCMVideoCodecType_AppleProRes422:
        case kCMVideoCodecType_AppleProRes4444:
        case kCMVideoCodecType_AppleProRes422HQ:
        case kCMVideoCodecType_AppleProRes4444XQ:
        case kCMVideoCodecType_AppleProRes422LT:
        case kCMVideoCodecType_AppleProRes422Proxy:
            return CodecId::kProres;
        case kCMVideoCodecType_JPEG:
        case kCMVideoCodecType_JPEG_OpenDML:
            return CodecId::kMjpeg;
        default:
            return CodecId::kUnknown;
    }
}

CodecId AudioCodecToCq(FourCharCode c) {
    switch (c) {
        case kAudioFormatLinearPCM:
            return CodecId::kPcmS16Le;  // 近似：实际格式见 StreamInfo，这里仅作 codec 标签
        case kAudioFormatMPEG4AAC:
        case kAudioFormatMPEG4AAC_HE:
        case kAudioFormatMPEG4AAC_LD:
        case kAudioFormatMPEG4AAC_ELD:
            return CodecId::kAac;
        case kAudioFormatMPEGLayer3:
            return CodecId::kMp3;
        case kAudioFormatFLAC:
            return CodecId::kFlac;
        case kAudioFormatOpus:
            return CodecId::kOpus;
        default:
            return CodecId::kUnknown;
    }
}

// 从 CMSampleBuffer 判断是否为关键帧（独立可解码 / sync sample）。
// 依据 kCMSampleBufferAttachmentKey_DependsOnOthers：为 false（不依赖其它帧）
// 即关键帧。无该附件时保守当作关键帧。
bool IsKeyframe(CMSampleBufferRef sbuf) {
    if (sbuf == nullptr) return false;
    CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sbuf, true);
    if (atts == nullptr || CFArrayGetCount(atts) == 0) {
        // 无附件：可能 passthrough 不提供依赖信息。保守当作关键帧。
        return true;
    }
    CFDictionaryRef d = static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(atts, 0));
    if (d == nullptr) return true;
    CFBooleanRef dep = static_cast<CFBooleanRef>(
        CFDictionaryGetValue(d, kCMSampleAttachmentKey_DependsOnOthers));
    if (dep == nullptr) {
        // passthrough 模式下该附件可能缺失；保守当作关键帧。
        return true;
    }
    // 不依赖其它帧（kCFBooleanFalse）=> 关键帧。
    return (dep == kCFBooleanFalse);
}

// 单条轨的输出状态（实现内部，含 ObjC 平台类型，不出现在 core 头）。
struct TrackState {
    AVAssetReaderTrackOutput* __strong output = nullptr;  // passthrough 输出
    CMSampleBufferRef next = nullptr;  // 预取的下一样本（+1 retained），耗尽为 nullptr
    int32_t stream_index = -1;
    MediaType media_type = MediaType::kUnknown;
    CodecId codec = CodecId::kUnknown;
    // StreamInfo 字段（从首个样本的格式描述解析，避免 deprecated 属性）。
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t sample_rate = 0;
    uint32_t channels = 0;
    PixelFormat pixel_format = PixelFormat::kUnknown;
    RationalTime time_base{0, 1};
};

void ReleaseSample(CMSampleBufferRef& s) {
    if (s != nullptr) {
        CFRelease(s);
        s = nullptr;
    }
}

// 从 CMFormatDescription（Open 时来自 track.formatDescriptions，不依赖读取样本）
// 抽取 stream 元数据（codec/尺寸/采样率）。
void ExtractStreamMeta(TrackState& ts, CMFormatDescriptionRef fmt, MediaType type) {
    if (fmt == nullptr) return;
    ts.media_type = type;
    if (type == MediaType::kVideo) {
        FourCharCode codec = CMVideoFormatDescriptionGetCodecType(fmt);
        ts.codec = VideoCodecToCq(codec);
        CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(fmt);
        ts.width = static_cast<uint32_t>(dim.width);
        ts.height = static_cast<uint32_t>(dim.height);
        // 压缩层不感知像素格式细节；标记 kYUV420SemiPlanar 为常见 H.264 默认，
        // 真实解码后由 PALA-011 给出精确 PixelFormat。此处仅占位。
        ts.pixel_format = PixelFormat::kYUV420SemiPlanar;
    } else {
        const AudioStreamBasicDescription* asbd =
            CMAudioFormatDescriptionGetStreamBasicDescription(fmt);
        if (asbd != nullptr) {
            FourCharCode codec = static_cast<FourCharCode>(asbd->mFormatID);
            ts.codec = AudioCodecToCq(codec);
            ts.sample_rate = static_cast<uint32_t>(asbd->mSampleRate);
            ts.channels = static_cast<uint32_t>(asbd->mChannelsPerFrame);
        }
    }
}

}  // namespace

// ---------------------------------------------------------------------------
// AppleDemuxer — PAL IMediaDemuxer 的 Apple 实现
// ---------------------------------------------------------------------------
class AppleDemuxer : public IMediaDemuxer {
public:
    AppleDemuxer() = default;
    ~AppleDemuxer() override {
        TearDownReader();
        for (auto& ts : tracks_) ReleaseSample(ts.next);
    }

    // IPalResource
    void Destroy() override { delete this; }

    Status Open(const MediaSource& src) override {
        if (src.path == nullptr) return Status{StatusCode::kInvalidArgument};

        NSString* ns_path = [[NSString alloc] initWithUTF8String:src.path];
        if (ns_path == nil) return Status{StatusCode::kInvalidArgument};
        NSURL* url = [NSURL fileURLWithPath:ns_path];
        if (url == nil) return Status{StatusCode::kInvalidArgument};

        asset_ = [AVURLAsset URLAssetWithURL:url options:nil];
        if (asset_ == nil) return Status{StatusCode::kIoError};

        // 现代异步加载（避免 deprecated 同步阻塞 API）。用信号量把异步收敛成同步 Open。
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block BOOL loaded = NO;
        [asset_ loadValuesAsynchronouslyForKeys:@[ @"tracks", @"duration" ]
                              completionHandler:^{
                                  loaded = YES;
                                  dispatch_semaphore_signal(sem);
                              }];
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        if (!loaded) return Status{StatusCode::kIoError};

        // 记录时长（Rescale 到 120000，kRound）。
        duration_ = ToRational([asset_ duration], RoundMode::kRound);

        // 建 reader（全范围），预取每条轨首个样本，并从 track.formatDescriptions 解析元数据。
        CancelToken no_cancel;
        Status s = RebuildReader(kCMTimeZero, no_cancel);
        if (!s.IsOk()) return s;
        return Status::Ok();
    }

    Status GetDuration(RationalTime& out_duration) const override {
        out_duration = duration_;
        return Status::Ok();
    }

    int32_t GetStreamCount() const override {
        return static_cast<int32_t>(tracks_.size());
    }

    Status GetStreamInfo(int32_t index, StreamInfo& out_info) const override {
        if (index < 0 || index >= static_cast<int32_t>(tracks_.size())) {
            return Status{StatusCode::kInvalidArgument};
        }
        const TrackState& ts = tracks_[static_cast<size_t>(index)];
        out_info = StreamInfo{};
        out_info.type = ts.media_type;
        out_info.codec = ts.codec;
        out_info.time_base = ts.time_base;
        out_info.width = ts.width;
        out_info.height = ts.height;
        out_info.sample_rate = ts.sample_rate;
        out_info.channels = ts.channels;
        out_info.pixel_format = ts.pixel_format;
        return Status::Ok();
    }

    // 精确 seek：重建 reader，把读取时间范围起点设为 target，后续 ReadPacket 从该处继续。
    // 注：纯 demux 层只把容器读位置移到 target 附近的关键帧；真正的"重建到 t 帧"
    // 由解码后端（PALA-011）完成。这里保证"seek 后再读 pts 从该处继续（非从头）"。
    Status Seek(const RationalTime& target, const CancelToken& token) override {
        if (token.IsCancelled()) return token.Cancelled();
        if (asset_ == nil) return Status{StatusCode::kInvalidArgument};

        CMTime start = CMTimeMake(target.value, target.timescale);
        return RebuildReader(start, token);
    }

    // 读下一个压缩包：在所有轨已预取的 next 中，取 pts 最小者吐出。
    // 全部耗尽时返回 kIoNotFound（非错误计数）。
    //
    // 关键：passthrough 模式下容器层会吐出**零字节样本**（如 H.264 参数集 /
    // priming 包），它们不带帧数据且会破坏 pts 单调性（pts=0 的空包紧跟真正的
    // pts=0 首帧）。这类样本在 demux 层直接跳过，只向外吐出带有效编码数据的包。
    Status ReadPacket(MediaPacket& out_packet) override {
        out_packet = MediaPacket{};

        for (;;) {
            // 找 pts 最小的可用轨。
            int best = -1;
            CMTime best_pts = kCMTimeInvalid;
            for (int i = 0; i < static_cast<int>(tracks_.size()); ++i) {
                TrackState& ts = tracks_[static_cast<size_t>(i)];
                if (ts.next == nullptr) continue;
                CMTime pts = CMSampleBufferGetPresentationTimeStamp(ts.next);
                if (best < 0 || CMTimeCompare(pts, best_pts) < 0) {
                    best = i;
                    best_pts = pts;
                }
            }
            if (best < 0) {
                return Status{StatusCode::kIoNotFound};  // 流末尾，非错误
            }

            TrackState& ts = tracks_[static_cast<size_t>(best)];
            CMSampleBufferRef sbuf = ts.next;
            ts.next = nullptr;  // 该样本已被取走

            // 懒填充 stream 元数据：passthrough 首样本可能不带格式描述，
            // 用实际读到的样本补一次（仅一次）。
            if (ts.codec == CodecId::kUnknown) {
                CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sbuf);
                if (fmt != nullptr) ExtractStreamMeta(ts, fmt, ts.media_type);
            }

            // —— 抽取压缩数据（扁平化为连续缓冲，data 由 demuxer 所有）——
            CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sbuf);
            size_t length = 0;
            if (block != nullptr) {
                CMBlockBufferGetDataPointer(block, 0, nullptr, &length, nullptr);
            }
            if (length == 0) {
                // 零字节样本（参数集 / priming / 容器层非 VCL 配置包）。
                // 无帧数据，跳过并继续取下一包，避免污染调用方计数与 pts 单调性。
                CFRelease(sbuf);
                ts.next = [ts.output copyNextSampleBuffer];  // 预取下一包
                continue;
            }

            last_data_.clear();
            last_data_.resize(length);
            CMBlockBufferCopyDataBytes(block, 0, length, last_data_.data());

            CMTime pts = CMSampleBufferGetPresentationTimeStamp(sbuf);
            CMTime dts = CMSampleBufferGetDecodeTimeStamp(sbuf);
            if (CMTIME_IS_INVALID(dts)) dts = pts;

            out_packet.stream_index = ts.stream_index;
            out_packet.pts = ToRational(pts, RoundMode::kRound);
            out_packet.dts = ToRational(dts, RoundMode::kRound);
            out_packet.codec = ts.codec;
            out_packet.data = last_data_.empty() ? nullptr : last_data_.data();
            out_packet.size = last_data_.size();
            out_packet.is_keyframe = IsKeyframe(sbuf);

            // 预取该轨下一个样本。
            ts.next = [ts.output copyNextSampleBuffer];  // +1 retained（可能为 nil）

            // 用毕释放当前样本（我们已把数据拷出）。
            CFRelease(sbuf);
            return Status::Ok();
        }
    }

private:
    // 拆除当前 reader 与所有输出。
    void TearDownReader() {
        for (auto& ts : tracks_) {
            ReleaseSample(ts.next);
            ts.output = nullptr;
        }
        if (reader_ != nil) {
            if (reader_.status == AVAssetReaderStatusReading) {
                [reader_ cancelReading];
            }
            reader_ = nil;
        }
    }

    // 以 [start, asset.duration) 为时间范围重建 reader 与每条轨的 passthrough 输出，
    // 并预取每条轨首个样本。start = kCMTimeZero 即从头/重置。
    Status RebuildReader(CMTime start, const CancelToken& token) {
        TearDownReader();
        if (asset_ == nil) return Status{StatusCode::kInvalidArgument};
        if (token.IsCancelled()) return token.Cancelled();

        NSError* err = nil;
        reader_ = [AVAssetReader assetReaderWithAsset:asset_ error:&err];
        if (reader_ == nil || err != nil) return Status{StatusCode::kIoError};

        CMTime dur = [asset_ duration];
        CMTime start_clamped = start;
        if (CMTIME_IS_INVALID(start_clamped)) start_clamped = kCMTimeZero;
        if (CMTimeCompare(start_clamped, dur) > 0) start_clamped = dur;
        CMTimeRange range = CMTimeRangeMake(start_clamped,
                                            CMTimeSubtract(dur, start_clamped));
        if (CMTIME_IS_INVALID(range.duration) || range.duration.value < 0) {
            range = CMTimeRangeMake(kCMTimeZero, dur);
        }
        reader_.timeRange = range;

        NSArray<AVAssetTrack*>* all_tracks = [asset_ tracks];
        int32_t idx = 0;
        // 先收集并添加所有输出（此时还不能 copyNextSampleBuffer）。
        for (AVAssetTrack* track in all_tracks) {
            // 注意：mediaType 是 NSString，必须用字符串比较，不能指针比较
            // （track.mediaType 与全局常量 AVMediaTypeVideo 可能是不同实例）。
            BOOL is_video = [track.mediaType isEqualToString:AVMediaTypeVideo];
            BOOL is_audio = [track.mediaType isEqualToString:AVMediaTypeAudio];
            if (!is_video && !is_audio) {
                continue;
            }
            AVAssetReaderTrackOutput* out =
                [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:nil];
            // nil outputSettings = passthrough（不解码，保留压缩数据）。
            [reader_ addOutput:out];

            TrackState ts;
            ts.output = out;
            ts.stream_index = idx++;
            ts.media_type = is_video ? MediaType::kVideo : MediaType::kAudio;
            ts.time_base = RationalTime{kProjectTimeScale, kProjectTimeScale};  // 包统一报项目网格
            // 从 track 的格式描述取 codec/尺寸/采样率（Open 即可得，不依赖读取样本）。
            NSArray* fds = track.formatDescriptions;
            if (fds.count > 0) {
                // 用 CFBridgingRetain（函数式桥接，避免 __bridge 旧式强转触发 -Wold-style-cast），
                // 转成 CFTypeRef 后再 static_cast 到 CMFormatDescriptionRef。
                CFTypeRef fdRef = CFBridgingRetain(fds[0]);
                CMFormatDescriptionRef fd =
                    static_cast<CMFormatDescriptionRef>(fdRef);
                ExtractStreamMeta(ts, fd, ts.media_type);
                CFRelease(fdRef);
            }
            tracks_.push_back(std::move(ts));
        }

        if (![reader_ startReading]) {
            // 某些资产（如纯音频或受限）可能 startReading 失败；把错误转成 Status。
            NSError* rerr = [reader_ error];
            if (rerr != nil) {
                std::printf("[AppleDemuxer] startReading failed: %s\n",
                            [rerr.localizedDescription UTF8String]);
            } else {
                std::printf("[AppleDemuxer] startReading failed (no error)\n");
            }
            TearDownReader();
            return Status{StatusCode::kIoError};
        }

        // startReading 之后才能预取首样本（copyNextSampleBuffer 要求 reader 已启动）。
        for (auto& ts : tracks_) {
            ts.next = [ts.output copyNextSampleBuffer];  // +1 retained（可能为 nil）
        }
        return Status::Ok();
    }

    AVAsset* __strong asset_ = nil;
    AVAssetReader* __strong reader_ = nil;
    std::vector<TrackState> tracks_;
    RationalTime duration_{0, 1};
    std::vector<uint8_t> last_data_;  // 最近一个包的压缩数据（MediaPacket.data 指向它）
};

// ---------------------------------------------------------------------------
// PAL 工厂（声明于 core/include/cq/pal/media.h，定义于本 PAL 实现）
// ---------------------------------------------------------------------------
Status CreateMediaDemuxer(const MediaSource& src, PalPtr<IMediaDemuxer>& out_demuxer) {
    AppleDemuxer* d = new AppleDemuxer();
    Status s = d->Open(src);
    if (!s.IsOk()) {
        d->Destroy();
        out_demuxer.reset();
        return s;
    }
    out_demuxer = PalPtr<IMediaDemuxer>(d);
    return Status::Ok();
}

}  // namespace cq
