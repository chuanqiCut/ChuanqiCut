// ChuanqiCut — Platform Audio 抽象接口（CORE-006 / AUDIO-001）
//
// 职责：PCM 缓冲描述 + 播放/采集引擎抽象。
// 下游 AUDIO-001（音频图与 PCM 缓冲管理）、PALA-030（AVAudioEngine）、
// PALD-030（Oboe）依赖。
//
// 设计边界（与 AUDIO-001 的分工）：
//   * 本契约只抽象「PCM 输入输出引擎」——平台音频框架（AVAudioEngine / Oboe）负责
//     低延迟搬运 PCM 块；混音/效果（AUDIO-004/010）在 core 层基于 PcmBuffer 实现，
//     平台引擎不感知，避免平台音频图差异泄漏到 core。
//   * PcmBuffer 是 POD，零分配语义友好，音频线程可无锁使用。
//
// 红线：零平台类型、零 FFmpeg 类型。音频线程无锁无分配（接口不在此加锁）。

#ifndef CQ_PLATFORM_AUDIO_H_
#define CQ_PLATFORM_AUDIO_H_

#include <cstdint>

#include "cq/base/concurrency.h"  // CancelToken
#include "cq/base/rational_time.h"          // RationalTime（time.h 已含 status.h）
#include "cq/platform/common.h"

namespace cq {

// PCM 缓冲描述（POD）。data 指向平台引擎/池提供的样本内存。
// 音频线程使用：零分配、无锁语义友好。
struct PcmBuffer {
    SampleFormat format = SampleFormat::kUnknown;
    uint32_t channels = 0;
    uint32_t sample_rate = 0;   // Hz
    uint64_t frame_count = 0;   // 单声道样本帧数（总样本数 = frame_count * channels）
    const void* data = nullptr; // 样本内存（由提供方所有，按生命周期约定使用）
    uint64_t data_bytes = 0;    // data 该厂商长度
    RationalTime pts;           // 首样本时间（项目有理数时间轴）

    // 单帧该厂商数（channels * 每样本该厂商）。-Wconversion 安全：显式 static_cast。
    uint64_t BytesPerFrame() const {
        uint32_t sample_bytes = 0;
        switch (format) {
            case SampleFormat::kInt16:   sample_bytes = 2u; break;
            case SampleFormat::kInt32:   sample_bytes = 4u; break;
            case SampleFormat::kFloat32: sample_bytes = 4u; break;
            case SampleFormat::kFloat64: sample_bytes = 8u; break;
            default:                     sample_bytes = 0u; break;
        }
        return static_cast<uint64_t>(sample_bytes) * static_cast<uint64_t>(channels);
    }
};

class IAudioEngine : public IPlatformResource {
public:
    // 打开播放输出流。frames_per_buffer 为单次 Write 期望的样本帧数（性能/延迟调参）。
    virtual Status OpenOutput(uint32_t sample_rate, uint32_t channels,
                              SampleFormat fmt, uint32_t frames_per_buffer) = 0;

    // 写入一块 PCM 播放。buf.data 必须在调用期间有效。
    // 内部缓冲已满时返回 kResourceExhausted（整块丢弃语义：调用方按块重试/丢弃）。
    virtual Status Write(const PcmBuffer& buf) = 0;

    // 丢弃全部已缓冲未播放的输出样本（seek / 暂停静音用）。
    // ⚠️ 线程语义：内部经「代数递增 + 消费者在音频回调侧执行丢弃」实现 ——
    // 生产者线程（混音线程）调用**安全**；丢弃在下一次音频回调内生效
    // （≤ 一个回调周期，约 10ms）。不需要也不支持跨线程直接改环游标。
    virtual Status FlushOutput() = 0;

    // 当前内部缓冲中尚未播放的样本帧数（近似快照，relaxed；仅用于监控与
    // 预览混音器的漂移护栏，不作为同步依据）。未 OpenOutput 时返回 0。
    virtual uint64_t BufferedFrames() const = 0;

    // 打开采集输入流（录音）。
    virtual Status OpenInput(uint32_t sample_rate, uint32_t channels,
                             SampleFormat fmt, uint32_t frames_per_buffer) = 0;

    // 采集读取（阻塞直到有数据或被取消）。out 的 data 由引擎所有，生命周期见实现约定。
    virtual Status Read(PcmBuffer& out, const CancelToken& token) = 0;

    virtual Status Start() = 0;  // 启动流（播放/采集统一）
    virtual Status Stop() = 0;   // 停止流
};

// 工厂（由 Platform 平台实现）。返回 PlatformPtr。
Status CreateAudioEngine(PlatformPtr<IAudioEngine>& out_engine);

}  // namespace cq

#endif  // CQ_PLATFORM_AUDIO_H_
