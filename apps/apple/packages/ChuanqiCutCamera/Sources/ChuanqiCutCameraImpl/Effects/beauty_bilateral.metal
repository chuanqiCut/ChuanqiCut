// beauty_bilateral.metal — 磨皮亮度域双边滤波（CAM-012，ADR-0014 §3）
//
// App 层 shader 资产（红线 #6 边界：相机特效不进 SDK shader 清单），
// 随 Xcode 编译期内建为 default.metallib，运行时经
// CIKernel(functionName:fromMetalLibraryData:) 加载（iOS 17.2 SDK 没有
// CIKernel 源码串初始化器，见 pitfalls P40）。
//
// 管线（与 TASK-CAM-012 实现要点一致：下采样 → 亮度域双边 → 上采样 → 按强度混合）：
//   Pass 1 cq_beauty_down_h  输出半分辨率：下采样(2x2 盒) + 水平双边
//   Pass 2 cq_beauty_up_v_mix 输出全分辨率：垂直双边 + 双线性上采样 + 强度混合
//
// 边界行为：sample() 越界行为未定义，两个 kernel 都把采样点手动夹取到
// texel 中心范围（等效 clampedToExtent，边缘不发黑）。
//
// 坐标约定：CIImage extent origin = (0,0)（相机帧恒成立；Swift 侧断言，
// 非零 origin 直接放弃 → SharedUI 回落默认 CI 实现）。

#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;

// Rec.709 亮度。CI 工作空间是 premultiplied RGBA；相机帧 alpha=1，
// premultiplied 与直通值一致。权重同作用于 alpha，均值按 Σw 归一，
// premultiplied 语义在两次平均与 mix 下均保持。
static inline float cq_beauty_luma(float4 c) {
    return dot(c.rgb, float3(0.2126f, 0.7152f, 0.0722f));
}

// 采样点夹取到 texel 中心范围（extent = [x, y, w, h]）。
static inline float2 cq_beauty_clamp_pos(float2 p, float4 ext) {
    return clamp(p, ext.xy, ext.xy + ext.zw - 1.0f);
}

// 空间权重：半分辨率下 1 tap ≈ 全分辨率 2px，σs = 2（tap 单位）。
static inline float cq_beauty_spatial(float d) {
    return exp(-d * d / 8.0f);
}

extern "C" {

// Pass 1：下采样 + 水平亮度域双边。
// 输出 extent 由 Swift 侧声明为半分辨率；dest 坐标经 inv_scale 映射到源空间。
//   center = (coord + 0.5) × inv_scale：落在 2x2 块中心，双线性即完成盒式下采样
//   （直接采 coord × inv_scale 是隔点取值，细纹理会走样，必须带 0.5 偏移）。
//   tap i 距中心 i 个半分辨率像素 = i × inv_scale 个源像素。
// 权重 = 空间高斯 × 亮度域高斯（σr 越大磨得越狠、保边越弱）。
float4 cq_beauty_down_h(coreimage::sampler src,
                        float2 inv_scale,
                        float taps,
                        float sigma_range) {
    float4 ext = src.extent();
    float2 center = cq_beauty_clamp_pos((src.coord() + 0.5f) * inv_scale, ext);
    float4 c0 = src.sample(center);
    float y0 = cq_beauty_luma(c0);
    float sigma2 = 2.0f * sigma_range * sigma_range;

    float4 acc = c0;
    float wsum = 1.0f;
    int r = int(taps + 0.5f);
    for (int i = 1; i <= r; ++i) {
        float d = float(i);
        float ws = cq_beauty_spatial(d);
        float2 dx = float2(d * inv_scale.x, 0.0f);
        float4 p1 = src.sample(cq_beauty_clamp_pos(center + dx, ext));
        float4 p2 = src.sample(cq_beauty_clamp_pos(center - dx, ext));
        float dy1 = cq_beauty_luma(p1) - y0;
        float dy2 = cq_beauty_luma(p2) - y0;
        float w1 = ws * exp(-dy1 * dy1 / sigma2);
        float w2 = ws * exp(-dy2 * dy2 / sigma2);
        acc += p1 * w1 + p2 * w2;
        wsum += w1 + w2;
    }
    return acc / wsum;
}

// Pass 2：垂直双边（半分辨率）+ 双线性上采样 + 与原图按强度混合。
// 输出 extent = 原图 extent。orig.coord() 即全分辨率目标坐标；
// hblur 以 down_scale 映射到半分辨率坐标（分数位置 = 双线性上采样，内建）。
// 保边混合：out = mix(原图, 双边结果, mix_t)，发丝/眼缘的高频细节来自原图项。
float4 cq_beauty_up_v_mix(coreimage::sampler hblur,
                          coreimage::sampler orig,
                          float2 down_scale,
                          float taps,
                          float sigma_range,
                          float mix_t) {
    float2 p = orig.coord();
    float4 o = orig.sample(cq_beauty_clamp_pos(p, orig.extent()));

    float4 bext = hblur.extent();
    float2 center = cq_beauty_clamp_pos(p * down_scale, bext);
    float4 b0 = hblur.sample(center);
    float y0 = cq_beauty_luma(b0);
    float sigma2 = 2.0f * sigma_range * sigma_range;

    float4 acc = b0;
    float wsum = 1.0f;
    int r = int(taps + 0.5f);
    for (int i = 1; i <= r; ++i) {
        float d = float(i);
        float ws = cq_beauty_spatial(d);
        float2 dy2v = float2(0.0f, d);
        float4 p1 = hblur.sample(cq_beauty_clamp_pos(center + dy2v, bext));
        float4 p2 = hblur.sample(cq_beauty_clamp_pos(center - dy2v, bext));
        float dy1 = cq_beauty_luma(p1) - y0;
        float dy2 = cq_beauty_luma(p2) - y0;
        float w1 = ws * exp(-dy1 * dy1 / sigma2);
        float w2 = ws * exp(-dy2 * dy2 / sigma2);
        acc += p1 * w1 + p2 * w2;
        wsum += w1 + w2;
    }
    float4 blurred = acc / wsum;
    return mix(o, blurred, mix_t);
}

} // extern "C"
