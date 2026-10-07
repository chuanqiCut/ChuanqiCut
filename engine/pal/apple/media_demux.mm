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

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <sys/stat.h>
#include <vector>

#include "cq/base/perf.h"       // CQ_SLOW_CALL_WF（CORE-010）
#include "cq/base/logging.h"        // 带 workflow 的分级日志
#include "cq/base/rational_time.h"        // RationalTime / Rescale / RoundMode / kProjectTimeScale
#include "cq/base/status.h"      // Status / StatusCode
#include "cq/base/concurrency.h" // CancelToken
#include "cq/pal/media.h"        // IMediaDemuxer / MediaPacket / StreamInfo / CreateMediaDemuxer
#include "cq/pal/pal_common.h"       // CodecId / MediaType / PixelFormat 等枚举

namespace cq {

// 慢调用告警统一走 core/base 的 CQ_SLOW_CALL_WF（CORE-010）：Release 可见 +
// 按链路可筛，不再在每个文件里各抄一份 Debug-only 的结构体。
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
// MEDIA-022：'hev1'（ffmpeg 默认 HEVC tag）与 'dvh1'/'dvhe'（杜比视界，HEVC 基底）
// 与 'hvc1' 同属 HEVC —— 缺了它们，iPhone 相册/常见 HEVC 素材会被报成 kUnknown。
CodecId VideoCodecToCq(FourCharCode c) {
    switch (c) {
        case kCMVideoCodecType_H264:
            return CodecId::kH264;
        case kCMVideoCodecType_HEVC:
        case kCMVideoCodecType_HEVCWithAlpha:
        case 'hev1':
        case 'dvh1':
        case 'dvhe':
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

// 码流关键帧判决（passthrough 下的可靠兜底）：解析 NAL 找 IDR(H.264)/IRAP(HEVC)。
// 返回值：kKeyframe=判定为关键帧；kNonKey=判定为非关键帧；kUnknown=无法判定。
enum class NalVerdict { kKeyframe = 0, kNonKey = 1, kUnknown = 2 };

// 读取 CMSampleBuffer 的连续压缩数据指针（不拷贝，零拷贝）。passthrough 下 CMBlockBuffer
// 通常为单段连续；非连续则本兜底路径直接判定为「无法判定」（退化为保守），避免越界。
static bool GetSampleData(CMSampleBufferRef sbuf, const uint8_t*& out_data, size_t& out_len) {
    out_data = nullptr;
    out_len = 0;
    if (sbuf == nullptr) return false;
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sbuf);
    if (block == nullptr) return false;
    size_t length = 0;
    char* ptr = nullptr;
    if (CMBlockBufferGetDataPointer(block, 0, &length, nullptr, &ptr) != kCMBlockBufferNoErr) {
        return false;
    }
    if (ptr == nullptr || length == 0) return false;
    if (!CMBlockBufferIsRangeContiguous(block, 0, length)) return false;  // 非连续→无法判定
    out_data = reinterpret_cast<const uint8_t*>(ptr);
    out_len = length;
    return true;
}

// 取得 AVCC/HEVC 的 NAL 长度字节数（1/2/3/4）。失败返回默认 4（MP4 passthrough 最常见）。
static size_t GetNalLengthSize(CMFormatDescriptionRef fmt, FourCharCode codec) {
    size_t default_size = 4;
    if (fmt == nullptr) return default_size;
    CFDictionaryRef atoms = static_cast<CFDictionaryRef>(
        CMFormatDescriptionGetExtension(fmt, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms));
    if (atoms == nullptr) return default_size;
    if (codec == kCMVideoCodecType_H264) {
        CFDataRef avcc = static_cast<CFDataRef>(CFDictionaryGetValue(atoms, CFSTR("avcC")));
        if (avcc != nullptr) {
            const uint8_t* a = CFDataGetBytePtr(avcc);
            CFIndex n = CFDataGetLength(avcc);
            // AVCConfigurationRecord：byte4 低 2 位 = lengthSizeMinusOne。
            if (a != nullptr && n > 4) return static_cast<size_t>((a[4] & 0x03) + 1);
        }
    } else if (codec == kCMVideoCodecType_HEVC || codec == kCMVideoCodecType_HEVCWithAlpha ||
               codec == 'hev1' || codec == 'dvh1' || codec == 'dvhe') {
        // MEDIA-022：'hev1'/杜比视界同样携带 hvcC。
        CFDataRef hvcc = static_cast<CFDataRef>(CFDictionaryGetValue(atoms, CFSTR("hvcC")));
        if (hvcc != nullptr) {
            const uint8_t* h = CFDataGetBytePtr(hvcc);
            CFIndex n = CFDataGetLength(hvcc);
            // HEVCDecoderConfigurationRecord：byte21 低 2 位 = lengthSizeMinusOne。
            if (h != nullptr && n > 21) return static_cast<size_t>((h[21] & 0x03) + 1);
        }
    }
    return default_size;
}

// 解析样本码流，用 VCL NAL 判定关键帧（IDR/IRAP）。
static NalVerdict DetectKeyframeByNal(const uint8_t* data, size_t len,
                                      FourCharCode codec, CMFormatDescriptionRef fmt) {
    if (data == nullptr || len == 0) return NalVerdict::kUnknown;
    // 检测 Annex-B（起始码 00 00 00 01 / 00 00 01）vs AVCC（长度前缀）。
    bool annexb = (len >= 4 && data[0] == 0 && data[1] == 0 && data[2] == 0 && data[3] == 1);
    size_t nal_len_size = annexb ? 0 : GetNalLengthSize(fmt, codec);

    bool saw_vcl = false;
    bool saw_key = false;
    size_t pos = 0;
    while (pos < len) {
        size_t nal_start = 0;
        size_t nal_size = 0;
        if (annexb) {
            if (pos + 3 < len && data[pos] == 0 && data[pos + 1] == 0 && data[pos + 2] == 1) {
                pos += 3;
            } else if (pos + 2 < len && data[pos] == 0 && data[pos + 1] == 1) {
                pos += 2;
            } else {
                ++pos;
                continue;
            }
            nal_start = pos;
            size_t end = nal_start;
            while (end + 3 <= len) {
                if ((end + 2 < len && data[end] == 0 && data[end + 1] == 0 && data[end + 2] == 1) ||
                    (end + 1 < len && data[end] == 0 && data[end + 1] == 1)) break;
                ++end;
            }
            nal_size = end - nal_start;
        } else {
            if (pos + nal_len_size > len) break;
            size_t l = 0;
            for (size_t i = 0; i < nal_len_size; ++i) l = (l << 8) | data[pos + i];
            nal_start = pos + nal_len_size;
            if (nal_start + l > len) break;
            nal_size = l;
            pos = nal_start + l;
        }
        if (nal_size == 0) continue;
        if (codec == kCMVideoCodecType_H264) {
            int nal_type = data[nal_start] & 0x1F;
            if (nal_type >= 1 && nal_type <= 5) {  // VCL（IDR=5）
                saw_vcl = true;
                if (nal_type == 5) saw_key = true;
            }
        } else {
            if (nal_size < 2) continue;
            int nal_type = (data[nal_start] >> 1) & 0x3F;  // HEVC 2 字节 NAL 头
            bool is_vcl = (nal_type <= 9) || (nal_type >= 16 && nal_type <= 23);
            if (is_vcl) {
                saw_vcl = true;
                if (nal_type >= 16 && nal_type <= 23) saw_key = true;  // IRAP
            }
        }
    }
    if (!saw_vcl) return NalVerdict::kUnknown;  // 仅 SPS/PPS/SEI 等非 VCL 样本
    if (saw_key) return NalVerdict::kKeyframe;
    return NalVerdict::kNonKey;
}

// 从 CMSampleBuffer 判断是否为关键帧（独立可解码 / sync sample）。
//
// 分层判定（团队要求，不要只换一个附件 key）：
//   1) 附件信号：优先 kCMSampleAttachmentKey_NotSync（存在且 false→关键帧）；
//      其次 kCMSampleAttachmentKey_DependsOnOthers（存在且 false→关键帧）。
//      不创建附件数组（createIfNecessary=false），缺失即视为「无附件」走下一层。
//   2) 附件缺失（passthrough 常见）→ 解析码流 NAL 判断 IDR(H.264 type5)/IRAP(HEVC 16..23)。
//      这是 passthrough 下的可靠兜底，避免退化回「全当关键帧」。
//   3) 仍无法判定（非连续缓冲 / 无 VCL / 未知 codec）→ 兜底策略：保守当作关键帧。
//      后果：极少数无法判定样本被误标关键帧，可能让 kKeyframeBefore 略多选一帧，但**不会
//      丢失真正关键帧**，seek 仍能自关键帧正确启动解码；相对地若激进当非关键帧则真正关键
//      帧会被漏标、seek 回退失败。正常 MP4 passthrough 下每个样本都含 VCL NAL，第 3 层极
//      罕见触发。
bool IsKeyframe(CMSampleBufferRef sbuf) {
    if (sbuf == nullptr) return false;
    CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sbuf, false);
    if (atts != nullptr && CFArrayGetCount(atts) > 0) {
        CFDictionaryRef d = static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(atts, 0));
        if (d != nullptr) {
            CFBooleanRef not_sync = static_cast<CFBooleanRef>(
                CFDictionaryGetValue(d, kCMSampleAttachmentKey_NotSync));
            if (not_sync != nullptr) return (not_sync == kCFBooleanFalse);
            CFBooleanRef dep = static_cast<CFBooleanRef>(
                CFDictionaryGetValue(d, kCMSampleAttachmentKey_DependsOnOthers));
            if (dep != nullptr) return (dep == kCFBooleanFalse);
        }
    }
    // 分层 2：码流 NAL 解析。
    const uint8_t* data = nullptr;
    size_t len = 0;
    if (GetSampleData(sbuf, data, len)) {
        CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sbuf);
        FourCharCode codec = (fmt != nullptr) ? CMVideoFormatDescriptionGetCodecType(fmt)
                                             : static_cast<FourCharCode>(0);
        NalVerdict v = DetectKeyframeByNal(data, len, codec, fmt);
        if (v == NalVerdict::kKeyframe) return true;
        if (v == NalVerdict::kNonKey) return false;
    }
    // 分层 3：兜底（保守，见函数注释）。
    return true;
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
        // CORE-010：Release 可见（慢调用不是调试细节，是「系统正在变得不可用」）。
        CQ_SLOW_CALL_WF(Workflow::kDemux, "demuxer Open(含 ScanKeyframes)");
        if (src.path == nullptr) return Status{StatusCode::kInvalidArgument};

        NSString* ns_path = [[NSString alloc] initWithUTF8String:src.path];
        if (ns_path == nil) return Status{StatusCode::kInvalidArgument};
        NSURL* url = [NSURL fileURLWithPath:ns_path];
        if (url == nil) return Status{StatusCode::kInvalidArgument};

        asset_ = [AVURLAsset URLAssetWithURL:url options:nil];
        if (asset_ == nil) return Status{StatusCode::kIoError};

        // 加载 tracks + duration（异步加载 + 信号量收敛成同步 Open）。
        // ⚠️ completionHandler 触发 ≠ 加载成功：它在所有 key 到**终态**时调用，
        // 终态含 Failed/Cancelled。不查 statusOfValue 会把「加载失败」漏成
        // 「Open 成功 + duration=0」——invalid CMTime 经 ToRational 变 {0,1}，
        // timescale=1 骗过 timescale<=0 检查，probe 带 0 成功返回（P33）。
        // ⚠️ 必须**有限超时**：实测（P33 排障）加载失败后重建的新 asset 的
        // completion 可能**永不触发**（AVFoundation 同进程同 URL 加载状态被
        // 污染），无限等 = Open 挂死。超时按「正常加载 40~400ms × 10 余量」取
        // 5s；超时/失败返回 kIoError，上层按「文件无法解析」处理。
        // 瞬态失败重建 asset 重试一次：新实例不受前实例失败状态影响。
        constexpr int64_t kLoadTimeoutNs = 5LL * 1000 * 1000 * 1000;  // 5s
        Status load_status{StatusCode::kUnknown};
        for (int attempt = 0;; ++attempt) {
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            [asset_ loadValuesAsynchronouslyForKeys:@[ @"tracks", @"duration" ]
                                  completionHandler:^{
                                      dispatch_semaphore_signal(sem);
                                  }];
            const bool completed =
                dispatch_semaphore_wait(
                    sem, dispatch_time(DISPATCH_TIME_NOW, kLoadTimeoutNs)) == 0;
            sem = nil;

            BOOL loaded = NO;
            if (completed) {
                loaded = YES;
                for (NSString* key in @[ @"tracks", @"duration" ]) {
                    NSError* err = nil;
                    AVKeyValueStatus st = [asset_ statusOfValueForKey:key error:&err];
                    if (st != AVKeyValueStatusLoaded) {
                        loaded = NO;
                        std::printf(
                            "[AppleDemuxer] load '%s' attempt %d -> status=%ld err='%s'\n",
                            key.UTF8String, attempt, static_cast<long>(st),
                            err.localizedDescription.UTF8String ?: "(nil)");
                        break;
                    }
                }
            } else {
                std::printf("[AppleDemuxer] load attempt %d -> timeout (5s)\n", attempt);
            }
            if (loaded) {
                load_status = Status::Ok();
                break;
            }
            if (attempt >= 1) {
                load_status = Status{StatusCode::kIoError};
                break;
            }
            // 文件已不存在 = 确定性失败，重试无意义（省一次 5s 超时）。
            // 存在的文件偶发加载失败（P33）才值得重建 asset 重试。
            struct stat st_buf{};
            if (::stat(url.fileSystemRepresentation, &st_buf) != 0) {
                std::printf("[AppleDemuxer] file gone, skip retry\n");
                load_status = Status{StatusCode::kIoError};
                break;
            }
            asset_ = nil;  // 重建 asset 重试（绕开前实例的失败状态）
        }
        if (!load_status.IsOk()) return load_status;

        // 记录时长（Rescale 到 120000，kRound）。
        duration_ = ToRational([asset_ duration], RoundMode::kRound);

        // 建 reader（全范围），预取每条轨首个样本，并从 track.formatDescriptions 解析元数据。
        CancelToken no_cancel;
        Status s = RebuildReader(kCMTimeZero, no_cancel);
        if (!s.IsOk()) return s;
        // 关键帧扫描在 Open 同步完成（供 Seek 吸附）。⚠️ 后台线程方案已否决：
        // 与播放路径在同一 AVAsset 上并发建 AVAssetReader 会触发
        // NSInternalInconsistencyException（output already added，P71）。
        ScanKeyframes();
        s = RebuildReader(kCMTimeZero, no_cancel);
        if (!s.IsOk()) return s;
        return Status::Ok();
    }

    Status GetDuration(RationalTime& out_duration) const override {
        out_duration = duration_;
        return Status::Ok();
    }

    // MEDIA-026：轻量打开——只加载 duration，不建 reader / 不扫关键帧。
    // 导入探测（cq_media_probe_duration）专用：大文件从秒级降到毫秒级。
    Status OpenLight(const MediaSource& src) override {
        if (src.path == nullptr) return Status{StatusCode::kInvalidArgument};
        NSString* ns_path = [[NSString alloc] initWithUTF8String:src.path];
        if (ns_path == nil) return Status{StatusCode::kInvalidArgument};
        NSURL* url = [NSURL fileURLWithPath:ns_path];
        if (url == nil) return Status{StatusCode::kInvalidArgument};

        AVURLAsset* asset = [AVURLAsset URLAssetWithURL:url options:nil];
        if (asset == nil) return Status{StatusCode::kIoError};

        // 有限超时 + 单次重试：与全量 Open 的加载纪律一致（P33：加载失败后
        // completion 可能永不触发，无限等 = 挂死）。
        constexpr int64_t kLoadTimeoutNs = 5LL * 1000 * 1000 * 1000;
        for (int attempt = 0;; ++attempt) {
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            [asset loadValuesAsynchronouslyForKeys:@[ @"duration" ]
                                 completionHandler:^{
                                     dispatch_semaphore_signal(sem);
                                 }];
            const bool completed = dispatch_semaphore_wait(
                sem, dispatch_time(DISPATCH_TIME_NOW, kLoadTimeoutNs)) == 0;
            if (completed) {
                NSError* err = nil;
                if ([asset statusOfValueForKey:@"duration" error:&err] ==
                    AVKeyValueStatusLoaded) {
                    break;
                }
                std::printf("[AppleDemuxer] OpenLight duration load failed (attempt %d)\n",
                            attempt);
            } else {
                std::printf("[AppleDemuxer] OpenLight load timeout (attempt %d)\n", attempt);
            }
            if (attempt >= 1) return Status{StatusCode::kIoError};
            asset = [AVURLAsset URLAssetWithURL:url options:nil];  // 重建重试
            if (asset == nil) return Status{StatusCode::kIoError};
        }
        duration_ = ToRational([asset duration], RoundMode::kRound);
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

    // 精确 seek：吸附到 <=target 的最近关键帧，重建 reader（timeRange.start = 该关键帧）。
    // 关键帧位置来自 Open 时扫描的 keyframe_times_（依赖已修复的 IsKeyframe，与 ffprobe 吻合）。
    // 精确 seek 必须自关键帧起解码：调用方（MEDIA-020）再从关键帧前向解码到 t 帧。
    // 无关键帧（空集）时退化为从头，保证不崩溃。
    Status Seek(const RationalTime& target, const CancelToken& token) override {
        if (token.IsCancelled()) return token.Cancelled();
        if (asset_ == nil) return Status{StatusCode::kInvalidArgument};

        // 吸附：<=target 的最大关键帧。
        RationalTime snap{0, kProjectTimeScale};
        for (const RationalTime& kf : keyframe_times_) {
            if (cq::CompareRational(kf, snap) >= 0 &&
                cq::CompareRational(kf, target) <= 0) {
                snap = kf;
            }
        }
        CMTime start = CMTimeMake(snap.value, snap.timescale);
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
        // CORE-010：Release 可见。逐包路径（每帧一次）的额外开销是两次单调时钟
        // 读取，相对毫秒级的解封装耗时可忽略。
        CQ_SLOW_CALL_WF(Workflow::kDemux, "demux ReadPacket");
#ifndef NDEBUG
        // 成对日志（进入/返回都打——析构式警报对「永不返回」的调用失明，
        // 「最后一个无配对进入」即卡点）。逐包高频，只在 Debug 保留。
        static std::atomic<int> seq{0};
        const int my_seq = seq.fetch_add(1);
        CQ_LOG_TRACE_WF(Workflow::kDemux, "ReadPacket enter #%d", my_seq);
        struct ExitLog {
            int seq;
            ~ExitLog() { CQ_LOG_TRACE_WF(Workflow::kDemux, "ReadPacket exit #%d", seq); }
        } exit_log{my_seq};
#endif
        // MEDIA-027：同 RebuildReader —— 泵线程无 autorelease pool，逐包调用必须
        // 自带池，否则 AVFoundation 的自动释放对象整段播放期内只增不减。
        @autoreleasepool {
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
        }  // @autoreleasepool（MEDIA-027）
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
        // MEDIA-027：本函数被**泵线程**按帧调用（每次 Seek 一次），而泵线程是纯
        // C++ std::thread，**没有 autorelease pool**。AVFoundation 在这里产出的
        // 自动释放对象（AVAssetReader / NSError / tracks 数组等）会一直挂到线程
        // 退出才回收 —— 播放越久攒越多。显式池把生命周期压到单次调用。
        @autoreleasepool {
        TearDownReader();
        tracks_.clear();  // 幂等：Open 可能重复调用（如 CreateMediaDemuxer + SystemFrameProvider::Open），
                          // 不清空会累积失效（output=nil）的旧轨，导致 ScanKeyframes 读到 0 样本。
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
        }  // @autoreleasepool（MEDIA-027）
    }

    // 一次性扫描视频轨关键帧 pts 集合（Seek 吸附到 <=target 关键帧用）。
    // 注意：扫描会消费当前 reader；调用方需在之后 RebuildReader(kCMTimeZero) 重置。
    void ScanKeyframes() {
        // CORE-010：Release 可见。全文件扫描是最容易在大素材上爆时间的调用之一。
        CQ_SLOW_CALL_WF(Workflow::kDemux, "ScanKeyframes(全文件)");
        keyframe_times_.clear();
        for (auto& ts : tracks_) {
            if (ts.media_type != MediaType::kVideo) continue;
            while (true) {
                CMSampleBufferRef sbuf = [ts.output copyNextSampleBuffer];
                if (sbuf == nullptr) break;
                // 零字节样本（参数集/priming）无帧数据，跳过。
                CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sbuf);
                size_t length = 0;
                if (block != nullptr) {
                    CMBlockBufferGetDataPointer(block, 0, nullptr, &length, nullptr);
                }
                if (length == 0) {
                    CFRelease(sbuf);
                    continue;
                }
                if (IsKeyframe(sbuf)) {
                    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sbuf);
                    keyframe_times_.push_back(ToRational(pts, RoundMode::kRound));
                }
                CFRelease(sbuf);
            }
            break;  // 仅扫描首个视频轨
        }
    }

    AVAsset* __strong asset_ = nil;
    AVAssetReader* __strong reader_ = nil;
    std::vector<TrackState> tracks_;
    RationalTime duration_{0, 1};
    std::vector<uint8_t> last_data_;  // 最近一个包的压缩数据（MediaPacket.data 指向它）
    std::vector<RationalTime> keyframe_times_;  // 视频轨关键帧 pts 集合（Seek 吸附用）
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
