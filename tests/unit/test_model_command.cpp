// ChuanqiCut — Command / CommandHistory 单测（MODEL-002）
//
// 验收对应 BACKLOG「100 次 undo 后回到初始态」：
//   * 6 类命令的 Do/Undo/Redo 往返（含 Add/Remove 的原 id 恢复）
//   * 大深度往返：101 条命令 → 全部 Undo → 指纹 == 初始态 → 全部 Redo → 指纹 == 最终态
//   * 失败语义：非法命令不入历史、不改模型、不清 redo
//   * 失败的 Do 不推进模型（先校验后变更的契约）
//
// 断言用 Check() 而非 assert：assert 在 Release（NDEBUG）下会被吃掉（假绿灯）。

#include <cstdio>
#include <string>

#include "cq/base/status.h"
#include "cq/base/time.h"
#include "cq/command/command.h"
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

cq::Clip MakeClip(int64_t start_ms, int64_t dur_ms, uint64_t asset_id = 1) {
    cq::Clip c;
    c.kind = cq::ClipKind::kVideo;
    c.source.asset_id = asset_id;
    c.source.source_in = Ms(0);
    c.source.source_duration = Ms(dur_ms);
    c.start = Ms(start_ms);
    c.duration = Ms(dur_ms);
    return c;
}

// 模型指纹：把全部实体字段摊平成字符串。Undo 往返的「回到初始态」靠它判定
// （Timeline 无比较运算符；指纹包含 id，顺带验证「原 id 恢复」）。
std::string Fingerprint(const cq::Timeline& tl) {
    std::string fp;
    char buf[128];
    for (const cq::Track& t : tl.Tracks()) {
        std::snprintf(buf, sizeof(buf), "T|%llu|%d|%d|%d;",
                      static_cast<unsigned long long>(t.id),
                      static_cast<int>(t.kind), t.enabled ? 1 : 0, t.muted ? 1 : 0);
        fp += buf;
        for (const cq::Clip& c : t.clips) {
            std::snprintf(buf, sizeof(buf),
                          "C|%llu|%d|%llu|%lld|%lld|%lld|%lld|%d|%d;",
                          static_cast<unsigned long long>(c.id),
                          static_cast<int>(c.kind),
                          static_cast<unsigned long long>(c.source.asset_id),
                          static_cast<long long>(c.source.source_in.value),
                          static_cast<long long>(c.source.source_duration.value),
                          static_cast<long long>(c.start.value),
                          static_cast<long long>(c.duration.value),
                          static_cast<int>(c.in_transition),
                          static_cast<int>(c.out_transition));
            fp += buf;
        }
    }
    return fp;
}

// ---------------------------------------------------------------------------

// 基础往返：6 类命令各自 Do → Undo → Redo 后与 Do 后状态一致（含 id）。
void TestRoundTripEachCommand() {
    cq::Timeline tl;
    cq::CommandHistory hist;

    // add-track
    Check(hist.Execute(std::make_unique<cq::AddTrackCommand>(cq::TrackKind::kVideo), tl).IsOk(),
          "Execute AddTrack");
    const uint64_t track_id = tl.Tracks().front().id;
    Check(hist.UndoDepth() == 1, "AddTrack 入栈");
    Check(hist.CanRedo() == false, "新执行后无 redo");
    hist.Undo(tl);
    Check(tl.Tracks().empty(), "Undo 后轨道消失");
    Check(hist.CanRedo(), "Undo 后可 Redo");
    hist.Redo(tl);
    Check(!tl.Tracks().empty() && tl.Tracks().front().id == track_id,
          "Redo 恢复原 track id");

    // insert-clip
    Check(hist.Execute(std::make_unique<cq::InsertClipCommand>(track_id, MakeClip(0, 5000)), tl).IsOk(),
          "Execute InsertClip");
    const cq::Clip* inserted = tl.FindClipAt(track_id, Ms(1000));
    Check(inserted != nullptr, "插入后可命中");
    const uint64_t clip_id = inserted->id;
    hist.Undo(tl);
    Check(tl.FindClip(clip_id) == nullptr, "Undo 后片段消失");
    hist.Redo(tl);
    const cq::Clip* restored = tl.FindClipAt(track_id, Ms(1000));
    Check(restored != nullptr && restored->id == clip_id, "Redo 恢复原 clip id");

    // move-clip
    const std::string fp_after_insert = Fingerprint(tl);
    Check(hist.Execute(std::make_unique<cq::MoveClipCommand>(clip_id, Ms(10000)), tl).IsOk(),
          "Execute MoveClip");
    Check(tl.FindClip(clip_id)->start == Ms(10000), "移动生效");
    hist.Undo(tl);
    Check(tl.FindClip(clip_id)->start == Ms(0), "Undo 回到原位");
    Check(Fingerprint(tl) == fp_after_insert, "Undo 后指纹与移动前一致");
    hist.Redo(tl);
    Check(tl.FindClip(clip_id)->start == Ms(10000), "Redo 回到新位");

    // trim-clip
    Check(hist.Execute(std::make_unique<cq::TrimClipCommand>(clip_id, Ms(3000)), tl).IsOk(),
          "Execute TrimClip");
    Check(tl.FindClip(clip_id)->duration == Ms(3000), "修剪生效");
    hist.Undo(tl);
    Check(tl.FindClip(clip_id)->duration == Ms(5000), "Trim Undo 回到原时长");
    hist.Redo(tl);
    Check(tl.FindClip(clip_id)->duration == Ms(3000), "Trim Redo 回到新时长");

    // remove-clip
    Check(hist.Execute(std::make_unique<cq::RemoveClipCommand>(clip_id), tl).IsOk(),
          "Execute RemoveClip");
    Check(tl.FindClip(clip_id) == nullptr, "删除生效");
    hist.Undo(tl);
    Check(tl.FindClip(clip_id) != nullptr && tl.FindClip(clip_id)->id == clip_id,
          "RemoveClip Undo 恢复原 id");
    Check(tl.FindClip(clip_id)->duration == Ms(3000), "恢复内容完整（含删除前的 trim 结果）");
    hist.Redo(tl);
    Check(tl.FindClip(clip_id) == nullptr, "RemoveClip Redo 再删");

    // remove-track（undo 需恢复轨道 + 其内片段）
    // 先补一条片段进轨道
    hist.Execute(std::make_unique<cq::InsertClipCommand>(track_id, MakeClip(20000, 5000)), tl);
    const std::string fp_before_remove_track = Fingerprint(tl);
    Check(hist.Execute(std::make_unique<cq::RemoveTrackCommand>(track_id), tl).IsOk(),
          "Execute RemoveTrack");
    Check(tl.Tracks().empty(), "轨道删除生效");
    Check(hist.Undo(tl).IsOk(), "RemoveTrack Undo");
    Check(Fingerprint(tl) == fp_before_remove_track, "轨道与其内片段被完整恢复");
}

// 核心验收：大深度往返。
// 结构：空模型 → AddTrack + 100 条 InsertClip（101 条）→
//       50 条 Move + 50 条 Trim（合计 201 条）→
//       全部 Undo（201 次）→ 指纹 == 空模型 → 全部 Redo → 指纹 == 最终态。
// 片段间距 20s / 时长 5s：移动 ±5s 内、修剪 ≤10s 恒合法（构造性保证，无随机）。
void TestHundredUndoReturnsToInitial() {
    cq::Timeline tl;
    cq::CommandHistory hist;

    const std::string fp_initial = Fingerprint(tl);  // 空模型

    Check(hist.Execute(std::make_unique<cq::AddTrackCommand>(cq::TrackKind::kVideo), tl).IsOk(),
          "stress: AddTrack");
    const uint64_t track_id = tl.Tracks().front().id;

    for (int i = 0; i < 100; ++i) {
        auto cmd = std::make_unique<cq::InsertClipCommand>(track_id, MakeClip(i * 20000, 5000));
        cq::Status s = hist.Execute(std::move(cmd), tl);
        if (!s.IsOk()) {
            Check(false, "stress: InsertClip 应全部合法");
            return;
        }
    }

    // 交替 Move / Trim：偶数 clip 移动 +k 秒，奇数移动 -k 秒；修剪都在 1s~10s。
    for (int i = 0; i < 50; ++i) {
        const uint64_t clip_id = tl.FindClipAt(track_id, Ms(i * 20000))->id;
        const int64_t delta_ms = (i % 2 == 0 ? 1 : -1) * (1000 + (i % 4) * 1000);  // ±1~4s
        cq::Status s = hist.Execute(
            std::make_unique<cq::MoveClipCommand>(clip_id, Ms(i * 20000 + delta_ms)), tl);
        if (!s.IsOk()) {
            Check(false, "stress: MoveClip 应全部合法");
            return;
        }
        cq::Status s2 = hist.Execute(
            std::make_unique<cq::TrimClipCommand>(clip_id, Ms(1000 + (i % 8) * 1000)), tl);
        if (!s2.IsOk()) {
            Check(false, "stress: TrimClip 应全部合法");
            return;
        }
    }

    Check(hist.UndoDepth() == 201, "stress: 历史深度 201");
    const std::string fp_final = Fingerprint(tl);
    Check(fp_final != fp_initial, "stress: 最终态与初始态不同");

    for (int i = 0; i < 201; ++i) {
        if (!hist.Undo(tl).IsOk()) {
            Check(false, "stress: 201 次 Undo 应全部成功");
            return;
        }
    }
    Check(Fingerprint(tl) == fp_initial, "stress: 全部 Undo 后回到初始态");
    Check(hist.UndoDepth() == 0 && !hist.CanUndo(), "stress: 撤销栈清空");
    Check(hist.CanRedo(), "stress: 重做栈满");

    for (int i = 0; i < 201; ++i) {
        if (!hist.Redo(tl).IsOk()) {
            Check(false, "stress: 201 次 Redo 应全部成功");
            return;
        }
    }
    Check(Fingerprint(tl) == fp_final, "stress: 全部 Redo 后回到最终态");
    Check(!hist.CanRedo(), "stress: 重做栈清空");
}

// 失败语义：失败 Do 不入历史 / 不改模型 / 不清 redo。
void TestFailedExecuteKeepsHistoryAndModel() {
    cq::Timeline tl;
    cq::CommandHistory hist;

    hist.Execute(std::make_unique<cq::AddTrackCommand>(cq::TrackKind::kVideo), tl);
    const uint64_t track_id = tl.Tracks().front().id;
    hist.Execute(std::make_unique<cq::InsertClipCommand>(track_id, MakeClip(0, 5000)), tl);
    const uint64_t clip_a = tl.FindClipAt(track_id, Ms(0))->id;
    hist.Execute(std::make_unique<cq::InsertClipCommand>(track_id, MakeClip(10000, 5000)), tl);
    Check(tl.FindClipAt(track_id, Ms(10000)) != nullptr, "前置：clip_b 已插入");

    const size_t depth_full = hist.UndoDepth();  // = 3

    // 1) 重叠 Move 失败：clip_a 移到 12s → [12,17) 与 clip_b [10,15) 重叠
    const std::string fp_full = Fingerprint(tl);
    cq::Status s = hist.Execute(
        std::make_unique<cq::MoveClipCommand>(clip_a, Ms(12000)), tl);
    Check(!s.IsOk(), "重叠 Move 被拒绝");
    Check(hist.UndoDepth() == depth_full, "失败 Execute 不入栈");
    Check(Fingerprint(tl) == fp_full, "失败 Execute 不改模型");

    // 2) 非法 Trim（零时长）失败
    s = hist.Execute(std::make_unique<cq::TrimClipCommand>(clip_a, Ms(0)), tl);
    Check(!s.IsOk(), "零时长 Trim 被拒绝");
    Check(hist.UndoDepth() == depth_full, "非法 Trim 不入栈");

    // 3) 引用不存在的实体
    s = hist.Execute(std::make_unique<cq::RemoveClipCommand>(99999), tl);
    Check(!s.IsOk(), "删除不存在的片段被拒绝");
    s = hist.Execute(std::make_unique<cq::MoveClipCommand>(99999, Ms(0)), tl);
    Check(!s.IsOk(), "移动不存在的片段被拒绝");
    s = hist.Execute(std::make_unique<cq::RemoveTrackCommand>(99999), tl);
    Check(!s.IsOk(), "删除不存在的轨道被拒绝");
    s = hist.Execute(std::make_unique<cq::InsertClipCommand>(99999, MakeClip(0, 1000)), tl);
    Check(!s.IsOk(), "插入到不存在的轨道被拒绝");
    Check(hist.UndoDepth() == depth_full, "全部失败未入栈");
    Check(Fingerprint(tl) == fp_full, "全部失败模型未变");

    // 4) nullptr 命令
    s = hist.Execute(nullptr, tl);
    Check(!s.IsOk(), "nullptr 命令被拒绝");

    // 5) 空 Undo / 空 Redo
    cq::CommandHistory empty;
    Check(!empty.Undo(tl).IsOk(), "空历史 Undo 被拒绝");
    Check(!empty.Redo(tl).IsOk(), "空历史 Redo 被拒绝");

    // 6) 新 Execute 丢弃 redo 分支（线性历史）
    hist.Execute(std::make_unique<cq::TrimClipCommand>(clip_a, Ms(2000)), tl);
    Check(!hist.CanRedo(), "新执行后 redo 分支被丢弃");

    // 失败的 Execute 不应丢 redo：Undo 一次造出 redo 分支，再执行失败命令
    hist.Undo(tl);  // 撤销 trim → clip_a 回到 5s，redo 分支存在
    Check(hist.CanRedo(), "前置：redo 分支存在");
    // 此时模型里 clip_b 也不在（它比 trim 先入栈，Undo 先弹它）——
    // 用不依赖 clip_b 的失败命令：零时长 Trim。
    hist.Execute(std::make_unique<cq::TrimClipCommand>(clip_a, Ms(0)), tl);  // 失败
    Check(hist.CanRedo(), "失败的 Execute 不清 redo 分支");

    // 7) Clear 丢弃全部历史（模型不变）
    const std::string fp2 = Fingerprint(tl);
    hist.Clear();
    Check(!hist.CanUndo() && !hist.CanRedo(), "Clear 清空双栈");
    Check(hist.UndoDepth() == 0, "Clear 后深度 0");
    Check(Fingerprint(tl) == fp2, "Clear 不改模型");
}

// 同轨排序不变量：Restore/Redo 后片段仍按 start 升序（命中测试依赖）。
void TestOrderInvariantAfterUndoRedo() {
    cq::Timeline tl;
    cq::CommandHistory hist;
    hist.Execute(std::make_unique<cq::AddTrackCommand>(cq::TrackKind::kVideo), tl);
    const uint64_t track_id = tl.Tracks().front().id;

    // 乱序插入（由 Timeline 排序），然后移动最左片段到最右（触发重排），
    // 再 Undo/Redo 一个来回，验证顺序不变量稳定。
    hist.Execute(std::make_unique<cq::InsertClipCommand>(track_id, MakeClip(10000, 5000)), tl);
    hist.Execute(std::make_unique<cq::InsertClipCommand>(track_id, MakeClip(0, 5000)), tl);
    hist.Execute(std::make_unique<cq::InsertClipCommand>(track_id, MakeClip(20000, 5000)), tl);
    const uint64_t first = tl.FindClipAt(track_id, Ms(0))->id;

    hist.Execute(std::make_unique<cq::MoveClipCommand>(first, Ms(30000)), tl);
    bool sorted = true;
    int64_t prev = -1;
    for (const cq::Clip& c : tl.FindTrack(track_id)->clips) {
        if (c.start.value < prev) sorted = false;
        prev = c.start.value;
    }
    Check(sorted, "移动后仍按 start 升序");

    hist.Undo(tl);
    hist.Redo(tl);
    sorted = true;
    prev = -1;
    for (const cq::Clip& c : tl.FindTrack(track_id)->clips) {
        if (c.start.value < prev) sorted = false;
        prev = c.start.value;
    }
    Check(sorted, "Undo/Redo 往返后仍按 start 升序");
}

}  // namespace

int main() {
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::printf("== ChuanqiCut Command / CommandHistory 单测（MODEL-002）==\n");

    TestRoundTripEachCommand();
    TestHundredUndoReturnsToInitial();
    TestFailedExecuteKeepsHistoryAndModel();
    TestOrderInvariantAfterUndoRedo();

    std::printf("== %d checks, %d failures ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
