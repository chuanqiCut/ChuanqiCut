// ChuanqiCut — MEDIA-020 SystemFrameProvider（跨平台「按时间戳取帧」编排实现）
//
// 位置：core 层（`cq::FrameProvider` 抽象由 MEDIA-010 在 frame_provider.h 定义并冻结）。
// 本文件是 MEDIA-010 抽象的**具体落地**：聚合 PAL 解封装后端（IMediaDemuxer，
// 由 PALA-010 提供真实 Apple 实现，或单测注入 Mock），在 demux + 解码之上实现
// 精确 seek 的*编排*——即「t 处真正的展示帧」的选取语义。
//
// 硬约束（与 MEDIA-010 一致）：
//   * 零平台类型：本文件只使用 base 层 + PAL 的 opaque 句柄与平台无关类型，绝不
//     出现 AV* / ffmpeg / 平台头。
//   * 统一 base 类型：RationalTime / Status / CancelToken。
//   * 内核禁用异常。
//
// 解码接缝（IFrameDecoder）：把「压缩包 → 展示帧」这一步抽象成平台无关接口，
// 真实实现由 PALA-011（VideoToolbox / MediaCodec）落地。本期提供：
//   * MockDecoder —— 单测用，带 B 帧 DPB 重排，验证精确 seek 语义。
//   * StubDecoder —— 真实链路冒烟占位，诚实返回「解码后端未实现」（PALA-011 未做）。
// SystemFrameProvider 不持有解码器实现，由注入方（PAL 层 / 单测）提供，满足
// core 不反向依赖 PAL 的分层。

#ifndef CQ_MEDIA_SYSTEM_FRAME_PROVIDER_H_
#define CQ_MEDIA_SYSTEM_FRAME_PROVIDER_H_

#include <memory>

#include "cq/base/concurrency.h"  // CancelToken
#include "cq/base/status.h"       // Status / StatusCode
#include "cq/base/time.h"         // RationalTime
#include "cq/media/frame_provider.h"  // FrameProvider（MEDIA-010 抽象）
#include "cq/media/decoder_pool.h"   // IDecoderPool / DecoderOf（MEDIA-012 接入）
#include "cq/pal/common.h"        // NativeImageHandle / PalPtr
#include "cq/pal/media.h"         // IMediaDemuxer / MediaPacket / MediaFrame / MediaSource

namespace cq {

// ===========================================================================
// IFrameDecoder — 解码接缝（MEDIA-020 内部，真实实现属 PALA-011）
// ===========================================================================
// 把「喂入压缩包（解码序/dts 序）→ 弹出展示帧（显示序/pts 序）」这一步抽象出来，
// 使 SystemFrameProvider 的精确 seek *编排* 与具体解码后端（VideoToolbox 等）解耦。
// 这样编排逻辑可在无真实解码器的前提下，用 MockDecoder 充分验证（见单测）。
//
// 内部约定：
//   * Feed 按 demuxer 给出的**解码序**（dts 升序）喂包。
//   * PopFrame 尽量按**显示序**（pts 升序）弹出已可重建的帧；B 帧必须等其参考
//     帧（通常在其后的 P 帧）喂入后才可弹出——这是「前向解码直到依赖可重建」的
//     真实语义，MockDecoder 据此建模。
//   * PopFrame 返回 kOk + 有效帧 ⇒ 得到一个展示帧；返回 kIoNotFound ⇒ 当前无可弹
//     帧（需继续 Feed，或已 drain 完）。此约定仅限解码接缝内部，不污染 Status 码表。
class IFrameDecoder {
public:
    virtual ~IFrameDecoder() = default;

    // 绑定流参数（codec / 尺寸等），provider 在 Open 时调用一次。
    virtual Status Open(const StreamInfo& info) = 0;

    // 喂入一个压缩包（解码序）。
    virtual Status Feed(const MediaPacket& pkt) = 0;

    // 弹出一个已可重建的展示帧（显示序）。
    //   kOk 且 out 有效 ⇒ 得到一帧；kIoNotFound ⇒ 当前无可用帧（需继续 Feed）。
    virtual Status PopFrame(MediaFrame& out) = 0;

    // 重置解码状态（DPB / 部分帧缓冲），回到可接收新 GOP 的状态。
    virtual void Flush() = 0;
};

// StubDecoder —— 真实链路冒烟占位。PALA-011（VideoToolbox 解码后端）尚未实现，
// 故 Feed 诚实返回 kDecodeUnsupported，调用方据此报告「解码能力不可用」的阻塞点，
// 绝不用 mock 伪造成功。冒烟测试只验证「demux 打通 + 阻塞点被如实暴露」。
class StubDecoder : public IFrameDecoder {
public:
    Status Open(const StreamInfo&) override { return Status::Ok(); }
    Status Feed(const MediaPacket&) override {
        // 无真实解码后端：明确告知「解码能力不可用」，由上层如实报告阻塞位置。
        return Status{StatusCode::kDecodeUnsupported};
    }
    Status PopFrame(MediaFrame&) override { return Status{StatusCode::kIoNotFound}; }
    void Flush() override {}
};

// ===========================================================================
// SystemFrameProvider — MEDIA-010 抽象的具体编排实现
// ===========================================================================
// 构造时注入：PAL 解封装器（PalPtr<IMediaDemuxer>，所有权被接管）+ 解码接缝
// （IFrameDecoder*，不接管，由注入方所有）。core 不反向依赖 PAL，故 demuxer 与
// decoder 均由外部注入；真实使用时由 PAL 层用 CreateMediaDemuxer + PALA-011 解码器装配。
class SystemFrameProvider : public FrameProvider {
public:
    SystemFrameProvider(PalPtr<IMediaDemuxer> demuxer, IFrameDecoder* decoder)
        : demuxer_(std::move(demuxer)), decoder_(decoder) {}

    ~SystemFrameProvider() override {
        // 若本实例经解码器池借过一路，归还（置空闲可复用，不销毁）。
        if (pool_ != nullptr && pool_handle_ != nullptr) {
            pool_->ReleaseDecoder(pool_handle_);
            pool_handle_ = nullptr;
        }
    }

    Status Open(const MediaSource& src) override {
        if (!demuxer_) return Status{StatusCode::kInvalidArgument};
        Status s = demuxer_->Open(src);
        if (!s.IsOk()) return s;
        StreamInfo info{};
        if (demuxer_->GetStreamCount() > 0) {
            s = demuxer_->GetStreamInfo(0, info);
            if (!s.IsOk()) return s;
        }
        s = AcquireDecoderFromPoolIfAny(info);
        if (!s.IsOk()) return s;
        if (decoder_ == nullptr) return Status{StatusCode::kInvalidArgument};
        s = decoder_->Open(info);
        if (!s.IsOk()) return s;
        decoder_->Flush();
        seeked_ = false;
        return Status::Ok();
    }

    // 若注入了解码器池，优先从池借一路（把解码路由到池中的解码器）；否则用构造注入的
    // decoder。池满降级时如实返回 kResourceExhausted，不伪造、不崩溃。
    Status AcquireDecoderFromPoolIfAny(const StreamInfo& info) {
        if (pool_ == nullptr) return Status::Ok();
        if (pool_handle_ != nullptr) {
            pool_->ReleaseDecoder(pool_handle_);  // 重开时先还旧路
            pool_handle_ = nullptr;
        }
        DecoderHandle h = nullptr;
        Status s = pool_->AcquireDecoder(info.codec, h);
        if (!s.IsOk()) return s;
        pool_handle_ = h;
        decoder_ = DecoderOf(h);
        return Status::Ok();
    }

    // 精确 seek（编辑核心）。先定位到 <= target 的最近关键帧（PAL 吸收平台差异），
    // 重置解码器 DPB；具体「解码到 t 帧」发生在 AcquireFrame。
    Status Seek(const RationalTime& target, SeekPolicy policy,
                const CancelToken& token) override {
        if (token.IsCancelled()) return token.Cancelled();
        if (!demuxer_) return Status{StatusCode::kInvalidArgument};
        Status s = demuxer_->Seek(target, token);
        if (!s.IsOk()) return s;
        if (decoder_ != nullptr) decoder_->Flush();
        seeked_ = true;
        seek_target_ = target;
        (void)policy;  // policy 的帧级选取在 AcquireFrame 内按 req.policy 执行
        return Status::Ok();
    }

    Status AcquireFrame(const FrameRequest& req, MediaFrame& out_frame,
                        const CancelToken& token) override {
        out_frame = MediaFrame{};
        if (!demuxer_ || !decoder_) return Status{StatusCode::kInvalidArgument};
        // 缓存命中（read-shortcut）：借出即返回，跳过解码（lease = move-out）。
        if (cache_ != nullptr) {
            MediaFrame cached{};
            if (cache_->Find(req.at, cached)) {
                loaned_ = true;
                loaned_key_ = req.at;
                out_frame = cached;
                return Status::Ok();
            }
        }
        // 若调用方未先 Seek，或目标时间变化，则内部对齐到 req.at（幂等）。
        if (!seeked_ || CompareRational(seek_target_, req.at) != 0) {
            Status s = Seek(req.at, req.policy, token);
            if (!s.IsOk()) return s;
        }
        Status s{StatusCode::kUnknown};
        switch (req.policy) {
            case SeekPolicy::kExact:
                s = AcquireExact(req.at, token);
                break;
            case SeekPolicy::kKeyframeBefore:
                s = AcquireKeyframeBefore(req.at, token);
                break;
            case SeekPolicy::kNearest:
                s = AcquireNearest(req.at, token);
                break;
        }
        if (s.IsOk()) {
            if (cache_ != nullptr) {
                // 先入缓存，再立即借出（move-out lease）：缓存只留一份，调用方独占。
                cache_->Insert(req.at, result_);
                MediaFrame loaned{};
                if (cache_->Find(req.at, loaned)) {
                    loaned_ = true;
                    loaned_key_ = req.at;
                    out_frame = loaned;
                } else {
                    out_frame = result_;  // 防御：理论上不会发生
                }
            } else {
                out_frame = result_;
            }
        }
        return s;
    }

    void ReleaseFrame(MediaFrame& frame) override {
        // lease 模型：帧内存归 provider/decoder 池所有。若从帧缓存借出，交回缓存
        // （重新入池，LRU 可再淘汰）；否则把句柄清零，防止调用方误用已归还帧。
        if (cache_ != nullptr && loaned_) {
            cache_->Insert(loaned_key_, frame);
            loaned_ = false;
        }
        frame = MediaFrame{};
    }

    Status GetDuration(RationalTime& out) const override {
        if (!demuxer_) return Status{StatusCode::kInvalidArgument};
        return demuxer_->GetDuration(out);
    }

    void SetFrameCache(IFrameCache* cache) override { cache_ = cache; }
    void SetDecoderPool(IDecoderPool* pool) override { pool_ = pool; }

private:
    // 显示区间归属：t 落在 [frame.pts, frame.pts + frame.duration) 内。
    static bool FrameContains(const MediaFrame& f, const RationalTime& t) {
        if (f.type != MediaType::kVideo) return false;
        RationalTime end{0, 1};
        Status s = AddRational(f.video.pts, f.video.duration, end);
        if (!s.IsOk()) return false;
        return CompareRational(f.video.pts, t) <= 0 && CompareRational(t, end) < 0;
    }

    // 把命中的帧写入 result_ 并返回 Ok（lease 模型：真实实现应移交池所有权）。
    Status Finalize(const MediaFrame& src) {
        result_ = src;
        return Status::Ok();
    }

    // kExact：从 <= t 的关键帧前向解码，丢弃显示序在 t 之前的帧，直到拿到
    // 「显示区间包含 t」的那一帧；B 帧依赖（其后 P 帧）在其可重建前不会弹出，
    // 故 provider 会自然「继续解码到 t 帧及其依赖可重建为止」才返回。
    Status AcquireExact(const RationalTime& t, const CancelToken& token) {
        MediaFrame before{};
        bool have_before = false;
        for (;;) {
            if (token.IsCancelled()) return token.Cancelled();
            MediaFrame f{};
            Status ps = decoder_->PopFrame(f);
            if (ps.IsOk()) {
                if (FrameContains(f, t)) return Finalize(f);
                if (CompareRational(f.video.pts, t) <= 0) {
                    before = f;
                    have_before = true;
                } else {
                    // 已越过 t（连续 duration 假设下，before 即包含帧）。
                    if (have_before) return Finalize(before);
                    return Finalize(f);  // 无 before 的兜底
                }
                continue;
            }
            // 无可用帧：喂下一个压缩包（解码序）。
            MediaPacket pkt{};
            Status rs = demuxer_->ReadPacket(pkt);
            if (rs.code == StatusCode::kIoNotFound) break;  // demux 末尾
            if (!rs.IsOk()) return rs;
            Status fs = decoder_->Feed(pkt);
            if (!fs.IsOk()) return fs;
        }
        // demux 结束：排空解码器缓冲中剩余的展示帧。
        for (;;) {
            if (token.IsCancelled()) return token.Cancelled();
            MediaFrame f{};
            Status ps = decoder_->PopFrame(f);
            if (!ps.IsOk()) break;
            if (FrameContains(f, t)) return Finalize(f);
            if (CompareRational(f.video.pts, t) <= 0) {
                before = f;
                have_before = true;
            } else {
                if (have_before) return Finalize(before);
                return Finalize(f);
            }
        }
        if (have_before) return Finalize(before);
        return Status{StatusCode::kIoNotFound};
    }

    // kKeyframeBefore：返回 <= t 最近关键帧（缩略图 / 不敏感场景）。不要求重建到 t。
    // 实现：seek 已落到 <= t 关键帧，前向解码弹出**第一帧**即该关键帧，直接返回。
    Status AcquireKeyframeBefore(const RationalTime& t, const CancelToken& token) {
        (void)t;
        for (;;) {
            if (token.IsCancelled()) return token.Cancelled();
            MediaFrame f{};
            Status ps = decoder_->PopFrame(f);
            if (ps.IsOk()) return Finalize(f);  // 首帧即关键帧
            MediaPacket pkt{};
            Status rs = demuxer_->ReadPacket(pkt);
            if (rs.code == StatusCode::kIoNotFound) return Status{StatusCode::kIoNotFound};
            if (!rs.IsOk()) return rs;
            Status fs = decoder_->Feed(pkt);
            if (!fs.IsOk()) return fs;
        }
    }

    // kNearest：在「解码开销」与「接近 t」间权衡，返回 |pts - t| 最小的可解码帧。
    Status AcquireNearest(const RationalTime& t, const CancelToken& token) {
        MediaFrame best{};
        bool have_best = false;
        int64_t best_dist = 0;
        for (;;) {
            if (token.IsCancelled()) return token.Cancelled();
            MediaFrame f{};
            Status ps = decoder_->PopFrame(f);
            if (ps.IsOk()) {
                int64_t d = static_cast<int64_t>(CompareRational(f.video.pts, t));
                int64_t ad = d < 0 ? -d : d;
                if (!have_best || ad < best_dist) {
                    best = f;
                    best_dist = ad;
                    have_best = true;
                }
                if (CompareRational(f.video.pts, t) > 0) {
                    // 已越过 t，单调序列下最近者已确定。
                    if (have_best) return Finalize(best);
                }
                continue;
            }
            MediaPacket pkt{};
            Status rs = demuxer_->ReadPacket(pkt);
            if (rs.code == StatusCode::kIoNotFound) break;
            if (!rs.IsOk()) return rs;
            Status fs = decoder_->Feed(pkt);
            if (!fs.IsOk()) return fs;
        }
        for (;;) {
            if (token.IsCancelled()) return token.Cancelled();
            MediaFrame f{};
            Status ps = decoder_->PopFrame(f);
            if (!ps.IsOk()) break;
            int64_t d = static_cast<int64_t>(CompareRational(f.video.pts, t));
            int64_t ad = d < 0 ? -d : d;
            if (!have_best || ad < best_dist) {
                best = f;
                best_dist = ad;
                have_best = true;
            }
        }
        if (have_best) return Finalize(best);
        return Status{StatusCode::kIoNotFound};
    }

    PalPtr<IMediaDemuxer> demuxer_;
    IFrameDecoder* decoder_ = nullptr;  // 不接管（Open 时可能被子解码器池覆盖）
    IFrameCache* cache_ = nullptr;      // 帧缓存钩子（MEDIA-011）
    IDecoderPool* pool_ = nullptr;      // 解码器池钩子（MEDIA-012）
    DecoderHandle pool_handle_ = nullptr;  // 本实例从池借到的路（析构/重开时归还）
    bool loaned_ = false;              // 当前 out_frame 是否来自帧缓存（move-out）
    RationalTime loaned_key_{0, 1};    // 借出的缓存 key（ReleaseFrame 时交回）
    bool seeked_ = false;
    RationalTime seek_target_{0, 1};
    MediaFrame result_;  // 命中帧暂存（lease 移交前）
};

// 工厂：构造 SystemFrameProvider（调用方持有 unique_ptr<FrameProvider>）。
// 定义在 system_frame_provider.cpp（out-of-line），使 cq_core 携带真实符号。
std::unique_ptr<FrameProvider> CreateSystemFrameProvider(
    PalPtr<IMediaDemuxer> demuxer, IFrameDecoder* decoder);

}  // namespace cq

#endif  // CQ_MEDIA_SYSTEM_FRAME_PROVIDER_H_
