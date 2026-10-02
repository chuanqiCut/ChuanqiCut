// ChuanqiCut — Apple 全屏拷贝 pass（Platform-Native shader 路径）
//
// 实现 core 的 `cq::IBlitPass`（core/include/cq/gfx/blit_pass.h）。
// MSL 源码在 pal/apple/shaders/blit_fullscreen_msl.h，不进 core。
//
// 为什么本文件在 pal/apple 而不是 core：见 blit_pass.h 头部的分层说明
// （core 不得内联平台原生 shader 源码；SPIR-V 链落地前这是唯一可用路径）。

#ifndef CQ_PAL_APPLE_BLIT_PASS_H_
#define CQ_PAL_APPLE_BLIT_PASS_H_

#include <memory>

#include "cq/gfx/blit_pass.h"   // cq::IBlitPass
#include "cq/gfx/gfx_device.h"  // cq::IGfxDevice
#include "cq/pal/common.h"      // TextureFormat

namespace cq {
namespace apple {

// 创建绑定到给定 GFX 设备的全屏拷贝 pass。设备必须在 pass 存活期内有效。
//
// target_format 必须与渲染目标的格式一致：Metal 的管线在创建时就绑定了目标像素格式，
// 后续渲染到不同格式的目标会失败。故格式是创建期参数，不是每次 Encode 的参数——
// 预览分辨率变化（Resize）不受影响，但换格式必须重建本 pass。
std::unique_ptr<IBlitPass> CreateBlitPass(IGfxDevice* gfx,
                                          TextureFormat target_format = TextureFormat::kRGBA8);

}  // namespace apple
}  // namespace cq

#endif  // CQ_PAL_APPLE_BLIT_PASS_H_
