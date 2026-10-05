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
    // 已喂入、尚未收到完成回调的包：dts.value → pts（重排依据）。key 约束：
    // demuxer 已把 pts/dts 统一转换到项目网格（timescale 120000），故用 value 作 key。
    std::map<int64_t, RationalTime> pending_dts_pts_;
    RationalTime prev_popped_pts_{0, 0};  // timescale=0 表示未初始化
    RationalTime prev_duration_{0, 1};    // 上一弹出帧 duration（显示序连续性判据：期望=pts+duration）
    bool has_prev_ = false;
    RationalTime nominal_duration_{4000, kProjectTimeScale};  // 首帧时长兜底（≈1/30s @120000）
    int64_t popped_count_ = 0;

    CqNativeImage* last_returned_ = nullptr;  // 供 Flush/析构释放，避免泄漏

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
