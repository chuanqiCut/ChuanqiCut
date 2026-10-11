// ChuanqiCut — FFmpeg demux 探测单测（DEPS-012 冒烟切片）
//
// 验证 vendored FFmpeg（demux 档）真实可用：打开 golden H.264 样本读容器头。
// 素材元数据（tests/golden/manifest.toml [[sample]] gf_1080p_h264）：
//   1920x1080 / 30fps / 150 帧 / 名义时长 5.0s / h264 / 无音轨。
//
// 素材路径由 CMake 注入 CQ_TEST_GOLDEN_H264（绝对路径，与运行 cwd 无关）。

#include <cstdio>
#include <cstdlib>
#include <string>

#include "cq/media/ffmpeg_probe.h"

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

void CheckNear(int64_t actual_us, double expect_s, double tol_s, const char* msg) {
    const double actual_s = static_cast<double>(actual_us) / 1e6;
    ++g_checks;
    if (actual_s < expect_s - tol_s || actual_s > expect_s + tol_s) {
        ++g_failures;
        std::printf("  FAIL: %s (actual=%.3fs expect=%.3fs tol=%.3fs)\n",
                    msg, actual_s, expect_s, tol_s);
    }
}

}  // namespace

int main() {
    const char* path = CQ_TEST_GOLDEN_H264;
    std::printf(">> probe: %s\n", path);

    cq::FFmpegProbeResult result;
    const cq::Status s = cq::FFmpegProbeFile(path, &result);
    Check(s.IsOk(), "FFmpegProbeFile 应成功（demux 档可打开 golden H.264）");

    if (s.IsOk()) {
        Check(result.container_name.find("mov") != std::string::npos,
              "容器名应含 mov（mp4 = mov 族）");
        CheckNear(result.duration_us, 5.0, 0.5, "容器时长应 ≈ 5.0s（名义 150帧/30fps）");
        Check(result.streams.size() == 1, "应恰好 1 条流（无音轨样本）");
        if (result.streams.size() == 1) {
            const cq::FFmpegStreamInfo& v = result.streams[0];
            Check(v.codec_name == "h264", "视频流 codec 应为 h264");
            Check(v.media_type == "video", "流类型应为 video");
            Check(v.width == 1920 && v.height == 1080, "分辨率应为 1920x1080");
        }
    }

    // 错误路径：不存在的文件必须 kIoNotFound，而不是崩溃或 kFormat。
    cq::FFmpegProbeResult miss;
    const cq::Status s_miss = cq::FFmpegProbeFile("/nonexistent/no_such_file.mp4", &miss);
    Check(s_miss.code == cq::StatusCode::kIoNotFound,
          "不存在的文件应返回 kIoNotFound");

    // 参数校验。
    Check(cq::FFmpegProbeFile(nullptr, &miss).code == cq::StatusCode::kInvalidArgument,
          "nullptr 路径应 kInvalidArgument");
    Check(cq::FFmpegProbeFile("", &miss).code == cq::StatusCode::kInvalidArgument,
          "空路径应 kInvalidArgument");
    Check(cq::FFmpegProbeFile(path, nullptr).code == cq::StatusCode::kInvalidArgument,
          "nullptr out 应 kInvalidArgument");

    std::printf("%d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
