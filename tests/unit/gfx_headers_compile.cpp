// ChuanqiCut — GFX 层头文件编译期自洽验证（GFX-001）
//
// 目的：
//   1. 证明 GFX 层头文件自洽——能独立编译，include 顺序无关。
//   2. 证明零平台类型：所有跨层资源都是 PAL 的 opaque 指针句柄，编译单元内不出现
//      任何平台类型（由 check_pal_headers.py 门禁 + 评审兜底，本 TU 固化
//      「接口只含 opaque 指针」这一事实）。
//   3. 证明分层边界：RenderGraph 将只依赖 IGfxDevice / IGfxEncoder / FrameContext，
//      IGfxEncoder 继承 PAL IPalResource（编码器抽象位于 GFX 层）。
//   4. 证明统一使用 base 层类型：时间 RationalTime、错误 Status、长任务 CancelToken。
//
// 注册为 ctest 用例（tests/CMakeLists.txt）。仅包含头文件 + static_assert，不链接实现。

#include <cstddef>
#include <type_traits>

// —— GFX 层头（聚合 + 各领域）——
#include "cq/gfx/gfx.h"
#include "cq/gfx/gfx_device.h"

// PAL 与 base（GFX 之下/之上依赖，验证跨层 include 顺序无关）。
#include "cq/pal/common.h"
#include "cq/pal/gfx.h"
#include "cq/base/time.h"
#include "cq/base/status.h"
#include "cq/base/concurrency.h"

namespace cq {
namespace {

// ---- 1. opaque 句柄都是指针（零平台类型的事实固化，与 PAL 一致）----
static_assert(std::is_pointer_v<TextureHandle>, "TextureHandle must be opaque pointer");
static_assert(std::is_pointer_v<RenderTargetHandle>, "RenderTargetHandle must be opaque pointer");
static_assert(std::is_pointer_v<PipelineHandle>, "PipelineHandle must be opaque pointer");
static_assert(sizeof(NativeImageHandle) == sizeof(void*),
              "NativeImageHandle must be pointer-sized (no platform struct leaked)");

// ---- 2. 分层边界：IGfxEncoder 位于 GFX 层，继承 PAL IPalResource ----
static_assert(std::is_base_of_v<IPalResource, IGfxEncoder>,
              "IGfxEncoder must be a PAL resource (encoder abstraction lives in GFX layer)");

// ---- 3. 抽象接口不可默认构造（纯虚），强制由实现层落地 ----
static_assert(!std::is_default_constructible_v<IGfxDevice>,
              "IGfxDevice is abstract, implemented in core/src/gfx later");
static_assert(!std::is_default_constructible_v<IGfxEncoder>,
              "IGfxEncoder is abstract");
static_assert(!std::is_default_constructible_v<IFrameEncoderClient>,
              "IFrameEncoderClient is abstract (RenderGraph implements it)");
static_assert(!std::is_default_constructible_v<ITexturePool>,
              "ITexturePool is abstract (GFX-002 implements it)");

// ---- 4. 时间一律 RationalTime（FrameContext.pts 用 RationalTime，禁止浮点秒）----
static_assert(std::is_same_v<RationalTime, decltype(FrameContext{}.pts)>,
              "FrameContext.pts must be RationalTime, not double seconds");

// ---- 5. 错误一律 Status（无异常路径）----
static_assert(std::is_same_v<Status, decltype(std::declval<IGfxDevice>().CreateRenderTarget(
                  std::declval<const RenderTargetDesc&>(),
                  std::declval<PalPtr<IRenderTarget>&>()))>,
              "All fallible GFX ops return Status");

// ---- 6. 长任务接口接受 CancelToken（协作取消，kCancelled 非错误）----
static_assert(std::is_same_v<Status (IGfxDevice::*)(const FrameContext&, IRenderTarget*,
                  IFrameEncoderClient&, const CancelToken&),
                  decltype(&IGfxDevice::RenderFrame)>,
              "RenderFrame(FrameContext, target, client, CancelToken) signature must match");

// ---- 7. 底层 PAL 设备经 PalDevice() 暴露（GFX 持有 PAL 设备，不重造）----
static_assert(std::is_same_v<IGraphicsDevice* (IGfxDevice::*)(),
                  decltype(&IGfxDevice::PalDevice)>,
              "PalDevice() must surface the underlying PAL IGraphicsDevice");

// ---- 8. 原生图像导入接入点委托 PAL INativeImageImporter（GFX-003 位置）----
static_assert(std::is_same_v<Status (IGfxDevice::*)(PalPtr<INativeImageImporter>&),
                  decltype(&IGfxDevice::CreateNativeImageImporter)>,
              "CreateNativeImageImporter must delegate to PAL INativeImageImporter");

// ---- 9. 纹理池钩子存在（GFX-002 接入点）----
static_assert(std::is_same_v<void (IGfxDevice::*)(ITexturePool*),
                  decltype(&IGfxDevice::SetTexturePool)>,
              "SetTexturePool must accept ITexturePool* (GFX-002 hook)");

// ---- 10. 工厂签名：用 PAL 设备构造 GFX 门面，返回跨平台 IGfxDevice* ----
static_assert(std::is_same_v<Status (*)(PalPtr<IGraphicsDevice>&, IGfxDevice*&),
                  decltype(&CreateGfxDevice)>,
              "CreateGfxDevice(PalPtr<IGraphicsDevice>&, IGfxDevice*&) signature must match");

}  // namespace
}  // namespace cq

int main() {
    // 编译期全部 static_assert 通过即代表头文件自洽、零平台类型、分层契约成立。
    return 0;
}
