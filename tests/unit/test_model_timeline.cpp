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

#include "cq/base/status.h"
#include "cq/base/rational_time.h"
#include "cq/model/timeline.h"

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
cq::RationalTime Ms(int64_t ms) {
    return cq::RationalTime(ms * 120, cq::kProjectTimeScale);
}

cq::Clip MakeClip(cq::ClipKind kind, int64_t start_ms, int64_t dur_ms) {
    cq::Clip c;
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
    cq::Timeline tl;
    uint64_t video_track = 0, audio_track = 0;

    Check(tl.AddTrack(cq::TrackKind::kVideo, video_track).IsOk(), "创建视频轨");
    Check(tl.AddTrack(cq::TrackKind::kAudio, audio_track).IsOk(), "创建音频轨");
    Check(video_track != audio_track, "轨道 id 唯一");
    Check(tl.Tracks().size() == 2, "时间线持有两条轨道");

    const cq::Track* vt = tl.FindTrack(video_track);
    Check(vt != nullptr && vt->kind == cq::TrackKind::kVideo, "可按 id 取回视频轨");

    Check(!tl.RemoveTrack(9999).IsOk(), "删除不存在的轨道返回错误");
    Check(tl.RemoveTrack(audio_track).IsOk(), "删除音频轨");
    Check(tl.Tracks().size() == 1, "删除后只剩一条轨道");
}

void TestOverlapRules() {
    cq::Timeline tl;
    uint64_t vt = 0, at = 0;
    tl.AddTrack(cq::TrackKind::kVideo, vt);
    tl.AddTrack(cq::TrackKind::kAudio, at);

    uint64_t c1 = 0;
    Check(tl.InsertClip(vt, MakeClip(cq::ClipKind::kVideo, 0, 1000), c1).IsOk(),
          "插入 0–1s 视频片段");

    // 同轨重叠 → 拒绝
    uint64_t dummy = 0;
    Check(!tl.InsertClip(vt, MakeClip(cq::ClipKind::kVideo, 500, 1000), dummy).IsOk(),
          "同轨重叠被拒绝（0.5–1.5s 与 0–1s 相交）");

    // 同轨首尾相接 → 允许（半开区间）
    uint64_t c2 = 0;
    Check(tl.InsertClip(vt, MakeClip(cq::ClipKind::kVideo, 1000, 1000), c2).IsOk(),
          "同轨首尾相接允许（1–2s 紧接 0–1s）");

    // 跨轨重叠 → 允许（这才是多轨）
    uint64_t a1 = 0;
    Check(tl.InsertClip(at, MakeClip(cq::ClipKind::kAudio, 0, 5000), a1).IsOk(),
          "跨轨重叠允许（音频 0–5s 覆盖视频轨）");

    // 类型不匹配 → 拒绝
    uint64_t bad = 0;
    Check(!tl.InsertClip(vt, MakeClip(cq::ClipKind::kAudio, 3000, 1000), bad).IsOk(),
          "音频片段放进视频轨被拒绝");

    // 零时长 → 拒绝
    uint64_t zero = 0;
    Check(!tl.InsertClip(vt, MakeClip(cq::ClipKind::kVideo, 5000, 0), zero).IsOk(),
          "零时长片段被拒绝");

    Check(tl.FindTrack(vt)->clips.size() == 2, "视频轨最终两个片段");
}

void TestHitTest() {
    cq::Timeline tl;
    uint64_t vt = 0;
    tl.AddTrack(cq::TrackKind::kVideo, vt);
    uint64_t c1 = 0, c2 = 0;
    tl.InsertClip(vt, MakeClip(cq::ClipKind::kVideo, 0, 1000), c1);    // 0–1s
    tl.InsertClip(vt, MakeClip(cq::ClipKind::kVideo, 1000, 1000), c2); // 1–2s

    const cq::Clip* hit = tl.FindClipAt(vt, Ms(500));
    Check(hit != nullptr && hit->id == c1, "0.5s 命中第一个片段");

    hit = tl.FindClipAt(vt, Ms(1000));
    Check(hit != nullptr && hit->id == c2, "1.0s 边界归属后一个片段（半开区间）");

    hit = tl.FindClipAt(vt, Ms(1500));
    Check(hit != nullptr && hit->id == c2, "1.5s 命中第二个片段");

    Check(tl.FindClipAt(vt, Ms(2500)) == nullptr, "2.5s 无片段（超出时间线）");
    Check(tl.FindClipAt(9999, Ms(500)) == nullptr, "轨道不存在时返回空");
}

void TestDurationAndTransition() {
    cq::Timeline tl;
    uint64_t vt = 0, at = 0;
    tl.AddTrack(cq::TrackKind::kVideo, vt);
    tl.AddTrack(cq::TrackKind::kAudio, at);

    uint64_t ignored = 0;
    tl.InsertClip(vt, MakeClip(cq::ClipKind::kVideo, 0, 2000), ignored);  // 0–2s
    tl.InsertClip(at, MakeClip(cq::ClipKind::kAudio, 0, 5000), ignored);  // 0–5s

    // 总时长取所有轨道的最大值（音频轨更长）
    Check(tl.Duration().value == Ms(5000).value, "总时长取最大轨道结束时刻（5s）");

    // 转场计入总时长：给音频轨加 1s 出转场 → 6s
    uint64_t at2 = 0;
    tl.AddTrack(cq::TrackKind::kAudio, at2);
    cq::Clip with_trans = MakeClip(cq::ClipKind::kAudio, 0, 5000);
    with_trans.out_transition = cq::TransitionKind::kCrossFade;
    with_trans.transition_duration = Ms(1000);
    uint64_t tc = 0;
    Check(tl.InsertClip(at2, with_trans, tc).IsOk(), "插入带出转场的片段");
    Check(tl.Duration().value == Ms(6000).value, "出转场时长计入总时长（5s + 1s = 6s）");

    // 空时间线
    cq::Timeline empty;
    Check(empty.Duration().value == 0, "空时间线时长为 0");
}

void TestEditOperations() {
    cq::Timeline tl;
    uint64_t vt = 0;
    tl.AddTrack(cq::TrackKind::kVideo, vt);
    uint64_t c1 = 0, c2 = 0;
    tl.InsertClip(vt, MakeClip(cq::ClipKind::kVideo, 0, 1000), c1);    // 0–1s
    tl.InsertClip(vt, MakeClip(cq::ClipKind::kVideo, 1000, 1000), c2); // 1–2s

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

}  // namespace

int main() {
    TestMultiTrack();
    TestOverlapRules();
    TestHitTest();
    TestDurationAndTransition();
    TestEditOperations();

    std::printf("\n%s: %d checks, %d failures\n", g_failures == 0 ? "PASSED" : "FAILED",
                g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
