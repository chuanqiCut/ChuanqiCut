// AppleAudioTrackReader — 音频轨 demux+解码一体直读（AUDIO-002 平台侧）
//
// 实现 core/cq/audio/track_reader.h 的 ChqIAudioTrackReader 契约。
// 机制：AVAssetReader + AVAssetReaderTrackOutput，输出设置指定 Linear PCM
//（Float32 / 交错 / spec.channels 声道 / spec.sample_rate）—— demux 与解码
//（AAC→PCM、重采样、单声道→立体声上混）由 AVFoundation 内部完成，本类不感知
// 编码格式。与 media_demux.mm（视频 passthrough，不解码）刻意分工不同：
// 音频块的消费形态就是 PCM（混音求和），走解码输出设置是同一 AVAssetReader
// 能力的「配置项」而非第二套解封装逻辑。
//
// 纪律（与 media_demux.mm 同源，坑不复述）：
//   * 资产加载走 loadValuesAsynchronouslyForKeys + 信号量收敛 + **有限超时**
//     + 终态校验（statusOfValueForKey）+ 单次重建重试（P33：加载失败后
//     completion 可能永不触发，无限等 = 挂死）。
//   * CMTime → 项目网格：ChqRationalTime + 显式舍入方向，绝不浮点秒（红线 #4）。
//   * Seek = 重建 reader（AVAssetReader 不支持运行中改 timeRange）。
//   * 本类的调用线程是**纯 C++ 混音线程，无 autorelease pool** —— 所有产
//     自动释放对象的入口（BuildReaderAt / PullNextChunk）必须自带池（P75 同源）。
//   * 平台类型（AV*/CM*）只出现在本 .mm；零 FFmpeg 类型。
//
// 线程约定：单线程顺序使用（预览混音线程）；无内部锁。
// 生命周期：经 ChqIPlatformResource::Destroy()（ChqAudioReaderPtr 管理，不跨模块 delete）。

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

#include <sys/stat.h>

#include <algorithm>
#include <cstring>
#include <new>
#include <vector>

#include "cq/audio/chq_track_reader.h"
#include "cq/base/chq_logging.h"
#include "cq/base/chq_rational_time.h"

namespace cq {

namespace {

// 资产加载超时：与 media_demux.mm 同值（正常加载 40~400ms × 10 余量）。
constexpr int64_t kLoadTimeoutNs = 5LL * 1000 * 1000 * 1000;

// CMTime → ChqRationalTime（项目网格，显式舍入方向；media_demux.mm 同款）。
ChqRationalTime ToRational(CMTime t, ChqRoundMode mode) {
    if (!CMTIME_IS_NUMERIC(t) || t.timescale <= 0) {
        return ChqRationalTime{0, 1};
    }
    ChqRationalTime src{static_cast<int64_t>(t.value), static_cast<int32_t>(t.timescale)};
    ChqRationalTime out{0, 1};
    const ChqStatus s = Rescale(src, kProjectTimeScale, mode, out);
    if (!s.IsOk()) {
        return ChqRationalTime{0, 1};  // 仅溢出可失败：罕见，按 0 处理并靠上层日志定位
    }
    return out;
}

}  // namespace

class AppleAudioTrackReader final : public ChqIAudioTrackReader {
public:
    explicit AppleAudioTrackReader(const ChqAudioGraphSpec& spec) : spec_(spec) {}

    ~AppleAudioTrackReader() override { TearDownReader(); }

    void Destroy() override { delete this; }

    ChqStatus Open(const ChqMediaSource& src) override {
        if (src.path == nullptr || src.path_len == 0) {
            return ChqStatus{ChqStatusCode::kInvalidArgument};
        }
        // 输出规格校验：Float32 交错（混音器求和逻辑的形状假设），Open 后恒定。
        if (spec_.format != ChqSampleFormat::kFloat32 || spec_.channels < 1 ||
            spec_.sample_rate == 0 || spec_.frames_per_block == 0) {
            return ChqStatus{ChqStatusCode::kInvalidArgument};
        }
        NSString* ns_path = [[NSString alloc] initWithBytes:src.path
                                                     length:src.path_len
                                                   encoding:NSUTF8StringEncoding];
        if (ns_path == nil) return ChqStatus{ChqStatusCode::kInvalidArgument};
        NSURL* url = [NSURL fileURLWithPath:ns_path];
        if (url == nil) return ChqStatus{ChqStatusCode::kIoError};

        // 异步加载 + 有限超时 + 终态校验 + 单次重建重试（P33 纪律，见文件头）。
        NSArray<NSString*>* keys = @[ @"tracks", @"duration" ];
        BOOL loaded = NO;
        AVURLAsset* asset = nil;
        for (int attempt = 0;; ++attempt) {
            asset = [AVURLAsset URLAssetWithURL:url options:nil];
            if (asset == nil) return ChqStatus{ChqStatusCode::kIoError};
            @autoreleasepool {
                dispatch_semaphore_t sem = dispatch_semaphore_create(0);
                [asset loadValuesAsynchronouslyForKeys:keys
                                     completionHandler:^{
                                       dispatch_semaphore_signal(sem);
                                     }];
                const bool completed = dispatch_semaphore_wait(
                                           sem, dispatch_time(DISPATCH_TIME_NOW, kLoadTimeoutNs)) == 0;
                if (completed) {
                    loaded = YES;
                    for (NSString* key in keys) {
                        NSError* err = nil;
                        if ([asset statusOfValueForKey:key error:&err] !=
                            AVKeyValueStatusLoaded) {
                            loaded = NO;
                            break;
                        }
                    }
                }
            }
            if (loaded) break;
            if (attempt >= 1) return ChqStatus{ChqStatusCode::kIoError};
            struct stat st_buf{};
            if (::stat(url.fileSystemRepresentation, &st_buf) != 0) {
                return ChqStatus{ChqStatusCode::kIoError};  // 文件已不存在：重试无意义
            }
            asset = nil;  // 重建 asset 重试（绕开前实例的失败状态，P33）
        }

        // 音频轨（首条；调用线程无 pool，包 @autoreleasepool）。
        // ⚠️ 用 [asset tracks] + 字符串比较过滤（media_demux.mm 同款）——
        // tracksWithMediaType: 在 macOS 15+/iOS 16+ 弃用（-Werror 必炸）。
        NSArray<AVAssetTrack*>* audio_tracks = nil;
        @autoreleasepool {
            NSArray<AVAssetTrack*>* all_tracks = [asset tracks];
            NSMutableArray<AVAssetTrack*>* filtered =
                [NSMutableArray arrayWithCapacity:all_tracks.count];
            for (AVAssetTrack* track in all_tracks) {
                // mediaType 是 NSString，必须字符串比较，不能指针比较（demux 同注）。
                if ([track.mediaType isEqualToString:AVMediaTypeAudio]) {
                    [filtered addObject:track];
                }
            }
            audio_tracks = filtered;
        }
        if (audio_tracks.count == 0) {
            // 无音频流 = Open 成功 + HasAudio()==false（「没有音频」不是错误）。
            has_audio_ = NO;
            duration_ = ChqRationalTime{0, 1};
            return ChqStatus::Ok();
        }
        has_audio_ = YES;
        audio_track_ = audio_tracks.firstObject;
        // 音频流时长用轨的 timeRange.duration（容器级 duration 可能含封面/章节）。
        duration_ = ToRational(audio_track_.timeRange.duration, ChqRoundMode::kRound);
        return ChqStatus::Ok();
    }

    bool HasAudio() const override { return has_audio_; }

    ChqStatus GetDuration(ChqRationalTime& out_duration) const override {
        out_duration = duration_;
        return ChqStatus::Ok();
    }

    ChqStatus Seek(const ChqRationalTime& src_time, const ChqCancelToken& token) override {
        if (!has_audio_) return ChqStatus{ChqStatusCode::kInvalidArgument};
        if (src_time.timescale <= 0) return ChqStatus{ChqStatusCode::kInvalidArgument};
        // 重锚 = 重建 reader（AVAssetReader 不支持运行中改 timeRange）。
        TearDownReader();
        pending_.clear();
        pending_consumed_ = 0;
        pending_pts_ = ChqRationalTime{0, 1};
        pending_has_pts_ = NO;
        eof_ = NO;
        return BuildReaderAt(src_time, token);
    }

    ChqStatus ReadBlock(ChqPcmBuffer& out, const ChqCancelToken& token) override {
        if (!has_audio_) return ChqStatus{ChqStatusCode::kInvalidArgument};
        const size_t ch = static_cast<size_t>(spec_.channels);
        const size_t want_frames = static_cast<size_t>(spec_.frames_per_block);
        block_scratch_.assign(want_frames * ch, 0.0f);
        size_t filled = 0;
        ChqRationalTime first_pts{0, 1};
        bool have_first_pts = NO;

        while (filled < want_frames) {
            if (token.IsCancelled()) {
                return token.Cancelled();
            }
            const size_t pending_frames =
                pending_.size() / ch - static_cast<size_t>(pending_consumed_);
            if (pending_frames > 0) {
                const size_t take = std::min(pending_frames, want_frames - filled);
                const size_t src_base = static_cast<size_t>(pending_consumed_) * ch;
                std::copy(pending_.begin() + static_cast<std::ptrdiff_t>(src_base),
                          pending_.begin() +
                              static_cast<std::ptrdiff_t>(src_base + take * ch),
                          block_scratch_.begin() +
                              static_cast<std::ptrdiff_t>(filled * ch));
                if (!have_first_pts && pending_has_pts_) {
                    // 本块首帧 pts = pending 首帧 pts + 已消费偏移（源网格换算）。
                    const int64_t offset_ticks =
                        static_cast<int64_t>(pending_consumed_) *
                        static_cast<int64_t>(kProjectTimeScale) /
                        static_cast<int64_t>(spec_.sample_rate);
                    first_pts = ChqRationalTime{pending_pts_.value + offset_ticks,
                                                kProjectTimeScale};
                    have_first_pts = YES;
                }
                pending_consumed_ += static_cast<int64_t>(take);
                filled += take;
                continue;
            }
            if (eof_) break;
            // pending 已耗尽：拉下一个样本（追加进 pending）。
            const ChqStatus ps = PullNextChunk();
            if (!ps.IsOk()) {
                if (filled == 0) return ps;  // 一帧都没有：错误原样透传
                break;                       // 已有部分块：先交付（EOF 下次到）
            }
        }

        if (filled == 0) {
            return ChqStatus{ChqStatusCode::kIoNotFound};  // 流读完（EOF）
        }
        // pending 全量消费完：压缩清零（防跨 seek 无限增长）。
        if (static_cast<size_t>(pending_consumed_) * ch == pending_.size()) {
            pending_.clear();
            pending_consumed_ = 0;
            pending_has_pts_ = NO;
        }
        out.format = spec_.format;
        out.channels = spec_.channels;
        out.sample_rate = spec_.sample_rate;
        out.frame_count = static_cast<uint64_t>(filled);
        out.data = block_scratch_.data();
        out.data_bytes = block_scratch_.size() * sizeof(float);
        out.pts = have_first_pts ? first_pts : ChqRationalTime{0, 1};
        return ChqStatus::Ok();
    }

private:
    // 拉取下一个 CMSampleBuffer 的 PCM 到 pending_（交错 float32 追加）。
    ChqStatus PullNextChunk() {
        if (output_ == nil) return ChqStatus{ChqStatusCode::kInvalidArgument};
        // 调用线程无 autorelease pool：CMSampleBuffer / 内部对象显式管理。
        CMSampleBufferRef sbuf = [output_ copyNextSampleBuffer];
        if (sbuf == nullptr) {
            // copyNextSampleBuffer 对 EOF 与错误都返回 nil：以 reader 状态分辨。
            if (reader_.status == AVAssetReaderStatusFailed) {
                CQ_LOG_WARN_WF(ChqWorkflow::kDecode, "音频轨读取失败 osstatus=%lld",
                               static_cast<long long>(reader_.error.code));
                return ChqStatus{ChqStatusCode::kDecodeError};
            }
            eof_ = YES;
            return ChqStatus::Ok();
        }
        struct SampleHolder {  // RAII：任何提前 return 都释放 +1 的样本引用
            CMSampleBufferRef buf;
            ~SampleHolder() {
                if (buf != nullptr) CFRelease(buf);
            }
        } holder{sbuf};

        if (pending_.empty()) {
            pending_pts_ = ToRational(
                CMSampleBufferGetPresentationTimeStamp(sbuf), ChqRoundMode::kRound);
            pending_has_pts_ = YES;
            pending_consumed_ = 0;
        }

        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sbuf);
        if (block == nullptr) return ChqStatus{ChqStatusCode::kDecodeError};
        // CMBlockBufferGetDataLength 返回 size_t（按 SDK 头对表，勿收窄成 int）。
        const size_t data_len = CMBlockBufferGetDataLength(block);
        if (data_len == 0) return ChqStatus{ChqStatusCode::kDecodeError};
        const size_t frame_bytes = static_cast<size_t>(spec_.channels) * sizeof(float);
        if (data_len % frame_bytes != 0) {
            return ChqStatus{ChqStatusCode::kDecodeError};  // 非整帧：规格错，不猜
        }
        // 交错 PCM 直读内存（输出设置即交错 float32；解码产物是连续单段）。
        size_t seg_len = 0;
        size_t total_len = 0;
        char* data_ptr = nullptr;
        const OSStatus st = CMBlockBufferGetDataPointer(block, 0, &seg_len,
                                                        &total_len, &data_ptr);
        if (st != kCMBlockBufferNoErr || data_ptr == nullptr) {
            return ChqStatus{ChqStatusCode::kDecodeError};
        }
        if (seg_len < data_len) {
            // 非连续块（罕见）：诚实报错，不做多段拼装猜测。
            CQ_LOG_WARN_WF(ChqWorkflow::kDecode, "音频样本块非连续 seg=%zu total=%zu",
                           seg_len, total_len);
            return ChqStatus{ChqStatusCode::kDecodeError};
        }
        const size_t old_size = pending_.size();
        pending_.resize(old_size + data_len / sizeof(float));
        memcpy(pending_.data() + old_size, data_ptr, data_len);
        return ChqStatus::Ok();
    }

    // 在 src_time（素材内时间）处重建 reader。成功后可 copyNextSampleBuffer。
    ChqStatus BuildReaderAt(const ChqRationalTime& src_time, const ChqCancelToken& token) {
        (void)token;
        if (audio_track_ == nil) return ChqStatus{ChqStatusCode::kInvalidArgument};
        @autoreleasepool {
            NSError* err = nil;
            AVAssetReader* reader = [[AVAssetReader alloc] initWithAsset:audio_track_.asset
                                                                   error:&err];
            if (reader == nil) {
                CQ_LOG_WARN_WF(ChqWorkflow::kDecode, "音频 reader 创建失败 err='%s'",
                               err.localizedDescription.UTF8String ?: "(nil)");
                return ChqStatus{ChqStatusCode::kIoError};
            }
            // 读到轨尾（timeRange.duration 已按轨计，比容器 duration 准）。
            CMTime start = CMTimeMake(src_time.value, src_time.timescale);
            CMTime total = audio_track_.timeRange.duration;
            CMTimeRange range = CMTimeRangeMake(start, total);
            reader.timeRange = range;
            NSDictionary* settings = @{
                AVFormatIDKey : @(kAudioFormatLinearPCM),
                AVLinearPCMBitDepthKey : @32,
                AVLinearPCMIsFloatKey : @YES,
                AVLinearPCMIsBigEndianKey : @NO,
                AVLinearPCMIsNonInterleaved : @NO,
                AVSampleRateKey : @(spec_.sample_rate),
                AVNumberOfChannelsKey : @(spec_.channels),
            };
            AVAssetReaderTrackOutput* output =
                [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audio_track_
                                                           outputSettings:settings];
            if (output == nil || ![reader canAddOutput:output]) {
                return ChqStatus{ChqStatusCode::kIoError};
            }
            [reader addOutput:output];
            if (![reader startReading]) {
                CQ_LOG_WARN_WF(ChqWorkflow::kDecode, "音频 startReading 失败 err='%s'",
                               reader.error.localizedDescription.UTF8String ?: "(nil)");
                return ChqStatus{ChqStatusCode::kIoError};
            }
            reader_ = reader;
            output_ = output;
            return ChqStatus::Ok();
        }
    }

    void TearDownReader() {
        output_ = nil;
        if (reader_ != nil) {
            if (reader_.status == AVAssetReaderStatusReading) {
                [reader_ cancelReading];
            }
            reader_ = nil;
        }
    }

    ChqAudioGraphSpec spec_{};
    BOOL has_audio_ = NO;
    ChqRationalTime duration_{0, 1};
    AVAssetTrack* audio_track_ = nil;  // Open 成功后持有（ARC）
    AVAssetReader* reader_ = nil;
    AVAssetReaderTrackOutput* output_ = nil;
    BOOL eof_ = NO;
    // 跨块 pending（交错 float32）+ 其首帧 pts 与消费进度（帧数）。
    std::vector<float> pending_;
    int64_t pending_consumed_ = 0;
    ChqRationalTime pending_pts_{0, 1};
    BOOL pending_has_pts_ = NO;
    std::vector<float> block_scratch_;  // ReadBlock 的输出暂存（复用，无逐块分配）
};

}  // namespace cq

// ---- Platform 工厂（core/cq/audio/track_reader.h 声明）----
namespace cq {
ChqStatus CreateAudioTrackReader(ChqPlatformPtr<ChqIAudioTrackReader>& out,
                                 const ChqAudioGraphSpec& spec) {
    if (spec.format != ChqSampleFormat::kFloat32 || spec.channels < 1 ||
        spec.sample_rate == 0 || spec.frames_per_block == 0) {
        return ChqStatus{ChqStatusCode::kInvalidArgument};
    }
    auto* impl = new (std::nothrow) AppleAudioTrackReader(spec);
    if (impl == nullptr) {
        return ChqStatus{ChqStatusCode::kResourceExhausted};
    }
    out = ChqPlatformPtr<ChqIAudioTrackReader>(impl);
    return ChqStatus::Ok();
}
}  // namespace cq
