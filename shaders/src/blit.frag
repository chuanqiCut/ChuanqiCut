#version 450

// ChuanqiCut — 预览全屏拷贝的 Portable 片元 shader（SHADER-001）
//
// Portable 层（shaders/src/），Vulkan GLSL 450 核心语义，禁止平台扩展（红线 #6）。
//
// 语义契约：
//   * 单点采样后原样返回，**不做任何通道交换**。源纹理的物理格式在各平台可能
//     是 BGRA8Unorm（Apple 零拷贝导入即如此），但采样器返回的一律是
//     「逻辑 RGBA」（.r=红 .g=绿 .b=蓝）——格式差异由纹理格式本身吸收。
//     早期版本在 shader 里手动交换通道，结果被「RT 顶红 / 底蓝」断言抓出，
//     故此处刻意保持直采。
//   * sampler 与 texture 同绑定（combined image sampler，binding 0）：
//     Metal 侧的 [[texture(0)]] / [[sampler(0)]] 由 SPIR-V 转译自动配对。

layout(location = 0) in vec2 vUv;

layout(location = 0) out vec4 oColor;

layout(binding = 0) uniform sampler2D uSrcTex;

void main()
{
    oColor = texture(uSrcTex, vUv);
}
