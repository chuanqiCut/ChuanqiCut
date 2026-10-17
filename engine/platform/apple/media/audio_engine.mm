// AppleAudioEngine — ChqIAudioEngine 的 Apple 实现（PALA-030，AUDIO-002 预览消费端）
//
// 机制：AVAudioEngine + AVAudioSourceNode。渲染回调（实时音频线程）从内部
// ChqSpscSampleRing 拉 PCM 去交错后交付；混音线程（core ChqPreviewAudioMixer）经
// Write() 推块进环。环是「音频线程无锁无分配」（红线 #8）的唯一执行点：
// 回调内只有环读 + 原子量 + memset。
//
// 范围（诚实边界，不要假装支持）：
//   * 仅输出（OpenOutput/Write/Start/Stop/FlushOutput/BufferedFrames）；
//     输入路径（OpenInput/Read）本期**未实现**，如实返回 kDecodeUnsupported
//     —— 采集侧（相机录制）走 AVAssetWriter 自有链路，无消费者；将来
//     旁白/配音功能落地时再实现。
//   * 仅 Float32 交错 stereo（与 ChqPreviewAudioMixer 的输出规格锁定一致）；
//     其它规格 kInvalidArgument 拒绝，不做静默转换。
//
// FlushOutput 的并发设计：调用方（混音线程，非实时）不能直接改环游标
//（head 只有实时消费者可写）。实现为「代数递增」：Flush 只递增 epoch，
// 渲染回调在下一次执行时发现 epoch 变化 → 自己执行 DropAllByConsumer。
// 生效延迟 ≤ 一个回调周期（约 10ms），无锁、无竞争。
//
// 线程模型：
//   * Write / FlushOutput / BufferedFrames —— 混音线程（生产者侧）。
//   * 渲染回调 —— 实时音频线程（消费者侧）。
//   * Start / Stop —— 装配方线程（非实时；Stop 同步停引擎，Destroy 依赖它）。

#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudioTypes.h>
#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif

#include <atomic>
#include <cstring>
#include <new>
#include <vector>

#include "cq/audio/chq_spsc_ring.h"
#include "cq/base/chq_logging.h"
#include "cq/platform/chq_audio.h"

namespace cq {

namespace {
// 环容量：≥ 350ms（lookahead 150ms + 重锚/调度余量），且 ≥ 4×回调块。
constexpr uint64_t kRingMinMs = 350;
constexpr uint64_t kRingMinBlocks = 4;
}  // namespace

class AppleAudioEngine final : public ChqIAudioEngine {
public:
    AppleAudioEngine() = default;
    ~AppleAudioEngine() override {
        // 生命周期硬序：先同步停引擎（渲染回调不再跑），再释放。
        // 渲染 block 持有本对象的裸 this（C++ 指针不被 block retain）——
        // running 态 delete = use-after-free，Destroy() 是唯一入口并守这条序。
        (void)StopTearDown();
    }

    void Destroy() override { delete this; }

    ChqStatus OpenOutput(uint32_t sample_rate, uint32_t channels, ChqSampleFormat fmt,
                         uint32_t frames_per_buffer) override {
        if (fmt != ChqSampleFormat::kFloat32 || channels != 2 || sample_rate == 0 ||
            frames_per_buffer == 0) {
            // 范围见文件头：规格不匹配诚实拒绝，不静默转换。
            return ChqStatus{ChqStatusCode::kInvalidArgument};
        }
        frame_bytes_ = static_cast<uint64_t>(channels) * sizeof(float);
        const uint64_t rate = sample_rate;
        uint64_t capacity_frames = rate * kRingMinMs / 1000;
        const uint64_t min_frames =
            static_cast<uint64_t>(kRingMinBlocks) * frames_per_buffer;
        if (capacity_frames < min_frames) capacity_frames = min_frames;

        const ChqStatus rs = ring_.Init(capacity_frames * frame_bytes_);
        if (!rs.IsOk()) return rs;
        scratch_.assign(static_cast<size_t>(ring_.CapacityBytes()), 0);

        // SDK 实名（AVAudioFormat.h:112 + :32）：initWithCommonFormat:sampleRate:
        // channels:interleaved:；常量 = AVAudioPCMFormatFloat32。
        output_format_ = [[AVAudioFormat alloc]
            initWithCommonFormat:AVAudioPCMFormatFloat32
                      sampleRate:static_cast<double>(sample_rate)
                        channels:static_cast<AVAudioChannelCount>(channels)
                     interleaved:NO];
        if (output_format_ == nil) return ChqStatus{ChqStatusCode::kIoError};

        engine_ = [[AVAudioEngine alloc] init];
        if (engine_ == nil) return ChqStatus{ChqStatusCode::kIoError};

        // 渲染 block 捕获 C++ this 裸指针（无 ObjC retain，无环；生命周期由
        // Destroy 的「先停后删」硬序保证，见析构注释）。
        AppleAudioEngine* self_ptr = this;
        const uint64_t fbytes = frame_bytes_;
        AVAudioSourceNodeRenderBlock block =
            ^OSStatus(BOOL* isSilence, const AudioTimeStamp* timestamp,
                      AVAudioFrameCount frame_count, AudioBufferList* output_data) {
              return self_ptr->RenderInto(isSilence, timestamp, frame_count,
                                          output_data, fbytes);
            };
        source_node_ = [[AVAudioSourceNode alloc] initWithFormat:output_format_
                                                     renderBlock:block];
        if (source_node_ == nil) return ChqStatus{ChqStatusCode::kIoError};
        [engine_ attachNode:source_node_];
        [engine_ connect:source_node_
                      to:engine_.mainMixerNode
                  format:output_format_];

        opened_ = true;
        return ChqStatus::Ok();
    }

    ChqStatus Write(const ChqPcmBuffer& buf) override {
        if (!opened_ || buf.data == nullptr) {
            return ChqStatus{ChqStatusCode::kInvalidArgument};
        }
        // 全有或全无：环满 = kResourceExhausted（调用方按块丢弃/重试）。
        return ring_.Write(buf.data, buf.data_bytes);
    }

    ChqStatus FlushOutput() override {
        if (!opened_) return ChqStatus{ChqStatusCode::kInvalidArgument};
        // 代数递增：真正的丢弃由渲染回调执行（见文件头并发设计）。
        flush_epoch_.fetch_add(1, std::memory_order_release);
        return ChqStatus::Ok();
    }

    uint64_t BufferedFrames() const override {
        if (!opened_ || frame_bytes_ == 0) return 0;
        // relaxed 快照：仅用于混音线程的漂移护栏（监控级），非同步依据。
        return ring_.ReadableBytes() / frame_bytes_;
    }

    ChqStatus OpenInput(uint32_t sample_rate, uint32_t channels, ChqSampleFormat fmt,
                        uint32_t frames_per_buffer) override {
        (void)sample_rate;
        (void)channels;
        (void)fmt;
        (void)frames_per_buffer;
        // 预留接口：本后端本期不提供输入（文件头「范围」）。
        return ChqStatus{ChqStatusCode::kDecodeUnsupported};
    }

    ChqStatus Read(ChqPcmBuffer& out, const ChqCancelToken& token) override {
        (void)out;
        (void)token;
        return ChqStatus{ChqStatusCode::kDecodeUnsupported};  // 同 OpenInput
    }

    ChqStatus Start() override {
        if (!opened_) return ChqStatus{ChqStatusCode::kInvalidArgument};
#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
        RegisterSessionObservers();  // iOS：打断/回到前台观察者（幂等）
#endif
        if (started_) {
            // ⚠️ 关键修复：started_ 为真 ≠ 引擎真的在跑。被系统打断（其他 App 抢会话 /
            // 进后台）时 AVAudioEngine 会被 OS 停掉，但本对象 started_ 仍是 true。
            // 若此处直接返回，恢复播放就是静音。故重新武装会话 + 重启引擎。
#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
            ReactivateIfNeeded();
#endif
            return ChqStatus::Ok();
        }
#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
        // iOS 必须激活 AVAudioSession（category 只设一次；重复设置无害但浪费）。
        if (!session_configured_) {
            NSError* err = nil;
            AVAudioSession* session = [AVAudioSession sharedInstance];
            [session setCategory:AVAudioSessionCategoryPlayback
                            mode:AVAudioSessionModeDefault
                         options:0
                           error:&err];
            if (err != nil) {
                CQ_LOG_WARN_WF(ChqWorkflow::kPreview, "AVAudioSession setCategory 失败 err='%s'",
                               err.localizedDescription.UTF8String ?: "(nil)");
                return ChqStatus{ChqStatusCode::kIoError};
            }
            session_configured_ = true;
        }
        NSError* err_active = nil;
        [[AVAudioSession sharedInstance] setActive:YES error:&err_active];
        if (err_active != nil) {
            CQ_LOG_WARN_WF(ChqWorkflow::kPreview, "AVAudioSession setActive 失败 err='%s'",
                           err_active.localizedDescription.UTF8String ?: "(nil)");
            return ChqStatus{ChqStatusCode::kIoError};
        }
#endif
        NSError* err = nil;
        if (![engine_ startAndReturnError:&err]) {
            CQ_LOG_WARN_WF(ChqWorkflow::kPreview, "AVAudioEngine 启动失败 err='%s'",
                           err.localizedDescription.UTF8String ?: "(nil)");
            return ChqStatus{ChqStatusCode::kIoError};
        }
        started_ = true;
        return ChqStatus::Ok();
    }

    ChqStatus Stop() override { return StopTearDown(); }

private:
    ChqStatus StopTearDown() {
#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
        UnregisterSessionObservers();
#endif
        if (engine_ != nil && started_) {
            [engine_ stop];
            started_ = false;
        }
        return ChqStatus::Ok();
    }

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
    // 打断结束 / 回到前台时重新武装：AVAudioSession 重新激活 + AVAudioEngine 重启。
    // 仅当本对象意图在播（started_）才动；观察者队列 = main，调用方保证主线程。
    void ReactivateIfNeeded() {
        if (!started_) return;
        NSError* err = nil;
        [[AVAudioSession sharedInstance] setActive:YES error:&err];
        if (err != nil) {
            CQ_LOG_WARN_WF(ChqWorkflow::kPreview,
                           "AVAudioSession 恢复激活失败 err='%s'",
                           err.localizedDescription.UTF8String ?: "(nil)");
        }
        if (![engine_ isRunning]) {
            NSError* e2 = nil;
            if (![engine_ startAndReturnError:&e2]) {
                CQ_LOG_WARN_WF(ChqWorkflow::kPreview,
                               "AVAudioEngine 打断后重启失败 err='%s'",
                               e2.localizedDescription.UTF8String ?: "(nil)");
            }
        }
    }

    void RegisterSessionObservers() {
        if (observers_registered_) return;
        NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
        // 观察者移除前 this 有效（移除在析构内的 StopTearDown）；block 只捕获裸指针、不 retain。
        AppleAudioEngine* self_ptr = this;
        interruption_token_ = [nc addObserverForName:AVAudioSessionInterruptionNotification
                                              object:nil
                                               queue:[NSOperationQueue mainQueue]
                                          usingBlock:^(NSNotification* note) {
                                            NSNumber* type = note.userInfo[AVAudioSessionInterruptionTypeKey];
                                            if (type != nil &&
                                                type.integerValue == AVAudioSessionInterruptionTypeEnded) {
                                                self_ptr->ReactivateIfNeeded();
                                            }
                                          }];
        active_token_ = [nc addObserverForName:UIApplicationDidBecomeActiveNotification
                                        object:nil
                                         queue:[NSOperationQueue mainQueue]
                                    usingBlock:^(NSNotification* /* note */) {
                                      self_ptr->ReactivateIfNeeded();
                                    }];
        observers_registered_ = true;
    }

    void UnregisterSessionObservers() {
        if (!observers_registered_) return;
        NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
        if (interruption_token_ != nil) {
            [nc removeObserver:interruption_token_];
            interruption_token_ = nil;
        }
        if (active_token_ != nil) {
            [nc removeObserver:active_token_];
            active_token_ = nil;
        }
        observers_registered_ = false;
    }
#endif

    // 渲染回调（实时音频线程，消费者侧）。只允许：环读 + 原子量 + memset。
    OSStatus RenderInto(BOOL* is_silence, const AudioTimeStamp* timestamp,
                        AVAudioFrameCount frame_count, AudioBufferList* output_data,
                        uint64_t fbytes) {
        (void)timestamp;
        // Flush 落地：消费者自己追平环（head 唯一写者是本线程，合法）。
        const uint32_t epoch = flush_epoch_.load(std::memory_order_acquire);
        if (epoch != flush_seen_.load(std::memory_order_relaxed)) {
            flush_seen_.store(epoch, std::memory_order_relaxed);
            ring_.DropAllByConsumer();
        }

        const uint64_t want_bytes = static_cast<uint64_t>(frame_count) * fbytes;
        uint64_t got_bytes = 0;
        if (want_bytes > 0 && want_bytes <= scratch_.size()) {
            // 环 Read 全有或全无：先按可读快照取 min（可读量只会增长，
            // 快照保守 → Read 不会失败）。
            const uint64_t available = ring_.ReadableBytes();
            got_bytes = available < want_bytes ? available : want_bytes;
            if (got_bytes > 0) {
                const ChqStatus rs = ring_.Read(scratch_.data(), got_bytes);
                if (!rs.IsOk()) got_bytes = 0;
            }
        }

        // 去交错交付：环内 LRLR… → 输出两个 buffer（标准非交错格式）。
        const auto frames = static_cast<uint64_t>(frame_count);
        const auto got_frames = got_bytes / fbytes;
        const auto* src = reinterpret_cast<const float*>(scratch_.data());
        auto* dst_l = static_cast<float*>(output_data->mBuffers[0].mData);
        auto* dst_r = static_cast<float*>(output_data->mBuffers[1].mData);
        for (uint64_t i = 0; i < frames; ++i) {
            if (i < got_frames) {
                dst_l[i] = src[i * 2];
                dst_r[i] = src[i * 2 + 1];
            } else {
                dst_l[i] = 0.0f;
                dst_r[i] = 0.0f;
            }
        }
        output_data->mBuffers[0].mDataByteSize =
            static_cast<UInt32>(frames * sizeof(float));
        output_data->mBuffers[1].mDataByteSize =
            static_cast<UInt32>(frames * sizeof(float));
        if (got_frames < frames) {
            underruns_.fetch_add(1, std::memory_order_relaxed);  // 静音缺口如实发生
        }
        if (is_silence != nullptr) {
            *is_silence = (got_frames == 0);
        }
        return noErr;
    }

    AVAudioEngine* engine_ = nil;
    AVAudioSourceNode* source_node_ = nil;
    AVAudioFormat* output_format_ = nil;
    bool opened_ = false;
    bool started_ = false;
#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
    bool session_configured_ = false;    // iOS AVAudioSession category 只设一次
    bool observers_registered_ = false;  // 打断/前台观察者是否已挂（Start 幂等注册）
    id interruption_token_ = nil;        // AVAudioSessionInterruptionNotification 观察者
    id active_token_ = nil;              // UIApplicationDidBecomeActiveNotification 观察者
#endif
    uint64_t frame_bytes_ = 0;
    ChqSpscSampleRing ring_;                // 生产者=Write（混音线程），消费者=渲染回调
    std::vector<uint8_t> scratch_;          // 环读暂存（OpenOutput 一次性分配）
    std::atomic<uint32_t> flush_epoch_{0};  // FlushOutput 递增（混音线程）
    std::atomic<uint32_t> flush_seen_{0};   // 渲染回调已消费到的代数
    std::atomic<uint64_t> underruns_{0};    // 诊断计数（回调线程写）
};

}  // namespace cq

// ---- Platform 工厂（core/cq/platform/audio.h 声明）----
namespace cq {
ChqStatus CreateAudioEngine(ChqPlatformPtr<ChqIAudioEngine>& out_engine) {
    auto* impl = new (std::nothrow) AppleAudioEngine();
    if (impl == nullptr) {
        return ChqStatus{ChqStatusCode::kResourceExhausted};
    }
    out_engine = ChqPlatformPtr<ChqIAudioEngine>(impl);
    return ChqStatus::Ok();
}
}  // namespace cq
