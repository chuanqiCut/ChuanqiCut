// ChuanqiCut — 音频图骨架（AUDIO-001）
//
// 职责：把「节点按拓扑序原位处理 PCM 块」做成可测的骨架。
//   * Prepare()（session 线程，允许分配/加锁）：校验拓扑（成环/断链/多源 →
//     kInvalidArgument）、拓扑排序、逐节点 OnPrepare；
//   * Process()（音频线程）：只做预排好序的线性遍历 + 虚调用，无锁、无分配。
//
// AUDIO-001 的拓扑限制为**单链**（每节点入度≤1、出度≤1、必须连通）：
// 多输入汇点是 AUDIO-004（混音）的扩展点 —— 届时放宽入度限制并给
// Process 上下文加输入视图，本骨架的 Prepare 校验与遍历框架不变。
//
// 生命周期：调用方持有节点与图；节点必须活过图的最后一次 Process。

#ifndef CQ_AUDIO_AUDIO_GRAPH_H_
#define CQ_AUDIO_AUDIO_GRAPH_H_

#include <cstddef>
#include <cstdint>
#include <vector>

#include "cq/audio/audio_types.h"
#include "cq/base/status.h"

namespace cq {

// 有向边：from 的输出喂给 to（from → to）。
struct AudioEdge {
    uint32_t from = 0;
    uint32_t to = 0;
};

// 音频节点接口。实现方约定：
//   * OnPrepare：仅在 Prepare 阶段调用（非音频线程），可分配、可校验规格；
//     返回非 Ok 拒绝装配（例如规格不符的变速节点）。
//   * Process：音频线程热路径 —— 无锁、无分配、不阻塞，原位变换 block；
//     不得改动 block.frame_count/data/pts（块规格全图恒定）。
class IAudioNode {
public:
    virtual ~IAudioNode() = default;
    virtual Status OnPrepare(const AudioGraphSpec& spec) = 0;
    virtual Status Process(AudioBuffer& block) = 0;
};

class AudioGraph {
public:
    // 装配并准备。nodes 为全部节点；edges 描述连接（见 AudioEdge）。
    // 失败时图保持未装配状态（NodeCount()==0）。
    Status Prepare(const std::vector<IAudioNode*>& nodes,
                   const std::vector<AudioEdge>& edges,
                   const AudioGraphSpec& spec);

    // 处理一块 PCM：按拓扑序逐节点原位变换。音频线程调用。
    // pts 随块穿透（节点不改块元数据），块间时序由调用方推进。
    Status Process(AudioBuffer& block) const;

    size_t NodeCount() const { return order_.size(); }

private:
    std::vector<IAudioNode*> order_;  // 拓扑序（Prepare 时排定）
};

}  // namespace cq

#endif  // CQ_AUDIO_AUDIO_GRAPH_H_
