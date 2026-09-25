// ChuanqiCut — PAL 头文件编译期自洽验证（CORE-006）
//
// 目的：
//   1. 证明 PAL 头文件自洽——能独立编译，不依赖隐藏的 include 顺序
//      （先 include 各独立域头再 include 聚合头，验证顺序无关）。
//   2. 证明零平台类型：所有跨层资源都是 common.h 的 opaque 指针句柄，
//      编译单元内不出现任何平台类型（平台类型即便在 AppleClang 下能编译通过，
//      也由 DEPS-004 符号扫描 + 评审兜底——本 TU 固化「接口只含 opaque 指针」这一事实）。
//   3. 证明统一使用 base 层类型：时间走 RationalTime（timescale=120000）、
//      错误走 Status、长任务接受 CancelToken、资源用 PalPtr 生命周期管理。
//
// 注册为 ctest 用例（tests/CMakeLists.txt）。

#include <cstddef>
#include <type_traits>

// —— 顺序无关性：先单独包含各域头，再包含聚合头 ——
#include "cq/pal/audio.h"
#include "cq/pal/capabilities.h"
#include "cq/pal/clock.h"
#include "cq/pal/common.h"
#include "cq/pal/fs.h"
#include "cq/pal/gfx.h"
#include "cq/pal/inference.h"
#include "cq/pal/log.h"
#include "cq/pal/media.h"

// 聚合头（再次包含，验证幂等）。
#include "cq/pal/pal.h"

#include "cq/base/time.h"  // kProjectTimeScale

namespace cq {
namespace {

// ---- 1. opaque 句柄都是指针（零平台类型的事实固化）----
static_assert(std::is_pointer_v<DeviceHandle>, "DeviceHandle must be an opaque pointer");
static_assert(std::is_pointer_v<TextureHandle>, "TextureHandle must be an opaque pointer");
static_assert(std::is_pointer_v<BufferHandle>, "BufferHandle must be an opaque pointer");
static_assert(std::is_pointer_v<NativeImageHandle>, "NativeImageHandle must be an opaque pointer");
static_assert(sizeof(NativeImageHandle) == sizeof(void*),
              "NativeImageHandle must be pointer-sized (no platform struct leaked)");

// ---- 1b. 文件句柄也是 PalPtr 管理的资源（生命周期全接口统一）----
static_assert(std::is_base_of_v<IPalResource, IFile>, "IFile must be a PalPtr-managed resource");
static_assert(!std::is_copy_constructible_v<PalPtr<IFile>>, "PalPtr<IFile> must be move-only");

// ---- 2. 所有资源接口继承 IPalResource（统一生命周期契约）----
static_assert(std::is_base_of_v<IPalResource, IGraphicsDevice>, "");
static_assert(std::is_base_of_v<IPalResource, ITexture>, "");
static_assert(std::is_base_of_v<IPalResource, IAudioEngine>, "");
static_assert(std::is_base_of_v<IPalResource, IMediaDemuxer>, "");
static_assert(std::is_base_of_v<IPalResource, IInferenceBackend>, "");
static_assert(std::is_base_of_v<IPalResource, IFileSystem>, "");
static_assert(std::is_base_of_v<IPalResource, IMonotonicClock>, "");

// ---- 3. PalPtr 是 move-only RAII（禁止拷贝，避免跨模块重复 Destroy）----
static_assert(!std::is_copy_constructible_v<PalPtr<IGraphicsDevice>>, "");
static_assert(!std::is_copy_assignable_v<PalPtr<IGraphicsDevice>>, "");
static_assert(std::is_move_constructible_v<PalPtr<IGraphicsDevice>>, "");
static_assert(std::is_move_assignable_v<PalPtr<IGraphicsDevice>>, "");

// ---- 4. 时间一律 RationalTime（项目 timescale=120000），禁止浮点秒 ----
static_assert(kProjectTimeScale == 120000, "PAL must align with ADR-0009 timescale 120000");
static_assert(std::is_same_v<RationalTime, decltype(std::declval<IMonotonicClock>().Now())>,
              "Clock must return RationalTime, not double seconds");
// GetDuration 以 RationalTime& 作为出参（而非 double 秒 / 裸 int64 毫秒）。
static_assert(std::is_same_v<Status (IMediaDemuxer::*)(RationalTime&) const,
                             decltype(&IMediaDemuxer::GetDuration)>,
              "GetDuration must take RationalTime& out-param");

// ---- 5. 错误一律 Status（无异常路径）----
static_assert(std::is_same_v<Status, decltype(std::declval<IGraphicsDevice>().CreateTexture(
                  std::declval<const TextureDesc&>(), std::declval<PalPtr<ITexture>&>()))>,
              "All fallible PAL ops return Status");

// ---- 6. 长任务接口接受 CancelToken（协作取消，kCancelled 非错误）----
static_assert(std::is_same_v<Status (IMediaDemuxer::*)(const RationalTime&, const CancelToken&),
                             decltype(&IMediaDemuxer::Seek)>,
              "Seek(RationalTime, CancelToken) signature must match");

// ---- 7. 枚举底层位宽稳定（跨端一致，不依赖编译器自动编号）----
static_assert(sizeof(Capability) == sizeof(int32_t), "Capability must be int32_t stable");
static_assert(sizeof(CapabilityValue) == sizeof(int32_t), "CapabilityValue must be int32_t stable");
static_assert(sizeof(CodecId) == sizeof(int32_t), "CodecId must be int32_t stable");

// ---- 8. TextureUsage bitmask 编译期可组合（验证 constexpr 运算符无 -Wconversion）----
constexpr TextureUsage kRt = TextureUsage::kSampled | TextureUsage::kRenderTarget;
static_assert(HasUsage(kRt, TextureUsage::kRenderTarget), "bitmask OR/AND must compose");
static_assert(!HasUsage(kRt, TextureUsage::kStorage), "bitmask check must be exact");

// ---- 9. 能力查询返回枚举（运行时查询，非编译期宏推断）----
static_assert(std::is_same_v<CapabilityValue, decltype(QueryCapability(Capability::kHwDecodeH264))>,
              "QueryCapability returns CapabilityValue");

}  // namespace
}  // namespace cq

int main() {
    // 编译期全部 static_assert 通过即代表头文件自洽、零平台类型、类型契约成立。
    return 0;
}
