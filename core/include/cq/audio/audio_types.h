// ChuanqiCut — 音频共享类型（AUDIO-001）
//
// core 层音频线的公共描述结构。与 PAL `PcmBuffer`（cq/pal/audio.h）字段对齐，
// 唯一差异：`data` 可变 —— 效果/混音节点（AUDIO-004/010）要原位写样本，
// PAL 侧 const 语义由 PALA-030 在边界做 AudioBuffer↔PcmBuffer 平凡适配。
//
// 红线：
//   * 零平台类型、零 FFmpeg 类型（头文件只含 C++ 基础类型与 cq 类型）。
//   * 时间一律 RationalTime（pts 穿透到每个块），禁止浮点秒。
//   * 本文件所有类型为 POD / 可平凡聚合，音频线程可无锁使用。

#ifndef CQ_AUDIO_AUDIO_TYPES_H_
#define CQ_AUDIO_AUDIO_TYPES_H_

#include <cstdint>

#include "cq/base/time.h"      // RationalTime（已含 status.h）
#include "cq/pal/common.h"     // SampleFormat

namespace cq {

// core 侧 PCM 块描述。data 指向预分配槽位内存（AudioBlockPool 所有），
// 生命周期 = Acquire 与 Release 之间。
struct AudioBuffer {
    SampleFormat format = SampleFormat::kUnknown;
    uint32_t channels = 0;
    uint32_t sample_rate = 0;   // Hz
    uint64_t frame_count = 0;   // 单声道样本帧数
    void* data = nullptr;       // 样本内存（池所有，可变 —— 节点原位处理）
    uint64_t data_bytes = 0;    // data 字节长度
    RationalTime pts;           // 首样本时间（项目有理数时间轴，timescale=60000）

    // 单帧字节数（channels * 每样本字节）。-Wconversion 安全：显式 static_cast。
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

// 音频图规格：全图统一块规格（交错格式、定块处理）。
// 变速/变声等需要不同内部规格的节点在 OnPrepare 里自行校验并拒绝装配
// （AUDIO-002/003 的事），图本身不做重采样 —— 那是独立节点职责。
struct AudioGraphSpec {
    SampleFormat format = SampleFormat::kFloat32;
    uint32_t channels = 2;
    uint32_t sample_rate = 48000;        // Hz
    uint32_t frames_per_block = 512;     // 定块大小（延迟/吞吐调参）
};

}  // namespace cq

#endif  // CQ_AUDIO_AUDIO_TYPES_H_
