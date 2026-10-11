// beauty_guided.metal — 磨皮「高通法」内核（CAM-034 P2，RESEARCH-015 决策 2）
//
// App 层 shader 资产（红线 #6 边界：相机特效不进 SDK shader 清单），随壳工程
// 脚本编译为独立 beauty_guided.metallib（与 beauty_bilateral 同纪律：
// 编译与链接双 -fcikernel，ADR-0021）。
//
// 算法（高通/结构分离法，YUCI 同族——P2 换代正解）：
//   Pass 1  cq_guided_down_h  半分辨率：下采样 + 水平 box blur（结构层水平分量）
//   Pass 2  cq_guided_up_mix  全分辨率：垂直 box blur（完成结构层 S）+ 双线性
//                             上采样 + 高频回注 out = S + (I − S) × k_eff
//
// 与双边滤波的观感差异（换代理由，传哲反馈驱动）：
//   1. box 均匀平均 = 磨皮程度**逐帧恒定**（双边每像素权重随内容变，叠加 AE
//      摆动即"程度脉动"——σ_local 禁用后的根本解）；
//   2. k 纹理保留系数显式控制"磨多狠/保多少细节"，滑杆语义直观（替代 σr 抽象
//      上限），单调映射可单测；
//   3. 无 exp（box 累加），ALU 便宜一个量级（RESEARCH-015 §决策2）。
//
// k_eff = keep × protect：keep = 纹理保留系数（滑杆反向单调），protect = 唇齿/
// 眉眼色域保护（复用 CAM-029 的 cq_beauty_protect 同款实现，本文件自带一份
// ——跨 metallib 不共享源码符号）。
//
// 坐标约定：与 beauty_bilateral 相同——extent origin = (0,0)，采样点手动夹取
// texel 中心（边缘不发黑）；premultiplied RGBA 语义在平均与混合下保持。

#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;

static inline float cq_guided_luma(float4 c) {
    return dot(c.rgb, float3(0.2126f, 0.7152f, 0.0722f));
}

static inline float2 cq_guided_clamp_pos(float2 p, float4 ext) {
    return clamp(p, ext.xy, ext.xy + ext.zw - 1.0f);
}

// 唇齿/眉眼色域保护（与 cq_beauty_protect 同款）：保护区 k_eff → ~0.15。
static inline float cq_guided_protect(float4 c) {
    float mx = max(max(c.r, c.g), c.b);
    float mn = min(min(c.r, c.g), c.b);
    float sat = (mx - mn) / max(mx, 1e-4f);
    float redness = (c.r - max(c.g, c.b)) / max(mx, 1e-4f);
    float lip = smoothstep(0.08f, 0.25f, redness);
    float brightFlat = smoothstep(0.75f, 0.95f, mx) * (1.0f - smoothstep(0.08f, 0.2f, sat));
    return 1.0f - 0.85f * max(lip, brightFlat);
}

extern "C" {

// Pass 1：下采样 + 水平 box blur（结构层水平分量）。
// center = (coord + 0.5) × inv_scale（2×2 盒下采样，同 cq_beauty_down_h）；
// 水平 box：半分辨率半径 radius（≈ 全分辨率 2radius px），采样 [−r, +r]。
float4 cq_guided_down_h(coreimage::sampler src,
                        float2 inv_scale,
                        float radius) {
    float4 ext = src.extent();
    float2 center = cq_guided_clamp_pos((src.coord() + 0.5f) * inv_scale, ext);
    int r = int(radius + 0.5f);
    float4 acc = float4(0.0f);
    float wsum = 0.0f;
    for (int i = -r; i <= r; ++i) {
        float2 p = cq_guided_clamp_pos(center + float2(float(i) * inv_scale.x, 0.0f), ext);
        acc += src.sample(p);
        wsum += 1.0f;
    }
    return acc / wsum;
}

// Pass 2：垂直 box blur（完成结构层 S）+ 上采样 + 高频回注。
// out = S + (orig − S) × keep × protect(orig)
//   keep   = 纹理保留系数（滑杆反向单调，Swift 侧 BeautyKernelProfile.guidedKeep）
//   protect= 中心像素色域保护（唇齿/眉眼保留细节）——中心像素定案，省逐 tap 计算。
float4 cq_guided_up_mix(coreimage::sampler hblur,
                        coreimage::sampler orig,
                        float2 down_scale,
                        float radius,
                        float keep) {
    float2 p = orig.coord();
    float4 o = orig.sample(cq_guided_clamp_pos(p, orig.extent()));

    float4 bext = hblur.extent();
    float2 center = cq_guided_clamp_pos(p * down_scale, bext);
    int r = int(radius + 0.5f);
    float4 acc = float4(0.0f);
    float wsum = 0.0f;
    for (int i = -r; i <= r; ++i) {
        float2 q = cq_guided_clamp_pos(center + float2(0.0f, float(i)), bext);
        acc += hblur.sample(q);
        wsum += 1.0f;
    }
    float4 structure = acc / wsum;   // 半分辨率 box → 双线性上采样即全分辨率 S
    float keepEff = keep * max(cq_guided_protect(o), 0.15f);
    return structure + (o - structure) * keepEff;
}

} // extern "C"
