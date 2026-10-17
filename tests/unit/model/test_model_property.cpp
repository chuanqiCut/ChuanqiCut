// ChuanqiCut — 效果属性系统单测（MODEL-003 / B0）
//
// 覆盖（对应 BACKLOG「属性系统」验收项）：
//   A. 属性值：类型安全读取（不猜不转）、五类工厂、相等比较
//   B. 属性袋：增删查/空 key 拒绝/指纹与插入顺序无关
//   C. 效果栈：保序、重复 id 拒绝、移除不留洞、指纹区分顺序
//   D. 时间线方法：clip 缺失 vs 效果缺失分码（kInvalidArgument / kIoNotFound）
//   E. 命令往返：四条命令 Do/Undo/Redo、失败不入栈、新建参数的"无幽灵"撤销
//   F. 100 深往返后指纹回初始态；digest 真断言（同值 set 只推进版本不变 digest）
//   G. 与轨道 muted/enabled 正交（音频线约束：属性命令不许碰轨级标志）
//
// 断言用 Check() 而非 assert：assert 在 Release（NDEBUG）下会被吃掉（假绿灯）。

#include <cstdio>
#include <string>

#include "cq/base/chq_status.h"
#include "cq/base/chq_rational_time.h"
#include "cq/command/chq_command.h"
#include "cq/model/chq_editor_model_state.h"
#include "cq/model/chq_property.h"
#include "cq/model/chq_timeline.h"

namespace {

int g_failures = 0;
int g_checks = 0;

void Check(bool cond, const char* msg) {
    ++g_checks;
    if (!cond) {
        ++g_failures;
        std::printf("  FAIL: %s\n", msg);
    }
}

cq::ChqRationalTime Ms(int64_t ms) {
    return cq::ChqRationalTime(ms * 120, cq::kProjectTimeScale);
}

cq::ChqClip MakeClip(int64_t start_ms, int64_t dur_ms, uint64_t asset_id = 1) {
    cq::ChqClip c;
    c.kind = cq::ChqClipKind::kVideo;
    c.source.asset_id = asset_id;
    c.source.source_in = Ms(0);
    c.source.source_duration = Ms(dur_ms);
    c.start = Ms(start_ms);
    c.duration = Ms(dur_ms);
    return c;
}

cq::ChqEffectBinding MakeEffect(const char* id, const char* name) {
    cq::ChqEffectBinding e;
    e.effect_id = id;
    e.effect_name = name;
    return e;
}

// 造一条视频轨 + 一个片段；返回 clip_id（0 = 失败）。
uint64_t MakeOneClipTimeline(cq::ChqTimeline& tl) {
    uint64_t track_id = 0;
    if (!tl.AddTrack(cq::ChqTrackKind::kVideo, track_id).IsOk()) return 0;
    uint64_t clip_id = 0;
    if (!tl.InsertClip(track_id, MakeClip(0, 5000), clip_id).IsOk()) return 0;
    return clip_id;
}

// ---------------------------------------------------------------------------
// A. 属性值
// ---------------------------------------------------------------------------
void TestPropertyValue() {
    std::printf("\n[A] 属性值（类型安全）\n");
    {
        float f = -1.0f;
        Check(cq::ChqPropertyValue::F(0.5f).AsFloat(f) && f == 0.5f, "F(0.5) 读回 0.5");
        int64_t i = -1;
        Check(!cq::ChqPropertyValue::F(0.5f).AsI64(i), "float 值当 i64 读 → 拒绝（不猜不转）");
        Check(cq::ChqPropertyValue::I64(7).AsI64(i) && i == 7, "I64(7) 读回 7");
        bool b = false;
        Check(cq::ChqPropertyValue::B(true).AsBool(b) && b, "B(true) 读回 true");
        Check(!cq::ChqPropertyValue::B(true).AsFloat(f), "bool 值当 float 读 → 拒绝");
        float c[4] = {0, 0, 0, 0};
        Check(cq::ChqPropertyValue::Color(0.1f, 0.2f, 0.3f, 0.4f).AsColor(c) && c[0] == 0.1f &&
                  c[3] == 0.4f,
              "Color 读回四分量");
        float v[2] = {0, 0};
        Check(cq::ChqPropertyValue::Vec2(1.5f, -2.5f).AsVec2(v) && v[0] == 1.5f && v[1] == -2.5f,
              "Vec2 读回两分量");
        Check(!cq::ChqPropertyValue::Vec2(1.0f, 2.0f).AsColor(c), "vec2 当 color 读 → 拒绝");
    }
    {
        Check(cq::ChqPropertyValue::I64(3) == cq::ChqPropertyValue::I64(3), "同型同值相等");
        Check(cq::ChqPropertyValue::I64(3) != cq::ChqPropertyValue::I64(4), "同型异值不等");
        Check(cq::ChqPropertyValue::F(1.0f) != cq::ChqPropertyValue::I64(1),
              "异型不相等（1.0f ≠ i64 1，类型是值的一部分）");
        Check(cq::ChqPropertyValue::Color(1, 2, 3, 4) == cq::ChqPropertyValue::Color(1, 2, 3, 4),
              "color 逐分量相等");
        Check(cq::ChqPropertyValue::Color(1, 2, 3, 4) != cq::ChqPropertyValue::Color(1, 2, 3, 5),
              "color 末分量不同即不等");
    }
}

// ---------------------------------------------------------------------------
// B. 属性袋
// ---------------------------------------------------------------------------
void TestPropertyBag() {
    std::printf("\n[B] 属性袋\n");
    cq::ChqPropertyBag bag;
    Check(bag.Set("opacity", cq::ChqPropertyValue::F(0.5f)).IsOk(), "Set 成功");
    Check(bag.Set("preset", cq::ChqPropertyValue::I64(2)).IsOk(), "Set 第二个 key");
    Check(bag.Size() == 2, "Size == 2");
    Check(!bag.Set("", cq::ChqPropertyValue::F(1.0f)).IsOk(), "空 key → 拒绝");
    Check(bag.Size() == 2, "空 key 被拒后袋不变");

    const cq::ChqPropertyValue* found = bag.Find("opacity");
    Check(found != nullptr, "Find 命中");
    float f = 0.0f;
    Check(found != nullptr && found->AsFloat(f) && f == 0.5f, "Find 读回正确值");
    Check(bag.Find("missing") == nullptr, "Find 未命中返回 nullptr");

    Check(bag.Erase("preset"), "Erase 已存在的 key 返回 true");
    Check(!bag.Erase("preset"), "Erase 不存在的 key 返回 false");
    Check(bag.Size() == 1, "Erase 后 Size == 1");

    // 覆盖写：同 key 后写胜
    Check(bag.Set("opacity", cq::ChqPropertyValue::F(0.9f)).IsOk(), "覆盖写成功");
    Check(bag.Size() == 1 && bag.Find("opacity") != nullptr, "覆盖写不增加条目");
    found = bag.Find("opacity");
    Check(found != nullptr && found->AsFloat(f) && f == 0.9f, "覆盖写读回新值");

    bag.Clear();
    Check(bag.Size() == 0, "Clear 后为空");

    // 指纹与插入顺序无关（map 有序；若换 unordered_map 这条会红）
    cq::ChqPropertyBag a;
    cq::ChqPropertyBag b;
    a.Set("x", cq::ChqPropertyValue::F(1.0f));
    a.Set("y", cq::ChqPropertyValue::I64(2));
    a.Set("z", cq::ChqPropertyValue::B(true));
    b.Set("z", cq::ChqPropertyValue::B(true));
    b.Set("x", cq::ChqPropertyValue::F(1.0f));
    b.Set("y", cq::ChqPropertyValue::I64(2));
    Check(a.Fingerprint() == b.Fingerprint(), "属性袋指纹与插入顺序无关");
    Check(a == b, "同内容两袋相等");

    b.Set("y", cq::ChqPropertyValue::I64(3));
    Check(a.Fingerprint() != b.Fingerprint(), "改一个值 → 指纹变（无假阴性）");
    Check(a != b, "改一个值 → 两袋不等");
}

// ---------------------------------------------------------------------------
// C. 效果栈
// ---------------------------------------------------------------------------
void TestEffectStack() {
    std::printf("\n[C] 效果栈\n");
    cq::ChqEffectStack st;
    Check(st.Append(MakeEffect("cq.effect.a", "效果A")).IsOk(), "Append A");
    Check(st.Append(MakeEffect("cq.effect.b", "效果B")).IsOk(), "Append B");
    Check(st.Size() == 2, "Size == 2");

    Check(!st.Append(MakeEffect("cq.effect.a", "效果A 副本")).IsOk(),
          "重复 effect_id → 拒绝（叠加由参数表达，不是两个绑定）");
    Check(st.Size() == 2, "重复 Append 被拒后栈不变");
    Check(!st.Append(MakeEffect("", "空 id")).IsOk(), "空 effect_id → 拒绝");

    const cq::ChqEffectBinding* found = st.Find("cq.effect.b");
    Check(found != nullptr && found->effect_name == "效果B", "Find 命中并读回展示名");
    Check(st.Find("nope") == nullptr, "Find 未命中 → nullptr");

    // 顺序即渲染顺序：Effects() 必须保序
    Check(st.Effects().size() == 2 && st.Effects()[0].effect_id == "cq.effect.a" &&
              st.Effects()[1].effect_id == "cq.effect.b",
          "Effects() 保序（顺序是渲染语义）");

    // 移除中间元素不留洞、不改其余相对顺序
    Check(st.Append(MakeEffect("cq.effect.c", "效果C")).IsOk(), "Append C");
    Check(st.Remove("cq.effect.b").IsOk(), "Remove 中间元素成功");
    Check(st.Size() == 2, "Remove 后 Size == 2");
    Check(st.Effects()[0].effect_id == "cq.effect.a" && st.Effects()[1].effect_id == "cq.effect.c",
          "Remove 后其余元素相对顺序不变");
    Check(st.Remove("cq.effect.b").code == cq::ChqStatusCode::kIoNotFound,
          "Remove 不存在 → kIoNotFound");

    // 指纹区分顺序（先 A 后 B ≠ 先 B 后 A）
    cq::ChqEffectStack s1;
    cq::ChqEffectStack s2;
    s1.Append(MakeEffect("a", "A"));
    s1.Append(MakeEffect("b", "B"));
    s2.Append(MakeEffect("b", "B"));
    s2.Append(MakeEffect("a", "A"));
    Check(s1.Fingerprint() != s2.Fingerprint(), "效果栈指纹区分顺序");

    // 启用位与参数进指纹
    cq::ChqEffectStack s3;
    s3.Append(MakeEffect("a", "A"));
    s3.Find("a")->enabled = false;
    Check(s1.Fingerprint() != s3.Fingerprint(), "启用位变化 → 指纹变");
}

// ---------------------------------------------------------------------------
// D. 时间线方法（分码语义）
// ---------------------------------------------------------------------------
void TestTimelineEffectMethods() {
    std::printf("\n[D] 时间线效果方法\n");
    cq::ChqTimeline tl;
    const uint64_t clip_id = MakeOneClipTimeline(tl);
    Check(clip_id != 0, "造时间线（1 轨 1 片段）");

    // clip 不存在 → kInvalidArgument（结构错误）
    Check(tl.AddClipEffect(9999, MakeEffect("e", "E")).code == cq::ChqStatusCode::kInvalidArgument,
          "AddClipEffect：clip 不存在 → kInvalidArgument");
    Check(tl.RemoveClipEffect(9999, "e").code == cq::ChqStatusCode::kInvalidArgument,
          "RemoveClipEffect：clip 不存在 → kInvalidArgument");
    Check(tl.SetClipEffectParam(9999, "e", "k", cq::ChqPropertyValue::F(1.0f)).code ==
              cq::ChqStatusCode::kInvalidArgument,
          "SetClipEffectParam：clip 不存在 → kInvalidArgument");
    Check(tl.SetClipEffectEnabled(9999, "e", false).code == cq::ChqStatusCode::kInvalidArgument,
          "SetClipEffectEnabled：clip 不存在 → kInvalidArgument");
    Check(tl.ReplaceClipEffects(9999, cq::ChqEffectStack{}).code ==
              cq::ChqStatusCode::kInvalidArgument,
          "ReplaceClipEffects：clip 不存在 → kInvalidArgument");

    // 效果不存在 → kIoNotFound（与"片段没了"分码）
    Check(tl.RemoveClipEffect(clip_id, "e").code == cq::ChqStatusCode::kIoNotFound,
          "RemoveClipEffect：效果不存在 → kIoNotFound");
    Check(tl.SetClipEffectParam(clip_id, "e", "k", cq::ChqPropertyValue::F(1.0f)).code ==
              cq::ChqStatusCode::kIoNotFound,
          "SetClipEffectParam：效果不存在 → kIoNotFound");
    Check(tl.SetClipEffectEnabled(clip_id, "e", true).code == cq::ChqStatusCode::kIoNotFound,
          "SetClipEffectEnabled：效果不存在 → kIoNotFound");
    Check(tl.EraseClipEffectParam(clip_id, "e", "k").code == cq::ChqStatusCode::kIoNotFound,
          "EraseClipEffectParam：效果不存在 → kIoNotFound");

    // 正常路径
    Check(tl.AddClipEffect(clip_id, MakeEffect("cq.effect.blur", "模糊")).IsOk(), "挂效果成功");
    Check(tl.AddClipEffect(clip_id, MakeEffect("cq.effect.blur", "模糊")).code ==
              cq::ChqStatusCode::kInvalidArgument,
          "重复 effect_id → kInvalidArgument");
    Check(tl.FindClip(clip_id)->effects.Size() == 1, "重复被拒后仍只有 1 个效果");

    Check(tl.SetClipEffectParam(clip_id, "cq.effect.blur", "radius",
                                cq::ChqPropertyValue::F(8.0f)).IsOk(),
          "设参数 radius=8 成功");
    Check(tl.SetClipEffectParam(clip_id, "cq.effect.blur", "", cq::ChqPropertyValue::F(1.0f))
              .code == cq::ChqStatusCode::kInvalidArgument,
          "空 key → kInvalidArgument");
    const cq::ChqEffectBinding* e = tl.FindClip(clip_id)->effects.Find("cq.effect.blur");
    Check(e != nullptr && e->params.Size() == 1, "参数袋只有 radius 一个 key（空 key 没进来）");
    Check(tl.EraseClipEffectParam(clip_id, "cq.effect.blur", "missing").code ==
              cq::ChqStatusCode::kIoNotFound,
          "擦除不存在的参数 → kIoNotFound");
    Check(tl.EraseClipEffectParam(clip_id, "cq.effect.blur", "radius").IsOk(), "擦除 radius 成功");
    Check(tl.FindClip(clip_id)->effects.Find("cq.effect.blur")->params.Size() == 0,
          "擦除后参数袋为空");

    // FindClip 返回的快照自带效果栈（拷贝语义：预览侧读到的与模型一致）
    Check(tl.SetClipEffectEnabled(clip_id, "cq.effect.blur", false).IsOk(), "禁用效果成功");
    Check(!tl.FindClip(clip_id)->effects.Find("cq.effect.blur")->enabled, "禁用已生效");
}

// ---------------------------------------------------------------------------
// E. 命令往返
// ---------------------------------------------------------------------------
void TestCommands() {
    std::printf("\n[E] 属性命令往返\n");
    // ---- add-clip-effect：Do → Undo → Redo ----
    {
        cq::ChqTimeline tl;
        const uint64_t clip_id = MakeOneClipTimeline(tl);
        cq::ChqCommandHistory hist;
        Check(hist.Execute(std::make_unique<cq::ChqAddClipEffectCommand>(
                               clip_id, MakeEffect("cq.effect.a", "A")), tl).IsOk(),
              "Execute AddClipEffect");
        Check(tl.FindClip(clip_id)->effects.Size() == 1, "Do 后效果在位");
        Check(hist.UndoDepth() == 1, "AddClipEffect 入栈");

        Check(hist.Undo(tl).IsOk(), "Undo AddClipEffect");
        Check(tl.FindClip(clip_id)->effects.Size() == 0, "Undo 后效果消失");
        Check(hist.Redo(tl).IsOk(), "Redo AddClipEffect");
        Check(tl.FindClip(clip_id)->effects.Size() == 1 &&
                  tl.FindClip(clip_id)->effects.Find("cq.effect.a") != nullptr,
              "Redo 后效果回来（id 由调用方给出，无需 Restore 语义）");
    }

    // ---- remove-clip-effect：Undo 整栈还原（含顺序）----
    {
        cq::ChqTimeline tl;
        const uint64_t clip_id = MakeOneClipTimeline(tl);
        tl.AddClipEffect(clip_id, MakeEffect("a", "A"));
        tl.AddClipEffect(clip_id, MakeEffect("b", "B"));
        tl.AddClipEffect(clip_id, MakeEffect("c", "C"));

        cq::ChqCommandHistory hist;
        Check(hist.Execute(std::make_unique<cq::ChqRemoveClipEffectCommand>(clip_id, "b"), tl)
                  .IsOk(),
              "Execute RemoveClipEffect（移除中间元素）");
        Check(tl.FindClip(clip_id)->effects.Size() == 2, "Do 后剩 2 个效果");

        Check(hist.Undo(tl).IsOk(), "Undo RemoveClipEffect");
        const cq::ChqEffectStack& st = tl.FindClip(clip_id)->effects;
        Check(st.Size() == 3, "Undo 后 3 个效果全部回来");
        Check(st.Effects()[0].effect_id == "a" && st.Effects()[1].effect_id == "b" &&
                  st.Effects()[2].effect_id == "c",
              "Undo 整栈还原**含原次序**（逐条 Append 还原会改变顺序，那是错的）");
        Check(hist.Redo(tl).IsOk() && tl.FindClip(clip_id)->effects.Size() == 2,
              "Redo 后再移除");
    }

    // ---- set-effect-param：改已有值 ----
    {
        cq::ChqTimeline tl;
        const uint64_t clip_id = MakeOneClipTimeline(tl);
        tl.AddClipEffect(clip_id, MakeEffect("e", "E"));
        tl.SetClipEffectParam(clip_id, "e", "opacity", cq::ChqPropertyValue::F(1.0f));

        cq::ChqCommandHistory hist;
        Check(hist.Execute(std::make_unique<cq::ChqSetEffectParamCommand>(
                               clip_id, "e", "opacity", cq::ChqPropertyValue::F(0.5f)), tl).IsOk(),
              "Execute SetEffectParam 1.0 → 0.5");
        float f = 0.0f;
        const cq::ChqEffectBinding* eff = tl.FindClip(clip_id)->effects.Find("e");
        Check(eff != nullptr && eff->params.Find("opacity") != nullptr &&
                  eff->params.Find("opacity")->AsFloat(f) && f == 0.5f,
              "Do 后 opacity == 0.5");
        Check(hist.Undo(tl).IsOk(), "Undo SetEffectParam");
        eff = tl.FindClip(clip_id)->effects.Find("e");
        Check(eff != nullptr && eff->params.Find("opacity") != nullptr &&
                  eff->params.Find("opacity")->AsFloat(f) && f == 1.0f,
              "Undo 后 opacity 回到 1.0");
        Check(hist.Redo(tl).IsOk(), "Redo SetEffectParam");
        eff = tl.FindClip(clip_id)->effects.Find("e");
        Check(eff != nullptr && eff->params.Find("opacity") != nullptr &&
                  eff->params.Find("opacity")->AsFloat(f) && f == 0.5f,
              "Redo 后 opacity 回到 0.5");
    }

    // ---- set-effect-param：新建 key（had_old = false）→ Undo 必须擦除，不留幽灵 ----
    {
        cq::ChqTimeline tl;
        const uint64_t clip_id = MakeOneClipTimeline(tl);
        tl.AddClipEffect(clip_id, MakeEffect("e", "E"));

        cq::ChqCommandHistory hist;
        Check(hist.Execute(std::make_unique<cq::ChqSetEffectParamCommand>(
                               clip_id, "e", "radius", cq::ChqPropertyValue::F(8.0f)), tl).IsOk(),
              "Execute SetEffectParam（新建 key）");
        Check(tl.FindClip(clip_id)->effects.Find("e")->params.Find("radius") != nullptr,
              "Do 后 radius 存在");
        Check(hist.Undo(tl).IsOk(), "Undo 新建参数");
        Check(tl.FindClip(clip_id)->effects.Find("e")->params.Find("radius") == nullptr,
              "Undo 后 radius 被擦除（不写假默认值、不留幽灵参数）");
        Check(hist.Redo(tl).IsOk() &&
                  tl.FindClip(clip_id)->effects.Find("e")->params.Find("radius") != nullptr,
              "Redo 后 radius 回来");
    }

    // ---- set-effect-enabled：Do → Undo → Redo ----
    {
        cq::ChqTimeline tl;
        const uint64_t clip_id = MakeOneClipTimeline(tl);
        tl.AddClipEffect(clip_id, MakeEffect("e", "E"));

        cq::ChqCommandHistory hist;
        Check(hist.Execute(std::make_unique<cq::ChqSetEffectEnabledCommand>(clip_id, "e", false), tl)
                  .IsOk(),
              "Execute SetEffectEnabled(false)");
        Check(!tl.FindClip(clip_id)->effects.Find("e")->enabled, "Do 后效果禁用");
        Check(hist.Undo(tl).IsOk(), "Undo SetEffectEnabled");
        Check(tl.FindClip(clip_id)->effects.Find("e")->enabled, "Undo 后效果恢复启用");
        Check(hist.Redo(tl).IsOk() && !tl.FindClip(clip_id)->effects.Find("e")->enabled,
              "Redo 后效果再禁用");
    }

    // ---- 失败命令：不入栈、不清 redo、模型不动 ----
    {
        cq::ChqTimeline tl;
        const uint64_t clip_id = MakeOneClipTimeline(tl);
        cq::ChqCommandHistory hist;
        Check(hist.Execute(std::make_unique<cq::ChqAddClipEffectCommand>(clip_id, MakeEffect("e", "E")),
                           tl).IsOk(),
              "先挂一个效果（造 redo 分支用）");
        Check(hist.Undo(tl).IsOk(), "Undo 造出 redo 分支");
        Check(hist.CanRedo(), "有 redo 分支");

        const size_t depth = hist.UndoDepth();
        Check(!hist.Execute(std::make_unique<cq::ChqAddClipEffectCommand>(
                                9999, MakeEffect("e2", "E2")), tl).IsOk(),
              "对不存在的 clip 挂效果 → 失败");
        Check(hist.UndoDepth() == depth, "失败命令不入栈");
        Check(hist.CanRedo(), "失败命令不清 redo 分支");
        Check(!hist.Execute(std::make_unique<cq::ChqSetEffectParamCommand>(
                                clip_id, "no-such-effect", "k", cq::ChqPropertyValue::F(1.0f)),
                            tl).IsOk(),
              "对不存在的效果设参数 → 失败");
        Check(hist.UndoDepth() == depth, "效果缺失的失败命令也不入栈");
    }
}

// ---------------------------------------------------------------------------
// F. 大深度往返 + digest 真断言
// ---------------------------------------------------------------------------
void TestDeepRoundTripAndDigest() {
    std::printf("\n[F] 大深度往返与 digest\n");
    cq::ChqTimeline tl;
    const uint64_t clip_id = MakeOneClipTimeline(tl);
    tl.AddClipEffect(clip_id, MakeEffect("e", "E"));

    cq::ChqCommandHistory hist;
    // 25 轮：每轮设两个参数（一个改值、一个新建后由下一轮改）
    for (int round = 0; round < 25; ++round) {
        const float v = static_cast<float>(round) * 0.01f;
        Check(hist.Execute(std::make_unique<cq::ChqSetEffectParamCommand>(
                               clip_id, "e", "opacity", cq::ChqPropertyValue::F(v)), tl).IsOk(),
              "深往返：设 opacity");
        Check(hist.Execute(std::make_unique<cq::ChqSetEffectParamCommand>(
                               clip_id, "e", "radius", cq::ChqPropertyValue::F(v * 2.0f)), tl)
                  .IsOk(),
              "深往返：设 radius");
    }
    const uint64_t fp_final = tl.FindClip(clip_id)->effects.Fingerprint();
    Check(hist.UndoDepth() == 50, "50 条命令入栈");

    for (int i = 0; i < 50; ++i) {
        if (!hist.Undo(tl).IsOk()) {
            Check(false, "深往返：Undo 失败");
            break;
        }
    }
    Check(tl.FindClip(clip_id)->effects.Find("e")->params.Size() == 0,
          "50 次 Undo 后参数袋回到空（新建 key 全部擦除，无幽灵）");
    for (int i = 0; i < 50; ++i) {
        if (!hist.Redo(tl).IsOk()) {
            Check(false, "深往返：Redo 失败");
            break;
        }
    }
    Check(tl.FindClip(clip_id)->effects.Fingerprint() == fp_final,
          "50 次 Redo 后效果栈指纹与撤销前一致");

    // ---- digest：属性变化必须推进（假阴性守卫）----
    cq::ChqEditorModelState state;
    uint64_t track_id = 0;
    uint64_t cid = 0;
    Check(state.timeline().AddTrack(cq::ChqTrackKind::kVideo, track_id).IsOk(), "model state 建轨");
    Check(state.timeline().InsertClip(track_id, MakeClip(0, 5000), cid).IsOk(), "model state 建片段");

    const uint64_t d0 = state.Digest();
    Check(state.Execute(std::make_unique<cq::ChqAddClipEffectCommand>(cid, MakeEffect("e", "E")))
              .IsOk(),
          "model state：挂效果");
    const uint64_t d1 = state.Digest();
    Check(d1 != d0, "挂效果 → digest 变（漏字段就会出现假阴性）");

    Check(state.Execute(std::make_unique<cq::ChqSetEffectParamCommand>(
                            cid, "e", "opacity", cq::ChqPropertyValue::F(0.5f))).IsOk(),
          "model state：设 opacity=0.5");
    const uint64_t d2 = state.Digest();
    Check(d2 != d1, "改参数值 → digest 变");

    // 同值再设一次：内容没变 ⇒ digest 不变（这是内容指纹的正确语义，
    // 不是缺陷；版本号仍推进，由 Session 层负责）
    Check(state.Execute(std::make_unique<cq::ChqSetEffectParamCommand>(
                            cid, "e", "opacity", cq::ChqPropertyValue::F(0.5f))).IsOk(),
          "model state：同值再设 opacity=0.5");
    Check(state.Digest() == d2, "同值 set：digest 不变（内容指纹语义：没变就是没变）");

    // 禁用位也进 digest
    Check(state.Execute(std::make_unique<cq::ChqSetEffectEnabledCommand>(cid, "e", false)).IsOk(),
          "model state：禁用效果");
    Check(state.Digest() != d2, "禁用效果 → digest 变");

    // Undo 回 d2
    Check(state.Undo().IsOk() && state.Digest() == d2, "Undo 禁用 → digest 回到 d2");
}

// ---------------------------------------------------------------------------
// G. 与轨道 muted/enabled 正交（音频线约束的真断言）
// ---------------------------------------------------------------------------
void TestOrthogonalToTrackFlags() {
    std::printf("\n[G] 与轨级标志正交\n");
    cq::ChqTimeline tl;
    uint64_t video_track = 0;
    uint64_t video_clip = 0;
    uint64_t audio_track = 0;
    uint64_t audio_clip = 0;
    Check(tl.AddTrack(cq::ChqTrackKind::kVideo, video_track).IsOk(), "建视频轨");
    Check(tl.InsertClip(video_track, MakeClip(0, 5000), video_clip).IsOk(), "建视频片段");
    Check(tl.AddTrack(cq::ChqTrackKind::kAudio, audio_track).IsOk(), "建音频轨");
    {
        cq::ChqClip ac = MakeClip(0, 5000);
        ac.kind = cq::ChqClipKind::kAudio;
        Check(tl.InsertClip(audio_track, ac, audio_clip).IsOk(), "建音频片段");
    }

    cq::ChqCommandHistory hist;
    Check(hist.Execute(std::make_unique<cq::ChqAddClipEffectCommand>(
                           audio_clip, MakeEffect("e", "E")), tl).IsOk(),
          "音频片段挂效果");
    Check(hist.Execute(std::make_unique<cq::ChqSetEffectParamCommand>(
                           audio_clip, "e", "gain", cq::ChqPropertyValue::F(0.8f)), tl).IsOk(),
          "音频片段设参数");

    // 轨级标志一个都不许被属性命令碰
    const cq::ChqTrack* vt = tl.FindTrack(video_track);
    const cq::ChqTrack* at = tl.FindTrack(audio_track);
    Check(vt != nullptr && vt->enabled && !vt->muted, "视频轨 enabled/muted 未被属性命令触碰");
    Check(at != nullptr && at->enabled && !at->muted, "音频轨 enabled/muted 未被属性命令触碰");

    // 反向语义归属：轨级 muted 由混音器消费（AUDIO-004），**不是**属性系统的输入。
    // 模型层当前没有 SetTrackMuted 入口（muted 是 ChqTrack 的字段，由将来的
    // 轨级命令设置）—— 这里能断言的是：clip 效果栈与轨级标志互不覆盖，
    // 音频片段上的效果参数完好无损。
    const cq::ChqClip* ac = tl.FindClip(audio_clip);
    Check(ac != nullptr && ac->effects.Find("e") != nullptr &&
              ac->effects.Find("e")->params.Find("gain") != nullptr,
          "音频片段的效果栈完好（属性与轨级 muted 是两个维度，互不接管）");
}

}  // namespace

int main() {
    std::printf("== 效果属性系统单测（MODEL-003 / B0）==\n");
    TestPropertyValue();
    TestPropertyBag();
    TestEffectStack();
    TestTimelineEffectMethods();
    TestCommands();
    TestDeepRoundTripAndDigest();
    TestOrthogonalToTrackFlags();
    std::printf("\n== %d checks, %d failures ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
