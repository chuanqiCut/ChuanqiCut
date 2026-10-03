// ChuanqiCut — 媒体时长探测的 C ABI（UIA-009 子步骤 3）
//
// ⚠️ 单独成 TU（ADR-0011 规则 1）：本 TU 调用 PAL 工厂链路
//    （PalFrameProviderFactory::Create → CreateFrameProvider）。
//    cq_tests_c_abi / c_abi_session 只链 cq_core，不引用本 TU 的符号，
//    链接器不拉入本 archive member —— 隔离成立。新增此类 TU 时须登记
//    ADR-0011 §3 的 TU 表。
//
// 为什么探测走「整 provider 打开再关」：时长来自 demuxer 解析（容器头），
// provider 是现有唯一封装了「打开 → 拿 duration」的入口；探测是用户导入时
// 的低频动作，打开/关闭一次的开销（毫秒级）可接受，不值得另开旁路。

#include "cq/cq_sdk.h"

#include <memory>

#include "cq/base/status.h"
#include "cq/base/time.h"
#include "cq/media/pal_frame_provider.h"

int32_t cq_media_probe_duration(const char* path, int64_t* out_value,
                                int32_t* out_timescale) {
    if (path == nullptr || out_value == nullptr || out_timescale == nullptr) {
        return static_cast<int32_t>(cq::StatusCode::kInvalidArgument);
    }
    *out_value = 0;
    *out_timescale = 0;

    cq::MediaSource src;
    src.path = path;
    src.path_len = std::strlen(path);  // PAL 侧拒绝 path_len==0（frame_provider_apple 校验）

    cq::PalFrameProviderFactory factory;
    std::unique_ptr<cq::FrameProvider> provider;
    cq::Status s = factory.Create(src, provider);
    if (!s.IsOk()) return static_cast<int32_t>(s.code);
    if (provider == nullptr) return static_cast<int32_t>(cq::StatusCode::kInternal);

    cq::RationalTime duration;
    s = provider->GetDuration(duration);
    if (!s.IsOk()) return static_cast<int32_t>(s.code);
    if (duration.timescale <= 0) return static_cast<int32_t>(cq::StatusCode::kDecodeError);

    *out_value = duration.value;
    *out_timescale = duration.timescale;
    return static_cast<int32_t>(cq::StatusCode::kOk);
}
