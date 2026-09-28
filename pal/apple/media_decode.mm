// ChuanqiCut — PALA-011 Apple 硬解后端实现（VTDecompressionSession）
//
// 见 media_decode.h 的设计说明。要点：
//   * H.264 硬解（优先硬件，运行时查询是否真硬解）。
//   * SPS/PPS 注入：Open 时经 source path 打开 AVAsset 取视频轨 CMFormatDescription
//     （内嵌 avcC，含 SPS/PPS）建立解码会话，无需手解 avcC、不碰已废弃 API。
//   * dts→pts 重排：VideoToolbox 内部 DPB 已在显示序回调，PopFrame 按显示序出队。
//   * seek 后 flush：Flush 清空待出队帧并复位时长跟踪；新 GOP 以 IDR 起，VT 内部复位。
//
// 红线：零 FFmpeg 类型；平台类型只在本 .mm / media_decode.h；错误一律 Status；内核禁用异常。

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

#include <atomic>
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>

#include "cq/base/status.h"
#include "cq/base/time.h"
#include "media_decode.h"

namespace cq {

// ---------------------------------------------------------------------------
// 构造 / 析构
// ---------------------------------------------------------------------------
VideoToolboxDecoder::VideoToolboxDecoder(const char* source_path)
    : source_path_(source_path != nullptr ? source_path : "") {}

VideoToolboxDecoder::~VideoToolboxDecoder() {
    ReleaseOutputQueue();
    if (last_returned_ != nullptr) {
        if (last_returned_->refcount.fetch_sub(1) == 1) delete last_returned_;
        last_returned_ = nullptr;
    }
    TeardownSession();
}

void VideoToolboxDecoder::TeardownSession() {
    if (session_ != nullptr) {
        VTDecompressionSessionInvalidate(session_);
        CFRelease(session_);
        session_ = nullptr;
    }
    if (format_desc_ != nullptr) {
        CFRelease(format_desc_);
        format_desc_ = nullptr;
    }
}

void VideoToolboxDecoder::ReleaseOutputQueue() {
    std::lock_guard<std::mutex> lk(queue_mutex_);
    for (auto& of : output_queue_) {
        if (of.pb) CFRelease(of.pb);
    }
    output_queue_.clear();
}

// ---------------------------------------------------------------------------
// CMTime -> RationalTime（项目网格 120000，非整除显式 kRound）
// ---------------------------------------------------------------------------
RationalTime VideoToolboxDecoder::ToRational(CMTime t) const {
    if (CMTIME_IS_INVALID(t) || CMTIME_IS_INDEFINITE(t)) {
        return RationalTime{0, kProjectTimeScale};
    }
    RationalTime src{static_cast<int64_t>(t.value), static_cast<int32_t>(t.timescale)};
    RationalTime out = src;
    Status s = Rescale(src, kProjectTimeScale, RoundMode::kRound, out);
    if (!s.IsOk()) out = src;
    return out;
}

// ---------------------------------------------------------------------------
// 输出回调（显示序）：把 CVPixelBuffer 入队
// ---------------------------------------------------------------------------
void VideoToolboxDecoder::OutputCallback(void* ref_con, void* source_ref_con, OSStatus status,
                                         VTDecodeInfoFlags info_flags, CVImageBufferRef image_buffer,
                                         CMTime pts, CMTime duration) {
    (void)source_ref_con;
    (void)info_flags;
    (void)duration;
    auto* self = static_cast<VideoToolboxDecoder*>(ref_con);
    if (status != noErr) return;
    if (image_buffer == nullptr) return;
    CVPixelBufferRef pb = reinterpret_cast<CVPixelBufferRef>(image_buffer);
    self->Enqueue(pb, self->ToRational(pts));
}

void VideoToolboxDecoder::Enqueue(CVPixelBufferRef pb, const RationalTime& pts) {
    if (pb == nullptr) return;
    CFRetain(pb);  // 取所有权（回调的 imageBuffer 由 VT 持有，须保留）
    std::lock_guard<std::mutex> lk(queue_mutex_);
    output_queue_.push_back({pb, pts});
}

// ---------------------------------------------------------------------------
// Open：取得 codec 描述并建立 VT 会话
// ---------------------------------------------------------------------------
Status VideoToolboxDecoder::Open(const StreamInfo& info) {
    // 幂等：先清旧会话（若存在），避免重复 Open 累积。
    TeardownSession();
    ReleaseOutputQueue();
    if (last_returned_ != nullptr) {
        if (last_returned_->refcount.fetch_sub(1) == 1) delete last_returned_;
        last_returned_ = nullptr;
    }
    has_prev_ = false;
    prev_popped_pts_ = RationalTime{0, 0};
    fed_first_ = false;
    fed_second_ = false;
    popped_count_ = 0;
    session_hw_ = false;

    bound_codec_ = info.codec;
    width_ = info.width;
    height_ = info.height;

    if (bound_codec_ != CodecId::kH264) {
        // 本期仅 H.264；HEVC/其它诚实返回不支持，绝不伪造。
        return Status{StatusCode::kDecodeUnsupported};
    }
    if (source_path_.empty()) {
        // 无 source path 无法取得 avcC/SPS/PPS；诚实报告缺 codec 描述。
        return Status{StatusCode::kDecodeUnsupported};
    }

    // 经 AVAsset 取得视频轨 CMFormatDescription（内嵌 avcC，含 SPS/PPS）。
    @autoreleasepool {
        NSString* ns_path = [NSString stringWithUTF8String:source_path_.c_str()];
        if (ns_path == nil) return Status{StatusCode::kInvalidArgument};
        NSURL* url = [NSURL fileURLWithPath:ns_path];
        if (url == nil) return Status{StatusCode::kInvalidArgument};

        AVURLAsset* asset = [AVURLAsset URLAssetWithURL:url options:nil];
        if (asset == nil) return Status{StatusCode::kIoError};

        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block BOOL loaded = NO;
        [asset loadValuesAsynchronouslyForKeys:@[ @"tracks" ]
                            completionHandler:^{
                                loaded = YES;
                                dispatch_semaphore_signal(sem);
                            }];
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        if (!loaded) return Status{StatusCode::kIoError};

        // macOS 15.0 起 `tracksWithMediaType:` 已弃用，改用异步
        // `loadTracksWithMediaType:completionHandler:` + semaphore 同步等待。
        // （项目最低 macOS 15.4，必定支持新 API；-Werror 下弃用告警即错误。）
        __block NSArray<AVAssetTrack*>* tracks = nil;
        dispatch_semaphore_t track_sem = dispatch_semaphore_create(0);
        [asset loadTracksWithMediaType:AVMediaTypeVideo
                     completionHandler:^(NSArray<AVAssetTrack*>* t, NSError* err) {
            tracks = (err == nil) ? t : nil;
            (void)err;
            dispatch_semaphore_signal(track_sem);
        }];
        dispatch_semaphore_wait(track_sem, DISPATCH_TIME_FOREVER);
        if (tracks.count == 0) return Status{StatusCode::kDecodeUnsupported};
        AVAssetTrack* track = tracks[0];
        NSArray* fds = track.formatDescriptions;
        if (fds.count == 0) return Status{StatusCode::kDecodeUnsupported};

        CMFormatDescriptionRef fd = (__bridge CMFormatDescriptionRef)fds[0];
        if (CMFormatDescriptionGetMediaType(fd) != kCMMediaType_Video) {
            return Status{StatusCode::kDecodeUnsupported};
        }
        FourCharCode codec = CMVideoFormatDescriptionGetCodecType(fd);
        if (codec != kCMVideoCodecType_H264) {
            return Status{StatusCode::kDecodeUnsupported};
        }
        CFRetain(fd);
        format_desc_ = fd;
    }

    // 建立 VT 解码会话（优先硬件；是否真硬解运行后查询）。
    VTDecompressionOutputCallbackRecord cb{&VideoToolboxDecoder::OutputCallback, this};
    NSDictionary* attrs = @{
        (__bridge id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (__bridge id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    // ⚠️ 这两个常量在 iOS 上要求 **iOS 17.0+**（macOS 为 10.9 起）。
    //    项目最低部署目标是 **iOS 16**（ADR-0010），直接引用会被 -Werror
    //    （-Wunguarded-availability-new）判为错误。
    //    2026-09-28 实测：iOS device 切片构建在此处失败（脚本如实失败未放宽）。
    //    处理：用 @available 守卫，iOS 16 下不指定/不查询（硬解仍由系统默认策略决定，
    //    只是不显式开启、也不上报"是否硬件"）。**不为此抬高部署目标**——那违背 ADR-0010。
    //    注：@available(iOS 17.0, *) 在非 iOS 平台（macOS）恒为真，故 macOS 行为不变。
    NSDictionary* spec = nil;
    if (@available(iOS 17.0, *)) {
        spec = @{
            (__bridge id)kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: @YES,
        };
    }
    OSStatus st = VTDecompressionSessionCreate(
        kCFAllocatorDefault, format_desc_, (__bridge CFDictionaryRef)spec,
        (__bridge CFDictionaryRef)attrs, &cb, &session_);
    if (st != noErr || session_ == nullptr) {
        return Status{StatusCode::kDecodeError};
    }

    // 运行时查询：本次会话是否真的走了硬件解码（如实上报，不伪造）。
    // iOS 16 下该属性不可用 → 保持默认（未知），绝不谎报"已硬解"。
    if (@available(iOS 17.0, *)) {
        CFBooleanRef hw = nullptr;
        if (VTSessionCopyProperty(
                session_, kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                kCFAllocatorDefault, &hw) == noErr &&
            hw != nullptr) {
            session_hw_ = (hw == kCFBooleanTrue);
            CFRelease(hw);
        }
    }

    return Status::Ok();
}

// ---------------------------------------------------------------------------
// Feed：把 AVCC 压缩包拷成 CMSampleBuffer 喂入解码器
// ---------------------------------------------------------------------------
Status VideoToolboxDecoder::Feed(const MediaPacket& pkt) {
    if (session_ == nullptr || format_desc_ == nullptr) {
        return Status{StatusCode::kDecodeError};
    }
    if (pkt.codec != bound_codec_) {
        return Status::Ok();  // 跳过非本路（如音频）包，demuxer 可能交错吐多路
    }
    if (pkt.data == nullptr || pkt.size == 0) {
        return Status::Ok();  // 跳过空包（参数集/priming，PALA-010 已在 demux 侧过滤，双保险）
    }

    // 记录前两个喂入包的显示序差，作为首帧时长兜底（假定恒定帧率）。
    if (!fed_first_) {
        first_fed_pts_ = pkt.pts;
        fed_first_ = true;
    } else if (!fed_second_) {
        RationalTime d{0, kProjectTimeScale};
        if (SubRational(pkt.pts, first_fed_pts_, d).IsOk() && d.value > 0) {
            nominal_duration_ = d;
        }
        fed_second_ = true;
    }

    // 拷贝压缩数据（demuxer 的 last_data_ 在下次 ReadPacket 会被覆盖，必须拷贝）。
    CMBlockBufferRef block = nullptr;
    OSStatus st = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr, pkt.size,
                                                    kCFAllocatorDefault, nullptr, 0, pkt.size,
                                                    kCMBlockBufferAssureMemoryNowFlag, &block);
    if (st != noErr || block == nullptr) return Status{StatusCode::kDecodeError};
    st = CMBlockBufferReplaceDataBytes(pkt.data, block, 0, pkt.size);
    if (st != noErr) {
        CFRelease(block);
        return Status{StatusCode::kDecodeError};
    }

    CMSampleTimingInfo timing;
    timing.duration = kCMTimeInvalid;
    timing.presentationTimeStamp = CMTimeMake(pkt.pts.value, pkt.pts.timescale);
    timing.decodeTimeStamp = (pkt.dts.timescale > 0)
                                 ? CMTimeMake(pkt.dts.value, pkt.dts.timescale)
                                 : timing.presentationTimeStamp;

    CMSampleBufferRef sbuf = nullptr;
    st = CMSampleBufferCreateReady(kCFAllocatorDefault, block, format_desc_, 1, 1, &timing, 0,
                                   nullptr, &sbuf);
    CFRelease(block);  // sbuf 已 retain block
    if (st != noErr || sbuf == nullptr) return Status{StatusCode::kDecodeError};

    VTDecodeInfoFlags info = 0;
    st = VTDecompressionSessionDecodeFrame(
        session_, sbuf, kVTDecodeFrame_EnableAsynchronousDecompression, nullptr, &info);
    CFRelease(sbuf);
    if (st != noErr) return Status{StatusCode::kDecodeError};
    return Status::Ok();
}

// ---------------------------------------------------------------------------
// PopFrame：按显示序弹出一个已重建的展示帧
// ---------------------------------------------------------------------------
Status VideoToolboxDecoder::PopFrame(MediaFrame& out) {
    out = MediaFrame{};
    CVPixelBufferRef pb = nullptr;
    RationalTime pts{0, kProjectTimeScale};
    {
        std::unique_lock<std::mutex> lk(queue_mutex_);
        if (output_queue_.empty()) {
            lk.unlock();
            // 异步帧可能尚未解码完成：等其落地后再判定是否真耗尽（避免提前报告 kIoNotFound）。
            if (session_ != nullptr) {
                VTDecompressionSessionWaitForAsynchronousFrames(session_);
            }
            lk.lock();
            if (output_queue_.empty()) {
                return Status{StatusCode::kIoNotFound};  // 当前无可用帧（需继续 Feed / 已 drain）
            }
        }
        OutputFrame of = output_queue_.front();
        output_queue_.pop_front();
        pb = of.pb;
        pts = of.pts;

        RationalTime dur = nominal_duration_;
        if (has_prev_) {
            RationalTime d{0, kProjectTimeScale};
            if (SubRational(pts, prev_popped_pts_, d).IsOk()) dur = d;
        }
        prev_popped_pts_ = pts;
        has_prev_ = true;

        out.type = MediaType::kVideo;
        out.video.image = new CqNativeImage(pb);  // refcount=1，持有 pb（构造已 CFRetain）
        CFRelease(pb);  // 释放队列对 pb 的所有权，交由 CqNativeImage 独占
        out.video.pixel_format = PixelFormat::kBGRA8;
        out.video.color_space = ColorSpace::kRec709;
        out.video.width = width_;
        out.video.height = height_;
        out.video.pts = pts;
        out.video.duration = dur;

        // lease 模型：同一时刻只持有一个可消费帧，释放上一个返回的实例。
        if (last_returned_ != nullptr) {
            if (last_returned_->refcount.fetch_sub(1) == 1) delete last_returned_;
        }
        last_returned_ = static_cast<CqNativeImage*>(out.video.image);
    }
    ++popped_count_;
    return Status::Ok();
}

// ---------------------------------------------------------------------------
// Flush：清空待出队帧 + 复位时长跟踪（新 GOP 以 IDR 起，VT 内部 DPB 自动复位）
// ---------------------------------------------------------------------------
void VideoToolboxDecoder::Flush() {
    ReleaseOutputQueue();
    if (last_returned_ != nullptr) {
        if (last_returned_->refcount.fetch_sub(1) == 1) delete last_returned_;
        last_returned_ = nullptr;
    }
    has_prev_ = false;
    prev_popped_pts_ = RationalTime{0, 0};
}

// ---------------------------------------------------------------------------
// Apple 专属辅助：从 NativeImageHandle 取回 CVPixelBufferRef
// ---------------------------------------------------------------------------
CVPixelBufferRef GetCvPixelBuffer(NativeImageHandle handle) {
    auto* img = static_cast<CqNativeImage*>(handle);
    return (img != nullptr) ? img->pixel_buffer : nullptr;
}

}  // namespace cq
