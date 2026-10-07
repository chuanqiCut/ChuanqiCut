// ChuanqiCut — PALA-011 Apple 硬解后端实现（VTDecompressionSession）
//
// 见 media_decode.h 的设计说明。要点：
//   * H.264 / HEVC 硬解（优先硬件，运行时查询是否真硬解）。HEVC 是 MEDIA-022
//     新增 —— iPhone 相册默认编码，不支持 = 相册导入几乎全挂。
//   * SPS/PPS（avcC）与 VPS/SPS/PPS（hvcC）注入：Open 时经 source path 打开
//     AVAsset 取视频轨 CMFormatDescription 建立解码会话，无需手解参数集、
//     不碰已废弃 API。
//   * dts→pts 重排：VideoToolbox 内部 DPB 已在显示序回调，PopFrame 按显示序出队。
//   * seek 后 flush：Flush 清空待出队帧并复位时长跟踪；新 GOP 以 IDR/IRAP 起，VT 内部复位。
//
// 红线：零 FFmpeg 类型；平台类型只在本 .mm / media_decode.h；错误一律 Status；内核禁用异常。

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "cq/base/logging.h"
#include "cq/base/perf.h"
#include "cq/base/status.h"
#include "cq/base/rational_time.h"
#include "media_decode.h"

namespace cq {

// 慢调用告警统一走 core/base 的 CQ_SLOW_CALL_WF（CORE-010）。
// 旧版是本文件自己抄的一份 `#ifndef NDEBUG` 结构体——**Release 包里什么都不留**，
// 而 MEDIA-027 定位冻结时唯一指认到 `provider+acquire 8226ms` 的就是它。
// 现在它属于 kPerf 链路的 Warn，**Release 也能看见**，且可用 CQ_LOG_WORKFLOW 筛。

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
// 输出回调（完成序，≈dts 序，非显示序！）：完成登记 + 把 CVPixelBuffer 入队，
// 显示序重排在 PopFrame 内做（见 media_decode.h 设计要点）。
// ---------------------------------------------------------------------------
void VideoToolboxDecoder::OutputCallback(void* ref_con, void* source_ref_con, OSStatus status,
                                         VTDecodeInfoFlags info_flags, CVImageBufferRef image_buffer,
                                         CMTime pts, CMTime duration) {
    (void)info_flags;
    (void)duration;
    auto* self = static_cast<VideoToolboxDecoder*>(ref_con);
    // source_ref_con = DecodeFrame 传入的源 CMSampleBuffer（已 CFRetain）：取 dts 后释放。
    RationalTime dts{0, 0};  // timescale=0 = 无效（无 dts 可用时不得登记/参与重排）
    CMSampleBufferRef sbuf = static_cast<CMSampleBufferRef>(source_ref_con);
    if (sbuf != nullptr) {
        CMTime dts_cm = CMSampleBufferGetDecodeTimeStamp(sbuf);
        if (CMTIME_IS_NUMERIC(dts_cm)) dts = self->ToRational(dts_cm);
        CFRelease(sbuf);
    }
    if (self == nullptr) return;
    // ⚠️ MEDIA-027 顺序约束：**先入队，再做完成登记**。
    //
    // 反过来的顺序（原实现：先 MarkDecoded 再 Enqueue）有一个真实竞态：等待方
    // （PopFrame 的重排等待 / Flush 的「等在途帧落地」）以 pending 集合空为
    // 「全部完成」的判据，而 MarkDecoded 先清空 pending 时该帧**还没进队列** ——
    // 等待方据此清队/放行，随后这一帧才入队，于是上一解码区间的旧帧漏进新序列。
    // MEDIA-021 实测到的「Seek 后首弹弹出旧 GOP 的 128000」即此形态。
    // 先入队后登记，「pending 空」才真正蕴含「已产出的帧都已在队列里」。
    if (status == noErr && image_buffer != nullptr) {
        CVPixelBufferRef pb = reinterpret_cast<CVPixelBufferRef>(image_buffer);
        self->Enqueue(pb, self->ToRational(pts), dts);
    }
    // 完成登记：无论成败都从 pending 移除 —— 丢帧/解错的包不能永远压住重排等待。
    if (dts.timescale != 0) {
        self->MarkDecoded(dts);
#ifndef NDEBUG
        self->DebugRecordLatency(
            dts.value,
            static_cast<uint64_t>(
                std::chrono::steady_clock::now().time_since_epoch().count()));
#endif
    }
}

void VideoToolboxDecoder::Enqueue(CVPixelBufferRef pb, const RationalTime& pts,
                                  const RationalTime& dts) {
    if (pb == nullptr) return;
    CFRetain(pb);  // 取所有权（回调的 imageBuffer 由 VT 持有，须保留）
    std::lock_guard<std::mutex> lk(queue_mutex_);
    output_queue_.push_back({pb, pts, dts});
#ifndef NDEBUG
    // MEDIA-027：队列深度是「解码出的帧有没有被消费掉」的直接观测量 —— 播放期
    // 间它应当稳定在个位数（喂一包弹一帧），持续单调增长即队列只进不出。
    if (output_queue_.size() % 50 == 0) {
        CQ_LOG_TRACE_WF(Workflow::kDecode, "output_queue_ 深度=%zu", output_queue_.size());
    }
    if (debug_enqueue_logs_ < 3) {
        ++debug_enqueue_logs_;
        CQ_LOG_TRACE_WF(Workflow::kDecode, "enqueue pts=%lld/%d dts=%lld/%d (q=%zu)",
                        static_cast<long long>(pts.value), static_cast<int>(pts.timescale),
                        static_cast<long long>(dts.value), static_cast<int>(dts.timescale),
                        output_queue_.size());
    }
#endif
}

void VideoToolboxDecoder::MarkDecoded(const RationalTime& dts) {
    std::lock_guard<std::mutex> lk(queue_mutex_);
    pending_dts_pts_.erase(dts.value);
    pending_submit_nanos_.erase(dts.value);
}

#ifndef NDEBUG
void VideoToolboxDecoder::DebugRecordSubmit(int64_t dts_value, uint64_t nanos) {
    std::lock_guard<std::mutex> lk(queue_mutex_);
    debug_submit_nanos_[dts_value] = nanos;
}

void VideoToolboxDecoder::DebugRecordLatency(int64_t dts_value, uint64_t now_nanos) {
    std::lock_guard<std::mutex> lk(queue_mutex_);
    const auto it = debug_submit_nanos_.find(dts_value);
    if (it == debug_submit_nanos_.end()) return;  // 无配对提交时刻（理论不可达）
    debug_latency_nanos_.push_back(now_nanos - it->second);
    debug_submit_nanos_.erase(it);
    if (debug_latency_nanos_.size() % 60 == 0) {
        std::vector<uint64_t> sorted = debug_latency_nanos_;
        std::sort(sorted.begin(), sorted.end());
        auto ms = [](uint64_t n) { return n / 1'000'000; };
        CQ_LOG_TRACE_WF(Workflow::kDecode,
                        "decode latency (n=%zu) min=%llums p50=%llums p95=%llums max=%llums",
                        sorted.size(), ms(sorted.front()), ms(sorted[sorted.size() / 2]),
                        ms(sorted[sorted.size() * 95 / 100]), ms(sorted.back()));
    }
}
#endif

// ---------------------------------------------------------------------------
// MEDIA-025：HDR 源判定（纯函数，供单测）
// ---------------------------------------------------------------------------
bool VideoToolboxDecoder::IsHdrColorSource(CFStringRef primaries, CFStringRef transfer) {
    // 传递函数 HLG/PQ = HDR，无论原色域 —— 必须转换后再进 SDR 渲染链。
    if (transfer != nullptr &&
        (CFEqual(transfer, kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG) ||
         CFEqual(transfer, kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ))) {
        return true;
    }
    // BT.2020 宽色域 + 非 709 传递函数（或标签缺失的未知传递函数）= 按 HDR 处理。
    // 709 传递函数的 2020 素材（SDR 宽色域）不转 —— 只有色域差异，转换收益小 [E]。
    const bool wide_gamut =
        primaries != nullptr &&
        CFEqual(primaries, kCMFormatDescriptionColorPrimaries_ITU_R_2020);
    const bool sdr_709 = transfer == nullptr ||
                         CFEqual(transfer, kCMFormatDescriptionTransferFunction_ITU_R_709_2);
    return wide_gamut && !sdr_709;
}

// ---------------------------------------------------------------------------
// Open：取得 codec 描述并建立 VT 会话
// ---------------------------------------------------------------------------
Status VideoToolboxDecoder::Open(const StreamInfo& info) {
    // CORE-010：Release 也要看见（旧版被 #ifndef NDEBUG 挡住，Release 包零告警）。
    CQ_SLOW_CALL_WF(Workflow::kDecode, "decoder Open(VT 会话)");
    // 幂等：先清旧会话（若存在），避免重复 Open 累积。
    TeardownSession();
    ReleaseOutputQueue();
    if (last_returned_ != nullptr) {
        if (last_returned_->refcount.fetch_sub(1) == 1) delete last_returned_;
        last_returned_ = nullptr;
    }
    has_prev_ = false;
    order_mismatch_streak_ = 0;  // MEDIA-027
    prev_popped_pts_ = RationalTime{0, 0};
    {
        std::lock_guard<std::mutex> lk(queue_mutex_);
        pending_dts_pts_.clear();
        pending_submit_nanos_.clear();  // 与 pending_dts_pts_ 必须同清（MEDIA-027）
    }
    fed_first_ = false;
    fed_second_ = false;
    popped_count_ = 0;
    session_hw_ = false;

    bound_codec_ = info.codec;
    width_ = info.width;
    height_ = info.height;

    // MEDIA-022：H.264 + HEVC。HEVC 是 iPhone 相册默认编码（含杜比视界基底），
    // 不支持 = 相册导入几乎全挂。实现路径与 H.264 完全同构：格式描述（hvcC）
    // 直接取自视频轨 CMFormatDescription 建 VT 会话 —— 旧注释里「parameter-set
    // 构造 API 已废弃」的顾虑不适用（我们从不手解 parameter set）。
    const bool want_hevc = (bound_codec_ == CodecId::kHevc);
    if (bound_codec_ != CodecId::kH264 && !want_hevc) {
        // ProRes/MJPEG 等其它编码诚实返回不支持，绝不伪造。
        return Status{StatusCode::kDecodeUnsupported};
    }
    if (source_path_.empty()) {
        // 无 source path 无法取得 avcC/hvcC；诚实报告缺 codec 描述。
        return Status{StatusCode::kDecodeUnsupported};
    }

    // 经 AVAsset 取得视频轨 CMFormatDescription（内嵌 avcC/hvcC，含参数集）。
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
        // MEDIA-025：读源色彩标签（重建 'hvc1' 格式描述会丢扩展，必须在此处读；
        // CFString 由 fd 持有，先拷成 std::string 防 fd 释放后悬空）。
        // iPhone 实拍 = BT.2020 原色域 + HLG/PQ（或杜比视界封装）——全链路此前
        // 零色彩管理，HDR 素材直接吐 BGRA 按 sRGB 显示 → 颜色失真（用户实测反馈）。
        const CFStringRef prim = static_cast<CFStringRef>(CMFormatDescriptionGetExtension(
            fd, kCMFormatDescriptionExtension_ColorPrimaries));
        const CFStringRef transfer = static_cast<CFStringRef>(CMFormatDescriptionGetExtension(
            fd, kCMFormatDescriptionExtension_TransferFunction));
        const CFStringRef matrix = static_cast<CFStringRef>(CMFormatDescriptionGetExtension(
            fd, kCMFormatDescriptionExtension_YCbCrMatrix));
        hdr_source_ = IsHdrColorSource(prim, transfer);
        auto tag_to_str = [](CFStringRef s) {
            if (s == nullptr) return std::string();
            char buf[64] = {};
            if (CFStringGetCString(s, buf, sizeof(buf), kCFStringEncodingUTF8)) {
                return std::string(buf);
            }
            return std::string();
        };
        src_primaries_ = tag_to_str(prim);
        src_transfer_ = tag_to_str(transfer);
        src_matrix_ = tag_to_str(matrix);
        // 格式描述 codec 必须与 demuxer 报告的流编码一致（HEVC = 'hvc1'/'hev1'；
        // 杜比视界 'dvh1'/'dvhe' 是 HEVC 基底 + 扩展，按 HEVC 会话尝试 —— VT 不接受
        // 时如实 kDecodeError，不伪造成功）。
        const FourCharCode codec = CMVideoFormatDescriptionGetCodecType(fd);
        const FourCharCode kHev1 = 'hev1';
        const FourCharCode kDolbyHvc1 = 'dvh1';
        const FourCharCode kDolbyHevc = 'dvhe';
        const bool codec_ok =
            want_hevc ? (codec == kCMVideoCodecType_HEVC || codec == kHev1 ||
                         codec == kDolbyHvc1 || codec == kDolbyHevc)
                      : (codec == kCMVideoCodecType_H264);
        if (!codec_ok) {
            return Status{StatusCode::kDecodeUnsupported};
        }
        CFRetain(fd);
        format_desc_ = fd;

        // MEDIA-022：VT 解码器按 'hvc1' 注册，'hev1'/'dvh1'/'dvhe' 格式描述会
        // 匹配不到解码器（VTDecompressionSessionCreate 返回 -12906
        // kVTUnsupportedDecompressionErr）—— 实测于本机 macOS 26 Intel。
        // 修法：用**同一份 hvcC** 重建 subtype='hvc1' 的格式描述（hvc1 与 hev1
        // 的码流与参数集完全相同，差别只在参数集是否允许随流携带）。iPhone
        // 实拍本来就是 'hvc1'，此重建只服务 ffmpeg 等工具产出的素材。
        if (want_hevc && codec != kCMVideoCodecType_HEVC) {
            CFDictionaryRef atoms = static_cast<CFDictionaryRef>(CMFormatDescriptionGetExtension(
                fd, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms));
            CFDataRef hvcc =
                atoms != nullptr
                    ? static_cast<CFDataRef>(CFDictionaryGetValue(atoms, CFSTR("hvcC")))
                    : nullptr;
            if (hvcc == nullptr) {
                CFRelease(fd);
                format_desc_ = nullptr;
                return Status{StatusCode::kDecodeUnsupported};  // 无 hvcC 无法重建
            }
            CFStringRef atom_keys[] = {CFSTR("hvcC")};
            CFTypeRef atom_values[] = {hvcc};
            CFDictionaryRef atom_dict = CFDictionaryCreate(
                kCFAllocatorDefault, reinterpret_cast<const void**>(atom_keys),
                reinterpret_cast<const void**>(atom_values), 1,
                &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            CFStringRef ext_key = kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms;
            CFDictionaryRef ext = CFDictionaryCreate(
                kCFAllocatorDefault, reinterpret_cast<const void**>(&ext_key),
                reinterpret_cast<const void**>(&atom_dict), 1, &kCFTypeDictionaryKeyCallBacks,
                &kCFTypeDictionaryValueCallBacks);
            CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(fd);
            CMVideoFormatDescriptionRef rebuilt = nullptr;
            OSStatus rst = CMVideoFormatDescriptionCreate(
                kCFAllocatorDefault, kCMVideoCodecType_HEVC, dims.width, dims.height, ext,
                &rebuilt);
            CFRelease(ext);
            CFRelease(atom_dict);
            if (rst != noErr || rebuilt == nullptr) {
                CFRelease(fd);
                format_desc_ = nullptr;
                // Error：这是**失败返回路径**，Release 必须留痕。
                CQ_LOG_ERROR_WF(Workflow::kDecode, "hvc1 重建失败 osstatus=%d",
                                static_cast<int>(rst));
                return Status{StatusCode::kDecodeError};
            }
            CFRelease(fd);      // 换用重建后的格式描述（原 fd 仅为 hvcC 来源）
            format_desc_ = rebuilt;
        }
    }

    // 建立 VT 解码会话（优先硬件；是否真硬解运行后查询）。
    VTDecompressionOutputCallbackRecord cb{&VideoToolboxDecoder::OutputCallback, this};
    // MEDIA-023：预览吞吐修复——输出降采样到 ≤1080p（解码+缩放 VT 内部一体完成，
    // 经 destinationImageBufferAttributes 的 kCVPixelBufferWidth/HeightKey 声明）。
    // 真机剖面（baselines「预览播放吞吐」）：4K60 实拍素材全尺寸 VT→BGRA 转换时
    // 泵仅 17~32 帧/s；输出 ≤1080p 后每帧 BGRA ≤6MB，转换/导入/blit 全链路受益。
    // 1080p 及以下素材尺寸不变（attrs 不带尺寸键，行为同旧）。
    const CMVideoDimensions src_dims = CMVideoFormatDescriptionGetDimensions(format_desc_);
    const auto clamped = ClampOutputDimensions(src_dims.width, src_dims.height);
    output_width_ = static_cast<uint32_t>(clamped.first);
    output_height_ = static_cast<uint32_t>(clamped.second);
    NSMutableDictionary* attrs = [@{
        (__bridge id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (__bridge id)kCVPixelBufferMetalCompatibilityKey: @YES,
    } mutableCopy];
    if (output_width_ != static_cast<uint32_t>(src_dims.width) ||
        output_height_ != static_cast<uint32_t>(src_dims.height)) {
        attrs[(__bridge id)kCVPixelBufferWidthKey] = @(output_width_);
        attrs[(__bridge id)kCVPixelBufferHeightKey] = @(output_height_);
        // Info：降采样是**用户可见的行为变化**（画质下来了），值得留到 Release。
        CQ_LOG_INFO_WF(Workflow::kDecode, "输出降采样 %ux%u -> %ux%u（MEDIA-023）",
                       static_cast<unsigned>(src_dims.width),
                       static_cast<unsigned>(src_dims.height), output_width_, output_height_);
    }
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
        // 诊断打印（与 demuxer 的排障打印同风格）：OSStatus + 格式关键参数进日志。
        // 已知案例（MEDIA-022 排障）：'hev1' HEVC 在部分平台要求特定输出属性。
        const FourCharCode fcc = CMVideoFormatDescriptionGetCodecType(format_desc_);
        int chroma = -1, depth_luma = -1, depth_chroma = -1;
        CFDictionaryRef atoms = static_cast<CFDictionaryRef>(CMFormatDescriptionGetExtension(
            format_desc_, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms));
        if (atoms != nullptr) {
            CFDataRef hvcc = static_cast<CFDataRef>(CFDictionaryGetValue(atoms, CFSTR("hvcC")));
            if (hvcc != nullptr && CFDataGetLength(hvcc) > 20) {
                const uint8_t* h = CFDataGetBytePtr(hvcc);
                chroma = static_cast<int>(h[16] & 0x03);
                depth_luma = static_cast<int>(h[18] & 0x07) + 8;
                depth_chroma = static_cast<int>(h[19] & 0x07) + 8;
            }
        }
        CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(format_desc_);
        std::fprintf(
            stderr,
            "[VideoToolboxDecoder] VTDecompressionSessionCreate failed osstatus=%d "
            "(codec=%c%c%c%c %ux%u chroma=%d luma=%dbit chroma_depth=%dbit)\n",
            static_cast<int>(st), static_cast<int>((fcc >> 24) & 0xFF),
            static_cast<int>((fcc >> 16) & 0xFF), static_cast<int>((fcc >> 8) & 0xFF),
            static_cast<int>(fcc & 0xFF), static_cast<unsigned>(dims.width),
            static_cast<unsigned>(dims.height), chroma, depth_luma, depth_chroma);
        fflush(stderr);
        return Status{StatusCode::kDecodeError};
    }

    // MEDIA-023 备注：输出尺寸经 destinationImageBufferAttributes 声明（会话创建时
    // 生效），无创建后属性可设；若 VT 对该格式拒绝降采样，会话创建本身会失败并
    // 走上方 -12906/-12907 诊断打印，行为诚实可见。

    // MEDIA-025：HDR 源 → 命令 VT 的 PixelTransfer 把输出转换到 BT.709 SDR
    // （解码+色彩转换 VT 内部一体完成，零额外 pass）。⚠️ PixelTransfer 属性必须
    // **打包成字典**经 kVTDecompressionPropertyKey_PixelTransferProperties 设置
    // —— 直接对会话设子键返回 -12900 kVTParameterErr（真机实测）。属性被拒 =
    // 如实日志并保持旧行为（颜色仍不对但不阻塞解码）。
    if (hdr_source_) {
        NSDictionary* xfer = @{
            (__bridge id)kVTPixelTransferPropertyKey_DestinationColorPrimaries:
                (__bridge id)kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
            (__bridge id)kVTPixelTransferPropertyKey_DestinationTransferFunction:
                (__bridge id)kCMFormatDescriptionTransferFunction_ITU_R_709_2,
            (__bridge id)kVTPixelTransferPropertyKey_DestinationYCbCrMatrix:
                (__bridge id)kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2,
        };
        const OSStatus ps = VTSessionSetProperty(
            session_, kVTDecompressionPropertyKey_PixelTransferProperties,
            (__bridge CFDictionaryRef)xfer);
        const bool ok = ps == noErr;
        color_converted_ = ok;
        CQ_LOG_INFO_WF(Workflow::kDecode,
                       "色彩管理: src(prim=%s transfer=%s matrix=%s) hdr=%d -> 709/SDR %s (status=%d)",
                       src_primaries_.c_str(), src_transfer_.c_str(), src_matrix_.c_str(),
                       hdr_source_ ? 1 : 0, ok ? "已应用" : "被拒（保持旧行为）",
                       static_cast<int>(ps));
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
    CQ_LOG_INFO_WF(Workflow::kDecode, "Open 完成 hw=%s out=%ux%u 色彩(源=%s/%s%s)",
                   session_hw_ ? "YES" : "NO/unknown", output_width_, output_height_,
                   src_primaries_.c_str(), src_transfer_.c_str(),
                   color_converted_ ? " →已转709" : (hdr_source_ ? " →转换失败" : ""));
    fflush(stderr);

    return Status::Ok();
}

// ---------------------------------------------------------------------------
// Feed：把 AVCC/HVCC 压缩包拷成 CMSampleBuffer 喂入解码器
// ---------------------------------------------------------------------------
Status VideoToolboxDecoder::Feed(const MediaPacket& pkt) {
    // MEDIA-027：泵线程无 autorelease pool（同 demuxer 侧），逐包调用自带池。
    @autoreleasepool {
    if (session_ == nullptr || format_desc_ == nullptr) {
        return Status{StatusCode::kDecodeError};
    }
    if (pkt.codec != bound_codec_) {
        return Status::Ok();  // 跳过非本路（如音频）包，demuxer 可能交错吐多路
    }
    if (pkt.data == nullptr || pkt.size == 0) {
        return Status::Ok();  // 跳过空包（参数集/priming，PALA-010 已在 demux 侧过滤，双保险）
    }

    // 记录前两个喂入包的 dts 差，作为首帧时长兜底（假定恒定帧率）。
    // ⚠️ 必须用 dts 差而非 pts 差（MEDIA-021 实测暴露）：喂入是解码序，B 帧存在时
    // 前两个包是 I 和其后的参考帧，pts 差 = (bframes+1) 帧（本 golden = 4 帧）——
    // 首帧展示区间被报宽 4 倍，kExact 的「区间归属」会在关键帧上提前命中，
    // 画面差 1~3 帧。CFR 下解码序相邻 dts 间隔恒为一帧，与 B 帧排布无关。
    if (!fed_first_) {
        first_fed_dts_ = pkt.dts;
        fed_first_ = true;
    } else if (!fed_second_) {
        RationalTime d{0, kProjectTimeScale};
        if (SubRational(pkt.dts, first_fed_dts_, d).IsOk() && d.value > 0) {
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
    // CORE-010：Release 也要看见（旧版 SlowCallAlarm 被 NDEBUG 挡住，Release 包零告警）。
    CQ_SLOW_CALL_WF(Workflow::kDecode, "decoder Feed(VT 提交)");
#ifndef NDEBUG
    // 成对 enter/exit：**用于定位「进去了没出来」** —— Watchdog 只能报「当前卡在
    // 哪」，但一次性的永久阻塞要靠这一对才能指认到函数。Release 下整段消失。
    static std::atomic<int> feed_seq{0};
    const int my_feed_seq = feed_seq.fetch_add(1);
    CQ_LOG_TRACE_WF(Workflow::kDecode, "Feed enter #%d", my_feed_seq);
    struct FeedExitLog {
        int seq;
        ~FeedExitLog() { CQ_LOG_TRACE_WF(Workflow::kDecode, "Feed exit #%d", seq); }
    } feed_exit{my_feed_seq};
#endif

    // 登记未完成包（重排依据）——必须在 DecodeFrame **之前**：回调可能在另一线程
    // 立即完成并 erase，若先提交后登记会产生永不清理的幽灵条目。
    //
    // ⚠️ P77：登记还必须在 queue_mutex_ **之下**做。这两张 map 的另一侧写入方是
    // VT 输出回调（CoreMedia 线程，MarkDecoded 持锁 erase / Enqueue 持锁入队）。
    // 早先这里是无锁插入，与回调的持锁 erase 构成并发读写 std::map —— 红黑树被
    // 写坏，表现为 Feed() 内 map::operator[] → __tree_balance_after_insert 解引用
    // 空节点 SIGSEGV（门禁 core-dbg 复现，堆栈见 .ips）。顺序对了不等于互斥对了。
    // 锁必须在 VTDecompressionSessionDecodeFrame **之前释放**：回调要抢同一把锁，
    // 持锁提交会自锁死。
    {
        std::lock_guard<std::mutex> lk(queue_mutex_);
        pending_dts_pts_[pkt.dts.value] = pkt.pts;
        pending_submit_nanos_[pkt.dts.value] =
            static_cast<uint64_t>(std::chrono::steady_clock::now().time_since_epoch().count());
    }

    VTDecodeInfoFlags info = 0;
    // sourceFrameRefCon 传 CFRetain(sbuf)：回调从中取 dts 做完成登记，并负责释放。
    void* source_ref = const_cast<void*>(CFRetain(sbuf));
#ifndef NDEBUG
    const auto submit_nanos =
        static_cast<uint64_t>(std::chrono::steady_clock::now().time_since_epoch().count());
#endif
    st = VTDecompressionSessionDecodeFrame(session_, sbuf,
                                           kVTDecodeFrame_EnableAsynchronousDecompression,
                                           source_ref, &info);
    CFRelease(sbuf);
#ifndef NDEBUG
    if (st == noErr) DebugRecordSubmit(pkt.dts.value, submit_nanos);
#endif
    if (st != noErr) {
        // 提交失败：回调不会发生，完成登记须在本线程补齐，否则重排会永远等待。
        {
            std::lock_guard<std::mutex> lk(queue_mutex_);
            pending_dts_pts_.erase(pkt.dts.value);
        }
        return Status{StatusCode::kDecodeError};
    }
    return Status::Ok();
    }  // @autoreleasepool（MEDIA-027）
}

// ---------------------------------------------------------------------------
// PopFrame：重排后按显示序弹出一个已重建的展示帧
//
// VT 回调按完成序（≈dts 序）入队，B 帧在其参考 P 之后完成 —— 直接弹队首会把
// P 当作显示序下一帧交付（kExact 差帧 + 负 duration，MEDIA-021 逐帧 pts 断言
// 实测暴露）。重排判据（精确，无需知道 B 帧深度）：
//   显示序连续性 —— 上一弹出帧 pts + duration = 本帧期望 pts（duration 即相邻
//   pts 差，CFR/VFR 皆成立）。队列最小 pts ≠ 期望 ⇒ 显示序下一帧尚未入队：
//   在途帧（pending 非空）可能补上 → 等待；无在途帧 → 返回 kIoNotFound，
//   由 provider 继续喂包（「B 未喂入」正是靠这个揭示的）。
// 流尾丢帧（demux 尽后仍缺帧）时 provider 走 drain 分支交付 before，会话不挂死。
// ---------------------------------------------------------------------------
Status VideoToolboxDecoder::PopFrame(MediaFrame& out) {
    // CORE-010：PopFrame 是 MEDIA-026/027 两次冻结的现场，告警必须 Release 可见。
    CQ_SLOW_CALL_WF(Workflow::kDecode, "decoder PopFrame(VT wait)");
#ifndef NDEBUG
    static std::atomic<int> pop_seq{0};
    const int my_pop_seq = pop_seq.fetch_add(1);
    CQ_LOG_TRACE_WF(Workflow::kDecode, "PopFrame enter #%d", my_pop_seq);
    struct PopExitLog {
        int seq;
        ~PopExitLog() { CQ_LOG_TRACE_WF(Workflow::kDecode, "PopFrame exit #%d", seq); }
    } pop_exit{my_pop_seq};
#endif
    out = MediaFrame{};
    CVPixelBufferRef pb = nullptr;
    RationalTime pts{0, kProjectTimeScale};
    {
        std::unique_lock<std::mutex> lk(queue_mutex_);
        size_t best = 0;
        for (;;) {
            if (output_queue_.empty()) {
                // MEDIA-026：等 in-flight 帧落地——2ms 轮询替代 VTWait（VT 静默
                // 丢帧时 VTWait **永久阻塞**，真机实测 PopFrame 进入后不返回）。
                // 退出条件：a) 队列有帧（回主流程弹出）b) pending 全完成（真耗尽）
                // c) 丢帧超时（最老 pending >1s → 按丢失处理，重新 seek 恢复）。
                while (output_queue_.empty()) {
                    const uint64_t now_nanos = static_cast<uint64_t>(
                        std::chrono::steady_clock::now().time_since_epoch().count());
                    bool aged = false;
                    for (const auto& [dts_value, submit] : pending_submit_nanos_) {
                        if (now_nanos - submit > 1'000'000'000ull) {
                            // Warn：本帧被放弃，媒体已不完整。Release 必须可见。
                            CQ_LOG_WARN_WF(Workflow::kDecode,
                                           "丢帧超时：dts=%lld 等 %llums 未完成，放弃等待（重新 seek 恢复）",
                                           static_cast<long long>(dts_value),
                                           static_cast<long long>((now_nanos - submit) / 1'000'000));
                            aged = true;
                            break;
                        }
                    }
                    if (aged) {
                        pending_dts_pts_.clear();
                        pending_submit_nanos_.clear();
                        has_prev_ = false;  // 显示序锚点失效，下一帧重新锚定
                        return Status{StatusCode::kIoNotFound};
                    }
                    if (pending_dts_pts_.empty()) {
                        // 无在途帧且队列空：需继续 Feed / 已 drain（不丢帧）。
                        return Status{StatusCode::kIoNotFound};
                    }
                    lk.unlock();
                    std::this_thread::sleep_for(std::chrono::milliseconds(2));
                    lk.lock();
                }
            }
            // 队列内 pts 最小帧（完成序乱序窗口有限，O(n) 扫描开销可忽略）。
            best = 0;
            for (size_t i = 1; i < output_queue_.size(); ++i) {
                if (CompareRational(output_queue_[i].pts, output_queue_[best].pts) < 0) best = i;
            }
            // MEDIA-027 闸门：队列超过上界即**跳过重排判据、强制交付最小帧**。
            // 不依赖判据正确性也能保证「队列一定会出」，内存因此有界。
            if (output_queue_.size() > kMaxQueuedFrames) {
                ++debug_queue_cap_hits_;
                if (debug_queue_cap_logs_ < 5 || debug_queue_cap_hits_ % 100 == 0) {
                    ++debug_queue_cap_logs_;
                    // Warn **且 Release 可见**：闸门被触发意味着「重排判据没能正常消化
                    // 队列」，是 MEDIA-027 那种病的最早信号。#ifndef NDEBUG 挡住它
                    // 等于把这个信号从所有真机 Release 包里抹掉。
                    CQ_LOG_WARN_WF(Workflow::kMem,
                                   "队列超上界(%zu)：跳过重排判据强制交付 pts=%lld/%d（第 %d 次）",
                                   kMaxQueuedFrames,
                                   static_cast<long long>(output_queue_[best].pts.value),
                                   static_cast<int>(output_queue_[best].pts.timescale),
                                   debug_queue_cap_hits_);
                }
                has_prev_ = false;  // 重锚显示序：后续 duration 用标称值，不拿缺口算差
                break;
            }
            if (!has_prev_) break;  // 流首 / Flush 后：无显示序连续性约束，队列最小帧即首帧
            // 显示序连续性检查。
            RationalTime expected{0, 1};
            if (!AddRational(prev_popped_pts_, prev_duration_, expected).IsOk()) {
                break;  // 期望算不出（溢出）：放弃约束，宁弹不错
            }
            if (CompareRational(output_queue_[best].pts, expected) == 0) break;  // 匹配，安全弹出
            if (!pending_dts_pts_.empty()) {
                // 有在途帧：它完成后可能填补缺口 → 等待后重查（2ms 轮询）。
                lk.unlock();
                std::this_thread::sleep_for(std::chrono::milliseconds(2));
                lk.lock();
                // MEDIA-026：丢帧超时（最老 pending >1s → 按丢失处理）。队列空时
                // **不在此返回**——交回主循环顶部的轮询（在途帧会经回调入队）。
                const uint64_t now_nanos = static_cast<uint64_t>(
                    std::chrono::steady_clock::now().time_since_epoch().count());
                for (const auto& [dts_value, submit] : pending_submit_nanos_) {
                    if (now_nanos - submit > 1'000'000'000ull) {
                        CQ_LOG_WARN_WF(Workflow::kDecode,
                                       "显示序等待超时：pending=%zu 有帧超 1s 未完成，放弃（重新 seek 恢复）",
                                       pending_submit_nanos_.size());
                        pending_dts_pts_.clear();
                        pending_submit_nanos_.clear();
                        has_prev_ = false;
                        return Status{StatusCode::kIoNotFound};
                    }
                }
                continue;
            }
            // 无在途帧且队列最小帧不匹配期望：可能是
            //   (a) 显示序下一帧还没喂进来（B 帧重排 —— **常态**，必须继续等）；
            //   (b) 缺口已成事实（VT 静默丢帧，或 VFR 让「上一帧 duration」外推
            //       失效），期望的那一帧永远不会来 —— 必须按缺口放行。
            //
            // ⚠️ MEDIA-027：旧实现在此**一律原样返回 kIoNotFound 且不弹出**。由于
            //    期望值与队列最小帧都不变，下一次 PopFrame 会做出完全相同的判定，
            //    于是无限重复：provider 继续 Feed → 解码继续入队 → 队列只进不出。
            //    实测真机 iPhone 17 Pro（1080x1920 BGRA ≈ 8.3MB/帧）：累积数百帧
            //    即 footprint 3.4GB，进程被 jetsam 以 signal 9 杀掉 —— 这就是
            //    「播放 5 秒后永久卡死」的真身。
            //
            //    但**不能**一见到不匹配就按缺口放行：B 帧重排下这是常态（先喂到的
            //    是参考 P，其 B 帧在其后才喂入），立即放行会跳过 B 帧 —— 首版修复
            //    就是这样把 media_sequential_real 打挂的（快路径比慢路径提前 3 帧）。
            //    故用「连续 mismatch 且已无在途帧」的**次数**区分二者：重排窗口内
            //    的几次是正常的，超过上界即判定为缺口。
            ++order_mismatch_streak_;
            if (order_mismatch_streak_ < kMaxMismatchStreak) {
                return Status{StatusCode::kIoNotFound};
            }
            ++debug_order_stall_;
            if (debug_order_stall_logs_ < 5 || debug_order_stall_ % 100 == 0) {
                ++debug_order_stall_logs_;
                // Warn **且 Release 可见**：这一行就是 MEDIA-027 指认真因（VFR 导致
                // 期望值与队列最小帧永不匹配）的直接证据。限流保留，等级提升。
                CQ_LOG_WARN_WF(Workflow::kDecode,
                               "显示序缺口 #%d：连续 %d 次未等到期望=%lld/%d，按缺口交付 pts=%lld/%d（q=%zu）",
                               debug_order_stall_, order_mismatch_streak_,
                               static_cast<long long>(expected.value),
                               static_cast<int>(expected.timescale),
                               static_cast<long long>(output_queue_[best].pts.value),
                               static_cast<int>(output_queue_[best].pts.timescale),
                               output_queue_.size());
            }
            has_prev_ = false;  // 重锚：缺口的 duration 不能拿来外推下一帧
            break;
        }
        OutputFrame of = output_queue_[best];
        output_queue_.erase(output_queue_.begin() + static_cast<long>(best));
        order_mismatch_streak_ = 0;  // 本次等待结束（MEDIA-027）
        pb = of.pb;
        pts = of.pts;

        RationalTime dur = nominal_duration_;
        if (has_prev_) {
            RationalTime d{0, kProjectTimeScale};
            if (SubRational(pts, prev_popped_pts_, d).IsOk()) dur = d;
        }
        prev_duration_ = dur;  // 下一帧的显示序期望 = pts + dur
        prev_popped_pts_ = pts;
        has_prev_ = true;

        out.type = MediaType::kVideo;
        out.video.image = new CqNativeImage(pb);  // refcount=1，持有 pb（构造已 CFRetain）
        CFRelease(pb);  // 释放队列对 pb 的所有权，交由 CqNativeImage 独占
        out.video.pixel_format = PixelFormat::kBGRA8;
        out.video.color_space = ColorSpace::kRec709;
        // MEDIA-023：实际输出尺寸（降采样后）—— 调用方（视口计算/复用判据）
        // 依赖它与真实 CVPixelBuffer 一致；源尺寸见 width_/height_。
        out.video.width = output_width_;
        out.video.height = output_height_;
        out.video.pts = pts;
        out.video.duration = dur;
#ifndef NDEBUG
        if (debug_pop_logs_ < 3) {
            ++debug_pop_logs_;
            CQ_LOG_TRACE_WF(Workflow::kDecode, "pop pts=%lld/%d dur=%lld/%d",
                            static_cast<long long>(out.video.pts.value),
                            static_cast<int>(out.video.pts.timescale),
                            static_cast<long long>(out.video.duration.value),
                            static_cast<int>(out.video.duration.timescale));
        }
#endif

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
    // 先等在途帧落地再清队：异步回调可能在 Flush 后才到达（B 帧晚于其参考帧
    // 完成），若不清会把上一解码区间的旧帧漏进新序列的首弹（MEDIA-021 实测：
    // Seek 后首弹弹出旧 GOP 的 128000）。provider 串行调用 Flush/Feed，无并发。
    if (session_ != nullptr) {
        // MEDIA-026 已证：VT 在**静默丢帧**（永不回调）时该 API 永久阻塞 —— 泵线程
        // 卡死即「播放 5 秒后冻结」的真身（真机成对日志实测：PopFrame 进入后无 exit）。
        // PopFrame 已换成轮询，这里必须同步换掉：Flush 在**每次 Seek** 上都会调用，
        // 留着它就等于给慢路径留一个永久阻塞入口（原注释「暂保留」是已知债）。
        // 纪律一致：等「在途帧落地」这件事本身 + 有限超时，超时如实放弃。
        const uint64_t t0 = static_cast<uint64_t>(
            std::chrono::steady_clock::now().time_since_epoch().count());
        for (;;) {
            {
                std::lock_guard<std::mutex> lk(queue_mutex_);
                if (pending_dts_pts_.empty()) break;
            }
            const uint64_t now = static_cast<uint64_t>(
                std::chrono::steady_clock::now().time_since_epoch().count());
            if (now - t0 > 1'000'000'000ull) {
                // Warn **且 Release 可见**：Flush 超时意味着上一区间的残余帧可能漏进
                // 下一区间（MEDIA-021 的「Seek 后首弹弹出旧 GOP」就是这个形态）。
                CQ_LOG_WARN_WF(Workflow::kDecode,
                               "Flush 等待在途帧超时(1s)：按丢失处理，残余帧可能漏进下一区间");
                break;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
        }
    }
    ReleaseOutputQueue();
    {
        std::lock_guard<std::mutex> lk(queue_mutex_);
        pending_dts_pts_.clear();  // 重排等待依据随队列一并失效
        pending_submit_nanos_.clear();
    }
    if (last_returned_ != nullptr) {
        if (last_returned_->refcount.fetch_sub(1) == 1) delete last_returned_;
        last_returned_ = nullptr;
    }
    has_prev_ = false;
    order_mismatch_streak_ = 0;  // MEDIA-027：等待依据随队列一并失效
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
