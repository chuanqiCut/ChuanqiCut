#version 450

// ChuanqiCut — 单层绘制（变换叠加）的 Portable 片元 shader（SHADER-010）
//
// Portable 层：Vulkan GLSL 450 核心语义，禁平台扩展（红线 #6）。
//
// 语义契约：
//   * 单点采样 + **逐层不透明度**，除此之外不做任何通道运算。blit.frag 的
//     「逻辑 RGBA 直采」约定原样继承（BGRA8Unorm 的通道差由纹理格式本身吸收，
//     手动换 R/B 会反色——pitfalls E8 的案底）。
//   * `* vAlpha` 乘的是**四个通道**（含 alpha）：预乘口径，与后续 alpha 合成的
//     混合方程一致；alpha=1 时 `c*1.0` 逐位等于 c，所以恒等层与 blit 无数值差。
//   * 采样无条件分支（红线：禁分支依赖的纹理采样）；越界 uv 由 sampler 的
//     clamp-to-edge 吸收，与 blit 同一采样器。
//   * combined image sampler，binding 0（与 blit.frag 同口径手写，反射未落地——
//     SHADER-002 的欠账，本卡不假装已有）。

precision highp float;

layout(location = 0) in vec2 vUv;
layout(location = 1) in float vAlpha;

layout(location = 0) out vec4 oColor;

layout(binding = 0) uniform sampler2D uSrcTex;

void main()
{
    oColor = texture(uSrcTex, vUv) * vAlpha;
}
