// ChuanqiCut — 预览全屏拷贝的 Platform-Native shader（MSL）
//
// 位置说明（红线 #6）：平台原生 shader 只允许出现在 pal/<platform>/shaders/。
// 本项目 SPIR-V 生成链尚未落地，Portable 层（shaders/src/blit.glsl）还不可用，
// 故此处是**能力缺失降级**路径，不是「平台特化优化」——后者必须先有 Portable
// 实现且收益 ≥ 20% 才允许合入。SPIR-V 链落地后，预览应改由 Portable 层驱动，
// 本文件届时退化为可选的 MSL 快路径。
//
// 为什么是 .h 而不是运行时读 .metal 文件：PAL 目前没有可用的资源加载接口
// （pal/fs.h 只有声明），运行时读文件会引入一条新的失败路径（文件缺失 / 打包遗漏）
// 却换不来任何收益。以 raw string 常量内联、由 blit_pass.mm include，
// 既满足「平台原生 shader 不进 core」，又不需要运行时 IO。
//
// ⚠️ 顶点几何与 uv 映射**不得随意改动**：uv(0,0)=图像左上 的约定已由
//    test_native_image_importer_apple.cpp 的「RT 顶/底像素 == 源顶/底行」
//    两项断言锁定（那两处用的就是本文件的几何）。改了会让画面上下颠倒。

#ifndef CQ_PAL_APPLE_SHADERS_BLIT_FULLSCREEN_MSL_H_
#define CQ_PAL_APPLE_SHADERS_BLIT_FULLSCREEN_MSL_H_

namespace cq {
namespace apple {
namespace shaders {

// 全屏三角形（比两个三角形的 quad 少一次光栅化接缝）。
//   clip(-1,-1)=屏幕左下 → uv(0,1)；clip(-1,3)=屏幕左上之外 → uv(0,-1)
//   插值后：屏幕上边 → v=0（图像顶行），屏幕下边 → v=1（图像底行）。
// 顶点布局：pos.xy(float2) + uv.xy(float2)，stride = 16 字节。
inline constexpr float kBlitVerts[3 * 4] = {
    -1.0f, -1.0f, 0.0f, 1.0f,
     3.0f, -1.0f, 2.0f, 1.0f,
    -1.0f,  3.0f, 0.0f, -1.0f,
};

inline constexpr char kBlitVertMsl[] = R"MSL(
#include <metal_stdlib>
using namespace metal;
struct VIn {
    float2 pos [[attribute(0)]];
    float2 uv  [[attribute(1)]];
};
struct VOut {
    float4 position [[position]];
    float2 uv;
};
vertex VOut vs_blit(VIn in [[stage_in]]) {
    VOut o;
    o.position = float4(in.pos, 0.0, 1.0);
    o.uv = in.uv;
    return o;
}
)MSL";

// 片元：直接采样返回。导入纹理物理格式为 BGRA8Unorm，Metal 对该格式的采样已按
// 「逻辑 RGBA」返回（.r=红 .g=绿 .b=蓝），**不要**在这里手动交换通道——
// 那正是初版实现被底部像素断言抓出的错误。
inline constexpr char kBlitFragMsl[] = R"MSL(
#include <metal_stdlib>
using namespace metal;
struct VOut {
    float4 position [[position]];
    float2 uv;
};
fragment float4 fs_blit(VOut in [[stage_in]],
                        texture2d<float> tex [[texture(0)]],
                        sampler smp [[sampler(0)]]) {
    return tex.sample(smp, in.uv);
}
)MSL";

}  // namespace shaders
}  // namespace apple
}  // namespace cq

#endif  // CQ_PAL_APPLE_SHADERS_BLIT_FULLSCREEN_MSL_H_
