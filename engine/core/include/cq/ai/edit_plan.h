// ChuanqiCut — EditPlan 契约（AIEDIT-001，schema cq.editplan/1）
//
// 大模型决策的唯一合法形态：**有界动词集的 action 列表**，不是时间线
// （ADR-0020 决策 3——LLM 直接产出时间线被否决：无界输出、难校验、难增量归因）。
// C++ 侧（ai/plan/edit_plan_validator）是唯一权威校验方；失败回传 LLM 自动修复
// ≤2 次，仍失败走本地规则引擎（AIEDIT-011，输出同 schema）。
//
// 动词集 P0 共 9 个（SPEC §6.1 / 执行器映射表 §7；SPEC 与任务卡行文写"八个"，
// 系笔误——select 三兄弟 3 个 + 落地动词 6 个，两处枚举清单一致按 9 冻结）：
//   select_intro / select_highlight / select_outro   语义标注（叙事层，不触模型）
//   place_clip / remove_range / trim_clip / reorder   时间线结构操作
//   set_transition / set_bgm_placeholder              转场 / 配乐意图（P0 记录，P0.5 执行）
//
// JSON 形状（SPEC §6.2，schema v1 冻结）：
// {
//   "schema": "cq.editplan/1",
//   "based_on": { "assets": ["a1","a2"], "timeline_rev": 0 },
//   "actions": [{
//     "op": "place_clip", "asset": "a2", "shot": 1,
//     "timeline_start": {"value": 0, "timescale": 120000},
//     "source_in":      {"value": 12000, "timescale": 120000},
//     "duration":       {"value": 18000, "timescale": 120000},
//     "reason": "质量最高（0.86）且有正面人脸，适合开场"
//   }],
//   "narrative": { "structure": "...", "dropped": [{"asset":"a3","shot":2,"reason":"..."}],
//                  "assistant_message": "..." },
//   "generator": "llm"
// }
//
// 校验硬规则（机器检查，错误码见 base/status.h 9500 段）：
//   * 时间字段一律 {"value","timescale"} 且 timescale == 120000（kProjectTimeScale）；
//     任何浮点出现在时间字段直接判非法（红线 4）。
//   * 未知 schema 版本 → 拒绝并降级，绝不猜测解析（SPEC §6.3.4）。
//   * 未知 op / 未知转场类型 → 非法；**未知附加字段宽松忽略**（手工宽松校验器，
//     给 LLM 输出留向前兼容余地——扩展必须走 schema 版本号，不走私加字段）。
//   * 语义校验对照 FeatureReport 资产表（EditPlanAssetTable）：asset/shot 引用存在、
//     source_in + duration ≤ 素材时长（__int128 溢出防御）、place_clip 段不重叠。
//   * trim_clip / remove_range / set_transition 对**实际时间线**的落点校验
//     （clip 是否存在、转场是否越界）归执行器 AIEDIT-006——校验器无时间线上下文。
//
// 增量对话（SPEC §6.4）：based_on.timeline_rev 用于乐观校验，rev 不符由
// 管线（AIEDIT-005）拒绝应用并触发全量重排；本头只冻结字段。

#ifndef CQ_AI_EDIT_PLAN_H_
#define CQ_AI_EDIT_PLAN_H_

#include <cstdint>
#include <string>
#include <vector>

#include "cq/base/rational_time.h"

namespace cq {

constexpr const char* kEditPlanSchema = "cq.editplan/1";

// 有界动词集（P0）。枚举值仅进程内使用，跨端序列化走字符串名。
enum class EditPlanOp : int32_t {
    kSelectIntro = 0,
    kSelectHighlight,
    kSelectOutro,
    kPlaceClip,
    kRemoveRange,
    kTrimClip,
    kReorder,
    kSetTransition,
    kSetBgmPlaceholder,
    kUnknown = -1,  // 解析失败的哨兵（非法 op 名不会映射进来，仅防御）
};

// 与 model/timeline.h 的 TransitionKind 对齐（AIEDIT-006 执行时直接投影），
// JSON 名 = 枚举名的 snake_case。
enum class EditPlanTransitionKind : int32_t {
    kNone = 0,        // "none"：显式清除转场
    kCrossFade,       // "cross_fade"
    kDipToBlack,      // "dip_to_black"
    kUnknown = -1,
};

// op 名 ↔ 枚举（校验器/管线/执行器共用；未知名返回 false）。
const char* EditPlanOpName(EditPlanOp op);
bool EditPlanOpFromName(const char* name, EditPlanOp& out_op);

const char* EditPlanTransitionKindName(EditPlanTransitionKind kind);
bool EditPlanTransitionKindFromName(const char* name, EditPlanTransitionKind& out_kind);

// 单个动作。字段所有权按 op 划分（校验器逐 op 检查必填/可选；非法组合判缺字段）：
//   select_intro/highlight/outro : asset + shot 必填
//   place_clip    : asset + shot + timeline_start + source_in + duration 必填
//   remove_range  : timeline_start + duration 必填（删除时间线区间 [start, start+dur)）
//   trim_clip     : timeline_start 必填（定位待裁 clip）；source_in / duration 可选
//                   （只裁提供的字段——增量语义）
//   reorder       : order 必填；语义 = 本 plan 内全部 place_clip 动作按 timeline_start
//                   升序编号后的新排列（长度必须等于 place_clip 数且为排列）
//   set_transition: timeline_start（=at）+ transition 必填；duration 必填
//   set_bgm_placeholder : 全字段可选（P0 仅记录意图，P0.5 执行）
// reason 全 op 可选：决策透明（RESEARCH-003 §4.4），UI 逐条展示。
struct EditPlanAction {
    EditPlanOp op = EditPlanOp::kUnknown;
    std::string asset;
    bool has_asset = false;             // 字段存在性（与「空串」区分，宽松校验的基础）
    int32_t shot = -1;
    bool has_shot = false;
    bool has_timeline_start = false;
    RationalTime timeline_start{};
    bool has_source_in = false;
    RationalTime source_in{};
    bool has_duration = false;
    RationalTime duration{};
    bool has_transition = false;
    EditPlanTransitionKind transition = EditPlanTransitionKind::kNone;
    std::vector<int32_t> order;         // reorder 专用
    std::string reason;
};

struct EditPlanDroppedShot {
    std::string asset;
    int32_t shot = 0;
    std::string reason;
};

// 叙事层：不触时间线模型（红线 5 的例外通道——它只进 UI 展示与 P0.5 消费记录）。
struct EditPlanNarrative {
    bool present = false;
    std::string structure;
    std::vector<EditPlanDroppedShot> dropped;
    std::string assistant_message;
};

// 乐观校验基线：plan 声明自己基于哪些资产与哪个时间线版本。
struct EditPlanBasedOn {
    std::vector<std::string> assets;
    int64_t timeline_rev = 0;
    bool has_timeline_rev = false;
};

struct EditPlan {
    std::string schema = kEditPlanSchema;
    EditPlanBasedOn based_on{};
    std::vector<EditPlanAction> actions;    // 允许为空（结构合法的 no-op plan；
                                            // 是否算决策失败由管线层判定）
    EditPlanNarrative narrative{};
    bool has_generator = false;
    std::string generator;                  // "llm"（默认，可省）| "local_rules"（降级，AIEDIT-011）
};

// 校验上下文：资产参照表（AIEDIT-005 从 FeatureReport 组装；
// shot_count = 该素材的镜头段数）。
struct EditPlanAssetInfo {
    std::string asset_id;
    RationalTime duration{};
    int32_t shot_count = 0;
};
using EditPlanAssetTable = std::vector<EditPlanAssetInfo>;

}  // namespace cq

#endif  // CQ_AI_EDIT_PLAN_H_
