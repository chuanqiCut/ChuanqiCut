// ChuanqiCut — 效果属性系统（MODEL-003 / B0 渲染地基第二块）
//
// 为什么 B0 就要它（RENDER-001 已立图，效果是图上第一批"真实节点"）：
//   没有属性系统，"滤镜/特效"只能以硬编码枚举散落在渲染器里 —— 每加一个效果
//   就要改一遍渲染路径，正是 ADR-0014「两套渲染路径」代价的微型复刻。
//   MODEL-003 把「片段上挂了什么效果、每个效果什么参数」变成**数据**：
//   渲染（RENDER-011）与 UI（属性面板）从此读同一份结构，不需要第二处真源。
//
// 本文件做什么：
//   * 属性值 / 属性袋（有序 map，指纹稳定）与效果绑定 / 效果栈的数据结构；
//   * 效果栈挂到 ChqClip（chq_timeline.h），顺序即渲染顺序（有序向量）。
//
// 本文件**不**做什么（有意留白，不要假装已有）：
//   * 不定义效果目录（哪些 effect_id 存在、默认参数是什么）—— 归 EFFECT-001；
//   * 不消费属性做渲染 —— 归 RENDER-011（B7）。B0 的装配器只如实上报
//     effects_dropped（见 chq_graph_assembler.cpp）。
//   * 不做序列化 —— 工程存档归 PROJECT 系列。
//
// 硬约束（与 CORE 层一致，勿破）：
//   * 零平台类型 / 零 FFmpeg 类型 / 禁用异常（错误一律 ChqStatus）；
//   * **时间不进属性**：属性是图形/效果参数（不透明度、缩放、颜色），不是时间量。
//     时间一律 ChqRationalTime（红线 #4），本结构没有任何时间字段 —— 这也是
//     它可以用浮点的前提。标量用 float 而非 double：与 platform/chq_gfx.h 的
//     clear_color[4] / SetViewport(float) 同一先例（非时间量允许浮点），
//     且 tools/platform/check_platform_headers.py 对契约头禁 double token。
//   * 属性袋用 std::map（有序）而非 unordered_map：指纹必须与插入顺序无关，
//     unordered_map 的迭代序会让同一份数据在不同插入历史下算出不同指纹。

#ifndef CQ_CORE_MODEL_CHQ_PROPERTY_H_
#define CQ_CORE_MODEL_CHQ_PROPERTY_H_

#include <cstdint>
#include <map>
#include <string>
#include <vector>

#include "cq/base/chq_status.h"

namespace cq {

// ---------------------------------------------------------------------------
// 属性类型（B0 最小集）
// ---------------------------------------------------------------------------
// 新增类型必须同步三处：ChqPropertyValue 的存储与工厂、AsXxx 读取、
// ChqPropertyBag::Fingerprint 的混合项 —— 别只加枚举（那会造出
// "设得进取不出"的暗类型）。
enum class ChqPropertyType : int32_t {
    kInt64 = 0,  // 整数（预设序号 / 计数 / 枚举位）
    kFloat = 1,  // 标量（不透明度 / 强度 / 半径）
    kBool = 2,   // 开关
    kColor = 3,  // RGBA（v[0..3]，0..1）
    kVec2 = 4,   // 二维（缩放 / 位移，v[0..1]）
};

// ---------------------------------------------------------------------------
// ChqPropertyValue — 单个属性值（tag + 定长存储）
// ---------------------------------------------------------------------------
// 定长内联存储（无堆分配）：ChqClip 快照每秒要被拷贝一次（模型发布），
// 值对象必须便宜；音频/渲染线程将来读属性时也无分配。
struct ChqPropertyValue {
    ChqPropertyType type = ChqPropertyType::kFloat;
    int64_t i = 0;    // kInt64
    float v[4] = {};  // kFloat: v[0]；kColor: v[0..3]；kVec2: v[0..1]
    bool b = false;   // kBool

    // ---- 工厂（按类型构造，调用方不需要先 memset）----
    static ChqPropertyValue I64(int64_t x);
    static ChqPropertyValue F(float x);
    static ChqPropertyValue B(bool x);
    static ChqPropertyValue Color(float r, float g, float b, float a);
    static ChqPropertyValue Vec2(float x, float y);

    // ---- 类型安全读取：类型不符返回 false，不猜不转 ----
    // （把 kFloat 的值当 kInt64 读出来是静默错误，宁可让调用方显式处理。）
    bool AsI64(int64_t& out) const;
    bool AsFloat(float& out) const;
    bool AsBool(bool& out) const;
    bool AsColor(float out[4]) const;
    bool AsVec2(float out[2]) const;

    bool operator==(const ChqPropertyValue& o) const;
    bool operator!=(const ChqPropertyValue& o) const { return !(*this == o); }
};

// ---------------------------------------------------------------------------
// ChqPropertyBag — 一个效果的参数袋（key → value）
// ---------------------------------------------------------------------------
class ChqPropertyBag {
public:
    // 覆盖写（同 key 后写胜）。空 key 拒绝（kInvalidArgument）——
    // 空 key 在 UI 上无法展示，在查询结构体里也无法与"截断"区分。
    ChqStatus Set(const std::string& key, const ChqPropertyValue& value);

    const ChqPropertyValue* Find(const std::string& key) const;

    // 删除。返回是否删掉了（false = 原本没有该 key）。
    bool Erase(const std::string& key);

    size_t Size() const { return entries_.size(); }
    void Clear() { entries_.clear(); }

    bool operator==(const ChqPropertyBag& o) const { return entries_ == o.entries_; }

    // 结构指纹（FNV-1a 64）。map 有序 ⇒ 与插入顺序无关。
    // 用途：模型 digest 判"属性变没变"（见 ChqEditorModelState::Fingerprint）。
    uint64_t Fingerprint() const;

    // 只读遍历（UI / 查询 ABI 用；有序 = 展示顺序稳定）。
    const std::map<std::string, ChqPropertyValue>& Entries() const { return entries_; }

private:
    std::map<std::string, ChqPropertyValue> entries_;
};

// ---------------------------------------------------------------------------
// ChqEffectBinding — 片段上挂的一个效果实例
// ---------------------------------------------------------------------------
struct ChqEffectBinding {
    std::string effect_id;    // 稳定 id（如 "cq.effect.blur"；效果目录归 EFFECT-001）
    std::string effect_name;  // 展示名（UI 直接显示，不查目录）
    bool enabled = true;      // 单效果开关（与轨道 muted 正交，见 chq_track.h）
    ChqPropertyBag params;

    // C++20 默认比较：成员逐个 ==（ChqPropertyBag 自带 operator==）。
    // 不写 = default 的话 ChqEffectStack::operator== 里的 vector 比较会实例化失败
    // （聚合类型不会自动获得 ==，2026-10-12 实测编译错误）。
    bool operator==(const ChqEffectBinding&) const = default;
};

// ---------------------------------------------------------------------------
// ChqEffectStack — 一个片段上的效果链
// ---------------------------------------------------------------------------
// 顺序即渲染顺序（有序向量）：效果的应用次序在视觉上不等价
// （先模糊后调色 ≠ 先调色后模糊），所以不用 map、不用排序恢复。
class ChqEffectStack {
public:
    // 追加到栈尾。effect_id 为空或栈内已有同 id → kInvalidArgument
    // （同 id 两个实例是 UI 错误：叠加两次应由参数表达，不是两个绑定）。
    ChqStatus Append(const ChqEffectBinding& effect);

    // 按 id 移除。不存在 → kIoNotFound（如实：没有这个东西）。
    // 移除不影响其余效果的相对顺序。
    ChqStatus Remove(const std::string& effect_id);

    ChqEffectBinding* Find(const std::string& effect_id);
    const ChqEffectBinding* Find(const std::string& effect_id) const;

    size_t Size() const { return effects_.size(); }
    void Clear() { effects_.clear(); }

    bool operator==(const ChqEffectStack& o) const { return effects_ == o.effects_; }

    // 结构指纹（FNV-1a 64；按栈序混合，顺序不同 ⇒ 指纹不同 —— 顺序是语义）。
    uint64_t Fingerprint() const;

    const std::vector<ChqEffectBinding>& Effects() const { return effects_; }

private:
    std::vector<ChqEffectBinding> effects_;
};

}  // namespace cq

#endif  // CQ_CORE_MODEL_CHQ_PROPERTY_H_
