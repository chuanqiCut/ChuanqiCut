// ChuanqiCut — PALA-010 Apple 解封装后端真实验证（AVFoundation / AVAssetReader）
//
// 硬验收（任务卡）：用真实 MP4 验证 demux 正确，而非仅"调用成功"。
//   * 打开 gf_1080p_h264.mp4，断言流数量=1、codec=H.264、尺寸=1920x1080。
//   * 总帧数 = 150（对照 tests/golden/manifest.toml 真值）。
//   * 时长与 manifest 一致（用 RationalTime，转秒仅打印）。
//   * 连续 ReadPacket 读到包且 pts 单调递增。
//   * Seek 到中间某时间后再读，pts 从该处继续（非从头）。
// 所有真实数字打印出来（含首末 pts、seek 后 pts）。
//
// 仅在 Apple 平台编译（tests/CMakeLists.txt 用 if(APPLE) 包裹，链接 cq_pal_apple）。

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "cq/base/status.h"
#include "cq/base/rational_time.h"
#include "cq/pal/media.h"

#ifndef CQ_SOURCE_DIR
#define CQ_SOURCE_DIR "."
#endif

namespace {

int g_failures = 0;
int g_checks = 0;

void Check(bool cond, const char* msg) {
    ++g_checks;
    if (cond) {
        std::printf("  ok  : %s\n", msg);
    } else {
        ++g_failures;
        std::printf("  FAIL: %s\n", msg);
    }
}

std::string RationalStr(const cq::RationalTime& t) {
    char buf[64];
    std::snprintf(buf, sizeof(buf), "v=%lld/ts=%d (%.6fs)",
                  static_cast<long long>(t.value), static_cast<int>(t.timescale),
                  t.ToSeconds());
    return std::string(buf);
}

}  // namespace

int main() {
    // 无缓冲输出：崩溃/挂起时仍能看到进度。
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::printf("== ChuanqiCut PALA-010 Apple 解封装真实验证 ==\n");

    const std::string path =
        std::string(CQ_SOURCE_DIR) + "/tests/golden/frames/gf_1080p_h264.mp4";
    std::printf("样本: %s\n", path.c_str());

    cq::MediaSource src;
    src.path = path.c_str();
    src.path_len = path.size();

    cq::PalPtr<cq::IMediaDemuxer> demuxer;
    cq::Status s = cq::CreateMediaDemuxer(src, demuxer);
    Check(s.IsOk() && demuxer, "CreateMediaDemuxer 打开成功");
    if (!demuxer) {
        std::printf("\n无法打开 demuxer，用例终止。\n");
        return 1;
    }

    // ---- 流信息 ----
    int32_t nstreams = demuxer->GetStreamCount();
    std::printf("\n[流信息] 流数量 = %d\n", nstreams);
    Check(nstreams == 1, "流数量 = 1（单视频轨，对照 manifest）");

    cq::StreamInfo info{};
    s = demuxer->GetStreamInfo(0, info);
    Check(s.IsOk(), "GetStreamInfo(0) 成功");
    std::printf("  stream[0]: type=%d codec=%d %ux%u\n",
                static_cast<int>(info.type), static_cast<int>(info.codec),
                info.width, info.height);
    Check(info.type == cq::MediaType::kVideo, "stream[0] 是视频");
    Check(info.codec == cq::CodecId::kH264, "codec = H.264");
    Check(info.width == 1920 && info.height == 1080, "尺寸 = 1920x1080");

    // ---- 时长 ----
    cq::RationalTime dur{0, 1};
    s = demuxer->GetDuration(dur);
    Check(s.IsOk(), "GetDuration 成功");
    std::printf("  时长 = %s，约 %.4f s（manifest: 5.0s / 150帧@30fps）\n",
                RationalStr(dur).c_str(), dur.ToSeconds());
    // 5.0s @ 120000 = 600000 ticks。允许 1 帧（4000 ticks）误差。
    Check(dur.value >= 600000 - 4000 && dur.value <= 600000 + 4000,
          "时长 ≈ 5.0s（600000 ticks @120000）");

    // ---- 顺序读取全部包，统计帧数 + pts 单调性 ----
    std::printf("\n[顺序读取] 从开头读全部包\n");
    std::vector<cq::RationalTime> pts_list;
    cq::RationalTime first_pts{0, 1};
    cq::RationalTime prev_pts{0, 1};
    bool monotonic = true;
    int keyframe_count = 0;
    int total = 0;
    cq::MediaPacket pkt{};
    cq::CancelToken no_cancel;
    int zero_size = 0;
    int dup_pts = 0;
    while (true) {
        cq::Status r = demuxer->ReadPacket(pkt);
        if (r.code == cq::StatusCode::kIoNotFound) break;  // 流末尾，非错误
        if (!r.IsOk()) {
            std::printf("  ReadPacket 出错: %s\n", cq::StatusToString(r.code));
            break;
        }
        if (pkt.size == 0) ++zero_size;
        if (total == 0) first_pts = pkt.pts;
        if (total > 0 && cq::CompareRational(pkt.pts, prev_pts) < 0) {
            monotonic = false;
            if (total < 30) {
                std::printf("  [非单调] #%d pts=%s < prev=%s\n", total,
                            RationalStr(pkt.pts).c_str(), RationalStr(prev_pts).c_str());
            }
        }
        if (total > 0 && cq::CompareRational(pkt.pts, prev_pts) == 0) ++dup_pts;
        if (pkt.is_keyframe) ++keyframe_count;
        pts_list.push_back(pkt.pts);
        prev_pts = pkt.pts;
        if (total < 5) {
            std::printf("  #%d pts=%s kf=%d sz=%zu\n", total,
                        RationalStr(pkt.pts).c_str(), pkt.is_keyframe ? 1 : 0,
                        pkt.size);
        }
        ++total;
    }
    std::printf("  zero_size 样本数 = %d, 重复 pts(与上一相同) 数 = %d\n", zero_size, dup_pts);
    std::printf("  总包数 = %d（manifest: 150）\n", total);
    std::printf("  关键帧数 = %d\n", keyframe_count);
    std::printf("  首包 pts = %s\n", RationalStr(first_pts).c_str());
    std::printf("  末包 pts = %s\n", RationalStr(prev_pts).c_str());
    Check(total == 150, "总帧数 = 150（对照 manifest 真值）");
    Check(monotonic, "pts 全程单调递增（无回退）");

    // ---- Seek 到中间再读，pts 应从中段继续（非从头）----
    std::printf("\n[Seek 验证] Seek 到 2.5s（=300000/120000）后再读\n");
    cq::RationalTime seek_t{300000, 120000};  // 2.5s
    s = demuxer->Seek(seek_t, no_cancel);
    Check(s.IsOk(), "Seek(2.5s) 成功");
    // 读若干包，确认首 pts 落在区间 [2.5s, ~2.5s+1帧] 附近（AVFoundation 会落到关键帧）
    bool after_seek_ok = false;
    cq::RationalTime seek_first{0, 1};
    for (int i = 0; i < 5; ++i) {
        cq::Status r = demuxer->ReadPacket(pkt);
        if (r.code == cq::StatusCode::kIoNotFound) break;
        if (!r.IsOk()) break;
        if (i == 0) seek_first = pkt.pts;
        std::printf("  seek 后第 %d 包: pts=%s keyframe=%d\n", i,
                    RationalStr(pkt.pts).c_str(), pkt.is_keyframe ? 1 : 0);
    }
    std::printf("  seek 后首包 pts = %s\n", RationalStr(seek_first).c_str());
    // 关键验收：不是从头（pts 远大于 0），即 seek 生效。
    after_seek_ok = (cq::CompareRational(seek_first, cq::RationalTime{0, 1}) > 0) &&
                    (cq::CompareRational(seek_first, seek_t) >= 0 ||
                     cq::CompareRational(seek_first, seek_t) > -4000);
    // seek 后首包 pts 应 >= 0 且接近 2.5s（可能被夹到最近关键帧，略小于 2.5s 也合理，
    // 只要不是从头读取的位置）。用更宽松判据：明显 > 0 且 >= 2.0s。
    Check(cq::CompareRational(seek_first, cq::RationalTime{0, 1}) > 0,
          "seek 后首包 pts > 0（不是从头）");
    Check(cq::CompareRational(seek_first, cq::RationalTime{240000, 120000}) >= 0,
          "seek 后首包 pts >= 2.0s（确实跳到中段）");
    (void)after_seek_ok;

    std::printf("\n== 结果：%d 项检查，%d 项失败 ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
