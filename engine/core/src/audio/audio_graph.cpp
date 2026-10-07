// ChuanqiCut — 音频图骨架实现（AUDIO-001）

#include "cq/audio/audio_graph.h"

namespace cq {

Status AudioGraph::Prepare(const std::vector<IAudioNode*>& nodes,
                           const std::vector<AudioEdge>& edges,
                           const AudioGraphSpec& spec) {
    order_.clear();
    const uint32_t n = static_cast<uint32_t>(nodes.size());

    // 规格 sanity：格式可知、声道/采样率/帧数合法（空图也要求规格可用，
    // 因为块规格是全图常量，调用方照样要用它分配缓冲）。
    AudioBuffer probe{};
    probe.format = spec.format;
    probe.channels = spec.channels;
    if (probe.BytesPerFrame() == 0 || spec.sample_rate == 0 ||
        spec.frames_per_block == 0) {
        return Status{StatusCode::kInvalidArgument};
    }

    // 链式拓扑校验：每节点出度≤1、入度≤1、无自环/重复边、边数 = n-1（连通）。
    std::vector<int64_t> succ(n, -1);      // 唯一后继
    std::vector<uint32_t> indeg(n, 0);
    for (const AudioEdge& e : edges) {
        if (e.from >= n || e.to >= n || e.from == e.to) {
            return Status{StatusCode::kInvalidArgument};
        }
        if (succ[e.from] != -1) {
            return Status{StatusCode::kInvalidArgument};  // 出度>1 / 重复边
        }
        succ[e.from] = static_cast<int64_t>(e.to);
        ++indeg[e.to];
        if (indeg[e.to] > 1) {
            return Status{StatusCode::kInvalidArgument};  // 入度>1（混音是 AUDIO-004）
        }
    }
    if (n > 0 && static_cast<uint64_t>(edges.size()) + 1 != static_cast<uint64_t>(n)) {
        return Status{StatusCode::kInvalidArgument};  // 断链（森林）或多余边
    }

    // 拓扑排序：链结构下 = 从唯一根（入度 0）沿 succ 走完 n 个节点。
    // 走不完 = 有环或断链组件 → 拒绝装配。
    if (n > 0) {
        uint32_t root = n;
        for (uint32_t i = 0; i < n; ++i) {
            if (indeg[i] == 0) {
                root = i;
                break;
            }
        }
        if (root == n) {
            return Status{StatusCode::kInvalidArgument};  // 纯环（无根）
        }
        order_.reserve(n);
        int64_t cur = static_cast<int64_t>(root);
        for (uint32_t visited = 0; visited < n; ++visited) {
            if (cur == -1) {
                order_.clear();
                return Status{StatusCode::kInvalidArgument};  // 断链/环组件
            }
            order_.push_back(nodes[static_cast<uint32_t>(cur)]);
            cur = succ[static_cast<uint32_t>(cur)];
        }
    }

    // 逐节点 OnPrepare（链序 = 上游先于下游）。任一失败 → 拒绝整个装配。
    for (IAudioNode* node : order_) {
        const Status st = node->OnPrepare(spec);
        if (!st.IsOk()) {
            order_.clear();
            return st;
        }
    }
    return Status::Ok();
}

Status AudioGraph::Process(AudioBuffer& block) const {
    for (IAudioNode* node : order_) {
        const Status st = node->Process(block);
        if (!st.IsOk()) {
            return st;  // 音频线程：无异常，失败立即短路（上游决定丢块策略）
        }
    }
    return Status::Ok();
}

}  // namespace cq
