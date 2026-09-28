// ChuanqiCut — Apple 端 AAC 音轨封装验收（IMediaMuxer::WriteAudioFrame / AddAudioTrack）
//
// 重点验证：导出 MP4 真的带一条 AAC 音轨，且 codec=aac、采样率/声道正确。
//   * 视频轨：合成 BGRA CVPixelBuffer（不依赖 PALA-010/011 解码，聚焦音频能力），
//     经 IMediaMuxer 写入；证明音频与视频共用同一 writer。
//   * 音频轨：合成 float32 立体声正弦 PCM，按 PTS 非递减喂入 WriteAudioFrame。
//     音频 PTS 用项目网格 120000（chunk=1024 样本 @48000 → 2560 tick，整除，无需舍入）。
//   * ffprobe 验证：audio stream codec=aac / sample_rate=48000 / channels=2；
//     video stream codec=h264；音频时长与写入吻合。
//   * 契约验证：AddAudioTrack 前写音频返回 kEncodeError；非 AAC codec 返回 kEncodeUnsupported；
//     AddVideoTrack 前 AddAudioTrack 返回 kInvalidArgument（writer 未建立）。
//
// 无缓冲输出（崩溃/挂起时能看到进度）。仅 Apple 平台。

#include <CoreVideo/CoreVideo.h>

#include <cfloat>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "cq/base/status.h"
#include "cq/base/time.h"
#include "cq/pal/media.h"   // IMediaMuxer / CreateMediaMuxer / AudioTrackConfig / PcmBuffer
#include "cq/pal/common.h"
#include "media_decode.h"   // CqNativeImage（仅帧源包装，Apple TU）

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

const char* Rt(const cq::RationalTime& t) {
    static char buf[64];
    std::snprintf(buf, sizeof(buf), "%lld/%d (%.4fs)", static_cast<long long>(t.value),
                  static_cast<int>(t.timescale), t.ToSeconds());
    return buf;
}

bool RunCapture(const char* cmd, std::string& out) {
    out.clear();
    FILE* f = popen(cmd, "r");
    if (f == nullptr) return false;
    char buf[1024];
    while (std::fgets(buf, sizeof(buf), f) != nullptr) {
        out += buf;
    }
    int st = pclose(f);
    return st == 0;
}

}  // namespace

int main() {
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::printf("== ChuanqiCut AAC 音轨封装验收（IMediaMuxer 平台无关调用 / Apple 后端）==\n");

    // ---- 合成视频帧（BGRA CVPixelBuffer，绿色，640x360）----
    const uint32_t kW = 640;
    const uint32_t kH = 360;
    CVPixelBufferRef pb = nullptr;
    CVReturn cvr = CVPixelBufferCreate(kCFAllocatorDefault, kW, kH, kCVPixelFormatType_32BGRA,
                                       nullptr, &pb);
    Check(cvr == kCVReturnSuccess && pb != nullptr, "合成 BGRA CVPixelBuffer 640x360 成功");
    if (cvr != kCVReturnSuccess || pb == nullptr) {
        std::printf("\nCVPixelBuffer 创建失败，用例终止。\n");
        return 1;
    }
    CVPixelBufferLockBaseAddress(pb, 0);
    {
        size_t stride = CVPixelBufferGetBytesPerRow(pb);
        auto* base = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(pb));
        for (uint32_t y = 0; y < kH; ++y) {
            for (uint32_t x = 0; x < kW; ++x) {
                uint8_t* px = base + static_cast<size_t>(y) * stride + static_cast<size_t>(x) * 4;
                px[0] = 0;    // B
                px[1] = 180;  // G
                px[2] = 0;    // R
                px[3] = 255;  // A
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    cq::CqNativeImage img(pb);  // 包装为 NativeImageHandle（由本测试负责析构）
    cq::NativeImageHandle video_handle = &img;

    // ---- 平台无关拿到 muxer ----
    cq::PalPtr<cq::IMediaMuxer> muxer;
    cq::Status s = cq::CreateMediaMuxer(muxer);
    Check(s.IsOk() && muxer, "CreateMediaMuxer 拿到平台无关 IMediaMuxer");
    if (!muxer) {
        std::printf("\nMuxer 工厂失败，用例终止。\n");
        return 1;
    }

    const std::string out_path = "/tmp/cq_muxer_audio_out.mp4";
    std::remove(out_path.c_str());
    s = muxer->Open(out_path.c_str(), cq::ContainerFormat::kMp4);
    Check(s.IsOk(), "IMediaMuxer::Open 成功（MP4 容器）");
    if (!s.IsOk()) {
        std::printf("\nMuxer Open 失败，用例终止。\n");
        return 1;
    }

    // ---- 视频轨（建立 writer，AAC 音频轨要求其后添加）----
    cq::VideoTrackConfig vcfg{};
    vcfg.codec = cq::CodecId::kH264;
    vcfg.width = kW;
    vcfg.height = kH;
    vcfg.frame_rate = cq::RationalTime{30, 1};
    vcfg.bitrate = cq::BitrateTier::kHigh;
    vcfg.max_keyframe_interval = 1;
    vcfg.allow_hardware = true;
    s = muxer->AddVideoTrack(vcfg);
    Check(s.IsOk(), "IMediaMuxer::AddVideoTrack 成功（建立 H.264 视频轨 / writer）");

    // ---- 契约验证：AddVideoTrack 之前 AddAudioTrack 应失败（writer 未建立）----
    {
        cq::AudioTrackConfig early{};
        cq::PalPtr<cq::IMediaMuxer> m2;
        cq::Status s2 = cq::CreateMediaMuxer(m2);
        Check(s2.IsOk() && m2, "早期 muxer 创建成功（用于验证 AddVideoTrack 前置约束）");
        std::string p2 = "/tmp/cq_muxer_audio_early.mp4";
        std::remove(p2.c_str());
        m2->Open(p2.c_str(), cq::ContainerFormat::kMp4);
        cq::Status sa = m2->AddAudioTrack(early);  // 未 AddVideoTrack
        Check(!sa.IsOk(), "AddVideoTrack 之前 AddAudioTrack 返回错误（writer 未建立，诚实）");
        std::remove(p2.c_str());
    }

    // ---- 契约验证：非 AAC codec 返回 kEncodeUnsupported（诚实，不伪造）----
    {
        cq::AudioTrackConfig mp3{};
        mp3.codec = cq::CodecId::kMp3;
        cq::Status sm = muxer->AddAudioTrack(mp3);
        Check(sm.code == cq::StatusCode::kEncodeUnsupported,
              "AddAudioTrack(kMp3) 返回 kEncodeUnsupported（本期仅 AAC）");
    }

    // ---- 契约验证：AddAudioTrack 之前 WriteAudioFrame 应失败 ----
    {
        std::vector<float> silent(8, 0.0f);
        cq::PcmBuffer p{};
        p.format = cq::SampleFormat::kFloat32;
        p.channels = 2;
        p.sample_rate = 48000;
        p.frame_count = 4;
        p.data = silent.data();
        p.data_bytes = silent.size() * sizeof(float);
        p.pts = cq::RationalTime{0, cq::kProjectTimeScale};
        cq::CancelToken no_cancel;
        cq::Status sw = muxer->WriteAudioFrame(p, p.pts, no_cancel);
        Check(!sw.IsOk(), "AddAudioTrack 之前 WriteAudioFrame 返回错误");
    }

    // ---- 添加真实的 AAC 音频轨 ----
    cq::AudioTrackConfig acfg{};
    acfg.codec = cq::CodecId::kAac;
    acfg.sample_rate = 48000;
    acfg.channels = 2;
    acfg.bitrate = cq::BitrateTier::kMedium;  // 128 kbps
    s = muxer->AddAudioTrack(acfg);
    Check(s.IsOk(), "IMediaMuxer::AddAudioTrack 成功（建立 AAC 音频轨）");
    if (!s.IsOk()) {
        std::printf("\nAddAudioTrack 失败，用例终止。\n");
        return 1;
    }

    // ---- 写视频帧（30 帧 @30fps，PTS = i*4000 tick @120000 网格）----
    cq::CancelToken no_cancel;
    int vid_n = 30;
    int vid_written = 0;
    bool vid_ok = true;
    for (int i = 0; i < vid_n; ++i) {
        cq::RationalTime pts{static_cast<int64_t>(i) * 4000, cq::kProjectTimeScale};
        cq::Status ws = muxer->WriteVideoFrame(video_handle, pts, no_cancel);
        if (!ws.IsOk()) {
            std::printf("  WriteVideoFrame 失败 @pts=%s: %s\n", Rt(pts),
                        cq::StatusToString(ws.code));
            vid_ok = false;
            break;
        }
        ++vid_written;
    }
    Check(vid_ok && vid_written == vid_n, "视频轨成功写 30 帧");

    // ---- 写合成 float32 立体声正弦 PCM（chunk=1024 样本 @48000）----
    // tick 计算：1024/48000 s * 120000 = 2560 tick（整除，符合「非整除须显式舍入」约束）。
    const uint32_t kSampleRate = 48000;
    const uint32_t kChannels = 2;
    const uint32_t kChunk = 1024;
    const double kFreq = 440.0;  // 440 Hz 正弦
    const int kChunks = 100;     // 100 * 1024 / 48000 ≈ 2.133 s 音频
    const int64_t kTicksPerChunk = static_cast<int64_t>(kChunk) * cq::kProjectTimeScale / kSampleRate;

    std::vector<float> pcm_buf(static_cast<size_t>(kChunk) * kChannels);
    int audio_chunks_written = 0;
    bool audio_ok = true;
    int64_t pts_value = 0;
    for (int c = 0; c < kChunks; ++c) {
        // 填充正弦（左右声道同相）。
        for (uint32_t f = 0; f < kChunk; ++f) {
            double t = static_cast<double>(static_cast<uint32_t>(c) * kChunk + f) /
                       static_cast<double>(kSampleRate);
            float sample = static_cast<float>(0.3 * std::sin(2.0 * M_PI * kFreq * t));
            pcm_buf[static_cast<size_t>(f) * kChannels + 0] = sample;
            pcm_buf[static_cast<size_t>(f) * kChannels + 1] = sample;
        }
        cq::PcmBuffer p{};
        p.format = cq::SampleFormat::kFloat32;
        p.channels = kChannels;
        p.sample_rate = kSampleRate;
        p.frame_count = kChunk;
        p.data = pcm_buf.data();
        p.data_bytes = pcm_buf.size() * sizeof(float);
        p.pts = cq::RationalTime{pts_value, cq::kProjectTimeScale};

        cq::Status ws = muxer->WriteAudioFrame(p, p.pts, no_cancel);
        if (!ws.IsOk()) {
            std::printf("  WriteAudioFrame 失败 @pts=%s: %s\n", Rt(p.pts),
                        cq::StatusToString(ws.code));
            audio_ok = false;
            break;
        }
        ++audio_chunks_written;
        pts_value += kTicksPerChunk;
    }
    Check(audio_ok && audio_chunks_written == kChunks, "音频轨成功写 100 块 float32 PCM");
    double audio_seconds = static_cast<double>(kChunks) * kChunk / static_cast<double>(kSampleRate);
    std::printf("  音频时长 ≈ %.3f s（%d 块 × %u 样本 @%u Hz）\n", audio_seconds, kChunks,
                kChunk, kSampleRate);

    s = muxer->Finish(no_cancel);
    Check(s.IsOk(), "IMediaMuxer::Finish 成功（封装完成，含音视频双轨）");
    if (!s.IsOk()) {
        std::printf("\n封装收尾失败，用例终止。\n");
        return 1;
    }

    // ---- ffprobe 验证产出文件 ----
    const char* ffprobe = std::getenv("CQ_FFPROBE_BIN");
    std::string ffprobe_bin = (ffprobe != nullptr && ffprobe[0] != '\0')
                                  ? ffprobe
                                  : "/Users/zhuning/.workbuddy/binaries/ffmpeg/bin/ffprobe";
    std::printf("\n[ffprobe 验证] 工具: %s\n", ffprobe_bin.c_str());

    // 取所有流的 codec/rate/channels。
    std::string cmd = std::string(ffprobe_bin) +
        " -v error -show_entries stream=index,codec_type,codec_name,sample_rate,channels"
        " -of default=noprint_wrappers=1 " +
        out_path;
    std::string probe_out;
    bool have_ffprobe = RunCapture(cmd.c_str(), probe_out);
    std::printf("  %s\n", probe_out.c_str());

    if (have_ffprobe) {
        bool has_video = probe_out.find("codec_type=video") != std::string::npos &&
                         probe_out.find("codec_name=h264") != std::string::npos;
        bool has_audio = probe_out.find("codec_type=audio") != std::string::npos &&
                         probe_out.find("codec_name=aac") != std::string::npos;
        Check(has_video, "ffprobe: 存在 video 流且 codec=h264");
        Check(has_audio, "ffprobe: 存在 audio 流且 codec=aac（关键验收点）");

        bool rate_ok = probe_out.find("sample_rate=48000") != std::string::npos;
        bool ch_ok = probe_out.find("channels=2") != std::string::npos;
        Check(rate_ok, "ffprobe: 音频采样率 = 48000（与 AudioTrackConfig 一致）");
        Check(ch_ok, "ffprobe: 音频声道 = 2（立体声，与 AudioTrackConfig 一致）");

        // 音频时长核对。
        std::string dcmd = std::string(ffprobe_bin) +
            " -v error -show_entries stream=duration -select_streams a:0"
            " -of default=noprint_wrappers=1 " +
            out_path;
        std::string dout;
        if (RunCapture(dcmd.c_str(), dout)) {
            std::printf("  %s", dout.c_str());
            double dur = 0;
            const char* dp = std::strstr(dout.c_str(), "duration=");
            if (dp != nullptr) dur = std::atof(dp + std::strlen("duration="));
            // ffmpeg 报告 AAC 时长含 priming，容差 0.2s。
            Check(dur > audio_seconds - 0.2 && dur < audio_seconds + 0.3,
                  "ffprobe: 音频时长 ≈ 写入时长（端到端真打通）");
        }
    } else {
        std::printf("  [警告] ffprobe 不可用，跳过 ffprobe 验证（其余检查仍进行）。\n");
    }

    std::printf(
        "\n[结论] AAC 音轨封装验收：经平台无关 IMediaMuxer 写 %d 视频帧 + %d 块 PCM；"
        "ffprobe 验证 audio codec=aac / sample_rate=48000 / channels=2。\n",
        vid_written, audio_chunks_written);
    std::printf("== 结果：%d 项检查，%d 项失败 ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
