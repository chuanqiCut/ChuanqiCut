// ChuanqiCut — Platform 头文件编译期自洽验证（CORE-006）
//
// 目的：
//   1. 证明 Platform 头文件自洽——能独立编译，不依赖隐藏的 include 顺序
//      （先 include 各独立域头再 include 聚合头，验证顺序无关）。
//   2. 证明零平台类型：所有跨层资源都是 common.h 的 opaque 指针句柄，
//      编译单元内不出现任何平台类型（平台类型即便在 AppleClang 下能编译通过，
//      也由 DEPS-004 符号扫描 + 评审兜底——本 TU 固化「接口只含 opaque 指针」这一事实）。
//   3. 证明统一使用 base 层类型：时间走 ChqRationalTime（timescale=120000）、
//      错误走 ChqStatus、长任务接受 ChqCancelToken、资源用 ChqPlatformPtr 生命周期管理。
//
// 注册为 ctest 用例（tests/CMakeLists.txt）。

#include <cstddef>
#include <type_traits>

// —— 顺序无关性：先单独包含各域头，再包含聚合头 ——
#include "cq/platform/chq_audio.h"
#include "cq/platform/chq_capabilities.h"
#include "cq/platform/chq_clock.h"
#include "cq/platform/chq_common.h"
#include "cq/platform/chq_fs.h"
#include "cq/platform/chq_gfx.h"
#include "cq/platform/chq_inference.h"
#include "cq/platform/chq_log.h"
#include "cq/platform/chq_media.h"

// 聚合头（再次包含，验证幂等）。
#include "cq/platform/chq_platform.h"

#include "cq/base/chq_rational_time.h"  // kProjectTimeScale

namespace cq {
namespace {

// ---- 1. opaque 句柄都是指针（零平台类型的事实固化）----
static_assert(std::is_pointer_v<DeviceHandle>, "DeviceHandle must be an opaque pointer");
static_assert(std::is_pointer_v<TextureHandle>, "TextureHandle must be an opaque pointer");
static_assert(std::is_pointer_v<BufferHandle>, "BufferHandle must be an opaque pointer");
static_assert(std::is_pointer_v<NativeImageHandle>, "NativeImageHandle must be an opaque pointer");
static_assert(sizeof(NativeImageHandle) == sizeof(void*),
              "NativeImageHandle must be pointer-sized (no platform struct leaked)");

// ---- 1b. 文件句柄也是 ChqPlatformPtr 管理的资源（生命周期全接口统一）----
static_assert(std::is_base_of_v<ChqIPlatformResource, ChqIFile>, "ChqIFile must be a ChqPlatformPtr-managed resource");
static_assert(!std::is_copy_constructible_v<ChqPlatformPtr<ChqIFile>>, "ChqPlatformPtr<ChqIFile> must be move-only");

// ---- 2. 所有资源接口继承 ChqIPlatformResource（统一生命周期契约）----
static_assert(std::is_base_of_v<ChqIPlatformResource, ChqIGraphicsDevice>, "");
static_assert(std::is_base_of_v<ChqIPlatformResource, ChqITexture>, "");
static_assert(std::is_base_of_v<ChqIPlatformResource, ChqIAudioEngine>, "");
static_assert(std::is_base_of_v<ChqIPlatformResource, ChqIMediaDemuxer>, "");
static_assert(std::is_base_of_v<ChqIPlatformResource, ChqIMediaMuxer>, "");
static_assert(std::is_base_of_v<ChqIPlatformResource, ChqIInferenceBackend>, "");
static_assert(std::is_base_of_v<ChqIPlatformResource, ChqIFileSystem>, "");
static_assert(std::is_base_of_v<ChqIPlatformResource, ChqIMonotonicClock>, "");

// ---- 3. ChqPlatformPtr 是 move-only RAII（禁止拷贝，避免跨模块重复 Destroy）----
static_assert(!std::is_copy_constructible_v<ChqPlatformPtr<ChqIGraphicsDevice>>, "");
static_assert(!std::is_copy_assignable_v<ChqPlatformPtr<ChqIGraphicsDevice>>, "");
static_assert(std::is_move_constructible_v<ChqPlatformPtr<ChqIGraphicsDevice>>, "");
static_assert(std::is_move_assignable_v<ChqPlatformPtr<ChqIGraphicsDevice>>, "");
// muxer 同样走 ChqPlatformPtr + Destroy() 生命周期（与 demuxer 对称）。
static_assert(!std::is_copy_constructible_v<ChqPlatformPtr<ChqIMediaMuxer>>, "");
static_assert(std::is_move_constructible_v<ChqPlatformPtr<ChqIMediaMuxer>>, "");

// ---- 4. 时间一律 ChqRationalTime（项目 timescale=120000），禁止浮点秒 ----
static_assert(kProjectTimeScale == 120000, "Platform must align with ADR-0009 timescale 120000");
static_assert(std::is_same_v<ChqRationalTime, decltype(std::declval<ChqIMonotonicClock>().Now())>,
              "Clock must return ChqRationalTime, not double seconds");
// GetDuration 以 ChqRationalTime& 作为出参（而非 double 秒 / 裸 int64 毫秒）。
static_assert(std::is_same_v<ChqStatus (ChqIMediaDemuxer::*)(ChqRationalTime&) const,
                             decltype(&ChqIMediaDemuxer::GetDuration)>,
              "GetDuration must take ChqRationalTime& out-param");

// ---- 5. 错误一律 ChqStatus（无异常路径）----
static_assert(std::is_same_v<ChqStatus, decltype(std::declval<ChqIGraphicsDevice>().CreateTexture(
                                            std::declval<const ChqTextureDesc&>(), std::declval<ChqPlatformPtr<ChqITexture>&>()))>,
              "All fallible Platform ops return ChqStatus");

// ---- 6. 长任务接口接受 ChqCancelToken（协作取消，kCancelled 非错误）----
static_assert(std::is_same_v<ChqStatus (ChqIMediaDemuxer::*)(const ChqRationalTime&, const ChqCancelToken&),
                             decltype(&ChqIMediaDemuxer::Seek)>,
              "Seek(ChqRationalTime, ChqCancelToken) signature must match");

// ---- 6b. ChqIMediaMuxer 对称契约：写帧/收尾接受 ChqCancelToken，帧为 opaque 句柄 ----
// WriteVideoFrame 必须以平台无关的 NativeImageHandle 传帧（零平台类型：绝不出现
// CVPixelBufferRef / jobject 等），且 PTS 为 ChqRationalTime、长任务接受 ChqCancelToken。
static_assert(
    std::is_same_v<ChqStatus (ChqIMediaMuxer::*)(NativeImageHandle, const ChqRationalTime&, const ChqCancelToken&),
                   decltype(&ChqIMediaMuxer::WriteVideoFrame)>,
    "WriteVideoFrame(NativeImageHandle, ChqRationalTime, ChqCancelToken) signature must match");
// Finish 接受 ChqCancelToken（取消返回 kCancelled 非错误）。
static_assert(std::is_same_v<ChqStatus (ChqIMediaMuxer::*)(const ChqCancelToken&),
                             decltype(&ChqIMediaMuxer::Finish)>,
              "Finish(ChqCancelToken) signature must match");
// Open 以输出路径 + 容器枚举表达，不泄漏平台文件/容器类型。
static_assert(std::is_same_v<ChqStatus (ChqIMediaMuxer::*)(const char*, ChqContainerFormat),
                             decltype(&ChqIMediaMuxer::Open)>,
              "Open(const char*, ChqContainerFormat) signature must match");
// 工厂返回 ChqStatus + ChqPlatformPtr<ChqIMediaMuxer>&（与 CreateMediaDemuxer 对称）。
static_assert(
    std::is_same_v<ChqStatus (*)(ChqPlatformPtr<ChqIMediaMuxer>&), decltype(&CreateMediaMuxer)>,
    "CreateMediaMuxer(ChqPlatformPtr<ChqIMediaMuxer>&) signature must match");
// 码率以档位枚举表达（避免把平台特定 bps 暴露到 core）。
static_assert(std::is_same_v<ChqBitrateTier, decltype(ChqVideoTrackConfig{}.bitrate)>,
              "ChqVideoTrackConfig.bitrate must be ChqBitrateTier (not raw bps)");
static_assert(sizeof(ChqBitrateTier) == sizeof(int32_t), "ChqBitrateTier must be int32_t stable");
// muxer 与 demuxer 同属媒体领域，接口对称：都继承 ChqIPlatformResource、都用 ChqRationalTime。
// FrameCount 返回帧计数（int64_t），不是时间，避免语义混淆。
static_assert(!std::is_same_v<ChqRationalTime, decltype(std::declval<ChqIMediaMuxer>().FrameCount())>,
              "FrameCount returns int64_t count, not ChqRationalTime");

// ---- 7. 枚举底层位宽稳定（跨端一致，不依赖编译器自动编号）----
static_assert(sizeof(ChqCapability) == sizeof(int32_t), "ChqCapability must be int32_t stable");
static_assert(sizeof(ChqCapabilityValue) == sizeof(int32_t), "ChqCapabilityValue must be int32_t stable");
static_assert(sizeof(ChqCodecId) == sizeof(int32_t), "ChqCodecId must be int32_t stable");

// ---- 8. ChqTextureUsage bitmask 编译期可组合（验证 constexpr 运算符无 -Wconversion）----
constexpr ChqTextureUsage kRt = ChqTextureUsage::kSampled | ChqTextureUsage::kRenderTarget;
static_assert(HasUsage(kRt, ChqTextureUsage::kRenderTarget), "bitmask OR/AND must compose");
static_assert(!HasUsage(kRt, ChqTextureUsage::kStorage), "bitmask check must be exact");

// ---- 9. 能力查询返回枚举（运行时查询，非编译期宏推断）----
static_assert(std::is_same_v<ChqCapabilityValue, decltype(QueryCapability(ChqCapability::kHwDecodeH264))>,
              "QueryCapability returns ChqCapabilityValue");

}  // namespace
}  // namespace cq

int main() {
    // 编译期全部 static_assert 通过即代表头文件自洽、零平台类型、类型契约成立。
    return 0;
}
