// ChuanqiCut — 音频轨读取器接缝（AUDIO-002，预览音频）
//
// 职责：把「容器文件里那条音频流」抽象成「按顺序读 PCM 块 + 可重锚」的平台能力。
// 与视频侧的分工同型（见 cq/media/frame_provider_factory.h 头注释）：
//   * ChqIAudioTrackReader      = 平台能力（demux + 解码一体；Apple = AVAssetReader
//     以 PCM 输出设置直读，AVFoundation 内部完成 AAC→PCM，core 不感知编码格式）。
//   * ChqPreviewAudioMixer      = 上层编排（audio/preview_mixer.h）：时间线 → 源时间
//     映射、多 clip 求和混音、与播放头的同步，全部在 core。
//
// 硬约束：零平台类型、零 FFmpeg 类型、禁用异常（错误一律 ChqStatus）。
// 线程约定：单个实例只允许单线程顺序使用（预览混音线程）；无内部锁。
//
// ⚠️ 与 MEDIA-021 FFmpegFrameProvider 的关系：FFmpeg 是**可选**解码后端（红线 #10、
//    模块册 media §两层架构）；本接缝同样允许后续以 FFmpeg 实现替换/并列，
//    契约不变。同 seek 同结果的一致性验收归 MEDIA-021 落地时建立。

#ifndef CQ_CORE_AUDIO_CHQ_TRACK_READER_H_
#define CQ_CORE_AUDIO_CHQ_TRACK_READER_H_

#include <memory>

#include "cq/base/chq_concurrency.h"   // ChqCancelToken
#include "cq/base/chq_rational_time.h" // ChqRationalTime
#include "cq/base/chq_status.h"
#include "cq/audio/chq_audio_types.h"  // ChqAudioGraphSpec
#include "cq/platform/chq_common.h"    // ChqPlatformPtr / ChqIPlatformResource
#include "cq/platform/chq_media.h"     // ChqMediaSource
#include "cq/platform/chq_audio.h"     // ChqPcmBuffer

namespace cq {

class ChqIAudioTrackReader : public ChqIPlatformResource {
public:
    // 打开媒体源（容器文件）。打开失败（文件不存在/不可解析）返回错误；
    // 容器内无音频流 = **Open 成功** + HasAudio()==false（「没有音频」不是错误）。
    // 成功后规格恒定（= 创建工厂时给定的 ChqAudioGraphSpec）。
    virtual ChqStatus Open(const ChqMediaSource& src) = 0;

    // 容器内是否存在音频流。Open 成功后恒可查询；无音频流时其余读接口拒绝。
    virtual bool HasAudio() const = 0;

    // 音频流时长（项目网格 timescale）。无音频流时返回 0 时长。
    virtual ChqStatus GetDuration(ChqRationalTime& out_duration) const = 0;

    // 重锚：此后 ReadBlock 自 src_time（素材内时间）起顺序产出。
    // 幂等：同一位置重复 Seek 合法（重建解码会话的代价由调用方权衡）。
    virtual ChqStatus Seek(const ChqRationalTime& src_time, const ChqCancelToken& token) = 0;

    // 顺序读下一块。输出规格 = 创建工厂时给定的 ChqAudioGraphSpec（全链恒定）。
    //   out.pts = 本块首样本的**素材内**时间（项目网格）。
    //   返回 kOk         —— out.frame_count ≥ 1（到流尾前允许不足一整块的部分块）
    //        kIoNotFound —— 流已读完（EOF；此后仍可 Seek 重读）
    //        kCancelled  —— token 触发（非错误）
    //   out.data 指向实现内部缓冲：**下次 ReadBlock / Seek / 析构前有效**，
    //   调用方要留存必须拷贝（混音器即用即拷，见 preview_mixer.cpp）。
    virtual ChqStatus ReadBlock(ChqPcmBuffer& out, const ChqCancelToken& token) = 0;
};

// 平台资源不可跨模块 delete（platform/common.h 契约：只能 Destroy()），
// 故按接口定制的 unique_ptr 删除器。混音器与 ABI 门面统一持有此别名。
struct ChqAudioReaderDeleter {
    void operator()(ChqIAudioTrackReader* p) const {
        if (p != nullptr) p->Destroy();
    }
};
using ChqAudioReaderPtr = std::unique_ptr<ChqIAudioTrackReader, ChqAudioReaderDeleter>;

class ChqIAudioTrackReaderFactory {
public:
    virtual ~ChqIAudioTrackReaderFactory() = default;

    // 产出**已 Open 完成**的读取器（调用方不必再调 Open）。容器无音频流同样成功
    //（HasAudio()==false 的读取器）；打开失败（文件不存在/不可解析）返回错误。
    // 生命周期：调用方持有 ChqAudioReaderPtr；本工厂不保留引用。
    virtual ChqStatus Create(const ChqMediaSource& src, const ChqAudioGraphSpec& spec,
                          ChqAudioReaderPtr& out) = 0;
};

// 平台工厂（platform 实现，声明在此；core 经它拿能力，不引平台头——
// 与 CreateMediaDemuxer / CreateFrameProvider 同型）。
ChqStatus CreateAudioTrackReader(ChqPlatformPtr<ChqIAudioTrackReader>& out,
                              const ChqAudioGraphSpec& spec);

// core 侧默认装配工厂：CreateAudioTrackReader + Open。
// 用途：C ABI 门面（audio/cq_sdk_audio.cpp）在不引用平台符号的前提下拿到
// 读取器能力；平台差异全部由 Platform 工厂吸收。
class ChqPlatformAudioReaderFactory final : public ChqIAudioTrackReaderFactory {
public:
    ChqStatus Create(const ChqMediaSource& src, const ChqAudioGraphSpec& spec,
                  ChqAudioReaderPtr& out) override;
};

}  // namespace cq

#endif  // CQ_CORE_AUDIO_CHQ_TRACK_READER_H_
