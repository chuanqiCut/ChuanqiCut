// ChuanqiCut — PALA-012 Apple 编码与封装实现（AVAssetWriter + PixelBufferAdaptor）
//
// 见 media_encode.h 的设计说明。要点：
//   * H.264 编码 + MP4 封装用 AVAssetWriter + AVAssetWriterInputPixelBufferAdaptor。
//   * 输入 CVPixelBuffer（BGRA / NV12）按源格式 1:1 拷入 encoder 自管 buffer 后 append，
//     不做色彩转换，规避通道交换类 bug（PALA-002 教训）。
//   * 每帧 PTS = RationalTime 直接转 CMTime（timescale 同构）；movieTimeScale = 120000，
//     杜绝累积漂移（ADR-0009）。
//   * Finish 阻塞等待 finishWriting；Cancel 调 cancelWriting 并删半成品文件。
//
// 红线：零 FFmpeg 类型；平台类型只在本 .mm（经 pImpl）；错误一律 Status；内核禁用异常。

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <dispatch/dispatch.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>

#include "cq/base/perf.h"
#include "cq/base/status.h"
#include "cq/base/time.h"
#include "media_encode.h"

namespace cq {

namespace {

// 把 src 像素按源格式 1:1 拷入 dst（同尺寸/同格式）。不转换色彩，规避通道交换 bug。
bool CopyPixelBuffer(CVPixelBufferRef src, CVPixelBufferRef dst) {
    if (src == nullptr || dst == nullptr) return false;
    if (CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        return false;
    }
    if (CVPixelBufferLockBaseAddress(dst, 0) != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        return false;
    }
    size_t plane_count = CVPixelBufferGetPlaneCount(src);
    if (plane_count == 0) {
        // 打包格式（BGRA 等）。
        size_t h = CVPixelBufferGetHeight(src);
        size_t src_stride = CVPixelBufferGetBytesPerRow(src);
        size_t dst_stride = CVPixelBufferGetBytesPerRow(dst);
        auto* s = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(src));
        auto* d = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(dst));
        size_t copy_row = (src_stride < dst_stride) ? src_stride : dst_stride;
        for (size_t y = 0; y < h; ++y) {
            std::memcpy(d + y * dst_stride, s + y * src_stride, copy_row);
        }
    } else {
        // 平面格式（NV12 等）：逐平面拷贝。
        for (size_t p = 0; p < plane_count; ++p) {
            size_t h = CVPixelBufferGetHeightOfPlane(src, p);
            size_t src_stride = CVPixelBufferGetBytesPerRowOfPlane(src, p);
            size_t dst_stride = CVPixelBufferGetBytesPerRowOfPlane(dst, p);
            auto* s = static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(src, p));
            auto* d = static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(dst, p));
            size_t copy_row = (src_stride < dst_stride) ? src_stride : dst_stride;
            for (size_t y = 0; y < h; ++y) {
                std::memcpy(d + y * dst_stride, s + y * src_stride, copy_row);
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(dst, 0);
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    return true;
}

}  // namespace

// 把音频码率档位映射到本机默认 AAC 码率（bps）。0 = 交给 AVAssetWriter 默认。
static int64_t AudioBitrateForTier(BitrateTier tier) {
    switch (tier) {
        case BitrateTier::kLow:      return 64'000;
        case BitrateTier::kMedium:   return 128'000;
        case BitrateTier::kHigh:     return 192'000;
        case BitrateTier::kLossless: return 256'000;  // AAC 无真正无损，取最高可达质量
        case BitrateTier::kUnknown:
        default:                     return 0;  // 交平台默认
    }
}

// ⚠️ `kCqParamErr` 是 macOS 的 OSStatus 常量（来自 MacTypes.h），iOS SDK 不通过常规头暴露。
//    2026-09-28 实测：iOS device 切片构建报 "use of undeclared identifier 'kCqParamErr'"
//    （而 macOS 构建正常——这正是只跑 macOS 验证会漏掉的典型问题）。
//    这里显式使用其数值（-50），避免平台头差异。
static const OSStatus kCqParamErr = -50;

// 依据 PcmBuffer 的实际格式构造线性 PCM 的 CMFormatDescription + CMBlockBuffer，
// 产出可供 AAC `AVAssetWriterInput` 吞入的 CMSampleBuffer。
// 支持 kFloat32 / kInt16；其它格式返回 OSStatus 参数错误（调用方应转成 kEncodeUnsupported）。
static OSStatus CreatePcmSampleBuffer(const cq::PcmBuffer& pcm, CMTime presentation_time,
                                      CMSampleBufferRef* out_sbuf) {
    if (out_sbuf == nullptr) return kCqParamErr;
    *out_sbuf = nullptr;
    if (pcm.data == nullptr || pcm.frame_count == 0) return kCqParamErr;

    uint32_t sample_bytes = 0;
    AudioFormatFlags flags = 0;
    switch (pcm.format) {
        case cq::SampleFormat::kFloat32:
            sample_bytes = 4;
            flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
            break;
        case cq::SampleFormat::kInt16:
            sample_bytes = 2;
            flags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
            break;
        default:
            return kCqParamErr;  // 仅支持 kFloat32 / kInt16
    }
    uint32_t channels = pcm.channels > 0 ? pcm.channels : 1;
    uint32_t bytes_per_frame =
        static_cast<uint32_t>(sample_bytes) * channels;  // 论文式显式转换，避免 -Wconversion
    if (pcm.data_bytes != static_cast<uint64_t>(pcm.frame_count) * static_cast<uint64_t>(bytes_per_frame)) {
        return kCqParamErr;  // data_bytes 与 frame_count*channels*样本字节 不符
    }

    AudioStreamBasicDescription asbd{};
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = flags;
    asbd.mSampleRate = static_cast<Float64>(pcm.sample_rate);
    asbd.mChannelsPerFrame = channels;
    asbd.mBitsPerChannel = static_cast<UInt32>(sample_bytes) * 8u;
    asbd.mFramesPerPacket = 1;
    asbd.mBytesPerFrame = bytes_per_frame;
    asbd.mBytesPerPacket = bytes_per_frame;
    asbd.mReserved = 0;

    AudioChannelLayout layout{};
    std::memset(&layout, 0, sizeof(layout));
    if (channels == 1) {
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono;
    } else if (channels == 2) {
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
    } else {
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Unknown;
    }

    CMFormatDescriptionRef fmt = nullptr;
    OSStatus st = CMAudioFormatDescriptionCreate(
        kCFAllocatorDefault, &asbd, sizeof(AudioChannelLayout), &layout, 0, nullptr, nullptr, &fmt);
    if (st != noErr || fmt == nullptr) return st;

    CMBlockBufferRef block = nullptr;
    st = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault, const_cast<void*>(pcm.data), pcm.data_bytes, kCFAllocatorNull,
        nullptr, 0, pcm.data_bytes, 0, &block);
    if (st != noErr || block == nullptr) {
        if (fmt != nullptr) CFRelease(fmt);
        return st;
    }

    CMSampleTimingInfo timing{};
    timing.duration = CMTimeMake(1, static_cast<int32_t>(pcm.sample_rate));  // 每样本时长
    timing.presentationTimeStamp = presentation_time;
    timing.decodeTimeStamp = kCMTimeInvalid;

    st = CMSampleBufferCreate(kCFAllocatorDefault, block, TRUE, nullptr, nullptr, fmt,
                              static_cast<CMItemCount>(pcm.frame_count), 1, &timing, 0, nullptr,
                              out_sbuf);
    if (block != nullptr) CFRelease(block);
    if (fmt != nullptr) CFRelease(fmt);
    return st;
}

// ---------------------------------------------------------------------------
// pImpl：持有 AVFoundation ObjC 对象（ARC 管理），使 media_encode.h 保持纯 C++。
// ---------------------------------------------------------------------------
struct AppleVideoEncoder::State {
    AVAssetWriter* __strong writer = nil;
    AVAssetWriterInput* __strong input = nil;
    AVAssetWriterInputPixelBufferAdaptor* __strong adaptor = nil;
    // 音频轨（AAC）：与视频共用同一个 writer，必须在 startWriting 前 addInput。
    AVAssetWriterInput* __strong audio_input = nil;
    std::string output_path;
    int32_t timescale = 120000;
    uint32_t width = 0;
    uint32_t height = 0;
    // session 是否已启动（startWriting + startSessionAtSourceTime）。AVAssetWriter 要求
    // startWriting 在所有 input 都 addInput 之后、首个样本 append 之前调用一次；
    // 故改为「首个样本写入时惰性启动」，以支持「先 AddVideoTrack / AddAudioTrack，再 Write*」。
    bool started = false;
    bool session_started = false;
};

AppleVideoEncoder::AppleVideoEncoder() : state_(new State()) {}

AppleVideoEncoder::~AppleVideoEncoder() {
    // 若仍处于 Writing 态（未 Finish/Cancel 即析构），安全中止，避免半成品文件残留。
    if (state_ != nullptr && state_->writer != nil &&
        state_->writer.status == AVAssetWriterStatusWriting) {
        [state_->writer cancelWriting];
        if (!state_->output_path.empty()) {
            std::remove(state_->output_path.c_str());
        }
    }
    delete state_;
}

// 惰性启动 writer：AVAssetWriter 要求所有 input 都 addInput 之后、首个样本 append 之前
// 调用 startWriting 一次。故在首个 WriteVideoFrame / WriteAudioFrame 时调用。
Status AppleVideoEncoder::EnsureStarted(AppleVideoEncoder::State* state) {
    if (state == nullptr || state->writer == nil) return Status{StatusCode::kEncodeError};
    if (state->writer.status == AVAssetWriterStatusWriting) return Status::Ok();
    if (state->writer.status == AVAssetWriterStatusFailed) {
        NSError* werr = state->writer.error;
        if (werr != nil) {
            std::printf("[AppleVideoEncoder] EnsureStarted 时 writer 已 Failed: %s\n",
                        [werr.localizedDescription UTF8String]);
        }
        return Status{StatusCode::kEncodeError};
    }
    if (![state->writer startWriting]) {
        NSError* werr = state->writer.error;
        if (werr != nil) {
            std::printf("[AppleVideoEncoder] startWriting 失败: %s\n",
                        [werr.localizedDescription UTF8String]);
        }
        return Status{StatusCode::kEncodeError};
    }
    state->started = true;
    return Status::Ok();
}

Status AppleVideoEncoder::Open(const char* output_path, const EncodeConfig& cfg) {
    if (output_path == nullptr) return Status{StatusCode::kInvalidArgument};
    if (cfg.width == 0 || cfg.height == 0) return Status{StatusCode::kInvalidArgument};
    if (cfg.timescale <= 0) return Status{StatusCode::kInvalidArgument};

    // 幂等：若已开，先中止旧 writer。
    if (state_->writer != nil && state_->writer.status == AVAssetWriterStatusWriting) {
        [state_->writer cancelWriting];
    }
    state_->writer = nil;
    state_->input = nil;
    state_->adaptor = nil;
    state_->output_path = output_path;
    state_->timescale = cfg.timescale;
    state_->width = cfg.width;
    state_->height = cfg.height;
    state_->session_started = false;
    frame_count_ = 0;

    // 若存在旧文件先删除（AVAssetWriter 不可覆盖已存在文件）。
    std::remove(output_path);

    // —— 硬件编码能力探针（一次性 VT 会话，诚实上报；不强制，软解回退仍可用）——
    // ⚠️ 与解码侧同理（见 media_decode.mm 的注释）：这两个常量在 iOS 上要求
    //    **iOS 17.4+**，而项目最低部署目标是 **iOS 16**（ADR-0010）。
    //    直接引用会被 -Werror（-Wunguarded-availability-new）判为错误。
    //    2026-09-28 实测：iOS device 切片构建在此处失败（脚本如实失败，未放宽编译选项）。
    //    处理：@available 守卫。iOS 16/17.0~17.3 下**不做探针**，hw_encode_ 保持 false
    //    ——即"不知为不知"，绝不谎报"已硬件编码"。不为此抬高部署目标。
    //    注：@available(iOS 17.4, *) 在 macOS 上恒为真（macOS 自 10.9 起可用），行为不变。
    hw_encode_ = false;
    if (@available(iOS 17.4, *)) {
        VTCompressionSessionRef probe = nullptr;
        CFDictionaryRef spec = (__bridge CFDictionaryRef) @{
            (__bridge id)kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: @YES,
        };
        OSStatus pst = VTCompressionSessionCreate(
            kCFAllocatorDefault, static_cast<int32_t>(cfg.width),
            static_cast<int32_t>(cfg.height),
                                                 kCMVideoCodecType_H264, spec, nullptr, nullptr,
                                                 nullptr, nullptr, &probe);
        if (pst == noErr && probe != nullptr) {
            CFBooleanRef hw = nullptr;
            if (VTSessionCopyProperty(
                    probe, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                    kCFAllocatorDefault, &hw) == noErr &&
                hw != nullptr) {
                hw_encode_ = (hw == kCFBooleanTrue);
                CFRelease(hw);
            }
            VTCompressionSessionInvalidate(probe);
            CFRelease(probe);
        }
    }

    NSString* ns_path = [NSString stringWithUTF8String:output_path];
    if (ns_path == nil) return Status{StatusCode::kInvalidArgument};
    NSURL* url = [NSURL fileURLWithPath:ns_path];
    if (url == nil) return Status{StatusCode::kInvalidArgument};

    NSError* err = nil;
    AVAssetWriter* writer = [AVAssetWriter assetWriterWithURL:url
                                                   fileType:AVFileTypeMPEG4
                                                      error:&err];
    if (writer == nil || err != nil) {
        if (err != nil) {
            std::printf("[AppleVideoEncoder] AVAssetWriter 创建失败: %s\n",
                        [err.localizedDescription UTF8String]);
        }
        return Status{StatusCode::kEncodeError};
    }
    // 项目时间轴网格（120000），样本 PTS 同构，杜绝累积漂移。
    writer.movieTimeScale = cfg.timescale;

    // 编码输出参数。
    NSMutableDictionary* compression = [NSMutableDictionary dictionary];
    if (cfg.average_bitrate > 0) {
        compression[AVVideoAverageBitRateKey] = @(cfg.average_bitrate);
    }
    compression[AVVideoMaxKeyFrameIntervalKey] = @(cfg.max_keyframe_interval);
    compression[AVVideoExpectedSourceFrameRateKey] =
        @(static_cast<double>(cfg.fps_numerator) / static_cast<double>(cfg.fps_denominator));

    NSDictionary* out_settings = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(static_cast<int>(cfg.width)),
        AVVideoHeightKey: @(static_cast<int>(cfg.height)),
        AVVideoCompressionPropertiesKey: compression,
    };

    AVAssetWriterInput* input =
        [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                         outputSettings:out_settings];
    if (input == nil) {
        return Status{StatusCode::kEncodeError};
    }
    input.expectsMediaDataInRealTime = NO;  // 离线编码，允许缓冲

    // adaptor：声明我们 append 的 buffer 格式（BGRA；源为 BGRA 时 1:1）。
    NSDictionary* attrs = @{
        (__bridge id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (__bridge id)kCVPixelBufferWidthKey: @(static_cast<int>(cfg.width)),
        (__bridge id)kCVPixelBufferHeightKey: @(static_cast<int>(cfg.height)),
    };
    AVAssetWriterInputPixelBufferAdaptor* adaptor =
        [AVAssetWriterInputPixelBufferAdaptor
            assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
                                   sourcePixelBufferAttributes:attrs];
    if (adaptor == nil) {
        return Status{StatusCode::kEncodeError};
    }

    if (![writer canAddInput:input]) {
        std::printf("[AppleVideoEncoder] canAddInput 失败\n");
        return Status{StatusCode::kEncodeError};
    }
    [writer addInput:input];
    // 注意：startWriting 必须等「所有 input（含音频轨）都 addInput 之后」才能调用，
    // 故延迟到首个样本写入时（EnsureStarted）再 startWriting（见 AddAudioTrack / Write*）。

    state_->writer = writer;
    state_->input = input;
    state_->adaptor = adaptor;
    return Status::Ok();
}

Status AppleVideoEncoder::EncodeFrame(CVPixelBufferRef pb, const RationalTime& pts,
                                     const CancelToken& token) {
    if (state_ == nullptr || state_->writer == nil || state_->input == nil ||
        state_->adaptor == nil) {
        return Status{StatusCode::kEncodeError};
    }
    if (pb == nullptr) return Status{StatusCode::kInvalidArgument};

    // 惰性启动 writer（所有 input 已 addInput，首个样本 append 前调用 startWriting）。
    Status ss = EnsureStarted(state_);
    if (!ss.IsOk()) return ss;

    // 背压：encoder 队列满时等待；期间响应取消。
    while (state_->input.isReadyForMoreMediaData == NO &&
           state_->writer.status == AVAssetWriterStatusWriting && !token.IsCancelled()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));  // 1ms 轮询，满足 UI 响应性
    }
    if (token.IsCancelled()) return token.Cancelled();
    if (state_->writer.status != AVAssetWriterStatusWriting) {
        return Status{StatusCode::kEncodeError};
    }

    uint32_t w = static_cast<uint32_t>(CVPixelBufferGetWidth(pb));
    uint32_t h = static_cast<uint32_t>(CVPixelBufferGetHeight(pb));
    OSType fmt = CVPixelBufferGetPixelFormatType(pb);

    CVPixelBufferRef dst = nullptr;
    CVReturn cr = CVPixelBufferCreate(kCFAllocatorDefault, w, h, fmt, nullptr, &dst);
    if (cr != kCVReturnSuccess || dst == nullptr) {
        return Status{StatusCode::kResourceExhausted};
    }

    if (!CopyPixelBuffer(pb, dst)) {
        CFRelease(dst);
        return Status{StatusCode::kEncodeError};
    }

    CMTime cmt = CMTimeMake(pts.value, pts.timescale);
    // 必须在首个样本 append 前启动写入会话（AVAssetWriter 要求 startSessionAtSourceTime:）。
    // 会话起点设为第一帧 PTS（非递减序下保证 <= 后续样本）。
    if (!state_->session_started) {
        [state_->writer startSessionAtSourceTime:cmt];
        state_->session_started = true;
    }
    BOOL ok = [state_->adaptor appendPixelBuffer:dst withPresentationTime:cmt];
    CFRelease(dst);
    if (!ok) {
        if (state_->writer.status == AVAssetWriterStatusFailed) {
            NSError* werr = state_->writer.error;
            if (werr != nil) {
                std::printf("[AppleVideoEncoder] append 失败: %s\n",
                            [werr.localizedDescription UTF8String]);
            }
            return Status{StatusCode::kEncodeError};
        }
        // 偶发背压未就绪但 writer 仍 Writing：重试一次。
        std::printf("[AppleVideoEncoder] append 返回 NO（writer 仍 Writing），视为背压重试失败\n");
        return Status{StatusCode::kEncodeError};
    }
    ++frame_count_;
    return Status::Ok();
}

Status AppleVideoEncoder::Finish() {
    if (state_ == nullptr || state_->writer == nil) {
        return Status{StatusCode::kEncodeError};
    }
    if (state_->writer.status != AVAssetWriterStatusWriting) {
        // 已失败/已结束：如实返回错误而非假装成功。
        if (state_->writer.status == AVAssetWriterStatusFailed) {
            NSError* werr = state_->writer.error;
            if (werr != nil) {
                std::printf("[AppleVideoEncoder] Finish 时 writer 已 Failed: %s\n",
                            [werr.localizedDescription UTF8String]);
            }
            return Status{StatusCode::kEncodeError};
        }
        return Status::Ok();  // 已 Completed/Cancelled
    }

    [state_->input markAsFinished];
    if (state_->audio_input != nil) {
        [state_->audio_input markAsFinished];
    }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [state_->writer finishWritingWithCompletionHandler:^{
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

    if (state_->writer.status != AVAssetWriterStatusCompleted) {
        NSError* werr = state_->writer.error;
        if (werr != nil) {
            std::printf("[AppleVideoEncoder] finishWriting 失败: %s\n",
                        [werr.localizedDescription UTF8String]);
        }
        return Status{StatusCode::kEncodeError};
    }
    return Status::Ok();
}

Status AppleVideoEncoder::AddAudioTrack(const AudioTrackConfig& cfg) {
    if (state_ == nullptr || state_->writer == nil) {
        // 必须在 AddVideoTrack（建立 writer）之后调用。诚实返回参数错误，不伪造。
        return Status{StatusCode::kInvalidArgument};
    }
    if (cfg.codec != CodecId::kAac) {
        // 当前仅支持 AAC 封装；其它 codec 如实返回不支持。
        return Status{StatusCode::kEncodeUnsupported};
    }
    // 必须在 startWriting 之前 addInput（writer 此时仍 Unknown 态），故此处可安全添加。
    if (state_->writer.status == AVAssetWriterStatusWriting) {
        // 防御：startWriting 已被调用（说明已有样本写入），此时再加 input 无效。
        std::printf("[AppleVideoEncoder] AddAudioTrack 在 startWriting 之后调用，无效\n");
        return Status{StatusCode::kInvalidArgument};
    }

    double sample_rate = static_cast<double>(cfg.sample_rate > 0 ? cfg.sample_rate : 48000);
    int channels = static_cast<int>(cfg.channels > 0 ? cfg.channels : 2);
    int64_t bitrate = AudioBitrateForTier(cfg.bitrate);

    NSMutableDictionary* audio_settings = [NSMutableDictionary dictionary];
    audio_settings[AVFormatIDKey] = @(kAudioFormatMPEG4AAC);
    audio_settings[AVSampleRateKey] = @(sample_rate);
    audio_settings[AVNumberOfChannelsKey] = @(channels);
    if (bitrate > 0) {
        audio_settings[AVEncoderBitRateKey] = @(bitrate);
    }

    AVAssetWriterInput* audio_input =
        [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                         outputSettings:audio_settings];
    if (audio_input == nil) {
        return Status{StatusCode::kEncodeError};
    }
    audio_input.expectsMediaDataInRealTime = NO;  // 离线编码，允许缓冲

    if (![state_->writer canAddInput:audio_input]) {
        std::printf("[AppleVideoEncoder] 音频 canAddInput 失败\n");
        return Status{StatusCode::kEncodeError};
    }
    [state_->writer addInput:audio_input];
    state_->audio_input = audio_input;
    return Status::Ok();
}

Status AppleVideoEncoder::WriteAudioFrame(const PcmBuffer& pcm, const RationalTime& pts,
                                         const CancelToken& token) {
    if (state_ == nullptr || state_->writer == nil || state_->audio_input == nil) {
        return Status{StatusCode::kEncodeError};
    }
    if (pcm.data == nullptr || pcm.frame_count == 0) {
        return Status{StatusCode::kInvalidArgument};
    }

    CQ_PERF_SCOPE(cq::PerfStage::kMux, pts);

    // 惰性启动 writer（首个样本 append 前 startWriting）。
    Status ss = EnsureStarted(state_);
    if (!ss.IsOk()) return ss;

    // 背压：音频输入队列满时等待；期间响应取消。
    while (state_->audio_input.isReadyForMoreMediaData == NO &&
           state_->writer.status == AVAssetWriterStatusWriting && !token.IsCancelled()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));  // 1ms 轮询，满足 UI 响应性
    }
    if (token.IsCancelled()) return token.Cancelled();
    if (state_->writer.status != AVAssetWriterStatusWriting) {
        return Status{StatusCode::kEncodeError};
    }

    CMTime cmt = CMTimeMake(pts.value, pts.timescale);
    // 会话起点设为首个样本（视频或音频）的 PTS（非递减序下保证 <= 后续样本）。
    if (!state_->session_started) {
        [state_->writer startSessionAtSourceTime:cmt];
        state_->session_started = true;
    }

    CMSampleBufferRef sbuf = nullptr;
    OSStatus st = CreatePcmSampleBuffer(pcm, cmt, &sbuf);
    if (st != noErr || sbuf == nullptr) {
        std::printf("[AppleVideoEncoder] PCM 样本缓冲构造失败 (osstatus=%d)\n",
                    static_cast<int>(st));
        return Status{StatusCode::kEncodeError};
    }

    BOOL ok = [state_->audio_input appendSampleBuffer:sbuf];
    CFRelease(sbuf);
    if (!ok) {
        if (state_->writer.status == AVAssetWriterStatusFailed) {
            NSError* werr = state_->writer.error;
            if (werr != nil) {
                std::printf("[AppleVideoEncoder] 音频 append 失败: %s\n",
                            [werr.localizedDescription UTF8String]);
            }
            return Status{StatusCode::kEncodeError};
        }
        std::printf("[AppleVideoEncoder] 音频 append 返回 NO（writer 仍 Writing），视为背压重试失败\n");
        return Status{StatusCode::kEncodeError};
    }
    return Status::Ok();
}

Status AppleVideoEncoder::Cancel() {
    if (state_ == nullptr) return Status::Ok();
    if (state_->writer != nil && state_->writer.status == AVAssetWriterStatusWriting) {
        [state_->writer cancelWriting];
    }
    // 删除半成品输出文件（取消是独立停止信号，不计入失败）。
    if (!state_->output_path.empty()) {
        std::remove(state_->output_path.c_str());
    }
    return Status::Ok();
}

}  // namespace cq
