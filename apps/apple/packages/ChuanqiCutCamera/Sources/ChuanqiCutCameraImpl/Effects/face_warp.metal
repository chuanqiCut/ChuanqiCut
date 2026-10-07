// face_warp.metal — 美型局部圆域位移场 warp（CAM-013，ADR-0014 §3）
//
// App 层 shader 资产（红线 #6 边界：相机特效不进 SDK shader 清单，同
// beauty_bilateral.metal）。经壳工程 postBuildScripts 以 **-fcikernel**
// 编译+链接为 face_warp.metallib（ADR-0021：两阶段都要 -fcikernel，否则
// 96B 空壳假绿），运行时 CIWarpKernel(functionName:fromMetalLibraryData:)
// 加载（FaceWarp.swift）。加载失败 = 美型整体跳过（诚实降级，无 CI 兜底）。
//
// warp kernel 契约：返回 float2 = dest 对应的源采样坐标，CI 内建重采样。
// 逐槽钟形羽化（cos，C1 连续）→ 多槽位移累加 → 幅度夹取（防叠加撕裂）
// → 采样点夹取到 texel 中心范围（同 beauty_bilateral 边界纪律）。
//
// 坐标约定（与契约层 FaceWarpGeometry 一致）：控制点/位移为**归一化
// origin 左上**（CAM-011 全链契约）；kernel 内转 CI 工作空间（origin 左下）：
//   px.x = nx × w, px.y = (1 - ny) × h（offset 的 y 同样取反）；
//   radius 以帧高 h 为基准（竖屏帧 w<h，半径相对水平特征略松，[E] 可接受）。

#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;

extern "C" {

// 8 个控制槽：slotN = (center.x, center.y, offset.dx, offset.dy)，归一化
// origin 左上；radii_a = 槽 0..3 半径、radii_b = 槽 4..7（归一化 × 帧高）；
// active_count = 生效槽数（≤8，尾部槽半径 0 亦会被跳过）。
// Swift 侧填充规则见 FaceWarp.apply（FaceWarpGeometry.controls 输出顺序填充，
// 缺位补零）。
float2 cq_face_warp(coreimage::sampler src,
                    float4 slot0, float4 slot1, float4 slot2, float4 slot3,
                    float4 slot4, float4 slot5, float4 slot6, float4 slot7,
                    float4 radii_a, float4 radii_b,
                    float active_count) {
    float4 ext = src.extent();
    float w = ext.z;
    float h = ext.w;
    float2 p = src.coord();
    // 归一化 origin 左上（与控制点同空间）
    float2 pn = float2(p.x / w, 1.0f - p.y / h);

    float4 slots[8] = {slot0, slot1, slot2, slot3, slot4, slot5, slot6, slot7};

    float2 shift_px = float2(0.0f, 0.0f);
    float max_radius_px = 0.0f;
    int n = min(int(active_count + 0.5f), 8);
    for (int i = 0; i < n; ++i) {
        float radius = (i < 4) ? radii_a[i] : radii_b[i - 4];
        if (radius <= 0.0f) { continue; }
        max_radius_px = max(max_radius_px, radius * h);
        float2 d = pn - slots[i].xy;
        float dist = length(d);
        if (dist >= radius) { continue; }
        // 钟形羽化：中心 1、边缘 0，C1 连续（无可见接缝的最低阶）
        float t = dist / radius;
        float fall = 0.5f + 0.5f * cos(t * M_PI_F);
        // 归一化位移 → 像素（y 取反：归一化向下 = CI 向上）
        shift_px += float2(slots[i].z * w, -slots[i].w * h) * fall;
    }

    // 幅度夹取：总位移不超过最大槽半径（多槽重叠时不撕裂）
    float len = length(shift_px);
    if (len > max_radius_px && len > 0.0f) {
        shift_px *= max_radius_px / len;
    }

    float2 src_px = p + shift_px;
    return clamp(src_px, ext.xy, ext.xy + ext.zw - 1.0f);
}

} // extern "C"
