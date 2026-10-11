// ChuanqiCut — 音频预览的 C ABI 实现（AUDIO-002）
//
// ⚠️ 为什么单独一个 TU（与 cq/preview/cq_sdk_preview.cpp 同一论证）：
//   本文件调用 Platform 音频工厂（CreateAudioEngine / CreateAudioTrackReader）。
//   静态库按 archive member 粒度拉符号，只有真正使用音频预览能力的目标才会
//   把本 TU 链进来 —— 不用音频的目标（如无 Platform 音频后端的 Android 构建）
//   不产生 Platform 链接依赖。
//
// 内核禁用异常（ARCH-001）：分配一律 new (std::nothrow)，失败返回 NULL。

#include "cq/cq_sdk.h"

#include <memory>
#include <new>

#include "cq/audio/preview_mixer.h"
#include "cq/audio/track_reader.h"
#include "cq/base/logging.h"
#include "cq/base/rational_time.h"
#include "cq/base/status.h"
#include "cq/model/model_snapshot.h"
#include "cq/platform/audio.h"
#include "../cq_session_impl.h"

namespace {

int32_t CodeOfEnum(cq::StatusCode code) { return static_cast<int32_t>(code); }

// 把 EditorSession 的已发布快照适配成混音器的输入
//（与 cq_sdk_preview.cpp 的 SessionSnapshotProvider 同型；两处各持一份，
//  避免共享类型跨 TU 耦合 —— 各自 6 行，不构成第二套逻辑）。
class AudioSessionSnapshotProvider final : public cq::IModelSnapshotProvider {
public:
    explicit AudioSessionSnapshotProvider(cq::EditorSession* session)
        : session_(session) {}
    std::shared_ptr<const cq::ModelSnapshot> CurrentSnapshot() const override {
        return session_->CurrentModelSnapshot();
    }

private:
    cq::EditorSession* session_;
};

}  // namespace

// CQAudioPreview 的真实定义。
// ⚠️ 必须在**全局**命名空间（放进匿名 namespace 会与头文件的 typedef 产生
//    命名歧义，与 CQSession / CQPreview 同一坑）。
// ⚠️ 成员顺序即销毁顺序的镜像：mixer 持有 engine / snapshot_provider 的非拥有
//    指针，故 mixer 必须先于它们销毁（unique_ptr 成员按声明序**逆序**析构，
//    把 mixer 放最后声明即可）。
struct CQAudioPreview {
    cq::EditorSession* session = nullptr;  // 非拥有（Swift 侧强持有 Session）
    std::unique_ptr<cq::IModelSnapshotProvider> snapshot_provider;   // 拥有
    std::unique_ptr<cq::IAudioTrackReaderFactory> reader_factory;    // 拥有
    cq::PlatformPtr<cq::IAudioEngine> engine;                        // 拥有
    std::unique_ptr<cq::PreviewAudioMixer> mixer;                    // 拥有（最后构造）
};

CQAudioPreview* cq_audio_preview_create(CQSession* session) {
    if (session == nullptr) return nullptr;

    CQAudioPreview* p = new (std::nothrow) CQAudioPreview();
    if (p == nullptr) return nullptr;
    p->session = &session->impl;
    if (p->session->CurrentModelSnapshot() == nullptr) {
        // 无内建模型快照（注入自定义 ISessionState）：无输入源，如实 NULL。
        cq_audio_preview_destroy(p);
        return nullptr;
    }

    p->snapshot_provider.reset(
        new (std::nothrow) AudioSessionSnapshotProvider(p->session));
    if (!p->snapshot_provider) {
        cq_audio_preview_destroy(p);
        return nullptr;
    }
    p->reader_factory.reset(new (std::nothrow) cq::PlatformAudioReaderFactory());
    if (!p->reader_factory) {
        cq_audio_preview_destroy(p);
        return nullptr;
    }

    // 平台播放引擎（PALA-030）。后端缺失 = 预览无声（运行时降级，诚实）。
    if (!cq::CreateAudioEngine(p->engine).IsOk() || !p->engine) {
        CQ_LOG_WARN_WF(cq::Workflow::kPreview, "音频预览不可用：平台音频引擎缺失");
        cq_audio_preview_destroy(p);
        return nullptr;
    }

    cq::PreviewAudioMixer::Config cfg;
    cfg.spec.format = cq::SampleFormat::kFloat32;
    cfg.spec.channels = 2;
    cfg.spec.sample_rate = 48000;
    cfg.spec.frames_per_block = 480;  // 10ms @ 48k；块网格 ticks 必须为整
    if (!p->engine->OpenOutput(cfg.spec.sample_rate, cfg.spec.channels,
                               cfg.spec.format,
                               cfg.spec.frames_per_block).IsOk()) {
        CQ_LOG_WARN_WF(cq::Workflow::kPreview, "音频预览不可用：引擎 OpenOutput 失败");
        cq_audio_preview_destroy(p);
        return nullptr;
    }

    p->mixer.reset(new (std::nothrow) cq::PreviewAudioMixer(
        p->reader_factory.get(), p->snapshot_provider.get(), p->engine.get(), cfg));
    if (!p->mixer) {
        cq_audio_preview_destroy(p);
        return nullptr;
    }
    if (!p->mixer->Start().IsOk()) {
        CQ_LOG_WARN_WF(cq::Workflow::kPreview, "音频预览不可用：混音线程启动失败");
        cq_audio_preview_destroy(p);
        return nullptr;
    }
    return p;
}

void cq_audio_preview_destroy(CQAudioPreview* audio) {
    if (audio == nullptr) return;
    // 顺序要紧（成员逆序析构由 unique_ptr 保证，这里仍显式 reset 一次以自明）：
    // 先停混音线程（它持有 engine/snapshot 的非拥有指针），再释放引擎。
    audio->mixer.reset();
    audio->engine.reset();
    audio->reader_factory.reset();
    audio->snapshot_provider.reset();
    delete audio;
}

int32_t cq_audio_preview_sync(CQAudioPreview* audio, int64_t playhead_value,
                              int32_t playhead_timescale, int32_t playing) {
    if (audio == nullptr || audio->mixer == nullptr || playhead_timescale <= 0) {
        return CodeOfEnum(cq::StatusCode::kInvalidArgument);
    }
    audio->mixer->Sync(cq::RationalTime{playhead_value, playhead_timescale},
                       playing != 0);
    return CodeOfEnum(cq::StatusCode::kOk);
}

int32_t cq_audio_preview_stats(CQAudioPreview* audio, uint64_t* out_blocks_rendered,
                               uint64_t* out_blocks_dropped, uint64_t* out_underruns,
                               uint64_t* out_resyncs) {
    if (audio == nullptr || audio->mixer == nullptr) {
        return CodeOfEnum(cq::StatusCode::kInvalidArgument);
    }
    const cq::PreviewAudioMixer::Stats s = audio->mixer->GetStats();
    if (out_blocks_rendered != nullptr) *out_blocks_rendered = s.blocks_rendered;
    if (out_blocks_dropped != nullptr) *out_blocks_dropped = s.blocks_dropped;
    if (out_underruns != nullptr) *out_underruns = s.underruns;
    if (out_resyncs != nullptr) *out_resyncs = s.resyncs;
    return CodeOfEnum(cq::StatusCode::kOk);
}
