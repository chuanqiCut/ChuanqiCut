// ChuanqiCut — PALA-012 Apple 编码与封装（AVAssetWriter + PixelBufferAdaptor）
//
// 实现 Apple 端的 H.264 编码与 MP4 封装能力。平台内部头，遵循 PALA-011 的先例
// （media_decode.h）：本头**仅被 Apple 平台 TU 包含**（tests/ 与未来 PAL 装配代码），
// 绝不进入 core 冻结头。门禁 check_pal_headers.py 只扫 core/include/cq/{pal,gfx,media}，
// 故此处出现平台类型（CVPixelBufferRef 是 C 类型，其余经 pImpl 隔离）安全。
//
// 为什么是平台内部头、而非 core 的 IMediaMuxer：
//   * 冻结契约（docs/specs/PAL-接口契约.md §4.2）只定义了 IMediaDemuxer / IFrameProvider，
//     **没有** muxer/encoder 接口；core/** 已冻结、本任务禁止改动。
//   * 跨平台「导出控制器」EXPORT-001（core/src/export/*）本期未实现，尚无可消费冻结
//     接口的下游；EXPORT-001 落地时再定义 IMediaMuxer 冻结契约，本能力作为 Apple 实现接入。
//   * 故本期按 PALA-011 的既定模式，先把「Apple 能导出 H.264 MP4」这一能力做出来并真实验证。
//
// 红线（与 core 一致）：内核禁用异常（错误一律 Status）；长任务接受 CancelToken；
// 时间用 RationalTime（项目网格 120000，非整除不静默舍入）；零 FFmpeg 类型。

#ifndef CQ_PAL_APPLE_MEDIA_ENCODE_H_
#define CQ_PAL_APPLE_MEDIA_ENCODE_H_

#include <cstdint>

#include "cq/base/concurrency.h"  // CancelToken
#include "cq/base/status.h"        // Status / StatusCode
#include "cq/base/rational_time.h"          // RationalTime
#include "cq/pal/media.h"          // AudioTrackConfig / PcmBuffer（音频轨复用）

// C 类型（CoreVideo），在纯 C++ 下也合法（与 media_decode.h 的 CVPixelBufferRef 一致）。
typedef struct __CVBuffer* CVPixelBufferRef;

namespace cq {

// 编码配置。timescale 必须为写入帧 PTS 的 timescale（本工程统一 120000，ADR-0009）。
struct EncodeConfig {
    uint32_t width = 0;
    uint32_t height = 0;
    int32_t timescale = 120000;          // 写入 PTS 的网格；非整除须显式对齐（本期源已是 120000）
    uint32_t fps_numerator = 30;         // 名义帧率（用于期望帧率/码率假设）
    uint32_t fps_denominator = 1;
    int64_t average_bitrate = 0;         // 0 = 交给 AVAssetWriter 默认值
    int32_t max_keyframe_interval = 30;  // GOP 长度；=1 表示全 I 帧（all-intra）
    bool allow_hardware = true;          // 优先硬件编码；不可用时软件回退（诚实，不伪造）
};

// Apple H.264 编码器 + MP4 封装器（AVAssetWriter + AVAssetWriterInputPixelBufferAdaptor）。
//
// 设计要点：
//   * 接受解码/渲染后的 CVPixelBuffer（BGRA 或 NV12），**按源格式 1:1 拷贝**进 encoder
//     自管的 CVPixelBuffer 再 append——不做任何 RGB↔YUV 色彩转换，从根本上规避「通道交换类
//     bug」（PALA-002 的教训：绿条 R==B 会让此类 bug 被掩盖）。
//   * 每帧 presentation timestamp 必须是 RationalTime 直接转出的 CMTime（timescale 同构），
//     且 movieTimeScale 设为同一网格（120000），杜绝累积漂移（ADR-0009 存在理由）。
//   * 写入顺序：调用方必须按 PTS 非递减顺序喂帧（AVAssetWriter 要求样本按展示序）。
//   * 收尾：Finish 阻塞等待 finishWriting 完成；Cancel 调 cancelWriting 并删除半成品文件。
//   * 硬件编码：Open 时以一次性 VTCompressionSession 探针查询本机是否真能硬件编码，
//     如实上报（IsHardwareAccelerated），不伪造；AVAssetWriter 自行选择编码器，
//     不可用时走软件路径，仍能导出 H.264（验收要求是「能导出 H.264」，硬件只是性能属性）。
class AppleVideoEncoder {
public:
    AppleVideoEncoder();
    ~AppleVideoEncoder();

    AppleVideoEncoder(const AppleVideoEncoder&) = delete;
    AppleVideoEncoder& operator=(const AppleVideoEncoder&) = delete;

    // 打开 writer，准备向 output_path 写 H.264 MP4。output_path 若存在先删除。
    // cfg 携带尺寸/timescale/码率/GOP。成功返回 Ok；路径非法/无法创建 writer 返回错误。
    Status Open(const char* output_path, const EncodeConfig& cfg);

    // 编码并写入一帧。pb 为解码/渲染产出的 CVPixelBuffer（BGRA 或 NV12）；
    // pts 为该帧展示时间戳（timescale 须等于 cfg.timescale）。须在 token 未取消且
    // writer 处于 Writing 态时调用，且 PTS 非递减。
    // 支持 CancelToken：背压等待期间若被取消，返回 kCancelled（非错误）。
    Status EncodeFrame(CVPixelBufferRef pb, const RationalTime& pts, const CancelToken& token);

    // 正常收尾：标记 input 完成并阻塞等待 finishWriting。返回错误若写入失败。
    Status Finish();

    // 添加 AAC 音频轨：在已建立的 writer 上挂一个 AAC `AVAssetWriterInput`
    // （采样率 / 声道 / 码率档位来自 cfg）。必须在 startWriting 之前调用
    // （AVAssetWriter 要求所有 input 在 startWriting 前 addInput），故本方法在
    // `AddVideoTrack` 之后、`Write*` 之前调用。不支持的 codec 返回 kEncodeUnsupported。
    Status AddAudioTrack(const AudioTrackConfig& cfg);

    // 写入一块线性 PCM 音频，内部喂给 AAC 输入经封装器编码为 AAC。
    // pcm 携带样本（kFloat32 / kInt16）、声道、采样率、frame_count、data。
    // pts 为首样本展示时间戳（timescale 须为轨约定网格 120000；非整除调用方已舍入）。
    // 长任务：背压等待期间若被取消返回 kCancelled（非错误）。
    Status WriteAudioFrame(const PcmBuffer& pcm, const RationalTime& pts, const CancelToken& token);

    // 取消：中止写入并删除半成品输出文件（不 finishWriting）。取消是独立停止信号（非错误）。
    Status Cancel();

    // 运行时查询：本机是否支持 H.264 硬件编码（Open 时一次性探针，诚实上报）。
    bool IsHardwareAccelerated() const { return hw_encode_; }

    // 已成功 EncodeFrame 的帧数（供测试/诊断）。
    int64_t FrameCount() const { return frame_count_; }

private:
    // pImpl：持有 AVFoundation ObjC 对象（仅 .mm 可见），使本头保持纯 C++ 干净。
    struct State;
    State* state_ = nullptr;

    // 惰性启动 writer：AVAssetWriter 要求所有 input 都 addInput 之后、首个样本 append 之前
    // 调用 startWriting 一次；故在首个 WriteVideoFrame / WriteAudioFrame 时调用。
    static Status EnsureStarted(State* state);

    bool hw_encode_ = false;
    int64_t frame_count_ = 0;
};

}  // namespace cq

#endif  // CQ_PAL_APPLE_MEDIA_ENCODE_H_
