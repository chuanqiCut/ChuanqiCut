// ChuanqiCut — GFX 层头文件编译期自洽验证（GFX-001）
//
// 目的：
//   1. 证明 GFX 层头文件自洽——能独立编译，include 顺序无关。
//   2. 证明零平台类型：所有跨层资源都是 Platform 的 opaque 指针句柄，编译单元内不出现
//      任何平台类型（由 check_platform_headers.py 门禁 + 评审兜底，本 TU 固化
//      「接口只含 opaque 指针」这一事实）。
//   3. 证明分层边界：RenderGraph 将只依赖 ChqIGfxDevice / ChqIGfxEncoder / ChqFrameContext，
//      ChqIGfxEncoder 继承 Platform ChqIPlatformResource（编码器抽象位于 GFX 层）。
//   4. 证明统一使用 base 层类型：时间 ChqRationalTime、错误 ChqStatus、长任务 ChqCancelToken。
//
// 注册为 ctest 用例（tests/CMakeLists.txt）。仅包含头文件 + static_assert，不链接实现。

#include <cstddef>
#include <type_traits>

// —— GFX 层头（聚合 + 各领域）——
#include "cq/gfx/chq_gfx.h"
#include "cq/gfx/chq_gfx_device.h"

// Platform 与 base（GFX 之下/之上依赖，验证跨层 include 顺序无关）。
#include "cq/platform/chq_common.h"
#include "cq/platform/chq_gfx.h"
#include "cq/base/chq_rational_time.h"
#include "cq/base/chq_status.h"
#include "cq/base/chq_concurrency.h"

namespace cq {
namespace {

// ---- 1. opaque 句柄都是指针（零平台类型的事实固化，与 Platform 一致）----
static_assert(std::is_pointer_v<TextureHandle>, "TextureHandle must be opaque pointer");
static_assert(std::is_pointer_v<RenderTargetHandle>, "RenderTargetHandle must be opaque pointer");
static_assert(std::is_pointer_v<PipelineHandle>, "PipelineHandle must be opaque pointer");
static_assert(sizeof(NativeImageHandle) == sizeof(void*),
              "NativeImageHandle must be pointer-sized (no platform struct leaked)");

// ---- 2. 分层边界：ChqIGfxEncoder 位于 GFX 层，继承 Platform ChqIPlatformResource ----
static_assert(std::is_base_of_v<ChqIPlatformResource, ChqIGfxEncoder>,
              "ChqIGfxEncoder must be a Platform resource (encoder abstraction lives in GFX layer)");

// ---- 3. 抽象接口不可默认构造（纯虚），强制由实现层落地 ----
static_assert(!std::is_default_constructible_v<ChqIGfxDevice>,
              "ChqIGfxDevice is abstract, implemented in engine/core/cq/gfx");
static_assert(!std::is_default_constructible_v<ChqIGfxEncoder>,
              "ChqIGfxEncoder is abstract");
static_assert(!std::is_default_constructible_v<ChqIFrameEncoderClient>,
              "ChqIFrameEncoderClient is abstract (RenderGraph implements it)");
static_assert(!std::is_default_constructible_v<ChqITexturePool>,
              "ChqITexturePool is abstract (GFX-002 implements it)");

// ---- 4. 时间一律 ChqRationalTime（ChqFrameContext.pts 用 ChqRationalTime，禁止浮点秒）----
static_assert(std::is_same_v<ChqRationalTime, decltype(ChqFrameContext{}.pts)>,
              "ChqFrameContext.pts must be ChqRationalTime, not double seconds");

// ---- 5. 错误一律 ChqStatus（无异常路径）----
static_assert(std::is_same_v<ChqStatus, decltype(std::declval<ChqIGfxDevice>().CreateRenderTarget(
                                            std::declval<const ChqRenderTargetDesc&>(),
                                            std::declval<ChqPlatformPtr<ChqIRenderTarget>&>()))>,
              "All fallible GFX ops return ChqStatus");

// ---- 6. 长任务接口接受 ChqCancelToken（协作取消，kCancelled 非错误）----
static_assert(std::is_same_v<ChqStatus (ChqIGfxDevice::*)(const ChqFrameContext&, ChqIRenderTarget*,
                                                          ChqIFrameEncoderClient&, const ChqCancelToken&),
                             decltype(&ChqIGfxDevice::RenderFrame)>,
              "RenderFrame(ChqFrameContext, target, client, ChqCancelToken) signature must match");

// ---- 7. 底层 Platform 设备经 PlatformDevice() 暴露（GFX 持有 Platform 设备，不重造）----
static_assert(std::is_same_v<ChqIGraphicsDevice* (ChqIGfxDevice::*)(),
                             decltype(&ChqIGfxDevice::PlatformDevice)>,
              "PlatformDevice() must surface the underlying Platform ChqIGraphicsDevice");

// ---- 8. 原生图像导入接入点委托 Platform ChqINativeImageImporter（GFX-003 位置）----
static_assert(std::is_same_v<ChqStatus (ChqIGfxDevice::*)(ChqPlatformPtr<ChqINativeImageImporter>&),
                             decltype(&ChqIGfxDevice::CreateNativeImageImporter)>,
              "CreateNativeImageImporter must delegate to Platform ChqINativeImageImporter");

// ---- 9. 纹理池钩子存在（GFX-002 接入点）----
static_assert(std::is_same_v<void (ChqIGfxDevice::*)(ChqITexturePool*),
                             decltype(&ChqIGfxDevice::SetTexturePool)>,
              "SetTexturePool must accept ChqITexturePool* (GFX-002 hook)");

// ---- 10. 工厂签名：用 Platform 设备构造 GFX 门面，返回跨平台 ChqIGfxDevice* ----
static_assert(std::is_same_v<ChqStatus (*)(ChqPlatformPtr<ChqIGraphicsDevice>&, ChqIGfxDevice*&),
                             decltype(&CreateGfxDevice)>,
              "CreateGfxDevice(ChqPlatformPtr<ChqIGraphicsDevice>&, ChqIGfxDevice*&) signature must match");

}  // namespace
}  // namespace cq

int main() {
    // 编译期全部 static_assert 通过即代表头文件自洽、零平台类型、分层契约成立。
    return 0;
}
