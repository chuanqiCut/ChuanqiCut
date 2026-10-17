// ChuanqiCut — 空间 / 层级 / 变速 / 关键帧单测（MODEL-004 / B5.5）
//
// 覆盖（对应 TASK-MODEL-004 acceptance 逐条）：
//   A. 默认值 = 恒等（新建 clip 不填 transform 时不改画面）
//   B. ChqTransform::Validate 取值域（NaN / 负缩放 / 越界旋转 / opacity > 1 / 野枚举）
//   C. relative_* 随画布修正（像素守恒）+ 浮点反比不保证可逆的实测对照
//   D. ChqSpeed 整数比：<= 0 拒绝、占时 = 源/speed、可逆、溢出如实报 kOverflow
//   E. 关键帧：覆盖写、升序不变量、空袋与负时刻拒绝、删除分码、指纹与插入历史无关
//   F. 时间线写路径校验与"失败不动模型"（Insert / Replace / Restore 三条插入路径同基）
//   G. 六条命令 Do/Undo/Redo + 40 次往返后 digest 逐位回初始态
//   H. digest 覆盖四组新字段（假阴性守卫）+ SplitClip 关键帧分箱
//
// 断言用 Check() 而非 assert：assert 在 Release（NDEBUG）下会被吃掉（假绿灯）。

#include <cstddef>
#include <cmath>
#include <cstdio>
#include <memory>

#include "cq/base/chq_rational_time.h"
#include "cq/base/chq_status.h"
#include "cq/command/chq_command.h"
#include "cq/model/chq_editor_model_state.h"
#include "cq/model/chq_property.h"
#include "cq/model/chq_timeline.h"
#include "cq/model/chq_transform.h"

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

cq::ChqPropertyBag Bag(const char* key, float v) {
    cq::ChqPropertyBag b;
    b.Set(key, cq::ChqPropertyValue::F(v));
    return b;
}

cq::ChqTransform Scaled(float s) {
    cq::ChqTransform t;
    t.scale_x = s;
    t.scale_y = s;
    return t;
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
// A. 默认值 = 恒等
// ---------------------------------------------------------------------------
void TestDefaults() {
    std::printf("\n[A] 默认值是恒等\n");
    cq::ChqTransform t;
    Check(t.IsIdentity(), "默认 transform 是恒等");
    Check(t.Validate().IsOk(), "默认 transform 合法");
    Check(cq::ChqTransform() == cq::ChqTransform(), "两份默认值相等");
    Check(cq::ChqTransform().Fingerprint() == cq::ChqTransform().Fingerprint(),
          "默认指纹稳定（同一份内容每次同一个值）");

    cq::ChqSpeed s;
    Check(s.numerator == 1 && s.denominator == 1, "默认 speed = 1:1（不变速）");
    Check(s.Validate().IsOk(), "默认 speed 合法");

    cq::ChqClip c = MakeClip(0, 5000);
    Check(c.transform.IsIdentity() && c.layer == cq::kLayerMin && c.keyframes.Empty(),
          "新建 clip 的新字段全在不改画面的默认值上");
    Check(cq::ChqTrack().transform.IsIdentity(), "新建轨的 transform 默认恒等");

    // 恒等判定用精确相等，不留 epsilon：差一点点就不是恒等
    Check(!Scaled(0.9999999f).IsIdentity(), "scale 差一点点也不算恒等");
    cq::ChqTransform moved;
    moved.translate_x = 0.0f;
    Check(moved.IsIdentity(), "translate 显式写 0 仍是恒等");
}

// ---------------------------------------------------------------------------
// B. Validate 取值域
// ---------------------------------------------------------------------------
void TestTransformValidate() {
    std::printf("\n[B] ChqTransform 取值域\n");
    const float nan = std::nanf("");
    const float inf = static_cast<float>(HUGE_VALF);

    cq::ChqTransform t;
    t.scale_x = 0.0f;
    Check(!t.Validate().IsOk(), "scale = 0 拒绝（图层退化成一条线）");
    Check(!Scaled(-1.0f).Validate().IsOk(), "负 scale 拒绝（与 mirror 语义重复）");
    Check(!Scaled(nan).Validate().IsOk(), "NaN scale 拒绝");
    Check(!Scaled(inf).Validate().IsOk(), "Inf scale 拒绝");

    t = cq::ChqTransform();
    t.relative_height = 0.0f;
    Check(!t.Validate().IsOk(), "relative = 0 拒绝");

    t = cq::ChqTransform();
    t.translate_y = nan;
    Check(!t.Validate().IsOk(), "NaN 位移拒绝（可以推出画布，但不许是 NaN）");
    t = cq::ChqTransform();
    t.translate_x = 9999.0f;
    Check(t.Validate().IsOk(), "大位移合法：看不见不等于非法");

    t = cq::ChqTransform();
    t.rotation_degrees = 720.0f;
    Check(!t.Validate().IsOk(), "720 度拒绝（与 0 度同画面不同指纹 → 假变化）");
    t = cq::ChqTransform();
    t.rotation_degrees = -360.0f;
    Check(t.Validate().IsOk(), "-360 度在域内");

    t = cq::ChqTransform();
    t.opacity = 1.5f;
    Check(!t.Validate().IsOk(), "opacity > 1 拒绝");
    t = cq::ChqTransform();
    t.opacity = 0.0f;
    Check(t.Validate().IsOk(), "opacity = 0 合法（全透明是一等公民）");

    t = cq::ChqTransform();
    t.mirror = static_cast<cq::ChqMirrorKind>(7);
    Check(!t.Validate().IsOk(), "野 mirror 枚举值拒绝");

    cq::ChqTransform a;
    cq::ChqTransform b;
    b.mirror = cq::ChqMirrorKind::kHorizontal;
    Check(a.Fingerprint() != b.Fingerprint(), "mirror 影响指纹");
    b = a;
    b.opacity = 0.5f;
    Check(a.Fingerprint() != b.Fingerprint(), "opacity 影响指纹");
    b = a;
    b.relative_width = 1.0f;
    b.relative_height = 1.0f;
    Check(a.Fingerprint() == b.Fingerprint(), "同值重写不改指纹（内容语义）");
}

// ---------------------------------------------------------------------------
// C. 改画布比例的相对尺寸修正（像素守恒 + 浮点反比可否逆的实测对照）
// ---------------------------------------------------------------------------
void TestRelativeRescale() {
    std::printf("\n[C] relative_* 随画布修正\n");
    cq::ChqTransform t;
    t.relative_width = 0.3f;
    t.relative_height = 0.5f;
    const float px_w = 0.3f * 1080.0f;  // 324
    const float px_h = 0.5f * 1920.0f;  // 960

    Check(!t.RescaleRelativeTo(0, 1920, 1080, 1080).IsOk(), "old 宽非正 → 拒绝");
    Check(!t.RescaleRelativeTo(1080, 1920, 1080, 0).IsOk(), "new 高非正 → 拒绝");
    Check(t.relative_width == 0.3f && t.relative_height == 0.5f, "被拒的调用不改值");

    cq::ChqTransform same = t;
    Check(same.RescaleRelativeTo(1080, 1920, 1080, 1920).IsOk(), "同尺寸调用成功");
    Check(same.relative_width == 0.3f && same.relative_height == 0.5f, "同尺寸不改动数值");

    // 1080×1920 → 1080×1080：宽不动、高按反比修正 → 盒子的像素宽高各自守恒（不被拉扁）
    cq::ChqTransform sq = t;
    Check(sq.RescaleRelativeTo(1080, 1920, 1080, 1080).IsOk(), "改 1:1 成功");
    Check(std::fabs(sq.relative_width * 1080.0f - px_w) < 1e-3f, "宽像素守恒（画布宽没变）");
    Check(std::fabs(sq.relative_height * 1080.0f - px_h) < 1e-3f,
          "高像素守恒：改比例后盒子形状不被拉扁（错乱的成因就是这条没做）");

    // 浮点反比**不保证**可逆：Undo 必须靠留档而不是重算，这两组实测就是它的依据
    cq::ChqTransform back = t;
    back.relative_width = 1.7f;
    back.relative_height = 1.0f;
    Check(back.RescaleRelativeTo(1080, 1920, 720, 1280).IsOk(), "改 720×1280 成功");
    Check(back.relative_width > 1.7f && back.relative_width < 2.6f, "中间值 ~2.55000019");
    Check(back.RescaleRelativeTo(720, 1280, 1080, 1920).IsOk(), "改回成功");
    Check(back.relative_width != 1.7f, "1.7 反比乘回回不到原值（float32 实测差 1.2e-7）");

    cq::ChqTransform lucky = t;
    lucky.relative_height = 1.0f;
    Check(lucky.RescaleRelativeTo(1080, 1920, 720, 1280).IsOk() &&
              lucky.RescaleRelativeTo(720, 1280, 1080, 1920).IsOk() &&
              lucky.relative_width == 0.3f,
          "0.3 同一条路径侥幸回到原值 —— 回不回取决于值，侥幸不能当契约，所以留档才是正解");

    // 极端比例：结果不可表示 → 拒绝且不改值
    cq::ChqTransform extreme;
    extreme.relative_width = 3.0e37f;
    extreme.relative_height = 1.0f;
    Check(extreme.RescaleRelativeTo(8192, 8192, 1, 1).code == cq::ChqStatusCode::kOverflow,
          "结果溢出 → kOverflow");
    Check(extreme.relative_width == 3.0e37f, "溢出时不改原值");
}

// ---------------------------------------------------------------------------
// D. 变速整数比
// ---------------------------------------------------------------------------
void TestSpeed() {
    std::printf("\n[D] ChqSpeed 整数比\n");
    cq::ChqRationalTime out;

    cq::ChqSpeed zero;
    zero.numerator = 0;
    Check(!zero.Validate().IsOk(), "numerator = 0 拒绝");
    cq::ChqSpeed neg;
    neg.denominator = -2;
    Check(!neg.Validate().IsOk(), "分母为负拒绝");

    const cq::ChqSpeed two_x{2, 1};
    Check(two_x.ApplyTo(Ms(5000), out).IsOk(), "2x 求占时成功");
    Check(cq::CompareRational(out, Ms(2500)) == 0, "占时 = 源时长 / speed = 2500ms");
    Check(cq::ChqSpeed{1, 2}.ApplyTo(Ms(5000), out).IsOk() &&
              cq::CompareRational(out, Ms(10000)) == 0,
          "0.5x → 10000ms");

    // 恒等比逐位等于源时长：不约分、不重定标（timescale 语义保持）
    Check(cq::ChqSpeed{1, 1}.ApplyTo(Ms(5000), out).IsOk() &&
              out.value == Ms(5000).value && out.timescale == Ms(5000).timescale,
          "1x 原样返回");

    // 奇数源时长：浮点倍速会引入舍入，整数比不会（红线 #4 的动机）
    const cq::ChqRationalTime odd(7, 3);  // 7/3 秒，二进制浮点表示不精确
    cq::ChqRationalTime slowed;
    Check(cq::ChqSpeed{3, 2}.ApplyTo(odd, slowed).IsOk(), "1.5x 作用于 7/3 秒");
    Check(cq::CompareRational(slowed, cq::ChqRationalTime(14, 9)) == 0, "结果 = 14/9 秒（精确）");
    cq::ChqRationalTime back;
    Check(cq::ChqSpeed{2, 3}.ApplyTo(slowed, back).IsOk() &&
              cq::CompareRational(back, odd) == 0,
          "反倍速再算一次回到 7/3 —— 变速可逆，浮点倍速做不到");

    Check(!two_x.ApplyTo(cq::ChqRationalTime(0, 120000), out).IsOk(), "源时长 0 拒绝");
    Check(!two_x.ApplyTo(cq::ChqRationalTime(5000, -1), out).IsOk(), "非法 timescale 拒绝");

    // 不设拍脑袋上界：域检查只管语义，乘算溢出由 ScaleRational 如实报
    Check(cq::ChqSpeed{1000000, 1}.Validate().IsOk(), "百万倍速过域检查（域只管正与语义）");
    Check(cq::ChqSpeed{1000000, 1}.ApplyTo(Ms(5000), out).code == cq::ChqStatusCode::kOverflow,
          "timescale 溢出 → kOverflow（不是伪装的 InvalidArgument）");

    Check(cq::ChqSpeed{2, 1}.Fingerprint() != cq::ChqSpeed{1, 2}.Fingerprint(),
          "指纹区分 2x 与 0.5x");
    Check(cq::ChqSpeed{2, 1}.Fingerprint() == cq::ChqSpeed{2, 1}.Fingerprint(), "同值同指纹");
}

// ---------------------------------------------------------------------------
// E. 关键帧袋
// ---------------------------------------------------------------------------
void TestKeyframes() {
    std::printf("\n[E] 关键帧数据槽\n");
    cq::ChqKeyframeList list;
    Check(list.Empty() && list.Size() == 0, "空表");
    Check(!list.Set(Ms(1000), cq::ChqPropertyBag()).IsOk(), "空袋拒绝（不留采不到的帧）");
    Check(!list.Set(cq::ChqRationalTime(0, 0), Bag("a", 1.0f)).IsOk(), "非法 timescale 拒绝");
    Check(!list.Set(cq::ChqRationalTime(-120, cq::kProjectTimeScale), Bag("a", 1.0f)).IsOk(),
          "负时刻（片段开始之前）拒绝");

    Check(list.Set(Ms(5000), Bag("scale", 2.0f)).IsOk(), "中段插入");
    Check(list.Set(Ms(1000), Bag("scale", 1.0f)).IsOk(), "更早时刻插入");
    Check(list.Set(Ms(9000), Bag("scale", 3.0f)).IsOk(), "更晚时刻插入");
    Check(list.Size() == 3, "三条帧");
    Check(list.Frames()[0].time == Ms(1000) && list.Frames()[1].time == Ms(5000) &&
              list.Frames()[2].time == Ms(9000),
          "升序不变量与插入顺序无关");

    const cq::ChqKeyframe* hit = list.Find(Ms(5000));
    Check(hit != nullptr, "Find 命中");
    float got = 0.0f;
    Check(hit != nullptr && hit->values.Find("scale") != nullptr &&
              hit->values.Find("scale")->AsFloat(got) && got == 2.0f,
          "命中的帧带原属性值");
    Check(list.Find(Ms(4000)) == nullptr, "Find 未命中返回空");

    Check(list.Set(Ms(5000), Bag("scale", 9.0f)).IsOk(), "同刻覆盖写成功");
    Check(list.Size() == 3, "覆盖写不增加条数");
    hit = list.Find(Ms(5000));
    Check(hit != nullptr && hit->values.Find("scale") != nullptr &&
              hit->values.Find("scale")->AsFloat(got) && got == 9.0f,
          "覆盖写后读到新值");

    const uint64_t fp = list.Fingerprint();
    cq::ChqKeyframeList rebuilt;
    Check(rebuilt.Set(Ms(9000), Bag("scale", 3.0f)).IsOk() &&
              rebuilt.Set(Ms(1000), Bag("scale", 1.0f)).IsOk() &&
              rebuilt.Set(Ms(5000), Bag("scale", 9.0f)).IsOk(),
          "乱序重建同样三条");
    Check(rebuilt.Fingerprint() == fp, "同一内容换个插入顺序 → 指纹相同");
    Check(rebuilt.Set(Ms(1000), Bag("scale", 1.5f)).IsOk() && rebuilt.Fingerprint() != fp,
          "改一帧属性 → 指纹变");

    Check(list.Erase(Ms(4000)).code == cq::ChqStatusCode::kIoNotFound,
          "删不存在的时刻 → kIoNotFound（与参数不对分码）");
    Check(list.Erase(Ms(9000)).IsOk(), "删除成功");
    Check(list.Size() == 2, "删后剩两条");
    list.Clear();
    Check(list.Empty(), "Clear 清空");
}

// ---------------------------------------------------------------------------
// F. 时间线写路径的校验与失败不动模型
// ---------------------------------------------------------------------------
void TestTimelineSpatial() {
    std::printf("\n[F] 时间线写路径校验\n");
    cq::ChqTimeline tl;
    uint64_t track_id = 0;
    Check(tl.AddTrack(cq::ChqTrackKind::kVideo, track_id).IsOk(), "建视频轨");

    cq::ChqClip bad = MakeClip(0, 5000);
    bad.transform.scale_x = std::nanf("");
    uint64_t out = 0;
    Check(!tl.InsertClip(track_id, bad, out).IsOk(), "NaN 缩放 → 插入被拒");
    Check(tl.Tracks()[0].clips.empty(), "失败后模型没动（不留半更新）");

    bad = MakeClip(0, 5000);
    bad.layer = cq::kLayerMax + 1;
    Check(!tl.InsertClip(track_id, bad, out).IsOk(), "layer 越上界 → 插入被拒");
    bad.layer = -1;
    Check(!tl.InsertClip(track_id, bad, out).IsOk(), "layer 负 → 插入被拒");

    bad = MakeClip(0, 5000);
    bad.speed = cq::ChqSpeed{0, 1};
    Check(!tl.InsertClip(track_id, bad, out).IsOk(), "speed 0 → 插入被拒");

    // 空袋在 Set 那一层就被拒（[E] 已锁），到不了 Clip 里 —— 这条换成
    // 正例：合法关键帧必须随片段一起存住（插入路径不许悄悄丢掉别处建好的数据）。
    bad = MakeClip(0, 5000);
    Check(bad.keyframes.Set(Ms(1000), Bag("opacity", 0.5f)).IsOk(), "夹具关键帧写入成功");
    Check(tl.InsertClip(track_id, bad, out).IsOk() && out != 0, "带关键帧的片段插入成功");
    Check(tl.FindClip(out) != nullptr && tl.FindClip(out)->keyframes.Size() == 1,
          "插入后关键帧还在（没被拷贝路径吞掉）");

    cq::ChqClip ok = MakeClip(6000, 5000);  // 避开上一段占的 0~5000（同轨重叠是合法拒绝）
    ok.transform.translate_x = 0.25f;
    ok.layer = 7;
    Check(tl.InsertClip(track_id, ok, out).IsOk() && out != 0, "合法字段插入成功");
    const cq::ChqClip* stored = tl.FindClip(out);
    Check(stored != nullptr && stored->transform.translate_x == 0.25f && stored->layer == 7,
          "字段按值存住（没被默认值覆盖）");

    Check(!tl.SetClipTransform(9999, cq::ChqTransform()).IsOk(), "clip 不存在 → 拒绝");
    Check(!tl.SetClipLayer(out, cq::kLayerMax + 1).IsOk(), "layer 越界 → 拒绝");
    Check(!tl.SetClipSpeed(out, cq::ChqSpeed{-3, 1}).IsOk(), "负倍速 → 拒绝");
    Check(tl.FindClip(out)->layer == 7, "被拒的 setter 没改模型");

    cq::ChqTransform t;
    t.scale_y = 2.0f;
    Check(tl.SetClipTransform(out, t).IsOk(), "SetClipTransform 成功");
    Check(tl.FindClip(out)->transform.scale_y == 2.0f, "写进去读得到");
    Check(tl.SetClipLayer(out, 3).IsOk() && tl.FindClip(out)->layer == 3, "SetClipLayer 生效");
    Check(tl.SetClipSpeed(out, cq::ChqSpeed{2, 1}).IsOk() &&
              tl.FindClip(out)->speed.numerator == 2,
          "SetClipSpeed 生效");
    Check(tl.SetTrackTransform(track_id, t).IsOk() &&
              tl.FindTrack(track_id)->transform.scale_y == 2.0f,
          "SetTrackTransform 生效");
    Check(!tl.SetTrackTransform(9999, cq::ChqTransform()).IsOk(), "轨不存在 → 拒绝");
    Check(!tl.SetTrackTransform(track_id, Scaled(-1.0f)).IsOk(), "非法 transform → 拒绝");

    Check(tl.SetClipKeyframe(out, Ms(1000), Bag("opacity", 0.5f)).IsOk(), "写关键帧");
    Check(!tl.SetClipKeyframe(out, Ms(1000), cq::ChqPropertyBag()).IsOk(),
          "空袋经时间线路径同样被拒");
    Check(tl.EraseClipKeyframe(out, Ms(2000)).code == cq::ChqStatusCode::kIoNotFound,
          "删不存在的帧 → kIoNotFound");
    Check(!tl.EraseClipKeyframe(9999, Ms(1000)).IsOk(), "clip 不存在 → 非 Ok");

    // ReplaceClip 过同一道校验（三条插入路径口径一致）
    cq::ChqClip rep = *tl.FindClip(out);
    rep.duration = Ms(6000);
    Check(tl.ReplaceClip(rep).IsOk(), "ReplaceClip 接受合法 transform");
    rep.transform.rotation_degrees = 1080.0f;
    Check(!tl.ReplaceClip(rep).IsOk(), "ReplaceClip 拒越界旋转");
    Check(tl.FindClip(out)->duration == Ms(6000),
          "被拒的 Replace 没动模型（时长停在上一次成功的 6000）");

    // RestoreClip / RestoreTrack 同样拦：Command 回放不许开后门
    cq::ChqClip rc = MakeClip(20000, 1000);
    rc.id = 777;
    Check(tl.RestoreClip(track_id, rc).IsOk(), "RestoreClip 合法片段成功");
    rc.id = 778;
    rc.layer = 5000;
    Check(!tl.RestoreClip(track_id, rc).IsOk(), "RestoreClip 拒越界 layer");
    cq::ChqTrack bt;
    bt.id = 888;
    bt.transform.opacity = 2.0f;
    Check(!tl.RestoreTrack(bt).IsOk(), "RestoreTrack 拒非法轨级 transform");
}

// ---------------------------------------------------------------------------
// G. 命令往返与深往返
// ---------------------------------------------------------------------------
void TestCommands() {
    std::printf("\n[G] 六条命令 Do/Undo/Redo\n");
    cq::ChqTimeline tl;
    const uint64_t clip_id = MakeOneClipTimeline(tl);
    const uint64_t track_id = tl.Tracks()[0].id;

    cq::ChqCommandHistory hist;
    cq::ChqTransform t;
    t.translate_x = 0.4f;
    t.rotation_degrees = 90.0f;
    t.mirror = cq::ChqMirrorKind::kHorizontal;
    Check(tl.FindClip(clip_id)->transform.IsIdentity(), "起点：恒等");
    Check(hist.Execute(std::make_unique<cq::ChqSetClipTransformCommand>(clip_id, t), tl).IsOk(),
          "Do set-clip-transform");
    Check(!tl.FindClip(clip_id)->transform.IsIdentity(), "Do 之后不再恒等");
    Check(hist.Undo(tl).IsOk() && tl.FindClip(clip_id)->transform.IsIdentity(),
          "Undo 回到恒等（原值逐字段还原）");
    Check(hist.Redo(tl).IsOk() && tl.FindClip(clip_id)->transform.rotation_degrees == 90.0f,
          "Redo 重放新值");

    Check(hist.Execute(std::make_unique<cq::ChqSetClipLayerCommand>(clip_id, 42), tl).IsOk(),
          "Do set-clip-layer");
    Check(hist.Undo(tl).IsOk() && tl.FindClip(clip_id)->layer == cq::kLayerMin,
          "Undo layer 回默认");

    Check(hist
              .Execute(std::make_unique<cq::ChqSetClipSpeedCommand>(clip_id, cq::ChqSpeed{3, 2}),
                       tl)
              .IsOk(),
          "Do set-clip-speed 3/2");
    Check(tl.FindClip(clip_id)->speed.denominator == 2, "speed 写进模型");
    Check(hist.Undo(tl).IsOk() && tl.FindClip(clip_id)->speed == cq::ChqSpeed{1, 1},
          "Undo speed 回 1:1");

    Check(hist.Execute(std::make_unique<cq::ChqSetTrackTransformCommand>(track_id, t), tl).IsOk(),
          "Do set-track-transform");
    Check(hist.Undo(tl).IsOk() && tl.FindTrack(track_id)->transform.IsIdentity(),
          "Undo 轨级 transform 回恒等");

    // 关键帧：原先没帧 → Undo 必须擦干净，不留空帧
    Check(hist
              .Execute(std::make_unique<cq::ChqSetClipKeyframeCommand>(clip_id, Ms(2000),
                                                                       Bag("scale", 1.0f)),
                       tl)
              .IsOk(),
          "Do set-clip-keyframe（新建）");
    Check(hist.Undo(tl).IsOk() && tl.FindClip(clip_id)->keyframes.Empty(),
          "Undo 新建关键帧 → 擦除（无幽灵空帧）");
    Check(hist.Redo(tl).IsOk() && tl.FindClip(clip_id)->keyframes.Size() == 1, "Redo 重新写入");

    // 同刻已有帧 → Undo 写回原袋
    Check(hist
              .Execute(std::make_unique<cq::ChqSetClipKeyframeCommand>(clip_id, Ms(2000),
                                                                       Bag("scale", 5.0f)),
                       tl)
              .IsOk(),
          "Do set-clip-keyframe（覆盖）");
    Check(hist.Undo(tl).IsOk() && tl.FindClip(clip_id)->keyframes.Size() == 1,
          "Undo 覆盖 → 仍只一条帧");
    float got = 0.0f;
    const cq::ChqPropertyValue* old_value =
        tl.FindClip(clip_id)->keyframes.Find(Ms(2000))->values.Find("scale");
    Check(old_value != nullptr && old_value->AsFloat(got) && got == 1.0f,
          "回到的确实是 1.0 而不是 5.0");

    Check(hist.Execute(std::make_unique<cq::ChqEraseClipKeyframeCommand>(clip_id, Ms(2000)), tl)
              .IsOk(),
          "Do erase-clip-keyframe");
    Check(hist.Undo(tl).IsOk() && tl.FindClip(clip_id)->keyframes.Size() == 1,
          "Undo 删除 → 帧带原值回来");
    Check(hist.Redo(tl).IsOk() && tl.FindClip(clip_id)->keyframes.Empty(), "Redo 再删一次");

    // 失败语义：删不存在的帧 → 不入栈
    const std::size_t depth = hist.UndoDepth();
    Check(!hist.Execute(std::make_unique<cq::ChqEraseClipKeyframeCommand>(clip_id, Ms(8000)), tl)
               .IsOk(),
          "删不存在的帧 → 失败");
    Check(hist.UndoDepth() == depth, "失败不入栈");

    // 深往返：20 轮（变换 + 改比例），全撤销后 digest 与 relative 逐位回初始态
    cq::ChqEditorModelState state;
    uint64_t s_track = 0;
    uint64_t s_clip = 0;
    Check(state.timeline().AddTrack(cq::ChqTrackKind::kVideo, s_track).IsOk(), "state 建轨");
    cq::ChqClip seed = MakeClip(0, 5000);
    seed.transform.relative_width = 0.3f;
    seed.transform.relative_height = 0.3f;
    Check(state.timeline().InsertClip(s_track, seed, s_clip).IsOk(),
          "state 建片段（relative 0.3）");
    const uint64_t fp0 = state.Digest();
    const float rel0 = state.timeline().FindClip(s_clip)->transform.relative_width;
    for (int round = 0; round < 20; ++round) {
        cq::ChqTransform next;
        next.translate_y = static_cast<float>(round) * 0.01f;
        Check(state.Execute(std::make_unique<cq::ChqSetClipTransformCommand>(s_clip, next)).IsOk(),
              "深往返：设 transform");
        Check(state.Execute(std::make_unique<cq::ChqSetCanvasCommand>(
                                round % 2 == 0 ? 720 : 1080, round % 2 == 0 ? 1280 : 1920))
                  .IsOk(),
              "深往返：改画布比例");
    }
    for (int i = 0; i < 40; ++i) {
        if (!state.Undo().IsOk()) {
            Check(false, "深往返：Undo 失败");
            break;
        }
    }
    Check(state.Digest() == fp0, "40 次 Undo 后 digest 逐位回初始态");
    Check(state.timeline().FindClip(s_clip)->transform.relative_width == rel0,
          "relative 逐位回初始值（靠留档，不靠反比重算）");
}

// ---------------------------------------------------------------------------
// H. digest 覆盖 + 分割分箱
// ---------------------------------------------------------------------------
void TestDigestAndSplit() {
    std::printf("\n[H] digest 覆盖四组新字段 + 分割分箱\n");
    cq::ChqEditorModelState state;
    uint64_t track_id = 0;
    uint64_t clip_id = 0;
    Check(state.timeline().AddTrack(cq::ChqTrackKind::kVideo, track_id).IsOk(), "建轨");
    Check(state.timeline().InsertClip(track_id, MakeClip(0, 10000), clip_id).IsOk(), "建片段");
    const uint64_t d0 = state.Digest();

    cq::ChqTransform t;
    t.scale_x = 1.5f;
    Check(state.Execute(std::make_unique<cq::ChqSetClipTransformCommand>(clip_id, t)).IsOk(),
          "改 transform");
    const uint64_t d1 = state.Digest();
    Check(d1 != d0, "transform → digest 变（漏字段就是假阴性）");

    Check(state.Execute(std::make_unique<cq::ChqSetClipLayerCommand>(clip_id, 9)).IsOk(),
          "改 layer");
    const uint64_t d2 = state.Digest();
    Check(d2 != d1, "layer → digest 变");

    Check(state.Execute(std::make_unique<cq::ChqSetClipSpeedCommand>(clip_id, cq::ChqSpeed{2, 1}))
              .IsOk(),
          "改 speed");
    const uint64_t d3 = state.Digest();
    Check(d3 != d2, "speed → digest 变");

    Check(state.Execute(std::make_unique<cq::ChqSetClipKeyframeCommand>(
                            clip_id, Ms(1000), Bag("opacity", 0.5f)))
              .IsOk(),
          "写关键帧");
    const uint64_t d4 = state.Digest();
    Check(d4 != d3, "keyframes → digest 变");

    Check(state.Execute(std::make_unique<cq::ChqSetClipKeyframeCommand>(
                            clip_id, Ms(1000), Bag("opacity", 0.5f)))
              .IsOk(),
          "同值再写一次");
    Check(state.Digest() == d4, "同值 set：digest 不变（内容指纹语义）");

    Check(state.Execute(std::make_unique<cq::ChqSetTrackTransformCommand>(track_id, t)).IsOk(),
          "改轨级 transform");
    Check(state.Digest() != d4, "轨级 transform → digest 变");

    // layer 是叠放整数，不是排序键：模型侧数组顺序仍只由 start 决定
    Check(state.timeline().Tracks()[0].clips.size() == 1, "改 layer 不新增、不重排片段");

    // 分割：关键帧按切点分箱（局部时间重基）
    cq::ChqTimeline tl;
    uint64_t tid = 0;
    Check(tl.AddTrack(cq::ChqTrackKind::kVideo, tid).IsOk(), "分割用建轨");
    uint64_t cid = 0;
    Check(tl.InsertClip(tid, MakeClip(0, 10000), cid).IsOk(), "分割用建片段");
    Check(tl.SetClipKeyframe(cid, Ms(2000), Bag("scale", 1.0f)).IsOk(), "帧 @2000");
    Check(tl.SetClipKeyframe(cid, Ms(5000), Bag("scale", 2.0f)).IsOk(), "帧 @5000（切点）");
    Check(tl.SetClipKeyframe(cid, Ms(8000), Bag("scale", 3.0f)).IsOk(), "帧 @8000");
    uint64_t right_id = 0;
    Check(tl.SplitClip(cid, Ms(5000), right_id).IsOk(), "在 @5000 分割");

    const cq::ChqClip* left = tl.FindClip(cid);
    const cq::ChqClip* right = tl.FindClip(right_id);
    Check(left != nullptr && left->keyframes.Size() == 2, "左半留 @2000 与切点 @5000");
    Check(right != nullptr && right->keyframes.Size() == 2, "右半留切点与 @8000（重基后）");
    if (left != nullptr && right != nullptr) {
        Check(left->keyframes.Find(Ms(2000)) != nullptr &&
                  left->keyframes.Find(Ms(8000)) == nullptr,
              "左半不再带超出自身时长的尾帧");
        Check(right->keyframes.Find(Ms(0)) != nullptr &&
                  right->keyframes.Find(Ms(3000)) != nullptr,
              "右半时刻已重基到右半起点（5000→0，8000→3000）");
        float lv = 0.0f;
        float rv = 0.0f;
        Check(left->keyframes.Find(Ms(5000))->values.Find("scale")->AsFloat(lv) &&
                  right->keyframes.Find(Ms(0))->values.Find("scale")->AsFloat(rv) && lv == rv &&
                  lv == 2.0f,
              "切点那一帧两侧同值 → 分完画面不跳");
        Check(right->transform == left->transform && right->layer == left->layer &&
                  right->speed == left->speed,
              "transform / layer / speed 两半各自继承（它们不是时间量，不重基）");
    }
}

}  // namespace

int main() {
    std::printf("== 空间 / 层级 / 变速 / 关键帧单测（MODEL-004 / B5.5）==\n");
    TestDefaults();
    TestTransformValidate();
    TestRelativeRescale();
    TestSpeed();
    TestKeyframes();
    TestTimelineSpatial();
    TestCommands();
    TestDigestAndSplit();
    std::printf("\n== %d checks, %d failures ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
