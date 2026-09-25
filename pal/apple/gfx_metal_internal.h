// ChuanqiCut — Apple PAL 内部调试/测试辅助（PALA-001）
//
// 本头文件位于 pal/apple/，**不在** core/include/cq/{pal,gfx,media}/ 门禁扫描范围，
// 也不出现在任何内核公共头中。它只暴露 Apple 平台专属的离屏读回 / 纹理上传辅助，
// 供 ctest 用例验证「渲染结果正确」使用（见 AGENTS.root.md 验收硬要求）。
//
// 门禁脚本 tools/pal/check_pal_headers.py 只扫 core/include/cq/**；此处允许平台类型，
// 但为了不污染纯 C++ 测试 TU，本头**刻意不 import 任何 Metal 头**——读回/上传函数
// 的签名只使用 PAL 的 opaque 句柄（IRenderTarget* / ITexture*）与 void*，
// 平台实现藏在 gfx_metal.mm 内。这样 tests/unit/test_gfx_metal.cpp 可以是纯 .cpp。

#pragma once

#include "cq/pal/gfx.h"

namespace cq {
namespace apple {

// 把离屏 RenderTarget 背后 Metal 纹理的内容读回为 RGBA8 像素。
// 内部用一次 blit 把纹理拷到 Shared 缓冲再 memcpy，兼容 Private/Managed 存储。
// 区域 (x,y,w,h) 必须在 RenderTarget 范围内。out_rgba8 由调用方提供，容量 >= out_size。
Status ReadRenderTargetPixels(IRenderTarget* rt,
                              uint32_t x, uint32_t y, uint32_t w, uint32_t h,
                              void* out_rgba8, size_t out_size);

// 把 RGBA8 数据上传进一张已创建的纹理（仅测试 / 调试用）。
// 假定纹理格式为 kRGBA8，行跨度为 width*4。用于注入「已知内容纹理」做采样验证。
Status UploadTextureData(ITexture* tex, const void* data, size_t bytes);

// 句柄桥接：PAL 的 Create* 返回 PalPtr<Ixxx>（接口指针），但渲染/管线装配需要 opaque
// 句柄（CqXxx*，见 common.h）。两者在后端实现里是「同一对象」（CqXxx 继承 Ixxx），
// 这里提供安全的下行转换，使客户端（含 ctest）能拿到装配所需的句柄而无需看到平台类型。
// 函数签名只用到 PAL 头类型，故可在纯 C++ 的测试 TU 中调用。
ShaderModuleHandle ToShaderHandle(IShaderModule* p);
PipelineHandle    ToPipelineHandle(IPipeline* p);
BufferHandle      ToBufferHandle(IBuffer* p);
TextureHandle     ToTextureHandle(ITexture* p);
SamplerHandle     ToSamplerHandle(ISampler* p);
RenderTargetHandle ToRenderTargetHandle(IRenderTarget* p);

}  // namespace apple
}  // namespace cq
