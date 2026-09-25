# 模块：GFX 抽象与平台后端

**边界**：`core/include/cq/gfx/`、`core/src/gfx/`、`pal/<platform>/gfx_*`

## 职责
薄 GPU 抽象（约 12 个概念），各平台后端实现，纹理池与内存预算，外部图像零拷贝导入。

## 概念映射
| CQ | Metal | Vulkan | GLES 3.1 |
|---|---|---|---|
| Device | MTLDevice | VkDevice | EGLDisplay+Context |
| CommandQueue | MTLCommandQueue | VkQueue | 隐式 |
| CommandBuffer | MTLCommandBuffer | VkCommandBuffer | 隐式 |
| Texture | MTLTexture | VkImage+View | GLuint |
| Buffer | MTLBuffer | VkBuffer | GLuint(UBO) |
| RenderTarget | MTLRenderPassDescriptor | VkRenderPass+Framebuffer | FBO |
| Pipeline | MTLRenderPipelineState | VkPipeline | GLuint program |
| ShaderModule | MTLLibrary | VkShaderModule | GLuint shader |
| Sampler | MTLSamplerState | VkSampler | GLuint |
| Fence | MTLFence/SharedEvent | VkFence/Semaphore | glFenceSync |

## 硬约束
1. **不抽象同步语义的细粒度差异**，只提供 wait/signal。
2. **不隐藏显存分配**：池化与预算在 core 层统一，后端只负责真实分配。
3. **后端特化不得泄漏到 core**：平台专属优化只能作为可选路径，必须有通用等价实现。
4. **不统一走 MoltenVK**（见 ADR-0002 理由）。
5. 外部图像导入失败必须能退化为 CPU 拷贝，不得崩溃。

## Compute Shader 风险
GLES 3.0 无 compute；Android 基线 ES 3.1 可用但存在 ROM 缺陷。
→ 核心效果必须有 fragment 等价实现；运行时能力查询 + 自动降级 + 设备黑名单。

## 验证
```bash
ctest -R gfx_pool
tools/perf/gfx_bench --platform=<p>   # 纹理带宽与帧时间
# 零拷贝验证：确认无 memcpy（Instruments / systrace）
```

## 相关
ADR-0002、ARCH-003 §2/§3/§7
