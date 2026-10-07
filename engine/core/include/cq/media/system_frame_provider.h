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
#include "cq/base/logging.h"          // CQ_LOG_*_WF：带 workflow 的分级日志（CORE-010）
#include "cq/base/perf.h"        // 性能埋点 + CQ_SLOW_CALL_WF（真机实测用）
#include "cq/base/status.h"       // Status / StatusCode
#include "cq/base/rational_time.h"         // RationalTime
#include "cq/media/frame_provider.h"  // FrameProvider（MEDIA-010 抽象）
#include "cq/media/decoder_pool.h"   // IDecoderPool / DecoderOf（MEDIA-012 接入）
#include "cq/pal/pal_common.h"        // NativeImageHandle / PalPtr
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
        ResetSequentialState();
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
        // CORE-010：统一走 base 的 SlowCallAlarm —— Release 可见。Seek 一旦卡住
        // 会顺着调用链把整条预览链拖死，而这类故障恰恰不会发生在 Debug 包上。
        CQ_SLOW_CALL_WF(Workflow::kFrameCache, "provider Seek");
        if (token.IsCancelled()) return token.Cancelled();
        if (!demuxer_) return Status{StatusCode::kInvalidArgument};
        Status s = demuxer_->Seek(target, token);
        if (!s.IsOk()) return s;
        if (decoder_ != nullptr) decoder_->Flush();
        seeked_ = true;
        seek_target_ = target;
        // MEDIA-021：Flush 清空了解码输出队列、demuxer 落点未知 —— 增量锚点与
        // 关键帧锚点一并失效（proven_span_ 保留：素材关键帧分布是素材属性，与
        // 解码位置无关）。consumed_ 复位：新目标尚未被任何取帧服务过。
        has_last_ = false;
        has_kf_ = false;
        consumed_ = false;
        (void)policy;  // policy 的帧级选取在 AcquireFrame 内按 req.policy 执行
        return Status::Ok();
    }

    Status AcquireFrame(const FrameRequest& req, MediaFrame& out_frame,
                        const CancelToken& token) override {
        // 埋点：取帧总耗时（含缓存查询 / seek / 解码）。真机实测打开埋点后，
        // 这是判断"取一帧够不够快"的主指标；pts 用于把耗时对齐到具体帧。
        // 用显式 PerfScope 而非 CQ_PERF_SCOPE 宏：需要在命中分支上附加信息，
        // 且宏生成的变量名依赖行号、不可靠。关闭时同样零开销（构造时查开关）。
        cq::PerfScope perf_scope(cq::PerfStage::kCacheLookup, req.at);
        (void)perf_scope;

        out_frame = MediaFrame{};
        if (!demuxer_ || !decoder_) return Status{StatusCode::kInvalidArgument};
        // 缓存命中（read-shortcut）：借出即返回，跳过解码（lease = move-out）。
        // 命中路径不动 decoder/demux，顺序增量锚点（has_last_）保持有效。
        if (cache_ != nullptr) {
            MediaFrame cached{};
            if (cache_->Find(req.at, cached)) {
                loaned_ = true;
                loaned_key_ = req.at;
                out_frame = cached;
                return Status::Ok();
            }
        }
        Status s{StatusCode::kUnknown};
        // MEDIA-021 快路径：顺序前进的 kExact 请求不重新 seek，从上次交付位置
        // 继续前向解码（每帧 seek 重解 GOP 是预览帧率的真瓶颈，见 ADR-0017）。
        bool handled = false;
        if (req.policy == SeekPolicy::kExact) {
            handled = TrySequentialAcquire(req.at, token, s);
        }
        if (!handled) {
            // 慢路径：对齐到 req.at（幂等）。consumed_ 表示该对齐目标已被一次取帧
            // 消费过 —— 重复请求同一目标时 decoder 输出队列已越过该帧，必须重新
            // seek，否则 AcquireExact 的「越过兜底」会返回下一帧（违反 kExact）。
            if (!seeked_ || consumed_ || CompareRational(seek_target_, req.at) != 0) {
                Status as = Seek(req.at, req.policy, token);
                if (!as.IsOk()) return as;
            }
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
        }
        if (s.IsOk()) {
            RecordDelivered();
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
        } else {
            // 失败/取消：Acquire* 可能已半途 Feed/Pop，decoder 相对锚点的增量关系
            // 不再可信 —— 失效锚点，下次走慢路径重新对齐（保守但简单）。
            has_last_ = false;
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

    // 接管解码器所有权（可选）。
    // 为什么需要：本类的构造签名收的是裸 `IFrameDecoder*` 且明确「不接管」，这在单测里
    // 没问题（decoder 是栈对象），但 PAL 装配时解码器是 new 出来的——没有接管能力，
    // 装配方就得自己想办法让 provider 与 decoder 同生命周期，容易漏。
    // 装配方（pal/<platform>/）用带 `unique_ptr<IFrameDecoder>` 的工厂重载即可。
    void AdoptDecoder(std::unique_ptr<IFrameDecoder> decoder) {
        owned_decoder_ = std::move(decoder);
        decoder_ = owned_decoder_.get();
    }

private:
    // CORE-010：这两个限流计数器提到 Release。它们服务于 Trace 级诊断，Release 下
    // CQ_LOG_TRACE_WF 展开为空、if 体被优化掉，成员本身零开销；留在 NDEBUG 块里
    // 则 Release 编译不过（用法已不再被条件编译保护）。
    int debug_finalize_logs_ = 0;
    int debug_chase_iters_ = 0;
    // =========================================================================
    // MEDIA-021：顺序取帧快路径（不重新 seek 的前进取帧）
    // =========================================================================
    // 动机（实测，见 .ai/memory/baselines.md「UIA-010 子步骤 5」）：顺序播放时
    // 每帧都「demuxer seek + decoder Flush + 从关键帧重解整个 GOP」，单帧 acquire
    // 93ms（Release，128x128），10fps 上限 —— 而孤立请求同素材仅 ~5ms。
    //
    // 正确性依据：若 (last_pts_, t] 区间内没有关键帧，则 seek(t) 只能落到该区间
    // **之前**的关键帧（<= t 的最近关键帧 <= last_pts_），从锚点继续前向解码的
    // 距离 (t - last_pts_) 严格不大于 seek 的解码距离 —— 继续解码不但不慢，还省
    // 掉 demuxer seek 与 Flush。AcquireExact 的「展示区间归属」判定不变，拿到的
    // 仍是包含 t 的那一帧，kExact 语义完整保留。
    //
    // 阈值不拍脑袋（E6 同族教训）：不用固定常量，而是维护「已证实的无关键帧最大
    // 跨度」proven_span_ —— 数据来源只有两处实证：连续两个关键帧的间隔、关键帧
    // 到交付帧的距离。初始为 0（未学到任何证据 → 全走慢路径），只吸收已见事实。
    // 区间内「实际有关键帧但跨度判定放行」的最坏情况 = 多解 (关键帧 - last_pts_)
    // <= 一个 GOP 的帧数，与优化前的全 GOP 重解同阶，不会爆炸。
    //
    // 已知限制（诚实记录，不在本路径修复）：
    //   * 快路径无法交付「上次交付过的同一帧」—— lease 语义下该帧像素已让渡给
    //     调用方；落在上一帧展示区间内的重复/微进请求一律走慢路径重解。
    //   * 帧间隙流（pts 不连续）下，快路径的越过兜底取区间后首帧，慢路径取区间
    //     前帧，近似选择相差一帧；golden 素材与常见相机素材无间隙。

    // 尝试顺序快路径。返回 true = 已定论（结果在 out_status，含失败/取消）；
    // 返回 false = 不适用，调用方走慢路径。
    bool TrySequentialAcquire(const RationalTime& t, const CancelToken& token,
                              Status& out_status) {
        // 锚点必须存在（上次成功交付后未被打断）。
        if (!has_last_) return false;
        // t 必须严格越过上次交付帧的展示区间终点：落在区间内的请求走慢路径
        // 重解（见上方「已知限制」第 1 条）。
        if (CompareRational(t, last_end_) < 0) return false;
        // 前进跨度必须不超已证实的无关键帧跨度，否则区间内大概率有关键帧，
        // seek 到该关键帧解码距离更短，走慢路径。
        RationalTime span{0, 1};
        Status ss = SubRational(t, last_pts_, span);
        if (!ss.IsOk()) return false;
        if (CompareRational(span, proven_span_) > 0) return false;
        out_status = AcquireExact(t, token);
        if (!out_status.IsOk()) {
            // 半途失败/取消：decoder 相对锚点已漂移，失效锚点，下次慢路径对齐。
            has_last_ = false;
        }
        return true;
    }

    // 记录本次交付帧（result_），更新增量锚点与自适应阈值样本。任何 policy 的
    // 成功交付都会推进解码位置，锚点一律有效。
    void RecordDelivered() {
        const RationalTime pts = result_.video.pts;
        RationalTime end{0, 1};
        if (!AddRational(pts, result_.video.duration, end).IsOk()) {
            has_last_ = false;  // 区间终点算不出（溢出等）：放弃锚点，宁慢不错
            return;
        }
        last_pts_ = pts;
        last_end_ = end;
        has_last_ = true;
        consumed_ = true;  // seek_target_ 已被服务，重复同目标必须重新 seek
        if (has_kf_) {
            // 实证样本：从最近关键帧到本交付帧之间无关键帧（Feed 序列全程观察）。
            RationalTime span{0, 1};
            if (SubRational(pts, last_kf_pts_, span).IsOk() &&
                CompareRational(span, proven_span_) > 0) {
                proven_span_ = span;
            }
        }
    }

    // 喂包同时观察关键帧分布（proven_span_ 的数据来源）。三个 Acquire* 循环
    // 共用，任何路径喂的包都算实证样本。
    Status FeedPacket(const MediaPacket& pkt) {
        if (pkt.is_keyframe) {
            if (has_kf_) {
                // 连续两个关键帧的间隔 = 已证实的无关键帧跨度（比「关键帧到交付
                // 帧」更完整的证据，通常恰为 GOP 长度）。
                RationalTime span{0, 1};
                if (SubRational(pkt.pts, last_kf_pts_, span).IsOk() &&
                    CompareRational(span, proven_span_) > 0) {
                    proven_span_ = span;
                }
            }
            last_kf_pts_ = pkt.pts;
            has_kf_ = true;
        }
        return decoder_->Feed(pkt);
    }

    // 顺序增量状态全量复位（Open / 换源时）。proven_span_ 也清零：换源后素材的
    // 关键帧分布是新的，旧证据不作数。
    void ResetSequentialState() {
        has_last_ = false;
        last_pts_ = RationalTime{0, 1};
        last_end_ = RationalTime{0, 1};
        has_kf_ = false;
        last_kf_pts_ = RationalTime{0, 1};
        proven_span_ = RationalTime{0, 1};
        consumed_ = false;
    }

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
        if (debug_finalize_logs_ < 3) {
            ++debug_finalize_logs_;
            CQ_LOG_TRACE_WF(Workflow::kFrameCache, "finalize pts=%lld/%d dur=%lld/%d",
                            static_cast<long long>(result_.video.pts.value),
                            static_cast<int>(result_.video.pts.timescale),
                            static_cast<long long>(result_.video.duration.value),
                            static_cast<int>(result_.video.duration.timescale));
        }
        return Status::Ok();
    }

    // kExact：从 <= t 的关键帧前向解码，丢弃显示序在 t 之前的帧，直到拿到
    // 「显示区间包含 t」的那一帧；B 帧依赖（其后 P 帧）在其可重建前不会弹出，
    // 故 provider 会自然「继续解码到 t 帧及其依赖可重建为止」才返回。
    //
    // 循环结构（MEDIA-021 实测暴露，勿改回「弹不出才喂」）：**先 Feed 一包，
    // 再连续 PopFrame**。原因：平台解码器按完成序回调，B 帧在其参考 P 之后完成；
    // 若队首 P 在 B 尚未喂入时就弹出，decoder 的重排判据（pending 未完成包中
    // 是否有 pts 更小者）无信息可用，kExact 会交付 P（差帧 + 负 duration）。
    // 预喂让每个 B 的存在在其前驱弹出前被 pending 判据看见；异步解码管线中
    // 预喂帧的解码与等待重叠，增量成本≈一次 demux ReadPacket。
    // MEDIA-027：单次 kExact 的**追帧上界**（成功弹出帧数）。
    //
    // 背景：真机实测出现单次 AcquireExact 连续解码 8 秒以上仍不返回 —— 泵线程被
    // 一帧独占，表现为播放永久冻结（rendered/s 掉到 0 后再不起来），期间播放头按
    // 墙钟继续走，下一次请求的目标又更远，形成永不收敛的追赶。顺序快路径靠
    // proven_span_ 约束跨度，但该跨度是从素材实证长出来的，最大可达一个 GOP 甚至
    // 更长的「关键帧到交付帧」距离，不足以兜住这个形态。
    //
    // 取值依据：一次精确 seek 最坏解码距离 = 一个 GOP。4K60 常见 GOP 2~5s = 120~300
    // 帧；给到 600（≈10s@60fps）留足余量，超过即判定「异常追赶」并如实返回
    // kIoNotFound，让泵继续下一帧而不是把整条预览链吊死。
    static constexpr int kMaxChasePops = 600;

    Status AcquireExact(const RationalTime& t, const CancelToken& token) {
        MediaFrame before{};
        bool have_before = false;
        bool drained = false;
        int chase_pops = 0;
        for (;;) {
            if (token.IsCancelled()) return token.Cancelled();
            if (!drained) {
                MediaPacket pkt{};
                Status rs = demuxer_->ReadPacket(pkt);
                if (rs.code == StatusCode::kIoNotFound) {
                    drained = true;  // demux 末尾：转入纯弹出（drain）阶段
                } else if (!rs.IsOk()) {
                    return rs;
                } else {
                    Status fs = FeedPacket(pkt);
                    if (!fs.IsOk()) return fs;
                }
            }
            MediaFrame f{};
            Status ps = decoder_->PopFrame(f);
            if (!ps.IsOk()) {
                if (drained) break;
                continue;  // 解码管线尚未出帧：继续喂下一包
            }
            // MEDIA-026 追帧探针（每 240 次弹出一次）：判别「t 跳变不可达」vs
            // 「解码追赶正常」。放进 Trace 后由开关控制，不必再改代码。
            if (++debug_chase_iters_ % 240 == 0) {
                CQ_LOG_TRACE_WF(Workflow::kFrameCache,
                                "chase t=%.2fs popped=%.2fs drained=%d lag_iters=%d",
                                t.ToSeconds(), f.video.pts.ToSeconds(), drained ? 1 : 0,
                                debug_chase_iters_);
            }
            if (FrameContains(f, t)) return Finalize(f);
            if (++chase_pops > kMaxChasePops) {
                // 追帧上界（MEDIA-027）：如实报告「这一帧没追上」，交还调用方
                // （泵计一次非 Ok 并继续下一请求），不把预览链吊死。
                // Warn **且 Release 可见**：追帧上界命中意味着「这一帧没按时交付」，
                // 是取帧链路病掉的最外层症状（MEDIA-027 时表现为帧率归零）。
                // 旧版这行被 NDEBUG 挡着——真机 Release 包只会给我们沉默。
                CQ_LOG_WARN_WF(Workflow::kFrameCache,
                               "追帧上界 %d：放弃 t=%.2fs（解码位置 %.2fs，drained=%d）",
                               kMaxChasePops, t.ToSeconds(), f.video.pts.ToSeconds(),
                               drained ? 1 : 0);
                return Status{StatusCode::kIoNotFound};
            }
            if (CompareRational(f.video.pts, t) <= 0) {
                before = f;
                have_before = true;
            } else {
                // 已越过 t（连续 duration 假设下，before 即包含帧）。
                if (have_before) return Finalize(before);
                return Finalize(f);  // 无 before 的兜底
            }
        }
        if (have_before) return Finalize(before);
        return Status{StatusCode::kIoNotFound};
    }

    // kKeyframeBefore：返回 <= t 最近关键帧（缩略图 / 不敏感场景）。不要求重建到 t。
    // 实现：seek 已落到 <= t 关键帧，前向解码弹出**第一帧**即该关键帧，直接返回。
    // 与 AcquireExact 同理由「先喂后弹」（seek 落 IDR，其 dts 最小、最先完成，
    // 首个弹出帧必为关键帧；预喂不改变这一点）。
    Status AcquireKeyframeBefore(const RationalTime& t, const CancelToken& token) {
        (void)t;
        for (;;) {
            if (token.IsCancelled()) return token.Cancelled();
            MediaPacket pkt{};
            Status rs = demuxer_->ReadPacket(pkt);
            if (rs.code == StatusCode::kIoNotFound) return Status{StatusCode::kIoNotFound};
            if (!rs.IsOk()) return rs;
            Status fs = FeedPacket(pkt);
            if (!fs.IsOk()) return fs;
            MediaFrame f{};
            Status ps = decoder_->PopFrame(f);
            if (ps.IsOk()) return Finalize(f);  // 首帧即关键帧
        }
    }

    // kNearest：在「解码开销」与「接近 t」间权衡，返回 |pts - t| 最小的可解码帧。
    // 与 AcquireExact 同理由「先喂后弹」（见其注释；重排后弹出为显示序，
    // 「越过 t 即最近者已定」的单调性才成立）。
    Status AcquireNearest(const RationalTime& t, const CancelToken& token) {
        MediaFrame best{};
        bool have_best = false;
        int64_t best_dist = 0;
        bool drained = false;
        for (;;) {
            if (token.IsCancelled()) return token.Cancelled();
            if (!drained) {
                MediaPacket pkt{};
                Status rs = demuxer_->ReadPacket(pkt);
                if (rs.code == StatusCode::kIoNotFound) {
                    drained = true;
                } else if (!rs.IsOk()) {
                    return rs;
                } else {
                    Status fs = FeedPacket(pkt);
                    if (!fs.IsOk()) return fs;
                }
            }
            MediaFrame f{};
            Status ps = decoder_->PopFrame(f);
            if (!ps.IsOk()) {
                if (drained) break;
                continue;
            }
            int64_t d = static_cast<int64_t>(CompareRational(f.video.pts, t));
            int64_t ad = d < 0 ? -d : d;
            if (!have_best || ad < best_dist) {
                best = f;
                best_dist = ad;
                have_best = true;
            }
            if (CompareRational(f.video.pts, t) > 0) {
                // 已越过 t，单调序列下最近者已确定。
                return Finalize(best);
            }
        }
        if (have_best) return Finalize(best);
        return Status{StatusCode::kIoNotFound};
    }

    PalPtr<IMediaDemuxer> demuxer_;
    IFrameDecoder* decoder_ = nullptr;  // 不接管（Open 时可能被子解码器池覆盖）
    std::unique_ptr<IFrameDecoder> owned_decoder_;  // AdoptDecoder 后持有，保证同生命周期
    IFrameCache* cache_ = nullptr;      // 帧缓存钩子（MEDIA-011）
    IDecoderPool* pool_ = nullptr;      // 解码器池钩子（MEDIA-012）
    DecoderHandle pool_handle_ = nullptr;  // 本实例从池借到的路（析构/重开时归还）
    bool loaned_ = false;              // 当前 out_frame 是否来自帧缓存（move-out）
    RationalTime loaned_key_{0, 1};    // 借出的缓存 key（ReleaseFrame 时交回）
    bool seeked_ = false;
    RationalTime seek_target_{0, 1};
    MediaFrame result_;  // 命中帧暂存（lease 移交前）

    // ---- MEDIA-021：顺序取帧增量状态（只存 pts/duration 元数据，绝不持有 image）----
    bool has_last_ = false;           // 增量锚点是否可信（上次成功交付后未被打断）
    RationalTime last_pts_{0, 1};     // 上次交付帧 pts
    RationalTime last_end_{0, 1};     // 上次交付帧展示区间终点（pts + duration）
    bool has_kf_ = false;             // 关键帧锚点是否有效（自上次 seek/复位后见过关键帧）
    RationalTime last_kf_pts_{0, 1};  // 最近喂入的关键帧 pts
    RationalTime proven_span_{0, 1};  // 已证实的无关键帧最大跨度（自适应阈值，实证才增长）
    bool consumed_ = false;           // seek_target_ 是否已被一次取帧消费（防同帧重复错帧）
};

// 工厂：构造 SystemFrameProvider（调用方持有 unique_ptr<FrameProvider>）。
// 定义在 system_frame_provider.cpp（out-of-line），使 cq_core 携带真实符号。
std::unique_ptr<FrameProvider> CreateSystemFrameProvider(
    PalPtr<IMediaDemuxer> demuxer, IFrameDecoder* decoder);

// 工厂重载：**接管解码器所有权**（内部转调 AdoptDecoder）。
// PAL 装配用这条——真实解码器（PALA-011 VideoToolboxDecoder 等）是堆对象，
// 交给 provider 持有即可保证二者同生命周期，装配方无需另设持有结构。
std::unique_ptr<FrameProvider> CreateSystemFrameProvider(
    PalPtr<IMediaDemuxer> demuxer, std::unique_ptr<IFrameDecoder> owned_decoder);

}  // namespace cq

#endif  // CQ_MEDIA_SYSTEM_FRAME_PROVIDER_H_
