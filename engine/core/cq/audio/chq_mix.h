// ChuanqiCut — 多轨混音原语（AUDIO-004）
//
// 职责：把「多轨 PCM 求和 + 削波」做成 core 层可复用、可单测的纯函数。
//   * MixAccumulateRange —— 把一段源样本按增益累加进累加器的一段（float32 交错）；
//   * MixClipRange       —— 硬削波到 [-1,1]，非有限值按 0 处置。
//
// 为什么是自由函数而不是 AudioGraph 节点：混音是 N 进 1 出的总线操作，
// AudioGraph 现为单链骨架（每节点入度≤1，AUDIO-001 册子预留的多输入扩展
// 至今没有消费方 —— 预览路径不经图，导出路径未立卡）。给没有消费方的接口
// 改验证框架是投机，故本卡只做原语 + 预览混音器切换；图的多输入扩展随
// 「图装配音频链」的卡一起做（TASK-AUDIO-004 范围裁决表）。
//
// 音频线程纪律（ARCH-001 铁律 2 的执行点）：
//   * 零分配、零锁、无静态可变状态、无 IO、无日志 —— 纯函数，音频线程可直接调；
//   * 全有或全无：任何参数不合法都在写内存之前返回 kInvalidArgument，
//     acc 一个该厂商都不碰（调用方因此可以放心把原语放在热路径上）。
//
// 格式约定：float32 交错。非 float32 总线的格式转换是独立节点职责
// （chq_audio_types.h 明示"图本身不做重采样"），本原语不接 int16/int32。
// 母带级限制器 / 软削波属 AUDIO-010 fx 家族，不在此处预留开关。

#ifndef CQ_CORE_AUDIO_CHQ_MIX_H_
#define CQ_CORE_AUDIO_CHQ_MIX_H_

#include <cmath>
#include <cstddef>
#include <cstdint>

#include "cq/base/chq_status.h"

namespace cq {

// 把 src 的第 [src_frame0, src_frame0+frames) 帧按增益 gain 累加进 acc 的
// 第 [dst_frame0, dst_frame0+frames) 帧。src 与 acc 均为 float32 交错
// （每帧 channels 个样本）。
//
// 增益语义：
//   * gain = 0      → 静音（等价 mute，但不改 src）；
//   * 0 < gain < 1  → 衰减；
//   * gain = 1      → 直通求和；
//   * gain > 1      → 放大（是否削波由调用方随后的 MixClipRange 决定）；
//   * gain < 0      → **反相**（极性翻转，是合法特性，不是错误）。
//
// 参数校验（任一不满足即 kInvalidArgument，且不写任何内存）：
//   * acc / src 非空；channels > 0；
//   * frames > 0、acc_frames > 0（零值参数显式拒绝，与池 Init(0) 同风格）；
//   * gain 必须有限（NaN/±Inf 会污染累加器，拒于入口）；
//   * dst_frame0 + frames ≤ acc_frames（累加器侧越界拒绝；size_t 运算先防回绕）。
//
// src 缓冲区自身的长度原语不可知（裸指针），越界责任在调用方 —— 这是与 acc 侧
// 的不对称：acc 侧可算故严查，src 侧文档约定。
//
// 注意（浮点）：多轨累加结果与累加顺序有关（浮点非结合）。调用方固定顺序即可复现；
// 测试对顺序敏感性用容差断言，不追求位级一致（见 TASK-AUDIO-004 验收）。
ChqStatus MixAccumulateRange(float* acc, size_t acc_frames, uint32_t channels,
                             const float* src, size_t src_frame0, size_t frames,
                             size_t dst_frame0, float gain);

// 硬削波：把 data 的前 frames 帧（每帧 channels 个样本）限制到 [-1, 1]。
//   * 超幅样本截到 ±1（与 AUDIO-002 预览 MVP 语义一致，不做母带限制器）；
//   * NaN / ±Inf 一律按 0 —— 解码异常或累加溢出的下游保护，
//     这是「无溢出」验收的可测定义：输出恒在 [-1,1]，不存在非有限值穿透。
//
// 参数校验（任一不满足即 kInvalidArgument，且不写任何内存）：
// data 非空；channels > 0；frames > 0。
ChqStatus MixClipRange(float* data, size_t frames, uint32_t channels);

}  // namespace cq

#endif  // CQ_CORE_AUDIO_CHQ_MIX_H_
