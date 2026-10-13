// ChuanqiCut — 效果属性系统实现（MODEL-003）
//
// 契约见 chq_property.h。指纹算法与 ChqRenderGraph / ChqEditorModelState 的
// FNV-1a 同参数（offset basis / prime），一份五行的混合原语在内核里有几处
// 匿名 namespace 副本（render_graph / graph_assembler / editor_model_state）——
// 它是纯函数、无语义可漂移，暂不收敛成公共头；若将来要收敛，另立 INFRA 卡，
// 不在这批里顺手重构（写集纪律）。

#include "cq/model/chq_property.h"

#include <cstring>

namespace cq {
namespace {

constexpr uint64_t kFnvOffset = 14695981039346656037ull;
constexpr uint64_t kFnvPrime = 1099511628211ull;

inline void Mix(uint64_t& h, uint64_t v) {
    for (int i = 0; i < 8; ++i) {
        h ^= (v >> (i * 8)) & 0xFFu;
        h *= kFnvPrime;
    }
}

inline void MixBytes(uint64_t& h, const char* p, size_t n) {
    Mix(h, static_cast<uint64_t>(n));  // 长度先进去：防 "ab"+"c" 与 "a"+"bc" 同哈希
    for (size_t i = 0; i < n; ++i) {
        h ^= static_cast<uint8_t>(p[i]);
        h *= kFnvPrime;
    }
}

inline void MixStr(uint64_t& h, const std::string& s) { MixBytes(h, s.data(), s.size()); }

// float → 位模式（memcpy，不做类型双关——那在 -Werror 下是 strict-aliasing 坑）。
inline void MixFloats(uint64_t& h, const float v[4]) {
    for (int i = 0; i < 4; ++i) {
        uint32_t bits = 0;
        std::memcpy(&bits, &v[i], sizeof(bits));
        Mix(h, static_cast<uint64_t>(bits));
    }
}

}  // namespace

// ===========================================================================
// ChqPropertyValue
// ===========================================================================

ChqPropertyValue ChqPropertyValue::I64(int64_t x) {
    ChqPropertyValue p;
    p.type = ChqPropertyType::kInt64;
    p.i = x;
    return p;
}

ChqPropertyValue ChqPropertyValue::F(float x) {
    ChqPropertyValue p;
    p.type = ChqPropertyType::kFloat;
    p.v[0] = x;
    return p;
}

ChqPropertyValue ChqPropertyValue::B(bool x) {
    ChqPropertyValue p;
    p.type = ChqPropertyType::kBool;
    p.b = x;
    return p;
}

ChqPropertyValue ChqPropertyValue::Color(float r, float g, float b, float a) {
    ChqPropertyValue p;
    p.type = ChqPropertyType::kColor;
    p.v[0] = r;
    p.v[1] = g;
    p.v[2] = b;
    p.v[3] = a;
    return p;
}

ChqPropertyValue ChqPropertyValue::Vec2(float x, float y) {
    ChqPropertyValue p;
    p.type = ChqPropertyType::kVec2;
    p.v[0] = x;
    p.v[1] = y;
    return p;
}

bool ChqPropertyValue::AsI64(int64_t& out) const {
    if (type != ChqPropertyType::kInt64) return false;
    out = i;
    return true;
}

bool ChqPropertyValue::AsFloat(float& out) const {
    if (type != ChqPropertyType::kFloat) return false;
    out = v[0];
    return true;
}

bool ChqPropertyValue::AsBool(bool& out) const {
    if (type != ChqPropertyType::kBool) return false;
    out = b;
    return true;
}

bool ChqPropertyValue::AsColor(float out[4]) const {
    if (type != ChqPropertyType::kColor) return false;
    for (int k = 0; k < 4; ++k) out[k] = v[k];  // 循环变量不叫 i：避开成员字段 i（-Wshadow）
    return true;
}

bool ChqPropertyValue::AsVec2(float out[2]) const {
    if (type != ChqPropertyType::kVec2) return false;
    out[0] = v[0];
    out[1] = v[1];
    return true;
}

bool ChqPropertyValue::operator==(const ChqPropertyValue& o) const {
    if (type != o.type) return false;
    switch (type) {
        case ChqPropertyType::kInt64:
            return i == o.i;
        case ChqPropertyType::kFloat:
            return v[0] == o.v[0];
        case ChqPropertyType::kBool:
            return b == o.b;
        case ChqPropertyType::kColor:
            return v[0] == o.v[0] && v[1] == o.v[1] && v[2] == o.v[2] && v[3] == o.v[3];
        case ChqPropertyType::kVec2:
            return v[0] == o.v[0] && v[1] == o.v[1];
    }
    return false;
}

// ===========================================================================
// ChqPropertyBag
// ===========================================================================

ChqStatus ChqPropertyBag::Set(const std::string& key, const ChqPropertyValue& value) {
    if (key.empty()) return ChqStatus(ChqStatusCode::kInvalidArgument);
    entries_[key] = value;
    return ChqStatus::Ok();
}

const ChqPropertyValue* ChqPropertyBag::Find(const std::string& key) const {
    auto it = entries_.find(key);
    return it == entries_.end() ? nullptr : &it->second;
}

bool ChqPropertyBag::Erase(const std::string& key) { return entries_.erase(key) != 0; }

uint64_t ChqPropertyBag::Fingerprint() const {
    uint64_t h = kFnvOffset;
    // map 有序 ⇒ 遍历序稳定；每个条目混合 key（长度+该厂商）、类型、全部存储该厂商。
    for (const auto& kv : entries_) {
        MixStr(h, kv.first);
        Mix(h, static_cast<uint64_t>(kv.second.type));
        Mix(h, static_cast<uint64_t>(kv.second.i));
        MixFloats(h, kv.second.v);
        Mix(h, kv.second.b ? 1 : 0);
    }
    return h;
}

// ===========================================================================
// ChqEffectStack
// ===========================================================================

ChqStatus ChqEffectStack::Append(const ChqEffectBinding& effect) {
    if (effect.effect_id.empty()) return ChqStatus(ChqStatusCode::kInvalidArgument);
    if (Find(effect.effect_id) != nullptr) {
        return ChqStatus(ChqStatusCode::kInvalidArgument);  // 同 id 两个实例是 UI 错误
    }
    effects_.push_back(effect);
    return ChqStatus::Ok();
}

ChqStatus ChqEffectStack::Remove(const std::string& effect_id) {
    for (auto it = effects_.begin(); it != effects_.end(); ++it) {
        if (it->effect_id == effect_id) {
            effects_.erase(it);
            return ChqStatus::Ok();
        }
    }
    return ChqStatus(ChqStatusCode::kIoNotFound);
}

ChqEffectBinding* ChqEffectStack::Find(const std::string& effect_id) {
    for (ChqEffectBinding& e : effects_) {
        if (e.effect_id == effect_id) return &e;
    }
    return nullptr;
}

const ChqEffectBinding* ChqEffectStack::Find(const std::string& effect_id) const {
    for (const ChqEffectBinding& e : effects_) {
        if (e.effect_id == effect_id) return &e;
    }
    return nullptr;
}

uint64_t ChqEffectStack::Fingerprint() const {
    uint64_t h = kFnvOffset;
    Mix(h, static_cast<uint64_t>(effects_.size()));
    for (const ChqEffectBinding& e : effects_) {
        MixStr(h, e.effect_id);
        MixStr(h, e.effect_name);
        Mix(h, e.enabled ? 1 : 0);
        Mix(h, e.params.Fingerprint());
    }
    return h;
}

}  // namespace cq
