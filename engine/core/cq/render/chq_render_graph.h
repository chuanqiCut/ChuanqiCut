// ChuanqiCut — RenderGraph（RENDER-001 / B0 渲染地基）
//
// 为什么现在就要它（RENDER-001 是 B0，也是多轨与导出的共同瓶颈）：
//   红线 #9 要求「预览与导出走同一张 RenderGraph，只换输出目标与时钟源」。
//   在它落地之前，预览是一条手写路径（取帧 → 导入 → 一次 blit），导出则完全不存在；
//   继续往上堆能力（多轨、滤镜、转场）必然逼出**第二条渲染路径** —— 本仓库已经在
//   「相机滤镜 vs 编辑器特效」上付过一次这个代价（ADR-0014），不得再犯（ADR-0034）。
//
// 本文件做什么：
//   * 节点与边的**数据结构** + 结构校验 + 拓扑排序（Kahn，含环检测）
//   * 图结构指纹（装配缓存判据：结构不变就不必重新装配）
//
// 本文件**不**做什么（有意留白，不要假装已有）：
//   * 多轨混合语义（alpha 合成 / 转场）—— 归 RENDER-011（B7）。B0 只装配命中轨，
//     命中多轨时由装配器发 Warn 并只取第一条（与引入 RenderGraph 前逐像素一致）。
//   * 节点级缓存（source/node/clip/sequence 四级，对齐 Resolve）——
//     结构已在 RESEARCH-014 建议里预留挂点，未实现。
//   * 资源池化 / 纹理生命周期 —— 由调用方（ChqRenderEvaluator + GFX 层）持有。
//
// Push vs Pull（RESEARCH-014 §6 要求立卡前必须回答）：
//   **B0 取 Pull**。理由：预览现状就是请求驱动（泵线程请求 pts → 渲染一帧），
//   Pull 与之逐该厂商一致，B0 的出口标准「与原 blit 路径像素一致」才能成立；
//   音频线（AUDIO-002）是 push 30Hz，那是**另一条时间线**（音频图），
//   由 `ChqIClockSource`（chq_clock_source.h）在同一装配器下区分用途，
//   不是把两条驱动方式塞进同一套节点语义里硬凑。
//
// 硬约束：零平台类型、零 FFmpeg 类型、禁用异常（错误一律 ChqStatus）、
//   时间一律 ChqRationalTime。

#ifndef CQ_CORE_RENDER_CHQ_RENDER_GRAPH_H_
#define CQ_CORE_RENDER_CHQ_RENDER_GRAPH_H_

#include <cstdint>

#include "cq/base/chq_rational_time.h"
#include "cq/base/chq_status.h"
#include "cq/render/chq_fit_mode.h"  // ChqFitMode（画布适配模式）

namespace cq {

// 节点种类（B0 最小集；新增种类必须同步本文件的校验与执行分支，别只加枚举）。
enum class ChqRenderNodeKind : int32_t {
    kSource = 0,  // 取帧 + 导入 → 产出一张可采样纹理（CPU 侧，Prepare 阶段执行）
    kBlit = 1,    // 把输入纹理画进目标（GPU 侧，Encode 阶段执行）
    kSink = 2,    // 输出标记：整图的终点，有且仅有一个
};

// 单节点最大输入数。固定上限而非动态容器：
//   B0 的合成语义只有「一个输入画进目标」，转场（两输入）是 B7 的事；
//   给个上限是为了让边关系成为 POD，图可以整体指纹化、整体比较。
constexpr uint32_t kMaxNodeInputs = 4;

// 节点数上限。B0 的实际图是 3 个节点（source → blit → sink）；
//   上限 32 留给 B7 的多轨与滤镜链，超过即 kResourceExhausted（不静默截断）。
constexpr uint32_t kMaxGraphNodes = 32;

struct ChqRenderNodeDesc {
    ChqRenderNodeKind kind = ChqRenderNodeKind::kSource;

    // ---- kSource ----
    uint64_t asset_id = 0;            // 素材 id（查 ChqAssetRegistry）
    uint64_t clip_id = 0;             // 命中的片段 id（属性系统与诊断用；0 = 无）
    ChqRationalTime source_time{0, 1};  // 素材内时间（= clip.source.source_in + (pts - clip.start)）
    // #21：源帧**显示朝向**旋转角（度，0/90/180/270），由解码侧经 Acquire 回填，
    // 装配时未知（与 source_width/height 同生命周期）。blit 据此做 UV 旋转还原朝向，
    // 几何旋转只在 GPU 一层（预览/导出共用 → 红线 #9），解码阶段不旋转像素。
    uint16_t source_rotation = 0;

    // ---- kBlit ----
    ChqFitMode fit_mode = ChqFitMode::kStretch;
    uint32_t target_width = 0;   // 输出目标像素尺寸（画布）
    uint32_t target_height = 0;
    uint32_t source_width = 0;   // 源帧像素尺寸（0 = 未知，取帧后回填）
    uint32_t source_height = 0;

    // ---- 边（DAG）：inputs[i] 是本节点的输入节点索引 ----
    uint32_t input_count = 0;
    uint32_t inputs[kMaxNodeInputs] = {};
};

class ChqRenderGraph {
public:
    ChqStatus AddNode(const ChqRenderNodeDesc& desc, uint32_t& out_index);
    // 连接 from → to（to 把 from 记为输入）。重复边按一次计（不产生重复依赖）。
    ChqStatus Connect(uint32_t from, uint32_t to);

    // 结构校验：索引合法 / 无环 / 非 source 节点必须有输入 / 有且仅有一个 sink。
    // 任一条不满足返回 kInvalidArgument 并把原因写进日志（Warn 级，Release 可见）。
    ChqStatus Validate() const;

    // 拓扑序（Kahn）。out_count < NodeCount() 即存在环（Validate 已拦，此处再兜底）。
    // out 数组由调用方提供，容量 >= NodeCount()（用 kMaxGraphNodes 即可）。
    ChqStatus TopoOrder(uint32_t* out, uint32_t& out_count) const;

    uint32_t NodeCount() const { return node_count_; }
    const ChqRenderNodeDesc* Node(uint32_t index) const {
        return index < node_count_ ? &nodes_[index] : nullptr;
    }
    // 可变访问：仅用于执行器回填运行期字段（如 source 的实际像素尺寸）。
    ChqRenderNodeDesc* MutableNode(uint32_t index) {
        return index < node_count_ ? &nodes_[index] : nullptr;
    }

    void Clear() { node_count_ = 0; }

    // 结构指纹（FNV-1a 64）。用途：**装配缓存判据** —— 装配输入没变（同一批片段、
    // 同一画布、同一适配模式）就不必重建图，60Hz 预览能省掉每帧的节点分配。
    // 与模型快照 digest（FNV-1a）同一套路，便于对照排查。
    uint64_t Fingerprint() const;

private:
    ChqRenderNodeDesc nodes_[kMaxGraphNodes] = {};
    uint32_t node_count_ = 0;
};

}  // namespace cq

#endif  // CQ_CORE_RENDER_CHQ_RENDER_GRAPH_H_
