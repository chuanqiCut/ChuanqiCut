// ChuanqiCut — 全屏纹理拷贝 pass 抽象（BIND-003 子步骤 4 引入）
//
// ┌────────────────────────────────────────────────────────────────────────┐
// │ 为什么是「抽象」、而不是在 core 里内联一段 shader 源码                    │
// ├────────────────────────────────────────────────────────────────────────┤
// │ 红线 #6（AGENTS.root.md）：Portable shader 位于 shaders/src/*.glsl，经    │
// │ SPIR-V 生成；core 层**不得**内联平台原生 shader 源码（MSL / GLSL ES）。    │
// │ 平台特化只允许出现在 pal/<platform>/shaders/。                           │
// │                                                                        │
// │ 但本项目的 SPIR-V 生成链尚未落地（shaders/ 目录为空），此时「平台原生     │
// │ shader」是**唯一可用路径**。这属于基线中的「能力缺失降级」                 │
// │ （无 Portable 可用 → 走平台原生），**不是**「平台特化优化」——后者必须先   │
// │ 有 Portable 实现且收益 ≥ 20% 才允许合入。                                │
// │                                                                        │
// │ 故：实现放 pal/<platform>/（MSL 源码置于 pal/<platform>/shaders/），      │
// │ core 只持抽象。SPIR-V 链落地后应由 Portable 层提供实现，接口形状不变。    │
// └────────────────────────────────────────────────────────────────────────┘
//
// 硬约束（与 GFX 层一致）：零平台类型、零 FFmpeg 类型、禁用异常（错误一律 Status）。

#ifndef CQ_GFX_BLIT_PASS_H_
#define CQ_GFX_BLIT_PASS_H_

#include "cq/base/status.h"
#include "cq/gfx/gfx_device.h"  // IGfxEncoder（本 pass 只经 GFX 层编码，不碰 PAL 编码器）
#include "cq/pal/common.h"      // TextureHandle

namespace cq {

// 全屏纹理拷贝：把一张纹理按「铺满输出目标」的方式绘制进当前 render pass。
//
// uv 约定（与 PALA-002 验收用例一致，不得上下颠倒）：
//   uv(0,0) = 图像左上，uv(1,1) = 图像右下。
//   该约定已由 test_native_image_importer_apple.cpp 的「RT 顶/底像素 == 源顶/底行」
//   两项断言锁定；实现若翻转 uv.y，那两项断言会失败。
class IBlitPass {
public:
    virtual ~IBlitPass() = default;

    // 在给定 encoder 上编码一次全屏绘制。调用前调用方须已 BeginRenderPass。
    // src 可以是零拷贝导入的解码帧纹理，也可以是普通纹理。
    virtual Status Encode(IGfxEncoder& encoder, TextureHandle src) = 0;
};

}  // namespace cq

#endif  // CQ_GFX_BLIT_PASS_H_
