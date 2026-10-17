// ChuanqiCut — RenderGraph 实现（RENDER-001 / B0）

#include "cq/render/chq_render_graph.h"

#include <cstdio>

#include "cq/base/chq_logging.h"  // CQ_LOG_*_WF

namespace cq {
namespace {

// FNV-1a 64（与模型快照 digest 同一算法，便于对照排查；非加密用途）。
constexpr uint64_t kFnvOffset = 14695981039346656037ull;
constexpr uint64_t kFnvPrime = 1099511628211ull;

inline void FnvUpdate(uint64_t& h, uint64_t v) {
    for (int i = 0; i < 8; ++i) {
        h ^= (v >> (i * 8)) & 0xff;
        h *= kFnvPrime;
    }
}

}  // namespace

ChqStatus ChqRenderGraph::AddNode(const ChqRenderNodeDesc& desc, uint32_t& out_index) {
    out_index = 0;
    if (node_count_ >= kMaxGraphNodes) {
        CQ_LOG_WARN_WF(ChqWorkflow::kGfx, "RenderGraph 节点数达上限 %u，拒绝新增",
                       static_cast<unsigned>(kMaxGraphNodes));
        return ChqStatus(ChqStatusCode::kResourceExhausted);
    }
    nodes_[node_count_] = desc;
    out_index = node_count_;
    ++node_count_;
    return ChqStatus::Ok();
}

ChqStatus ChqRenderGraph::Connect(uint32_t from, uint32_t to) {
    if (from >= node_count_ || to >= node_count_ || from == to) {
        return ChqStatus(ChqStatusCode::kInvalidArgument);
    }
    ChqRenderNodeDesc& dst = nodes_[to];
    // 重复边只记一次：重复依赖会让入度计数翻倍，Kahn 排序得到的入度永远减不到 0，
    // 表现为「明明是无环图却报有环」—— 这类假环很难查，故在入口就去重。
    for (uint32_t i = 0; i < dst.input_count; ++i) {
        if (dst.inputs[i] == from) return ChqStatus::Ok();
    }
    if (dst.input_count >= kMaxNodeInputs) {
        CQ_LOG_WARN_WF(ChqWorkflow::kGfx, "节点 %u 输入数达上限 %u，拒绝连接 %u",
                       static_cast<unsigned>(to), static_cast<unsigned>(kMaxNodeInputs),
                       static_cast<unsigned>(from));
        return ChqStatus(ChqStatusCode::kResourceExhausted);
    }
    dst.inputs[dst.input_count] = from;
    ++dst.input_count;
    return ChqStatus::Ok();
}

ChqStatus ChqRenderGraph::Validate() const {
    if (node_count_ == 0) {
        return ChqStatus(ChqStatusCode::kInvalidArgument);  // 空图无意义（连 sink 都没有）
    }

    // 1. 边索引合法 + 输入节点必须存在
    for (uint32_t i = 0; i < node_count_; ++i) {
        const ChqRenderNodeDesc& n = nodes_[i];
        for (uint32_t k = 0; k < n.input_count; ++k) {
            if (n.inputs[k] >= node_count_) {
                CQ_LOG_WARN_WF(ChqWorkflow::kGfx, "节点 %u 的输入 %u 越界（节点数 %u）",
                               static_cast<unsigned>(i), static_cast<unsigned>(n.inputs[k]),
                               static_cast<unsigned>(node_count_));
                return ChqStatus(ChqStatusCode::kInvalidArgument);
            }
        }
    }

    // 2. 有且仅有一个 sink
    uint32_t sink_count = 0;
    for (uint32_t i = 0; i < node_count_; ++i) {
        if (nodes_[i].kind == ChqRenderNodeKind::kSink) ++sink_count;
    }
    if (sink_count != 1) {
        CQ_LOG_WARN_WF(ChqWorkflow::kGfx, "sink 节点数 = %u（要求恰好 1）",
                       static_cast<unsigned>(sink_count));
        return ChqStatus(ChqStatusCode::kInvalidArgument);
    }

    // 3. kBlit / kTransform 必须有输入（画什么？）；kSource 必须无输入（它是图的叶子）
    for (uint32_t i = 0; i < node_count_; ++i) {
        const ChqRenderNodeDesc& n = nodes_[i];
        if ((n.kind == ChqRenderNodeKind::kBlit || n.kind == ChqRenderNodeKind::kTransform) &&
            n.input_count != 1) {
            CQ_LOG_WARN_WF(ChqWorkflow::kGfx, "绘制节点 %u 输入数 = %u（要求恰好 1）",
                           static_cast<unsigned>(i), static_cast<unsigned>(n.input_count));
            return ChqStatus(ChqStatusCode::kInvalidArgument);
        }
        if (n.kind == ChqRenderNodeKind::kSource && n.input_count != 0) {
            CQ_LOG_WARN_WF(ChqWorkflow::kGfx, "source 节点 %u 不应有输入（输入数 = %u）",
                           static_cast<unsigned>(i), static_cast<unsigned>(n.input_count));
            return ChqStatus(ChqStatusCode::kInvalidArgument);
        }
        // kTransform 的变换必须在语义域内：非法值（负 scale、opacity > 1、NaN）
        // 在这里拦，而不是等烘焙函数每帧再判一次。
        if (n.kind == ChqRenderNodeKind::kTransform &&
            (!n.clip_transform.Validate().IsOk() || !n.track_transform.Validate().IsOk())) {
            CQ_LOG_WARN_WF(ChqWorkflow::kGfx, "transform 节点 %u 的空间参数越界",
                           static_cast<unsigned>(i));
            return ChqStatus(ChqStatusCode::kInvalidArgument);
        }
    }

    // 4. 无环（Kahn 排出的节点数必须等于总节点数）
    uint32_t order[kMaxGraphNodes] = {};
    uint32_t order_count = 0;
    ChqStatus s = TopoOrder(order, order_count);
    if (!s.IsOk()) return s;
    if (order_count != node_count_) {
        CQ_LOG_WARN_WF(ChqWorkflow::kGfx, "RenderGraph 存在环：仅排出 %u / %u 个节点",
                       static_cast<unsigned>(order_count), static_cast<unsigned>(node_count_));
        return ChqStatus(ChqStatusCode::kInvalidArgument);
    }
    return ChqStatus::Ok();
}

ChqStatus ChqRenderGraph::TopoOrder(uint32_t* out, uint32_t& out_count) const {
    out_count = 0;
    if (out == nullptr) return ChqStatus(ChqStatusCode::kInvalidArgument);
    if (node_count_ == 0) return ChqStatus::Ok();

    // 入度 = 每个节点的输入数（边方向 from → to，to 依赖 from）
    uint32_t indegree[kMaxGraphNodes] = {};
    for (uint32_t i = 0; i < node_count_; ++i) {
        indegree[i] = nodes_[i].input_count;
    }

    // Kahn：反复取入度为 0 的节点。队列用固定数组（节点数 <= kMaxGraphNodes）。
    bool emitted[kMaxGraphNodes] = {};
    bool progress = true;
    while (progress) {
        progress = false;
        for (uint32_t i = 0; i < node_count_; ++i) {
            if (emitted[i] || indegree[i] != 0) continue;
            out[out_count] = i;
            ++out_count;
            emitted[i] = true;
            progress = true;
            // 释放 i 的出边：i 是哪些节点的输入？（扫全表；节点数上限 32，代价可忽略）
            for (uint32_t j = 0; j < node_count_; ++j) {
                for (uint32_t k = 0; k < nodes_[j].input_count; ++k) {
                    if (nodes_[j].inputs[k] == i && indegree[j] > 0) --indegree[j];
                }
            }
        }
    }
    // 有环时 out_count < node_count_：由调用方（Validate / 执行器）判定，此处不报错
    // —— 拓扑序本身是查询，不是校验，混在一起会让"查个顺序"也可能失败。
    return ChqStatus::Ok();
}

uint64_t ChqRenderGraph::Fingerprint() const {
    uint64_t h = kFnvOffset;
    FnvUpdate(h, static_cast<uint64_t>(node_count_));
    for (uint32_t i = 0; i < node_count_; ++i) {
        const ChqRenderNodeDesc& n = nodes_[i];
        FnvUpdate(h, static_cast<uint64_t>(n.kind));
        FnvUpdate(h, n.asset_id);
        FnvUpdate(h, n.clip_id);
        FnvUpdate(h, static_cast<uint64_t>(n.source_time.value));
        FnvUpdate(h, static_cast<uint64_t>(n.source_time.timescale));
        FnvUpdate(h, static_cast<uint64_t>(n.fit_mode));
        FnvUpdate(h, n.target_width);
        FnvUpdate(h, n.target_height);
        FnvUpdate(h, static_cast<uint64_t>(n.input_count));
        for (uint32_t k = 0; k < n.input_count; ++k) FnvUpdate(h, n.inputs[k]);
        // kTransform 才混入变换指纹：拖动画中画**就是**结构变化，指纹不变的话
        // 装配缓存会端着旧图不放，画面停在拖之前（预览最常见的静默失败）。
        // 只对 transform 节点混合，纯 blit 图的指纹值与引入本字段前逐位相同。
        if (n.kind == ChqRenderNodeKind::kTransform) {
            FnvUpdate(h, n.clip_transform.Fingerprint());
            FnvUpdate(h, n.track_transform.Fingerprint());
        }
    }
    return h;
}

}  // namespace cq
