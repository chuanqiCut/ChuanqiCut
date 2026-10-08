// ChuanqiCut — EditPlan 校验器实现（AIEDIT-001）
//
// 三层：手写 RFC 8259 JSON 解析（零第三方，P0 不走 dependency-governance）→
// 结构校验（schema 版本 / 必填 / 类型 / 时间形状）→ 语义校验（引用 / 边界 /
// 重叠 / 排列）。设计约束见同名头文件与 cq/ai/edit_plan.h 文件头。
//
// 错误码与路径的约定：错误在**检测点**就地装配（SetError），path 精确到字段
// （如 actions[2].timeline_start.value）——AIEDIT-005 把它原样回传 LLM 修复。

#include "edit_plan_validator.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <string>
#include <utility>
#include <vector>

#include "cq/base/rational_time.h"
#include "cq/base/status.h"

namespace cq {

// ---------------------------------------------------------------------------
// op / 转场类型名映射（edit_plan.h 声明；实现归本 TU——校验器是首个消费者）
// ---------------------------------------------------------------------------

const char* EditPlanOpName(EditPlanOp op) {
    switch (op) {
        case EditPlanOp::kSelectIntro:       return "select_intro";
        case EditPlanOp::kSelectHighlight:   return "select_highlight";
        case EditPlanOp::kSelectOutro:       return "select_outro";
        case EditPlanOp::kPlaceClip:         return "place_clip";
        case EditPlanOp::kRemoveRange:       return "remove_range";
        case EditPlanOp::kTrimClip:          return "trim_clip";
        case EditPlanOp::kReorder:           return "reorder";
        case EditPlanOp::kSetTransition:     return "set_transition";
        case EditPlanOp::kSetBgmPlaceholder: return "set_bgm_placeholder";
        case EditPlanOp::kUnknown:           break;
    }
    return nullptr;
}

bool EditPlanOpFromName(const char* name, EditPlanOp& out_op) {
    static const std::pair<const char*, EditPlanOp> kTable[] = {
        {"select_intro", EditPlanOp::kSelectIntro},
        {"select_highlight", EditPlanOp::kSelectHighlight},
        {"select_outro", EditPlanOp::kSelectOutro},
        {"place_clip", EditPlanOp::kPlaceClip},
        {"remove_range", EditPlanOp::kRemoveRange},
        {"trim_clip", EditPlanOp::kTrimClip},
        {"reorder", EditPlanOp::kReorder},
        {"set_transition", EditPlanOp::kSetTransition},
        {"set_bgm_placeholder", EditPlanOp::kSetBgmPlaceholder},
    };
    for (const auto& entry : kTable) {
        if (std::strcmp(entry.first, name) == 0) {
            out_op = entry.second;
            return true;
        }
    }
    return false;
}

const char* EditPlanTransitionKindName(EditPlanTransitionKind kind) {
    switch (kind) {
        case EditPlanTransitionKind::kNone:       return "none";
        case EditPlanTransitionKind::kCrossFade:  return "cross_fade";
        case EditPlanTransitionKind::kDipToBlack: return "dip_to_black";
        case EditPlanTransitionKind::kUnknown:    break;
    }
    return nullptr;
}

bool EditPlanTransitionKindFromName(const char* name, EditPlanTransitionKind& out_kind) {
    static const std::pair<const char*, EditPlanTransitionKind> kTable[] = {
        {"none", EditPlanTransitionKind::kNone},
        {"cross_fade", EditPlanTransitionKind::kCrossFade},
        {"dip_to_black", EditPlanTransitionKind::kDipToBlack},
    };
    for (const auto& entry : kTable) {
        if (std::strcmp(entry.first, name) == 0) {
            out_kind = entry.second;
            return true;
        }
    }
    return false;
}

}  // namespace cq

namespace cq {
namespace ai {

namespace {

// ---------------------------------------------------------------------------
// 错误装配（检测点就地调用）
// ---------------------------------------------------------------------------

void SetError(EditPlanError& err, StatusCode code, const std::string& path,
              const char* detail) {
    err.code = code;
    std::snprintf(err.path, sizeof(err.path), "%s", path.c_str());
    std::snprintf(err.detail, sizeof(err.detail), "%s", detail);
}

Status Fail(EditPlanError& err, StatusCode code, const std::string& path,
            const char* detail) {
    SetError(err, code, path, detail);
    return Status{code};
}

// 字段路径拼接（如 actions[2].timeline_start）。
std::string Join(const std::string& base, const char* field) {
    return base + "." + field;
}

std::string Index(const std::string& base, size_t i) {
    return base + "[" + std::to_string(i) + "]";
}

// ---------------------------------------------------------------------------
// 手写 JSON DOM + 解析器（RFC 8259 严格子集：转义/代理对/无尾逗号/无前导零）
// ---------------------------------------------------------------------------

enum class JType { kNull, kBool, kInt, kDouble, kString, kArray, kObject };

struct JValue {
    JType type = JType::kNull;
    bool bool_value = false;
    int64_t int_value = 0;
    bool int_overflow = false;  // 整数字面量超出 int64（仍为整数记法，非浮点）
    double double_value = 0.0;
    bool is_float = false;      // 字面量含 '.' / 'e' / 'E'
    std::string string_value;
    std::vector<JValue> items;                            // kArray
    std::vector<std::pair<std::string, JValue>> members;  // kObject

    const JValue* Find(std::string_view key) const {
        for (const auto& m : members) {
            if (m.first == key) return &m.second;
        }
        return nullptr;
    }
};

class JParser {
public:
    explicit JParser(std::string_view text) : text_(text) {}

    // 失败一律 kAiPlanJsonMalformed；why/offset 记入成员，由调用方取用。
    Status Parse(JValue& out) {
        Status s = ParseValue(out, 0);
        if (!s.IsOk()) return s;
        SkipWs();
        if (pos_ != text_.size()) {
            return FailAt("顶层值之后存在多余内容");
        }
        return Status::Ok();
    }

    const char* error_why() const { return why_.c_str(); }
    size_t error_offset() const { return why_offset_; }

private:
    std::string_view text_;
    size_t pos_ = 0;
    size_t why_offset_ = 0;
    std::string why_;

    Status FailAt(const char* why) {
        why_ = why;
        why_offset_ = pos_;
        return Status{StatusCode::kAiPlanJsonMalformed};
    }

    void SkipWs() {
        while (pos_ < text_.size()) {
            const char c = text_[pos_];
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
                ++pos_;
            } else {
                break;
            }
        }
    }

    bool Consume(char c) {
        if (pos_ < text_.size() && text_[pos_] == c) {
            ++pos_;
            return true;
        }
        return false;
    }

    Status ParseValue(JValue& out, int depth) {
        if (depth > kMaxDepth) return FailAt("嵌套深度超限");
        SkipWs();
        if (pos_ >= text_.size()) return FailAt("意外的输入结尾");
        const char c = text_[pos_];
        if (c == '{') return ParseObject(out, depth);
        if (c == '[') return ParseArray(out, depth);
        if (c == '"') {
            out.type = JType::kString;
            return ParseString(out.string_value);
        }
        if (c == 't') {
            return ParseLiteral("true", [&out]() {
                out.type = JType::kBool;
                out.bool_value = true;
            });
        }
        if (c == 'f') {
            return ParseLiteral("false", [&out]() {
                out.type = JType::kBool;
                out.bool_value = false;
            });
        }
        if (c == 'n') {
            return ParseLiteral("null", [&out]() { out.type = JType::kNull; });
        }
        return ParseNumber(out);
    }

    template <typename Setter>
    Status ParseLiteral(const char* lit, Setter setter) {
        const size_t len = std::char_traits<char>::length(lit);
        if (text_.size() - pos_ < len || text_.compare(pos_, len, lit) != 0) {
            return FailAt("非法字面量");
        }
        pos_ += len;
        setter();
        return Status::Ok();
    }

    Status ParseObject(JValue& out, int depth) {
        out.type = JType::kObject;
        ++pos_;  // '{'
        SkipWs();
        if (Consume('}')) return Status::Ok();
        while (true) {
            SkipWs();
            if (pos_ >= text_.size() || text_[pos_] != '"') {
                return FailAt("对象键须为字符串");
            }
            std::string key;
            Status s = ParseString(key);
            if (!s.IsOk()) return s;
            SkipWs();
            if (!Consume(':')) return FailAt("对象键后缺 ':'");
            JValue member;
            s = ParseValue(member, depth + 1);
            if (!s.IsOk()) return s;
            out.members.emplace_back(std::move(key), std::move(member));
            SkipWs();
            if (Consume(',')) continue;
            if (Consume('}')) return Status::Ok();
            return FailAt("对象缺 ',' 或 '}'");
        }
    }

    Status ParseArray(JValue& out, int depth) {
        out.type = JType::kArray;
        ++pos_;  // '['
        SkipWs();
        if (Consume(']')) return Status::Ok();
        while (true) {
            JValue item;
            Status s = ParseValue(item, depth + 1);
            if (!s.IsOk()) return s;
            out.items.push_back(std::move(item));
            SkipWs();
            if (Consume(',')) continue;
            if (Consume(']')) return Status::Ok();
            return FailAt("数组缺 ',' 或 ']'");
        }
    }

    Status ParseString(std::string& out) {
        ++pos_;  // '"'
        out.clear();
        while (true) {
            if (pos_ >= text_.size()) return FailAt("字符串未闭合");
            const unsigned char c = static_cast<unsigned char>(text_[pos_]);
            if (c == '"') {
                ++pos_;
                return Status::Ok();
            }
            if (c == '\\') {
                ++pos_;
                Status s = ParseEscape(out);
                if (!s.IsOk()) return s;
                continue;
            }
            if (c < 0x20U) return FailAt("字符串含未转义控制字符");
            out.push_back(static_cast<char>(c));
            ++pos_;
        }
    }

    Status ParseEscape(std::string& out) {
        if (pos_ >= text_.size()) return FailAt("转义序列未闭合");
        const char c = text_[pos_++];
        switch (c) {
            case '"':  out.push_back('"');  return Status::Ok();
            case '\\': out.push_back('\\'); return Status::Ok();
            case '/':  out.push_back('/');  return Status::Ok();
            case 'b':  out.push_back('\b'); return Status::Ok();
            case 'f':  out.push_back('\f'); return Status::Ok();
            case 'n':  out.push_back('\n'); return Status::Ok();
            case 'r':  out.push_back('\r'); return Status::Ok();
            case 't':  out.push_back('\t'); return Status::Ok();
            case 'u':  return ParseUnicodeEscape(out);
            default:   return FailAt("非法转义字符");
        }
    }

    Status ParseHex4(uint32_t& out) {
        if (text_.size() - pos_ < 4) return FailAt("\\u 缺 4 位十六进制");
        uint32_t v = 0;
        for (int i = 0; i < 4; ++i) {
            const char h = text_[pos_ + static_cast<size_t>(i)];
            v <<= 4U;
            if (h >= '0' && h <= '9') {
                v |= static_cast<uint32_t>(h - '0');
            } else if (h >= 'a' && h <= 'f') {
                v |= static_cast<uint32_t>(h - 'a' + 10);
            } else if (h >= 'A' && h <= 'F') {
                v |= static_cast<uint32_t>(h - 'A' + 10);
            } else {
                return FailAt("\\u 含非十六进制字符");
            }
        }
        pos_ += 4;
        out = v;
        return Status::Ok();
    }

    static void AppendUtf8(std::string& out, uint32_t cp) {
        if (cp <= 0x7FU) {
            out.push_back(static_cast<char>(cp));
        } else if (cp <= 0x7FFU) {
            out.push_back(static_cast<char>(0xC0U | (cp >> 6U)));
            out.push_back(static_cast<char>(0x80U | (cp & 0x3FU)));
        } else if (cp <= 0xFFFFU) {
            out.push_back(static_cast<char>(0xE0U | (cp >> 12U)));
            out.push_back(static_cast<char>(0x80U | ((cp >> 6U) & 0x3FU)));
            out.push_back(static_cast<char>(0x80U | (cp & 0x3FU)));
        } else {
            out.push_back(static_cast<char>(0xF0U | (cp >> 18U)));
            out.push_back(static_cast<char>(0x80U | ((cp >> 12U) & 0x3FU)));
            out.push_back(static_cast<char>(0x80U | ((cp >> 6U) & 0x3FU)));
            out.push_back(static_cast<char>(0x80U | (cp & 0x3FU)));
        }
    }

    Status ParseUnicodeEscape(std::string& out) {
        uint32_t cp = 0;
        Status s = ParseHex4(cp);
        if (!s.IsOk()) return s;
        if (cp >= 0xD800U && cp <= 0xDBFFU) {  // 高代理：必须跟低代理
            if (text_.size() - pos_ < 6 || text_[pos_] != '\\' || text_[pos_ + 1] != 'u') {
                return FailAt("孤立高代理");
            }
            pos_ += 2;
            uint32_t low = 0;
            s = ParseHex4(low);
            if (!s.IsOk()) return s;
            if (low < 0xDC00U || low > 0xDFFFU) return FailAt("代理对范围非法");
            cp = 0x10000U + ((cp - 0xD800U) << 10U) + (low - 0xDC00U);
        } else if (cp >= 0xDC00U && cp <= 0xDFFFU) {
            return FailAt("孤立低代理");
        }
        AppendUtf8(out, cp);
        return Status::Ok();
    }

    Status ParseNumber(JValue& out) {
        const size_t start = pos_;
        bool is_float = false;
        Consume('-');
        size_t int_digits = 0;
        while (pos_ < text_.size() && text_[pos_] >= '0' && text_[pos_] <= '9') {
            ++pos_;
            ++int_digits;
        }
        if (int_digits == 0) return FailAt("非法数字");
        const size_t first_digit = (text_[start] == '-') ? start + 1 : start;
        if (int_digits > 1 && text_[first_digit] == '0') return FailAt("前导零非法");

        if (Consume('.')) {
            is_float = true;
            size_t frac_digits = 0;
            while (pos_ < text_.size() && text_[pos_] >= '0' && text_[pos_] <= '9') {
                ++pos_;
                ++frac_digits;
            }
            if (frac_digits == 0) return FailAt("小数点后缺数字");
        }
        if (pos_ < text_.size() && (text_[pos_] == 'e' || text_[pos_] == 'E')) {
            ++pos_;
            is_float = true;
            if (!Consume('+')) Consume('-');
            size_t exp_digits = 0;
            while (pos_ < text_.size() && text_[pos_] >= '0' && text_[pos_] <= '9') {
                ++pos_;
                ++exp_digits;
            }
            if (exp_digits == 0) return FailAt("指数缺数字");
        }

        out.is_float = is_float;
        const std::string lex(text_.data() + start, pos_ - start);
        if (is_float) {
            out.type = JType::kDouble;
            out.double_value = std::strtod(lex.c_str(), nullptr);
            return Status::Ok();
        }
        // 整数路径：无符号累加 + 显式溢出检测（含 INT64_MIN 边界）。
        out.type = JType::kInt;
        const bool negative = text_[start] == '-';
        // 负数可到 |INT64_MIN|（9223372036854775808），正数上限 INT64_MAX。
        const uint64_t limit =
            negative ? 9223372036854775808ULL : static_cast<uint64_t>(INT64_MAX);
        uint64_t acc = 0;
        bool overflow = false;
        for (size_t i = first_digit; i < pos_; ++i) {
            const uint64_t digit = static_cast<uint64_t>(text_[i] - '0');
            if (acc > limit / 10U || (acc == limit / 10U && digit > limit % 10U)) {
                overflow = true;
                break;
            }
            acc = acc * 10U + digit;
        }
        out.int_overflow = overflow;
        if (!overflow) {
            if (negative && acc == 9223372036854775808ULL) {
                out.int_value = INT64_MIN;
            } else if (negative) {
                out.int_value = -static_cast<int64_t>(acc);
            } else {
                out.int_value = static_cast<int64_t>(acc);
            }
        }
        return Status::Ok();
    }

    static constexpr int kMaxDepth = 64;  // 防栈溢出 / 恶意嵌套
};

// ---------------------------------------------------------------------------
// 结构校验（检测点就地装配错误）
// ---------------------------------------------------------------------------

// 时间对象：{"value": int, "timescale": int == 120000}。
// 浮点记法（'.' / 'e'）→ kAiPlanFloatTime（红线 4 的机器检查点）；
// timescale != 120000 → kAiPlanTimescaleMismatch；其余形状错 → FieldMissing / FieldType。
Status TimeFromJson(const JValue& v, const std::string& path, EditPlanError& err,
                    RationalTime& out) {
    // 浮点秒的两种形态都在形状检查前识别（红线 4 机器检查的核心场景）：
    //   直接浮点（"timeline_start": 0.5）与对象内浮点（{"value": 0.5, ...}）。
    if (v.type == JType::kDouble) {
        return Fail(err, StatusCode::kAiPlanFloatTime, path,
                    "时间字段禁止浮点秒（红线 4）");
    }
    if (v.type != JType::kObject) {
        return Fail(err, StatusCode::kAiPlanFieldType, path,
                    "时间字段须为 {value, timescale} 对象");
    }
    const JValue* value = v.Find("value");
    if (value == nullptr) {
        return Fail(err, StatusCode::kAiPlanFieldMissing, Join(path, "value"),
                    "时间对象缺 value");
    }
    const JValue* timescale = v.Find("timescale");
    if (timescale == nullptr) {
        return Fail(err, StatusCode::kAiPlanFieldMissing, Join(path, "timescale"),
                    "时间对象缺 timescale");
    }
    if (value->type == JType::kDouble) {
        return Fail(err, StatusCode::kAiPlanFloatTime, Join(path, "value"),
                    "时间字段禁止浮点（红线 4）");
    }
    if (value->type != JType::kInt) {
        return Fail(err, StatusCode::kAiPlanFieldType, Join(path, "value"),
                    "value 须为整数");
    }
    if (value->int_overflow) {
        return Fail(err, StatusCode::kAiPlanFieldType, Join(path, "value"),
                    "value 超出 int64 表示范围");
    }
    if (timescale->type == JType::kDouble) {
        return Fail(err, StatusCode::kAiPlanFloatTime, Join(path, "timescale"),
                    "时间字段禁止浮点（红线 4）");
    }
    if (timescale->type != JType::kInt) {
        return Fail(err, StatusCode::kAiPlanFieldType, Join(path, "timescale"),
                    "timescale 须为整数");
    }
    if (timescale->int_overflow) {
        return Fail(err, StatusCode::kAiPlanFieldType, Join(path, "timescale"),
                    "timescale 超出 int64 表示范围");
    }
    if (timescale->int_value != static_cast<int64_t>(kProjectTimeScale)) {
        return Fail(err, StatusCode::kAiPlanTimescaleMismatch, Join(path, "timescale"),
                    "timescale 必须等于项目网格 120000");
    }
    out = RationalTime(value->int_value, kProjectTimeScale);
    return Status::Ok();
}

// 通用整数字段（timeline_rev / shot / order 元素）。浮点记法判类型错。
Status IntFromJson(const JValue& v, const std::string& path, EditPlanError& err,
                   int64_t& out) {
    if (v.type == JType::kDouble) {
        return Fail(err, StatusCode::kAiPlanFieldType, path, "须为整数（不接受浮点记法）");
    }
    if (v.type != JType::kInt) {
        return Fail(err, StatusCode::kAiPlanFieldType, path, "须为整数");
    }
    if (v.int_overflow) {
        return Fail(err, StatusCode::kAiPlanFieldType, path, "整数超出 int64 表示范围");
    }
    out = v.int_value;
    return Status::Ok();
}

// 可选时间字段：存在则解析（错误在检测点装配），不存在置 has=false 返回 Ok。
Status OptionalTime(const JValue& obj, const char* key, const std::string& action_path,
                    EditPlanError& err, bool& has, RationalTime& out) {
    has = false;
    const JValue* v = obj.Find(key);
    if (v == nullptr) return Status::Ok();
    has = true;
    return TimeFromJson(*v, Join(action_path, key), err, out);
}

// ---------------------------------------------------------------------------
// 结构校验：顶层与 action
// ---------------------------------------------------------------------------

Status ParseAction(const JValue& v, const std::string& path, EditPlanAction& out,
                   EditPlanError& err) {
    if (v.type != JType::kObject) {
        return Fail(err, StatusCode::kAiPlanFieldType, path, "action 元素须为对象");
    }

    const JValue* op = v.Find("op");
    if (op == nullptr) {
        return Fail(err, StatusCode::kAiPlanFieldMissing, Join(path, "op"), "缺少 op");
    }
    if (op->type != JType::kString) {
        return Fail(err, StatusCode::kAiPlanFieldType, Join(path, "op"), "op 须为字符串");
    }
    if (!EditPlanOpFromName(op->string_value.c_str(), out.op)) {
        return Fail(err, StatusCode::kAiPlanUnknownOp, Join(path, "op"),
                    "未知动词（有界动词集之外）");
    }

    // 已知可选字段：存在即查类型（宽松策略只豁免「未知」字段，不豁免已知字段错型）。
    if (const JValue* asset = v.Find("asset")) {
        if (asset->type != JType::kString) {
            return Fail(err, StatusCode::kAiPlanFieldType, Join(path, "asset"),
                        "asset 须为字符串");
        }
        out.has_asset = true;
        out.asset = asset->string_value;
    }
    if (const JValue* shot = v.Find("shot")) {
        int64_t wide = 0;
        Status s = IntFromJson(*shot, Join(path, "shot"), err, wide);
        if (!s.IsOk()) return s;
        if (wide < static_cast<int64_t>(INT32_MIN) || wide > static_cast<int64_t>(INT32_MAX)) {
            return Fail(err, StatusCode::kAiPlanFieldType, Join(path, "shot"),
                        "shot 超出 int32 表示范围");
        }
        out.has_shot = true;
        out.shot = static_cast<int32_t>(wide);
    }
    if (const JValue* reason = v.Find("reason")) {
        if (reason->type != JType::kString) {
            return Fail(err, StatusCode::kAiPlanFieldType, Join(path, "reason"),
                        "reason 须为字符串");
        }
        out.reason = reason->string_value;
    }

    Status s = OptionalTime(v, "timeline_start", path, err, out.has_timeline_start,
                            out.timeline_start);
    if (!s.IsOk()) return s;
    s = OptionalTime(v, "source_in", path, err, out.has_source_in, out.source_in);
    if (!s.IsOk()) return s;
    s = OptionalTime(v, "duration", path, err, out.has_duration, out.duration);
    if (!s.IsOk()) return s;

    if (const JValue* kind = v.Find("kind")) {
        if (kind->type != JType::kString) {
            return Fail(err, StatusCode::kAiPlanFieldType, Join(path, "kind"),
                        "kind 须为字符串");
        }
        if (!EditPlanTransitionKindFromName(kind->string_value.c_str(), out.transition)) {
            return Fail(err, StatusCode::kAiPlanTransitionKindUnknown, Join(path, "kind"),
                        "未知转场类型（none/cross_fade/dip_to_black 之外）");
        }
        out.has_transition = true;
    }

    if (const JValue* order = v.Find("order")) {
        if (order->type != JType::kArray) {
            return Fail(err, StatusCode::kAiPlanFieldType, Join(path, "order"),
                        "order 须为整数数组");
        }
        for (size_t i = 0; i < order->items.size(); ++i) {
            int64_t idx = 0;
            s = IntFromJson(order->items[i], Index(Join(path, "order"), i), err, idx);
            if (!s.IsOk()) return s;
            if (idx < 0 || idx > static_cast<int64_t>(INT32_MAX)) {
                return Fail(err, StatusCode::kAiPlanFieldType,
                            Index(Join(path, "order"), i), "order 元素须为非负整数");
            }
            out.order.push_back(static_cast<int32_t>(idx));
        }
    }

    // ---- per-op 必填性（字段缺失在结构层拒绝；值域问题留给语义层）----
    const bool needs_asset_shot = out.op == EditPlanOp::kSelectIntro ||
                                  out.op == EditPlanOp::kSelectHighlight ||
                                  out.op == EditPlanOp::kSelectOutro ||
                                  out.op == EditPlanOp::kPlaceClip;
    if (needs_asset_shot && !out.has_asset) {
        return Fail(err, StatusCode::kAiPlanFieldMissing, Join(path, "asset"),
                    "该动词要求 asset 字段");
    }
    if (needs_asset_shot && !out.has_shot) {
        return Fail(err, StatusCode::kAiPlanFieldMissing, Join(path, "shot"),
                    "该动词要求 shot 字段（非负整数）");
    }
    if (out.op == EditPlanOp::kPlaceClip &&
        (!out.has_timeline_start || !out.has_source_in || !out.has_duration)) {
        return Fail(err, StatusCode::kAiPlanFieldMissing, path,
                    "place_clip 要求 timeline_start/source_in/duration 齐全");
    }
    if (out.op == EditPlanOp::kRemoveRange && (!out.has_timeline_start || !out.has_duration)) {
        return Fail(err, StatusCode::kAiPlanFieldMissing, path,
                    "remove_range 要求 timeline_start/duration 齐全");
    }
    if (out.op == EditPlanOp::kTrimClip && !out.has_timeline_start) {
        return Fail(err, StatusCode::kAiPlanFieldMissing, Join(path, "timeline_start"),
                    "trim_clip 要求 timeline_start 定位待裁 clip");
    }
    if (out.op == EditPlanOp::kReorder && out.order.empty() && !v.Find("order")) {
        return Fail(err, StatusCode::kAiPlanFieldMissing, Join(path, "order"),
                    "reorder 要求 order 排列");
    }
    if (out.op == EditPlanOp::kSetTransition) {
        if (!out.has_timeline_start) {
            return Fail(err, StatusCode::kAiPlanFieldMissing, Join(path, "timeline_start"),
                        "set_transition 要求 timeline_start（at）");
        }
        if (!out.has_transition) {
            return Fail(err, StatusCode::kAiPlanFieldMissing, Join(path, "kind"),
                        "set_transition 要求 kind");
        }
        if (!out.has_duration) {
            return Fail(err, StatusCode::kAiPlanFieldMissing, Join(path, "duration"),
                        "set_transition 要求 duration");
        }
    }
    return Status::Ok();
}

Status ParseEditPlanImpl(const JValue& root, EditPlan& out_plan, EditPlanError& err) {
    if (root.type != JType::kObject) {
        return Fail(err, StatusCode::kAiPlanFieldType, "", "顶层须为 JSON 对象");
    }

    // schema：必填字符串；值不认识 → 拒绝并降级（SPEC §6.3.4）。
    const JValue* schema = root.Find("schema");
    if (schema == nullptr) {
        return Fail(err, StatusCode::kAiPlanFieldMissing, "schema", "缺少 schema 版本字段");
    }
    if (schema->type != JType::kString) {
        return Fail(err, StatusCode::kAiPlanFieldType, "schema", "schema 须为字符串");
    }
    if (schema->string_value != kEditPlanSchema) {
        return Fail(err, StatusCode::kAiPlanSchemaUnknown, "schema",
                    "未知的 schema 版本（拒绝并降级，绝不猜测解析）");
    }
    out_plan.schema = schema->string_value;

    // based_on：必填对象。
    const JValue* based_on = root.Find("based_on");
    if (based_on == nullptr) {
        return Fail(err, StatusCode::kAiPlanFieldMissing, "based_on", "缺少 based_on");
    }
    if (based_on->type != JType::kObject) {
        return Fail(err, StatusCode::kAiPlanFieldType, "based_on", "based_on 须为对象");
    }
    const JValue* assets = based_on->Find("assets");
    if (assets == nullptr) {
        return Fail(err, StatusCode::kAiPlanFieldMissing, "based_on.assets",
                    "缺少资产清单");
    }
    if (assets->type != JType::kArray) {
        return Fail(err, StatusCode::kAiPlanFieldType, "based_on.assets",
                    "assets 须为数组");
    }
    for (size_t i = 0; i < assets->items.size(); ++i) {
        const JValue& a = assets->items[i];
        if (a.type != JType::kString) {
            return Fail(err, StatusCode::kAiPlanFieldType, Index("based_on.assets", i),
                        "资产 id 须为字符串");
        }
        out_plan.based_on.assets.push_back(a.string_value);
    }
    const JValue* rev = based_on->Find("timeline_rev");
    if (rev == nullptr) {
        return Fail(err, StatusCode::kAiPlanFieldMissing, "based_on.timeline_rev",
                    "缺少 timeline_rev（乐观校验基线）");
    }
    int64_t rev_value = 0;
    Status s = IntFromJson(*rev, "based_on.timeline_rev", err, rev_value);
    if (!s.IsOk()) return s;
    out_plan.based_on.timeline_rev = rev_value;
    out_plan.based_on.has_timeline_rev = true;

    // actions：必填数组（允许空数组 = 结构合法的 no-op plan）。
    const JValue* actions = root.Find("actions");
    if (actions == nullptr) {
        return Fail(err, StatusCode::kAiPlanFieldMissing, "actions", "缺少 actions");
    }
    if (actions->type != JType::kArray) {
        return Fail(err, StatusCode::kAiPlanFieldType, "actions", "actions 须为数组");
    }
    for (size_t i = 0; i < actions->items.size(); ++i) {
        EditPlanAction action;
        s = ParseAction(actions->items[i], Index("actions", i), action, err);
        if (!s.IsOk()) return s;
        out_plan.actions.push_back(std::move(action));
    }

    // narrative：可选。
    const JValue* narrative = root.Find("narrative");
    if (narrative != nullptr) {
        if (narrative->type != JType::kObject) {
            return Fail(err, StatusCode::kAiPlanFieldType, "narrative",
                        "narrative 须为对象");
        }
        out_plan.narrative.present = true;
        if (const JValue* structure = narrative->Find("structure")) {
            if (structure->type != JType::kString) {
                return Fail(err, StatusCode::kAiPlanFieldType, "narrative.structure",
                            "structure 须为字符串");
            }
            out_plan.narrative.structure = structure->string_value;
        }
        if (const JValue* dropped = narrative->Find("dropped")) {
            if (dropped->type != JType::kArray) {
                return Fail(err, StatusCode::kAiPlanFieldType, "narrative.dropped",
                            "dropped 须为数组");
            }
            for (size_t i = 0; i < dropped->items.size(); ++i) {
                const JValue& d = dropped->items[i];
                const std::string elem_path = Index("narrative.dropped", i);
                if (d.type != JType::kObject) {
                    return Fail(err, StatusCode::kAiPlanFieldType, elem_path,
                                "dropped 元素须为对象");
                }
                const JValue* d_asset = d.Find("asset");
                const JValue* d_shot = d.Find("shot");
                if (d_asset == nullptr || d_shot == nullptr) {
                    return Fail(err, StatusCode::kAiPlanFieldMissing, elem_path,
                                "dropped 元素缺 asset/shot");
                }
                if (d_asset->type != JType::kString) {
                    return Fail(err, StatusCode::kAiPlanFieldType, Join(elem_path, "asset"),
                                "asset 须为字符串");
                }
                int64_t shot_value = 0;
                s = IntFromJson(*d_shot, Join(elem_path, "shot"), err, shot_value);
                if (!s.IsOk()) return s;
                if (shot_value < 0 || shot_value > static_cast<int64_t>(INT32_MAX)) {
                    return Fail(err, StatusCode::kAiPlanFieldType, Join(elem_path, "shot"),
                                "shot 须为非负整数");
                }
                EditPlanDroppedShot shot_entry;
                shot_entry.asset = d_asset->string_value;
                shot_entry.shot = static_cast<int32_t>(shot_value);
                if (const JValue* d_reason = d.Find("reason")) {
                    if (d_reason->type != JType::kString) {
                        return Fail(err, StatusCode::kAiPlanFieldType,
                                    Join(elem_path, "reason"), "reason 须为字符串");
                    }
                    shot_entry.reason = d_reason->string_value;
                }
                out_plan.narrative.dropped.push_back(std::move(shot_entry));
            }
        }
        if (const JValue* message = narrative->Find("assistant_message")) {
            if (message->type != JType::kString) {
                return Fail(err, StatusCode::kAiPlanFieldType, "narrative.assistant_message",
                            "assistant_message 须为字符串");
            }
            out_plan.narrative.assistant_message = message->string_value;
        }
    }

    // generator：可选（AIEDIT-011 降级标注 "local_rules"）。
    if (const JValue* generator = root.Find("generator")) {
        if (generator->type != JType::kString) {
            return Fail(err, StatusCode::kAiPlanFieldType, "generator",
                        "generator 须为字符串");
        }
        out_plan.has_generator = true;
        out_plan.generator = generator->string_value;
    }

    // 其余未知顶层字段宽松忽略（向前兼容；扩展必须走 schema 版本号）。
    return Status::Ok();
}

// ---------------------------------------------------------------------------
// 语义校验
// ---------------------------------------------------------------------------

const EditPlanAssetInfo* FindAsset(const EditPlanAssetTable& assets,
                                   const std::string& asset_id) {
    for (const EditPlanAssetInfo& info : assets) {
        if (info.asset_id == asset_id) return &info;
    }
    return nullptr;
}

// source_in + duration 与素材时长的比较统一升到 __int128：极端值下 int64 相加
// 会回绕（golden 有此案例），有理数纪律要求比较不得经过浮点（红线 4 / ARCH-001）。
bool TimeRangeOverruns(int64_t source_in, int64_t duration, int64_t asset_duration) {
    const __int128 end = static_cast<__int128>(source_in) + static_cast<__int128>(duration);
    return end > static_cast<__int128>(asset_duration);
}

}  // namespace

Status ParseEditPlan(std::string_view json, EditPlan& out_plan, EditPlanError& out_err) {
    out_plan = EditPlan{};
    JParser parser(json);
    JValue root;
    Status s = parser.Parse(root);
    if (!s.IsOk()) {
        std::string detail = std::string("JSON 语法非法：") + parser.error_why() +
                             "（byte " + std::to_string(parser.error_offset()) + "）";
        std::snprintf(out_err.detail, sizeof(out_err.detail), "%s", detail.c_str());
        out_err.code = StatusCode::kAiPlanJsonMalformed;
        out_err.path[0] = '\0';
        return s;
    }
    return ParseEditPlanImpl(root, out_plan, out_err);
}

Status ValidateEditPlan(const EditPlan& plan, const EditPlanAssetTable& assets,
                        EditPlanError& out_err) {
    // based_on.assets 引用存在性。
    for (size_t i = 0; i < plan.based_on.assets.size(); ++i) {
        if (FindAsset(assets, plan.based_on.assets[i]) == nullptr) {
            return Fail(out_err, StatusCode::kAiPlanAssetUnknown,
                        Index("based_on.assets", i),
                        "asset_id 引用不存在（对照 FeatureReport 资产表）");
        }
    }

    size_t place_count = 0;
    for (const EditPlanAction& a : plan.actions) {
        if (a.op == EditPlanOp::kPlaceClip) ++place_count;
    }

    // 逐 action 语义。
    for (size_t i = 0; i < plan.actions.size(); ++i) {
        const EditPlanAction& a = plan.actions[i];
        const std::string path = Index("actions", i);
        const bool needs_asset = a.op == EditPlanOp::kSelectIntro ||
                                 a.op == EditPlanOp::kSelectHighlight ||
                                 a.op == EditPlanOp::kSelectOutro ||
                                 a.op == EditPlanOp::kPlaceClip;
        if (needs_asset) {
            const EditPlanAssetInfo* info = FindAsset(assets, a.asset);
            if (info == nullptr) {
                return Fail(out_err, StatusCode::kAiPlanAssetUnknown, Join(path, "asset"),
                            "asset_id 引用不存在（对照 FeatureReport 资产表）");
            }
            if (a.shot < 0 || a.shot >= info->shot_count) {
                return Fail(out_err, StatusCode::kAiPlanShotOutOfRange, Join(path, "shot"),
                            "shot 序号越界（<0 或不小于素材镜头段数）");
            }
        }
        switch (a.op) {
            case EditPlanOp::kPlaceClip: {
                if (a.timeline_start.value < 0) {
                    return Fail(out_err, StatusCode::kAiPlanTimeNonPositive,
                                Join(path, "timeline_start"), "timeline_start 不得为负");
                }
                if (a.source_in.value < 0) {
                    return Fail(out_err, StatusCode::kAiPlanTimeNonPositive,
                                Join(path, "source_in"), "source_in 不得为负");
                }
                if (a.duration.value <= 0) {
                    return Fail(out_err, StatusCode::kAiPlanTimeNonPositive,
                                Join(path, "duration"), "duration 必须为正");
                }
                const EditPlanAssetInfo* info = FindAsset(assets, a.asset);
                if (info != nullptr &&
                    TimeRangeOverruns(a.source_in.value, a.duration.value,
                                      info->duration.value)) {
                    return Fail(out_err, StatusCode::kAiPlanSourceRange, path,
                                "source_in + duration 越过素材时长");
                }
                break;
            }
            case EditPlanOp::kRemoveRange:
                if (a.timeline_start.value < 0) {
                    return Fail(out_err, StatusCode::kAiPlanTimeNonPositive,
                                Join(path, "timeline_start"), "timeline_start 不得为负");
                }
                if (a.duration.value <= 0) {
                    return Fail(out_err, StatusCode::kAiPlanTimeNonPositive,
                                Join(path, "duration"), "duration 必须为正");
                }
                break;
            case EditPlanOp::kTrimClip:
                if (a.has_source_in && a.source_in.value < 0) {
                    return Fail(out_err, StatusCode::kAiPlanTimeNonPositive,
                                Join(path, "source_in"), "source_in 不得为负");
                }
                if (a.has_duration && a.duration.value <= 0) {
                    return Fail(out_err, StatusCode::kAiPlanTimeNonPositive,
                                Join(path, "duration"), "duration 必须为正");
                }
                break;
            case EditPlanOp::kSetTransition:
                if (a.timeline_start.value < 0) {
                    return Fail(out_err, StatusCode::kAiPlanTimeNonPositive,
                                Join(path, "timeline_start"), "at 不得为负");
                }
                if (a.duration.value <= 0) {
                    return Fail(out_err, StatusCode::kAiPlanTimeNonPositive,
                                Join(path, "duration"), "transition duration 必须为正");
                }
                break;
            case EditPlanOp::kReorder: {
                if (a.order.size() != place_count) {
                    return Fail(out_err, StatusCode::kAiPlanReorderNotPermutation,
                                Join(path, "order"),
                                "order 长度必须等于 plan 内 place_clip 数");
                }
                std::vector<bool> seen(place_count, false);
                for (const int32_t idx : a.order) {
                    if (idx < 0 || static_cast<size_t>(idx) >= place_count ||
                        seen[static_cast<size_t>(idx)]) {
                        return Fail(out_err, StatusCode::kAiPlanReorderNotPermutation,
                                    Join(path, "order"),
                                    "order 须为 [0, place_clip 数) 的排列");
                    }
                    seen[static_cast<size_t>(idx)] = true;
                }
                break;
            }
            case EditPlanOp::kSelectIntro:
            case EditPlanOp::kSelectHighlight:
            case EditPlanOp::kSelectOutro:
            case EditPlanOp::kSetBgmPlaceholder:
            case EditPlanOp::kUnknown:
                break;
        }
    }

    // place_clip 时间线段重叠检查（同 plan 内两两不重叠；相接 == 允许）。
    struct Segment {
        int64_t start;
        __int128 end;
        size_t index;
    };
    std::vector<Segment> segments;
    segments.reserve(plan.actions.size());
    for (size_t i = 0; i < plan.actions.size(); ++i) {
        const EditPlanAction& a = plan.actions[i];
        if (a.op != EditPlanOp::kPlaceClip) continue;
        Segment seg;
        seg.start = a.timeline_start.value;
        seg.end = static_cast<__int128>(a.timeline_start.value) +
                  static_cast<__int128>(a.duration.value);
        seg.index = i;
        segments.push_back(seg);
    }
    std::sort(segments.begin(), segments.end(), [](const Segment& x, const Segment& y) {
        if (x.start != y.start) return x.start < y.start;
        return x.end < y.end;
    });
    for (size_t k = 1; k < segments.size(); ++k) {
        if (segments[k - 1].end > static_cast<__int128>(segments[k].start)) {
            return Fail(out_err, StatusCode::kAiPlanTimelineOverlap,
                        Index("actions", segments[k].index),
                        "place_clip 时间线段重叠（相接允许，交叠不允许）");
        }
    }

    return Status::Ok();
}

Status ValidateEditPlanJson(std::string_view json, const EditPlanAssetTable& assets,
                            EditPlan& out_plan, EditPlanError& out_err) {
    Status s = ParseEditPlan(json, out_plan, out_err);
    if (!s.IsOk()) return s;
    return ValidateEditPlan(out_plan, assets, out_err);
}

}  // namespace ai
}  // namespace cq
