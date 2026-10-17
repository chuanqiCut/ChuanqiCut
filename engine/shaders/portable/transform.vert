#version 450

// ChuanqiCut — 单层绘制（变换叠加）的 Portable 顶点 shader（SHADER-010）
//
// Portable 层：只用 Vulkan GLSL 450 核心语义，禁平台扩展（红线 #6）。
//
// 语义契约：
//   * 本 shader **不做任何变换算术**：位移 / 缩放 / 旋转 / 裁剪 / 镜像全部由 core 在
//     装配期算好、烤进顶点（`engine/core/cq/render/chq_layer_geometry.cpp`）。
//     理由两条：① 三角函数在各家 libm / 各端 GPU 上末位不同，放进 shader 等于把
//     「三端一致」交给着色器实现；② 放 core 才能用普通单测锁死几何（见
//     `tests/unit/render/test_layer_geometry.cpp`），放 shader 只能靠真机看画面。
//   * 顶点布局 pos.xy(float2, loc0) + uv.xy(float2, loc1) + alpha(float, loc2)，
//     stride = 20。alpha 走顶点而不走 uniform：`ChqICommandEncoder` 没有绑 uniform
//     缓冲的方法（只有 SetVertexBuffer / SetTexture / SetSampler），加一个就是改契约头。
//   * uv(0,0) = 图像左上（与 blit.vert 同一约定，不得另立）；gl_Position.z = 0、w = 1。
//   * 恒等参数（整画布矩形 + uv(0..1) + alpha 1）下，本 shader 的插值结果与
//     blit.{vert,frag} 落在同一批像素上 —— 这是 RENDER-010「加法不是改写」的判据。

precision highp float;

layout(location = 0) in vec2 aPos;
layout(location = 1) in vec2 aUv;
layout(location = 2) in float aAlpha;

layout(location = 0) out vec2 vUv;
layout(location = 1) out float vAlpha;

void main()
{
    gl_Position = vec4(aPos, 0.0, 1.0);
    vUv = aUv;
    vAlpha = aAlpha;
}
