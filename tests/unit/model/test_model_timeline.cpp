// ChuanqiCut — 时间线数据模型单测（MODEL-001）
//
// 验收对应 BACKLOG「模型覆盖多轨 / 转场」：
//   * 多轨：视频轨 + 音频轨共存，跨轨重叠允许（多轨合成的意义）
//   * 同轨重叠被拒绝（语义含糊，干脆不允许）
//   * 转场挂在 clip 边界且计入总时长
//   * 命中测试：给定时刻能找到覆盖它的片段
//
// 断言用 Check() 而非 assert：assert 在 Release（NDEBUG）下会被编译器整个吃掉，
// 那样 CTest 会"全绿但什么都没测" —— 本项目踩过这类假绿灯。

#include <cstdio>

#include "cq/base/chq_status.h"
#include "cq/base/chq_rational_time.h"
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

// 毫秒 → 项目时间刻度（timescale = 120000，即 1ms = 120 ticks）
cq::ChqRationalTime Ms(int64_t ms) {
    return cq::ChqRationalTime(ms * 120, cq::kProjectTimeScale);
}

cq::ChqClip MakeClip(cq::ChqClipKind kind, int64_t start_ms, int64_t dur_ms) {
    cq::ChqClip c;
    c.kind = kind;
    c.source.asset_id = 1;
    c.source.source_in = Ms(0);
    c.source.source_duration = Ms(dur_ms);
    c.start = Ms(start_ms);
    c.duration = Ms(dur_ms);
    return c;
}

// ---------------------------------------------------------------------------

void TestMultiTrack() {
    cq::ChqTimeline tl;
    uint64_t video_track = 0, audio_track = 0;

    Check(tl.AddTrack(cq::ChqTrackKind::kVideo, video_track).IsOk(), "创建视频轨");
    Check(tl.AddTrack(cq::ChqTrackKind::kAudio, audio_track).IsOk(), "创建音频轨");
    Check(video_track != audio_track, "轨道 id 唯一");
    Check(tl.Tracks().size() == 2, "时间线持有两条轨道");

    const cq::ChqTrack* vt = tl.FindTrack(video_track);
    Check(vt != nullptr && vt->kind == cq::ChqTrackKind::kVideo, "可按 id 取回视频轨");

    Check(!tl.RemoveTrack(9999).IsOk(), "删除不存在的轨道返回错误");
    Check(tl.RemoveTrack(audio_track).IsOk(), "删除音频轨");
    Check(tl.Tracks().size() == 1, "删除后只剩一条轨道");
}

void TestOverlapRules() {
    cq::ChqTimeline tl;
    uint64_t vt = 0, at = 0;
    tl.AddTrack(cq::ChqTrackKind::kVideo, vt);
    tl.AddTrack(cq::ChqTrackKind::kAudio, at);

    uint64_t c1 = 0;
    Check(tl.InsertClip(vt, MakeClip(cq::ChqClipKind::kVideo, 0, 1000), c1).IsOk(),
          "插入 0–1s 视频片段");

    // 同轨重叠 → 拒绝
    uint64_t dummy = 0;
    Check(!tl.InsertClip(vt, MakeClip(cq::ChqClipKind::kVideo, 500, 1000), dummy).IsOk(),
          "同轨重叠被拒绝（0.5–1.5s 与 0–1s 相交）");

    // 同轨首尾相接 → 允许（半开区间）
    uint64_t c2 = 0;
    Check(tl.InsertClip(vt, MakeClip(cq::ChqClipKind::kVideo, 1000, 1000), c2).IsOk(),
          "同轨首尾相接允许（1–2s 紧接 0–1s）");

    // 跨轨重叠 → 允许（这才是多轨）
    uint64_t a1 = 0;
    Check(tl.InsertClip(at, MakeClip(cq::ChqClipKind::kAudio, 0, 5000), a1).IsOk(),
          "跨轨重叠允许（音频 0–5s 覆盖视频轨）");

    // 类型不匹配 → 拒绝
    uint64_t bad = 0;
    Check(!tl.InsertClip(vt, MakeClip(cq::ChqClipKind::kAudio, 3000, 1000), bad).IsOk(),
          "音频片段放进视频轨被拒绝");

    // 零时长 → 拒绝
    uint64_t zero = 0;
    Check(!tl.InsertClip(vt, MakeClip(cq::ChqClipKind::kVideo, 5000, 0), zero).IsOk(),
          "零时长片段被拒绝");

    Check(tl.FindTrack(vt)->clips.size() == 2, "视频轨最终两个片段");
}

void TestHitTest() {
    cq::ChqTimeline tl;
    uint64_t vt = 0;
    tl.AddTrack(cq::ChqTrackKind::kVideo, vt);
    uint64_t c1 = 0, c2 = 0;
    tl.InsertClip(vt, MakeClip(cq::ChqClipKind::kVideo, 0, 1000), c1);    // 0–1s
    tl.InsertClip(vt, MakeClip(cq::ChqClipKind::kVideo, 1000, 1000), c2); // 1–2s

    const cq::ChqClip* hit = tl.FindClipAt(vt, Ms(500));
    Check(hit != nullptr && hit->id == c1, "0.5s 命中第一个片段");

    hit = tl.FindClipAt(vt, Ms(1000));
    Check(hit != nullptr && hit->id == c2, "1.0s 边界归属后一个片段（半开区间）");

    hit = tl.FindClipAt(vt, Ms(1500));
    Check(hit != nullptr && hit->id == c2, "1.5s 命中第二个片段");

    Check(tl.FindClipAt(vt, Ms(2500)) == nullptr, "2.5s 无片段（超出时间线）");
    Check(tl.FindClipAt(9999, Ms(500)) == nullptr, "轨道不存在时返回空");
}

void TestDurationAndTransition() {
    cq::ChqTimeline tl;
    uint64_t vt = 0, at = 0;
    tl.AddTrack(cq::ChqTrackKind::kVideo, vt);
    tl.AddTrack(cq::ChqTrackKind::kAudio, at);

    uint64_t ignored = 0;
    tl.InsertClip(vt, MakeClip(cq::ChqClipKind::kVideo, 0, 2000), ignored);  // 0–2s
    tl.InsertClip(at, MakeClip(cq::ChqClipKind::kAudio, 0, 5000), ignored);  // 0–5s

    // 总时长取所有轨道的最大值（音频轨更长）
    Check(tl.Duration().value == Ms(5000).value, "总时长取最大轨道结束时刻（5s）");

    // 转场计入总时长：给音频轨加 1s 出转场 → 6s
    uint64_t at2 = 0;
    tl.AddTrack(cq::ChqTrackKind::kAudio, at2);
    cq::ChqClip with_trans = MakeClip(cq::ChqClipKind::kAudio, 0, 5000);
    with_trans.out_transition = cq::ChqTransitionKind::kCrossFade;
    with_trans.transition_duration = Ms(1000);
    uint64_t tc = 0;
    Check(tl.InsertClip(at2, with_trans, tc).IsOk(), "插入带出转场的片段");
    Check(tl.Duration().value == Ms(6000).value, "出转场时长计入总时长（5s + 1s = 6s）");

    // 空时间线
    cq::ChqTimeline empty;
    Check(empty.Duration().value == 0, "空时间线时长为 0");
}

void TestEditOperations() {
    cq::ChqTimeline tl;
    uint64_t vt = 0;
    tl.AddTrack(cq::ChqTrackKind::kVideo, vt);
    uint64_t c1 = 0, c2 = 0;
    tl.InsertClip(vt, MakeClip(cq::ChqClipKind::kVideo, 0, 1000), c1);    // 0–1s
    tl.InsertClip(vt, MakeClip(cq::ChqClipKind::kVideo, 1000, 1000), c2); // 1–2s

    // 移动：撞上邻居 → 拒绝
    Check(!tl.MoveClip(c1, Ms(500)).IsOk(), "移动到与邻居重叠的位置被拒绝");
    // 移动：原地 → 允许（不能把自己算成重叠）
    Check(tl.MoveClip(c1, Ms(0)).IsOk(), "原地移动允许（排除自身）");
    // 移动：整体右移（先移后面的）
    Check(tl.MoveClip(c2, Ms(3000)).IsOk(), "移动第二个片段到 3s");
    Check(tl.MoveClip(c1, Ms(2000)).IsOk(), "第一个片段随之移到 2s");
    Check(tl.Duration().value == Ms(4000).value, "移动后总时长 4s");

    // 修剪：延长到撞上邻居 → 拒绝；缩短 → 允许
    Check(!tl.TrimClip(c1, Ms(2000)).IsOk(), "修剪到与邻居重叠被拒绝");
    Check(tl.TrimClip(c1, Ms(1000)).IsOk(), "修剪为 1s 允许");
    Check(!tl.TrimClip(c1, Ms(0)).IsOk(), "修剪为零时长被拒绝");

    // 删除
    Check(tl.RemoveClip(c2).IsOk(), "删除第二个片段");
    Check(tl.FindClip(c2) == nullptr, "删除后查不到");
    Check(tl.FindTrack(vt)->clips.size() == 1, "轨道只剩一个片段");
    Check(!tl.RemoveClip(9999).IsOk(), "删除不存在的片段返回错误");
}

// ---------------------------------------------------------------------------
// EDIT-007：分割
// ---------------------------------------------------------------------------

void TestSplitClip() {
    cq::ChqTimeline tl;
    uint64_t vt = 0;
    tl.AddTrack(cq::ChqTrackKind::kVideo, vt);
    uint64_t cid = 0;
    tl.InsertClip(vt, MakeClip(cq::ChqClipKind::kVideo, 1000, 5000), cid);

    // 边界与缺失：切在 start / end 上无意义；不存在的片段不可切
    uint64_t sink = 0;
    Check(!tl.SplitClip(cid, Ms(1000), sink).IsOk(), "切在 start 边界被拒绝");
    Check(!tl.SplitClip(cid, Ms(6000), sink).IsOk(), "切在 end 边界被拒绝");
    Check(!tl.SplitClip(9999, Ms(3000), sink).IsOk(), "不存在的片段不可切");
    Check(tl.FindTrack(vt)->clips.size() == 1, "失败不产生半切状态");

    // 正常分割：左半保 id 收缩，右半新 id 且媒体引用联动
    uint64_t right_id = 0;
    Check(tl.SplitClip(cid, Ms(3000), right_id).IsOk(), "分割成功");
    Check(right_id != cid && right_id != 0, "右半获得新 id");

    const cq::ChqClip* left = tl.FindClip(cid);
    Check(left != nullptr && left->duration == Ms(2000), "左半收缩为 [start, at)");
    Check(left->out_transition == cq::ChqTransitionKind::kNone, "左半出转场作废");

    const cq::ChqClip* right = tl.FindClip(right_id);
    Check(right != nullptr, "右半可命中");
    Check(right->start == Ms(3000) && right->duration == Ms(3000), "右半占据 [at, end)");
    Check(right->source.source_in == Ms(2000), "右半 source_in 推进 Δ");
    Check(right->source.source_duration == Ms(3000), "右半 source_duration 收缩 Δ");
    Check(right->in_transition == cq::ChqTransitionKind::kNone, "右半入转场作废");
    Check(tl.FindTrack(vt)->clips.size() == 2, "分割后轨内两个片段");
    Check(tl.Duration().value == Ms(6000).value, "分割不改变总时长");

    // 分割后再插入新片段：id 仍唯一（next_id 单调推进）
    uint64_t fresh = 0;
    Check(tl.InsertClip(vt, MakeClip(cq::ChqClipKind::kVideo, 10000, 1000), fresh).IsOk(),
          "分割后仍可插入");
    Check(fresh != cid && fresh != right_id, "新插入 id 与两半都不冲突");

    // 邻居共存：A [0,5s) 与 B [5s,10s)，分割 A 不与 B 冲突
    cq::ChqTimeline tl2;
    uint64_t t2 = 0, a = 0, b = 0, a2 = 0;
    tl2.AddTrack(cq::ChqTrackKind::kVideo, t2);
    tl2.InsertClip(t2, MakeClip(cq::ChqClipKind::kVideo, 0, 5000), a);
    tl2.InsertClip(t2, MakeClip(cq::ChqClipKind::kVideo, 5000, 5000), b);
    Check(tl2.SplitClip(a, Ms(2000), a2).IsOk(), "有邻居时分割成功");
    Check(tl2.FindClip(a2) != nullptr && tl2.FindClip(a2)->duration == Ms(3000),
          "右半与原邻居首尾相接不判重叠");
}

// ---------------------------------------------------------------------------
// EDIT-008 模型基座：ReplaceClip（原位整体替换）
// ---------------------------------------------------------------------------

void TestReplaceClip() {
    cq::ChqTimeline tl;
    uint64_t vt = 0;
    tl.AddTrack(cq::ChqTrackKind::kVideo, vt);
    uint64_t c1 = 0, c2 = 0;
    tl.InsertClip(vt, MakeClip(cq::ChqClipKind::kVideo, 1000, 4000), c1);  // 1–5s
    tl.InsertClip(vt, MakeClip(cq::ChqClipKind::kVideo, 6000, 2000), c2);  // 6–8s

    // 左缘裁剪形态：start 1s→2s、source_in 0→1s、duration 4s→3s（右缘 5s 不动）
    cq::ChqClip reclip = *tl.FindClip(c1);
    reclip.start = Ms(2000);
    reclip.source.source_in = Ms(1000);
    reclip.duration = Ms(3000);
    Check(tl.ReplaceClip(reclip).IsOk(), "左缘裁剪形态的替换成功");
    const cq::ChqClip* after = tl.FindClip(c1);
    Check(after->start == Ms(2000) && after->duration == Ms(3000) &&
          after->source.source_in == Ms(1000), "三字段联动生效");
    Check(tl.FindTrack(vt)->clips.size() == 2, "替换不改变片段数");

    // 替换为与邻居重叠 → 拒绝（排除自身判定）
    cq::ChqClip overlap = *tl.FindClip(c1);
    overlap.start = Ms(5000);
    overlap.duration = Ms(3000);  // 5–8s，撞上 c2
    Check(!tl.ReplaceClip(overlap).IsOk(), "替换后与邻居重叠被拒绝");

    // 非法值：零时长 / 负 source_in / 不存在的 id / kind 不匹配
    cq::ChqClip zero = *tl.FindClip(c1);
    zero.duration = Ms(0);
    Check(!tl.ReplaceClip(zero).IsOk(), "零时长被拒绝");
    cq::ChqClip negative = *tl.FindClip(c1);
    negative.source.source_in.value = -120;
    Check(!tl.ReplaceClip(negative).IsOk(), "负 source_in 被拒绝");
    cq::ChqClip ghost = *tl.FindClip(c1);
    ghost.id = 9999;
    Check(!tl.ReplaceClip(ghost).IsOk(), "不存在的 id 被拒绝");
    cq::ChqClip wrong_kind = *tl.FindClip(c1);
    wrong_kind.kind = cq::ChqClipKind::kAudio;
    Check(!tl.ReplaceClip(wrong_kind).IsOk(), "kind 与轨道不匹配被拒绝");

    // start 变化的替换维持轨内按 start 升序
    cq::ChqClip reorder = *tl.FindClip(c1);
    reorder.start = Ms(9000);  // 移到 c2 之后（8s 结束，不重叠）
    reorder.duration = Ms(1000);
    Check(tl.ReplaceClip(reorder).IsOk(), "替换可移动 start");
    bool sorted = true;
    int64_t prev = -1;
    for (const cq::ChqClip& c : tl.FindTrack(vt)->clips) {
        if (c.start.value < prev) sorted = false;
        prev = c.start.value;
    }
    Check(sorted, "替换后仍按 start 升序");
}

// ---------------------------------------------------------------------------
// UIA-040：画布属性 + 跨轨移动
// ---------------------------------------------------------------------------

void TestCanvasAndCrossTrack() {
    cq::ChqTimeline tl;
    uint64_t vt = 0, vt2 = 0, at = 0;
    tl.AddTrack(cq::ChqTrackKind::kVideo, vt);
    tl.AddTrack(cq::ChqTrackKind::kVideo, vt2);
    tl.AddTrack(cq::ChqTrackKind::kAudio, at);
    uint64_t c1 = 0;
    tl.InsertClip(vt, MakeClip(cq::ChqClipKind::kVideo, 0, 4000), c1);

    // ---- 画布：默认 9:16，合法改写，越界拒绝 ----
    Check(tl.CanvasWidth() == 1080 && tl.CanvasHeight() == 1920, "默认画布 1080×1920");
    Check(tl.SetCanvas(1920, 1080).IsOk(), "画布改 16:9");
    Check(tl.CanvasWidth() == 1920 && tl.CanvasHeight() == 1080, "画布生效");
    Check(!tl.SetCanvas(0, 1080).IsOk(), "宽 0 被拒绝");
    Check(!tl.SetCanvas(8193, 1080).IsOk(), "宽超上界被拒绝");
    Check(tl.CanvasWidth() == 1920, "拒绝后画布不动");

    // ---- 跨轨移动：同类型轨成功，id 不变 ----
    Check(tl.MoveClipToTrack(c1, vt2, Ms(1000)).IsOk(), "跨轨移动成功");
    const cq::ChqClip* moved = tl.FindClip(c1);
    Check(moved != nullptr && moved->start == Ms(1000), "片段 id 不变、新起点生效");
    Check(tl.FindTrack(vt)->clips.empty(), "源轨已空");
    Check(tl.FindTrack(vt2)->clips.size() == 1, "目标轨收到片段");

    // ---- 拒绝矩阵：目标轨缺失 / 类型不匹配 / 目标轨重叠 / 不存在的片段 ----
    Check(!tl.MoveClipToTrack(c1, 9999, Ms(0)).IsOk(), "目标轨不存在被拒");
    Check(!tl.MoveClipToTrack(c1, at, Ms(0)).IsOk(), "视频片段上音频轨被拒");
    uint64_t c2 = 0;
    tl.InsertClip(vt2, MakeClip(cq::ChqClipKind::kVideo, 5000, 2000), c2);
    Check(!tl.MoveClipToTrack(c2, vt2, Ms(1000)).IsOk(), "目标轨与 c1 重叠被拒");
    Check(!tl.MoveClipToTrack(9999, vt, Ms(0)).IsOk(), "不存在的片段被拒");
    Check(tl.FindTrack(vt2)->clips.size() == 2, "拒绝不改模型");

    // ---- 同轨移动经同一入口（排除自身语义）----
    Check(tl.MoveClipToTrack(c2, vt2, Ms(9000)).IsOk(), "同轨移动允许");
    Check(tl.FindClip(c2)->start == Ms(9000), "同轨移动生效");

    // ---- 跨轨后总时长与有序性保持 ----
    bool sorted = true;
    int64_t prev = -1;
    for (const cq::ChqClip& c : tl.FindTrack(vt2)->clips) {
        if (c.start.value < prev) sorted = false;
        prev = c.start.value;
    }
    Check(sorted, "跨轨插入维持目标轨 start 升序");
}

}  // namespace

int main() {
    TestMultiTrack();
    TestOverlapRules();
    TestHitTest();
    TestDurationAndTransition();
    TestEditOperations();
    TestSplitClip();
    TestReplaceClip();
    TestCanvasAndCrossTrack();

    std::printf("\n%s: %d checks, %d failures\n", g_failures == 0 ? "PASSED" : "FAILED",
                g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
