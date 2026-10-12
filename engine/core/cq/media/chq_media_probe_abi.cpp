// ChuanqiCut — 媒体时长探测的 C ABI（UIA-009 子步骤 3）
//
// ⚠️ 单独成 TU（ADR-0011 规则 1）：本 TU 调用 Platform 工厂链路
//    （ChqPlatformFrameProviderFactory::Create → CreateFrameProvider）。
//    cq_tests_c_abi / c_abi_session 只链 cq_core，不引用本 TU 的符号，
//    链接器不拉入本 archive member —— 隔离成立。新增此类 TU 时须登记
//    ADR-0011 §3 的 TU 表。
//
// 为什么探测走「开 demuxer 再关」：时长来自 demuxer 解析（容器头），demuxer 是
// 现有唯一封装了「打开 → 拿 duration」的入口；探测是用户导入时的低频动作。
//
// ⚠️ 但**必须是轻量 demuxer**（CreateMediaDemuxerLight）：全量 demuxer 的 Open
// 会建 AVAssetReader 并逐样本扫描关键帧，真机大素材 967ms（2026-10-12 实测），
// 而探测只需要 duration —— 见下面 §1 的注释与 media_demux.mm 的 OpenLight。

#include "cq/cq_sdk.h"

#include <memory>

#include "cq/base/chq_status.h"
#include "cq/base/chq_rational_time.h"
#include "cq/platform/chq_media.h"

int32_t cq_media_probe_duration(const char* path, int64_t* out_value,
                                int32_t* out_timescale) {
    if (path == nullptr || out_value == nullptr || out_timescale == nullptr) {
        return static_cast<int32_t>(cq::ChqStatusCode::kInvalidArgument);
    }
    *out_value = 0;
    *out_timescale = 0;

    cq::ChqMediaSource src;
    src.path = path;
    src.path_len = std::strlen(path);  // Platform 侧拒绝 path_len==0（demuxer 校验）

    // MEDIA-026：探测走 **demuxer OpenLight**（只读容器时长），不再走完整
    // provider 打开 —— 全量 Open 对大文件做逐样本关键帧扫描（秒级），而探测
    // 只需要 duration。解码会话/VT/扫描全部不触碰。
    //
    // ⚠️ 2026-10-12 补完：必须走 **CreateMediaDemuxerLight**，不能用
    // CreateMediaDemuxer —— 后者在工厂内部就做了全量 Open（含 ScanKeyframes），
    // 真机 1080×1920 素材实测 967ms 且整段打在主线程（导入卡顿 + Thread
    // Performance Checker 优先级反转）。这一点在真机日志里暴露前无人发现，
    // 因为本地素材太小、Open 也是毫秒级。
    cq::ChqPlatformPtr<cq::ChqIMediaDemuxer> demuxer;
    cq::ChqStatus s = cq::CreateMediaDemuxerLight(src, demuxer);
    if (!s.IsOk()) return static_cast<int32_t>(s.code);
    if (!demuxer) return static_cast<int32_t>(cq::ChqStatusCode::kInternal);

    cq::ChqRationalTime duration;
    s = demuxer->GetDuration(duration);
    if (!s.IsOk()) return static_cast<int32_t>(s.code);
    if (duration.timescale <= 0) return static_cast<int32_t>(cq::ChqStatusCode::kDecodeError);
    // 容器打开但时长为 0 = 解析失败（如 P33：AVAsset 加载失败/取消时
    // [asset duration] 返回 invalid/0，被 ToRational 转成 {0, 120000}）。
    // 必须如实报错，否则上层拿 0 时长建 0 长度片段。
    if (duration.value <= 0) return static_cast<int32_t>(cq::ChqStatusCode::kDecodeError);

    *out_value = duration.value;
    *out_timescale = duration.timescale;
    return static_cast<int32_t>(cq::ChqStatusCode::kOk);
}
