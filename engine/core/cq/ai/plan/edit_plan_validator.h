// ChuanqiCut — EditPlan 校验器（AIEDIT-001）
//
// C++ 是唯一权威校验方（ADR-0020 决策 3）。三层校验：
//   1. JSON 语法（手写 RFC 8259 解析器，不引第三方——P0 不走 dependency-governance）
//   2. 结构：schema 版本、必填字段、JSON 类型、时间对象形状（{value,timescale} 且
//      timescale == 120000；时间字段浮点直接非法——红线 4 的机器检查）、有界动词集
//   3. 语义：asset/shot 引用存在、source_in+duration ≤ 素材时长（__int128 溢出防御）、
//      place_clip 段不重叠、reorder 为排列
//
// 错误定位：EditPlanError 携带 JSON 路径与人读描述，供 AIEDIT-005 把错误回传
// LLM 自动修复（≤2 次）。固定缓冲、零堆分配路径之外的成员不进热路径。
//
// 本头文件是内核私有实现（core/src 不进 PUBLIC include），对外只暴露
// cq/ai/edit_plan.h 的类型。

#ifndef CQ_AI_EDIT_PLAN_VALIDATOR_H_
#define CQ_AI_EDIT_PLAN_VALIDATOR_H_

#include <string_view>

#include "cq/ai/edit_plan.h"
#include "cq/base/status.h"

namespace cq {
namespace ai {

// 结构化校验错误（固定缓冲，供回传 LLM；path 形如 "actions[2].timeline_start"）。
struct EditPlanError {
    StatusCode code = StatusCode::kOk;
    char path[96] = {};
    char detail[192] = {};
};

// 第 1+2 层：解析 + 结构校验（不查资产上下文）。成功时 out_plan 填充完毕。
Status ParseEditPlan(std::string_view json, EditPlan& out_plan, EditPlanError& out_err);

// 第 3 层：语义校验（要求 plan 来自 ParseEditPlan）。assets 可为空表——
// 此时任何 asset 引用都判 kAiPlanAssetUnknown（断网降级路径的资产为空场景
// 由调用方保证语义，校验器只对照传入表）。
Status ValidateEditPlan(const EditPlan& plan, const EditPlanAssetTable& assets,
                        EditPlanError& out_err);

// 便捷组合：解析 + 结构 + 语义一遍过。
Status ValidateEditPlanJson(std::string_view json, const EditPlanAssetTable& assets,
                            EditPlan& out_plan, EditPlanError& out_err);

}  // namespace ai
}  // namespace cq

#endif  // CQ_AI_EDIT_PLAN_VALIDATOR_H_
