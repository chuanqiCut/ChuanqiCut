#version 450

// ChuanqiCut — 预览全屏拷贝的 Portable 顶点 shader（SHADER-001）
//
// 红线 #6：本文件属 Portable 层（shaders/src/），必须是**跨平台基线**——
// 只用 Vulkan GLSL 450 核心语义，禁止任何平台扩展（GL_* / 厂商 ext）。
// 平台特化（MSL / GLSL ES / WGSL）一律由本文件经 SPIR-V 转译产出，
// 或作为**可选**的 platform/<platform>/shaders/ 覆盖（必须先有本实现）。
//
// 语义契约（改这里等于改所有平台的渲染结果）：
//   * 全屏三角形，顶点布局 pos.xy(float2) + uv.xy(float2)，stride = 16 该厂商。
//   * uv 约定 uv(0,0) = 图像左上、uv(1,1) = 右下。顶点数据里的 uv.y 已按
//     目标 NDC 翻转（clip(-1,-1) 在 Vulkan/Metal 都是屏幕左下），本 shader
//     **不**再翻转——翻转放在数据里，是为了让「朝向」只在一处定义，
//     换个后端不必改 shader。
//   * gl_Position.z = 0、w = 1：本 pass 无深度语义。

layout(location = 0) in vec2 aPos;
layout(location = 1) in vec2 aUv;

layout(location = 0) out vec2 vUv;

void main()
{
    gl_Position = vec4(aPos, 0.0, 1.0);
    vUv = aUv;
}
