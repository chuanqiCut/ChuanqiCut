// ChuanqiCut — PALA-011 Apple 硬解后端（VideoToolbox）
//
// 实现 core 冻结接口 `cq::IFrameDecoder`（定义于 core/include/cq/media/system_frame_provider.h）。
// 用 VideoToolbox 的 `VTDecompressionSession` 做 H.264 / HEVC 硬解，输出 CVPixelBuffer
// （BGRA），包装为 PAL 的 `NativeImageHandle` 由上层消费。
//
// 红线（与 core 一致，本文件只是 PAL Apple 实现，不进入 core 头）：
//   * 平台类型（CVPixelBufferRef / VT* / AV* / CM*）只出现在本文件与 .mm；
//   * 内核禁用异常：错误一律 Status；长任务接受 CancelToken（本接缝为同步/协作式）。
//
// 本头**仅被 Apple 平台 TU 包含**（tests/ 与未来 PAL 装配代码），绝不进入 core。
// 门禁 check_pal_headers.py 只扫 core/include/cq/{pal,gfx,media}，故此处使用平台类型安全。

#ifndef CQ_PAL_APPLE_MEDIA_DECODE_H_
#define CQ_PAL_APPLE_MEDIA_DECODE_H_

#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>

#include <atomic>
#include <deque>
#include <map>
#include <mutex>
#include <string>
#include <utility>  // std::pair

#include "cq/media/system_frame_provider.h"  // cq::IFrameDecoder / MediaFrame / StreamInfo

namespace cq {

// 平台原生图像资源的 Apple 实现（common.h 中 `CqNativeImage` 的完整定义，仅 Apple TU 可见）。
// `NativeImageHandle` = `CqNativeImage*`，这里给出完整布局，供上层（含测试）取回 CVPixelBuffer
// 做像素级正确性验证；与 PALA-002 的 CVMetalTexture 零拷贝路径同根（本期先产出可验证的像素）。
//
// 生命周期：解码器每个 PopFrame 产出一个 CqNativeImage（refcount=1，持有 CVPixelBuffer）。
// 解码器在「下一次 PopFrame / Flush / 析构」时释放上一个返回的实例，因此调用方必须在
// 下一次取帧前消费并拷贝像素（lease 模型，与 PAL 一致；core 不反向依赖本结构）。
struct CqNativeImage {
    CVPixelBufferRef pixel_buffer = nullptr;  // 解码产出的像素（BGRA，可被 Metal 直接消费）
    std::atomic<int32_t> refcount{1};

    explicit CqNativeImage(CVPixelBufferRef pb) : pixel_buffer(pb) {
        if (pb) CFRetain(pb);
    }
    ~CqNativeImage() {
        if (pixel_buffer) {
            CFRelease(pixel_buffer);
            pixel_buffer = nullptr;
        }
    }
};

// Apple 平台专属辅助：从 NativeImageHandle 取回 CVPixelBufferRef（仅限 Apple TU 调用）。
CVPixelBufferRef GetCvPixelBuffer(NativeImageHandle handle);

// VideoToolbox 硬解后端（实现 IFrameDecoder）。
//
// 设计要点：
//   * 用 `VTDecompressionSession` 做 H.264 / HEVC 硬解（优先硬件；实际是否硬解由
//     `UsingHardwareAcceleratedVideoDecoder` 属性运行时查询，如实上报，不伪造）。
//   * 输入是 PALA-010 出的**压缩包**（AVCC/HVCC 长度前缀 NAL），输出是解码后的像素。
//   * 输出格式选 BGRA（CVPixelBuffer）：既能被 Metal 直接消费（PALA-002 零拷贝同根），
//     也便于像素级正确性验证（避免 NV12→RGB 转换引入的验证噪声）。10-bit HEVC
//     由 VT 自动转换到 8-bit BGRA（MEDIA-022；HDR 色调映射不在本期范围）。
//   * 参数集注入：通过 Open 时由 source path 打开 AVAsset 取得视频轨的
//     `CMFormatDescription`（内嵌 avcC/hvcC）建立解码会话；无需手解字节，
//     也绕开任何已废弃的 parameter-set 构造 API。
//   * 解码重排（dts→pts）：⚠️ VT 输出回调按**解码完成序**（≈dts 序），不是显示序
//     —— MEDIA-021 逐帧 pts 断言实测暴露（B 帧 B 在其参考 P 之后完成）。故
//     PopFrame 必须自行重排：回调携带 dts（经 sourceFrameRefCon 的 CMSampleBuffer
//     取得）并登记「已喂未完成」集合；弹出时取 pts 最小帧，仅当不存在 pts 更小
//     的未完成包时才可交付，否则等待异步帧完成。Flush 清空重排状态。
//   * seek 后 flush/reset：Flush() 清空待出队帧并复位时长跟踪；新 GOP 以 IDR/IRAP 起头，
//     VT 内部 DPB 随之自动复位，无需重建会话。
//
// 支持的编码（其余诚实返回 kDecodeUnsupported，绝不伪造）：
//   * H.264（avcC）；HEVC（hvcC，'hvc1'/'hev1'；杜比视界 'dvh1'/'dvhe' 按 HEVC 基底
//     尝试 —— MEDIA-022，iPhone 相册默认编码）。杜比视界会话在部分平台可能失败，
//     如实报错。
//
// 不实现（本次范围外，诚实返回 kDecodeUnsupported，绝不伪造）：
//   * PALA-012 编码导出
//   * PALA-002 零拷贝导入（本期产出 CVPixelBuffer，已为同根）
//   * ProRes / MJPEG 等其它解码（需求出现时按同构路径补）
class VideoToolboxDecoder : public IFrameDecoder {
public:
    // source_path：用于读取 avcC/hvcC 建立解码会话（Apple PAL 细节，不进入 core）。
    // 可为 nullptr；此时解码将返回 kDecodeUnsupported（诚实报告缺 codec 描述）。
    explicit VideoToolboxDecoder(const char* source_path = nullptr);
    ~VideoToolboxDecoder() override;

    VideoToolboxDecoder(const VideoToolboxDecoder&) = delete;
    VideoToolboxDecoder& operator=(const VideoToolboxDecoder&) = delete;

    Status Open(const StreamInfo& info) override;
    Status Feed(const MediaPacket& pkt) override;
    Status PopFrame(MediaFrame& out) override;
    void Flush() override;

    // 查询本次会话是否真正走了硬件解码（运行时查询，非编译期推断；不伪造硬解生效）。
    bool IsHardwareAccelerated() const { return session_hw_; }

    // 已解码且已出队的帧数（供测试/诊断）。
    int64_t PoppedCount() const { return popped_count_; }

    // 实际输出尺寸（MEDIA-023 降采样后；供测试/诊断）。
    uint32_t OutputWidth() const { return output_width_; }
    uint32_t OutputHeight() const { return output_height_; }

    // MEDIA-025：色彩管理状态（供诊断；true = 已命令 VT 转换到 BT.709 SDR）。
    bool HdrSource() const { return hdr_source_; }
    bool ColorConvertedToSdr() const { return color_converted_; }

    // MEDIA-027：输出队列上界（帧数）。**内存安全闸门**，不是性能调优参数。
    //
    // 背景（真机 iPhone 17 Pro 实测，1080x1920 BGRA ≈ 8.3MB/帧）：显示序连续性
    // 判据一旦「卡死」（VFR 帧长变化 / VT 静默丢帧后，队列最小 pts 与期望值不等
    // 且已无在途帧），PopFrame 会原样返回 kIoNotFound 而**不弹出**，队列从此只进
    // 不出 —— 数百帧即 3.4GB，进程被 jetsam 以 signal 9 杀掉，表现为「播放几秒后
    // 永久卡死」。重排判据的正确性不可能零缺陷，故必须有这道不依赖它的上界。
    //
    // 取值依据：播放期队列常态是「喂一包弹一帧」（深度 1~2），只有 B 帧重排窗口
    // 会短暂抬高；12 帧远超任何合理 B 帧深度（常见 ≤ 4），同时把最坏常驻内存
    // 压在 ~100MB（4K 素材降采样后）以内。
    static constexpr size_t kMaxQueuedFrames = 12;

    // MEDIA-027：判定「显示序缺口」所需的**连续**不匹配次数上界。
    //
    // 判据：PopFrame 观察到「队列最小 pts ≠ 期望值」且**已无在途帧**。B 帧重排下
    // 这是常态（参考 P 先到，其 B 帧在其后才喂入），连续几次是正常的；超过本上界
    // 即说明期望的那一帧永远不会来（丢帧 / VFR 外推失效），按缺口放行。
    //
    // 取值依据：B 帧重排窗口 = 连续 B 帧数 + 1，常见 ≤ 4（本仓库 golden 素材即 3）。
    // 取 8 留一倍余量；代价是缺口判定的延迟最多 8 次 Feed（≈8 帧缓冲），内存上界
    // 仍由 kMaxQueuedFrames 兜住。
    static constexpr int kMaxMismatchStreak = 8;

    // 输出尺寸钳制（MEDIA-023，纯函数可测）：长边 >1920 时等比缩到长边 1920，
    // 宽高取偶（YUV 采样对齐）；≤1080p 原样返回。
    static std::pair<int32_t, int32_t> ClampOutputDimensions(int32_t width, int32_t height) {
        constexpr int32_t kMaxEdge = 1920;
        int32_t w = width;
        int32_t h = height;
        if (w > kMaxEdge || h > kMaxEdge) {
            const int32_t num = (w >= h) ? w : h;
            w = (w * kMaxEdge + num / 2) / num;   // 四舍五入
            h = (h * kMaxEdge + num / 2) / num;
            if (w < 2) w = 2;
            if (h < 2) h = 2;
        }
        w -= w % 2;
        h -= h % 2;
        return {w, h};
    }

    // HDR 源判定（MEDIA-025，纯函数可测）：传递函数为 HLG/PQ，或原色域为
    // BT.2020 且传递函数非 709 —— 需要转换到 BT.709 SDR 再进渲染链。
    // 标签缺失（nullptr/无扩展）= 未知 → 按 SDR 处理（不转换，行为同旧）。
    static bool IsHdrColorSource(CFStringRef primaries, CFStringRef transfer);

private:
    // 输出回调（C 函数，经 refCon 取回 this）。
    static void OutputCallback(void* ref_con, void* source_ref_con, OSStatus status,
                              VTDecodeInfoFlags info_flags, CVImageBufferRef image_buffer,
                              CMTime pts, CMTime duration);

    void Enqueue(CVPixelBufferRef pb, const RationalTime& pts, const RationalTime& dts);
    // 回调完成登记（成败皆调）：把该包从「已喂未完成」集合移除，解锁重排等待。
    void MarkDecoded(const RationalTime& dts);
    void ReleaseOutputQueue();
    void TeardownSession();
    RationalTime ToRational(CMTime t) const;

    std::string source_path_;
    CodecId bound_codec_ = CodecId::kUnknown;
    uint32_t width_ = 0;
    uint32_t height_ = 0;
    uint32_t output_width_ = 0;   // MEDIA-023：实际输出尺寸（降采样后）
    uint32_t output_height_ = 0;
    // MEDIA-025：源色彩标签（std::string 拷贝 —— CFString 由源 fd 持有，fd 释放后
    // 原指针失效）与转换状态（供诊断与单测）。
    bool hdr_source_ = false;
    bool color_converted_ = false;
    std::string src_primaries_;
    std::string src_transfer_;
    std::string src_matrix_;

    CMFormatDescriptionRef format_desc_ = nullptr;  // Open 时取得，会话与 CMSampleBuffer 共用
    VTDecompressionSessionRef session_ = nullptr;

    // 输出队列（完成序入队，PopFrame 重排为显示序弹出）。互斥保护（回调可能在异线程）。
    std::mutex queue_mutex_;
    struct OutputFrame {
        CVPixelBufferRef pb = nullptr;
        RationalTime pts{0, kProjectTimeScale};
        RationalTime dts{0, kProjectTimeScale};
    };
    std::deque<OutputFrame> output_queue_;
    // ⚠️ P77 不变量：**下面两个容器 + output_queue_ 一律由 queue_mutex_ 保护**，
    // 没有例外。它们有两个写入方：①调用方线程（Feed 登记 / PopFrame、Flush 清理）；
    // ②VT 输出回调线程（OutputCallback → Enqueue / MarkDecoded，在 CoreMedia 队列上）。
    // 异步硬解下「喂第 N+1 包」与「第 N 包回调」天然并发 —— 曾经只有 Feed 的插入
    // 无锁，结果是并发写坏红黑树，SIGSEGV @0x0 落在 map::operator[] 的再平衡里。
    // 加字段 / 加访问点时，逐个 grep 该字段的全部访问点并指认守卫互斥量。
    // 已喂入、尚未收到完成回调的包：dts.value → pts（重排依据）。key 约束：
    // demuxer 已把 pts/dts 统一转换到项目网格（timescale 120000），故用 value 作 key。
    std::map<int64_t, RationalTime> pending_dts_pts_;
    // MEDIA-026：各未完成包的提交时刻（steady clock ns）——PopFrame 等待上界
    // 依据：VT 偶发**静默丢弃**某帧（永不回调，真机 ~5-7s 必现一次），等待无上界
    // 会把泵永久卡死。超时的帧按丢失处理（清理 + kIoNotFound，上层重新 seek）。
    std::map<int64_t, uint64_t> pending_submit_nanos_;
    RationalTime prev_popped_pts_{0, 0};  // timescale=0 表示未初始化
    RationalTime prev_duration_{0, 1};    // 上一弹出帧 duration（显示序连续性判据：期望=pts+duration）
    bool has_prev_ = false;
    RationalTime nominal_duration_{4000, kProjectTimeScale};  // 首帧时长兜底（≈1/30s @120000）
    int64_t popped_count_ = 0;

#ifndef NDEBUG
    // MEDIA-023 排障仪器（仅 Debug 构建）：Feed→解码回调的单帧延迟直方图。
    // 每完成 60 帧打印一次 min/p50/p95/max —— 判别「VT 异步往返」vs「转换慢路径」。
    // 逐帧累积 vector/map，不适合 Release，保留条件编译。
    void DebugRecordSubmit(int64_t dts_value, uint64_t nanos);
    void DebugRecordLatency(int64_t dts_value, uint64_t nanos);
    std::map<int64_t, uint64_t> debug_submit_nanos_;
    std::vector<uint64_t> debug_latency_nanos_;
    int debug_enqueue_logs_ = 0;
    int debug_pop_logs_ = 0;
#endif

    // CORE-010：下面两组计数**提到 Release** —— 它们驱动的日志是 Warn 级
    // （「显示序缺口」「队列超上界」），而这两个信号正是 MEDIA-027 冻结真身的
    // 直接证据。把它们关在 Debug 里，等于 Release 包对这类故障保持沉默。
    // Release 下这两处的额外成本是几个自增与一次比较，可以忽略。
    // 显示序连续性「卡死」计数：队列最小 pts 与期望不等且**无在途帧**时 PopFrame
    // 会返回 kIoNotFound 而**不弹出**，队列从此只进不出（内存无界增长的真凶）。
    int debug_order_stall_ = 0;
    int debug_order_stall_logs_ = 0;
    // 队列上界命中次数（>0 即说明重排判据把队列憋住了，属异常信号）。
    int debug_queue_cap_hits_ = 0;
    int debug_queue_cap_logs_ = 0;

    CqNativeImage* last_returned_ = nullptr;  // 供 Flush/析构释放，避免泄漏
    // MEDIA-027：连续「无在途帧且不匹配期望」的次数（判定显示序缺口的依据）。
    // 成功弹出一帧即清零 —— 它衡量的是**一次**等待被拖延了多久，不是累计。
    int order_mismatch_streak_ = 0;

    // 首帧时长兜底：记录前两个喂入包的解码序差（假定恒定帧率），用于首帧 duration。
    // 必须用 dts 差：B 帧文件前两个包的 pts 差 = (bframes+1) 帧（media_decode.mm
    // Feed 内注释），曾致首帧区间报宽 4 倍、kExact 在关键帧提前命中（画面差帧）。
    RationalTime first_fed_dts_{0, 0};
    bool fed_first_ = false;
    bool fed_second_ = false;

    bool session_hw_ = false;
};

}  // namespace cq

#endif  // CQ_PAL_APPLE_MEDIA_DECODE_H_
