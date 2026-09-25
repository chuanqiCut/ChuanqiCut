# ARCH-003：跨平台内核、GPU 抽象与 Shader 策略

> 版本：v1.0（待 Review）
> 日期：2026-09-23
> 这是本方案技术风险最高的部分，请重点 Review §4（Shader 工具链）与 §7（Compute Shader 风险）。

---

## 1. 为什么共享内核用 C++

| 候选 | 结论 | 理由 |
|---|---|---|
| **C++20** | ✅ 采用 | 业界事实标准（CapCut、Premiere、DaVinci 均为 C++ 核心）；与 Android NDK、鸿蒙 NAPI、Apple ObjC++ 均能直接互操作；团队能力匹配 |
| Rust + wgpu | ❌ | naga 到 MSL 的成熟度低于 SPIRV-Cross；NDK/NAPI 工具链整合成本高；无法渐进迁移 |
| Kotlin Multiplatform | ❌ | 只共享数据模型，无法承载渲染与算法；与 C++ 内核职责重复 |
| 各端独立实现 | ❌ | 三端三套效果算法，行为一致性无法保证，维护成本 ×3 |

**共享边界**：共享「引擎、算法、模型、序列化」；**不共享 UI**。UI 用各平台原生框架，见 `ARCH-005`。

---

## 2. GFX 抽象：薄，不要厚

### 2.1 为什么不统一走 Vulkan

考虑过「全部走 Vulkan，Apple 端用 MoltenVK」。否决理由：

1. Apple 端最大的性能优势是 **`CVPixelBuffer` → `MTLTexture` 零拷贝**（UMA）。走 MoltenVK 需要从 IOSurface 再导入一层，这层桥接的可用性与性能需要额外验证，收益不确定。
2. Android 端 Vulkan 实现碎片化严重，中低端设备必须保留 GLES 后端。**既然 Android 要写两个后端，抽象层的存在就是必要的**，那么 Apple 端直接写 Metal 后端反而是最省事、最可控的。
3. MoltenVK 本身很成熟（Valve/Unity/Godot 生产使用），但它是**又一层**依赖与又一层不确定性，在不需要它统一一切的前提下不值得。

**结论：自研 Thin GFX HAL。只抽象约 12 个概念，不做 RHI 级别的过度设计。** 目标代码量 3–5k 行。

### 2.2 概念映射表

| CQ GFX 概念 | Metal | Vulkan | GLES 3.1 |
|---|---|---|---|
| `Device` | `MTLDevice` | `VkDevice` | `EGLDisplay` + `EGLContext` |
| `CommandQueue` | `MTLCommandQueue` | `VkQueue` | 隐式 |
| `CommandBuffer` | `MTLCommandBuffer` | `VkCommandBuffer` | 隐式 |
| `Encoder` | `MTLRenderCommandEncoder` | `VkCmdBeginRenderPass` | `glBindFramebuffer` |
| `Texture` | `MTLTexture` | `VkImage` + `VkImageView` | `GLuint` |
| `Buffer` | `MTLBuffer` | `VkBuffer` | `GLuint`（UBO/SSBO） |
| `RenderTarget` | `MTLRenderPassDescriptor` | `VkRenderPass` + `VkFramebuffer` | FBO |
| `Pipeline` | `MTLRenderPipelineState` | `VkPipeline` | `GLuint` program |
| `ShaderModule` | `MTLLibrary` | `VkShaderModule` | `GLuint` shader |
| `Sampler` | `MTLSamplerState` | `VkSampler` | `GLuint` |
| `Fence` | `MTLFence` / `MTLSharedEvent` | `VkFence` / `VkSemaphore` | `glFenceSync` |
| `ExternalImage` | `CVPixelBuffer`→`CVMetalTexture` | `AHardwareBuffer`→`VkImage` | `AHardwareBuffer`→`EGLImage` |

### 2.3 抽象层的三条硬约束

1. **不抽象同步语义的细粒度差异**：只提供 `wait(fence)` / `signal(fence)`，各后端自行实现。
2. **不隐藏显存分配**：`TexturePool` 在 core 层做统一的池化与预算控制，后端只负责真实分配。
3. **平台特化只存在于 Platform-Native shader 层，不泄漏到 core**：若某效果在 Metal 上能用特性显著加速（argument buffer、tile memory 等），走 §4 的 Platform-Native 机制 —— 提供 portable 等价路径 + 平台特化加速，**特化代码只放在 `pal/<platform>/shaders/`**。core 层不得出现平台分支。

---

## 3. 零拷贝路径（每平台）

零拷贝是 Apple 端性能优势的来源，也是 Android 端最容易踩坑的地方。

| 平台 | 路径 | 关键点 |
|---|---|---|
| **Apple** | `CVPixelBuffer` → `CVMetalTextureCacheCreateTextureFromImage` → `MTLTexture` | 解码时 `kCVPixelBufferMetalCompatibilityKey=true`；texture cache 需按 device 持有并复用 |
| **Android (GLES)** | `MediaCodec` surface 模式 → `AHardwareBuffer` → `EGLImageKHR` → `GLuint` texture | 依赖 `AHardwareBuffer` 的 `AHARDWAREBUFFER_USAGE_GPU_SAMPLED`；部分国产 ROM 的 EGLImage 实现有 bug，需设备黑名单 |
| **Android (Vulkan)** | `AHardwareBuffer` → `VK_ANDROID_external_memory_android_hardware_buffer` → `VkImage` | 需检查 extension 与 `AHardwareBuffer` 格式支持表 |
| **HarmonyOS** | `OHNativeWindow` / Surface → Vulkan 外部内存 | P2，仅预留 |

**统一抽象**：`PAL` 提供 `INativeImageImporter::import(CQNativeImageHandle) -> TextureHandle`。上层只关心"给我一张可采样的纹理"，不关心底层怎么来的。导入失败必须能优雅退化为「CPU 拷贝路径」，而不是崩溃。

---

## 4. Shader 策略：双层机制

> **2026-09-23 修订**：初版为"单一源 + 禁止平台扩展"。传哲要求 shader 能单独使用平台特性，
> 已改为 **Portable 层（跨平台基线）+ Platform-Native 层（平台原生加速）**。详见 ADR-0002。

### 4.1 问题

Metal Shading Language 只在 Apple 可用；三端各写一套 shader 一致性无法保证。
但如果强行统一到最小公分母，又会放弃重点平台（iOS/macOS）的性能上限。**两个约束都要满足，所以分两层。**

### 4.2 双层结构

```
┌─ Portable 层（必需）─────────────────────────────────────────┐
│ shaders/src/*.glsl（Vulkan 方言 GLSL 4.50）                  │
│      │ glslang                                               │
│      ▼                                                       │
│   *.spv                                                      │
│      │ SPIRV-Cross                                            │
│      ├──→ *.metal (MSL)      Apple                            │
│      ├──→ *.glsl (ES 3.10)   Android Vulkan                   │
│      ├──→ *.glsl (ES 3.00)   Android GLES                     │
│      └──→ *.json             反射（绑定号由工具生成）           │
└──────────────────────────────────────────────────────────────┘

┌─ Platform-Native 层（可选加速）──────────────────────────────┐
│ pal/apple/shaders/*.metal     ← 可用满 Metal 特性            │
│ pal/android/shaders/*.glsl    ← 可用 GLES/Vulkan 扩展        │
│ pal/ohos/shaders/*            ← P2                            │
│ 直接编译，不经中间表示，无平台特性限制                          │
└──────────────────────────────────────────────────────────────┘
```

**运行时选择**：`RenderNode.specialize(platform)` 返回特化实现 → RenderGraph 按能力查询决定用特化还是 fallback 到 portable。

### 4.3 为什么 Portable 层仍选 SPIR-V

- 直接维护三套：否决（一致性无法保证）
- 自研 DSL：否决（编译器工作量远超收益）
- naga（Rust）：MSL 后端成熟度低于 SPIRV-Cross
- **SPIRV-Cross**：Apache-2.0，MSL 后端是 MoltenVK 的生产依赖，持续活跃维护。**采纳。**

### 4.4 Portable 层编写约束（硬性）

1. 只使用 GLSL 4.50 core 与 Vulkan 语义，`layout(binding=)` / `layout(set=)` 显式化
2. **不使用任何平台专属扩展**（要用平台特性就走 Platform-Native 层）
3. 不使用 SPIRV-Cross 支持不佳的特性：几何/细分着色器、复杂子组操作、8/16-bit 存储类型
4. 禁止分支依赖的纹理采样
5. 精度限定符显式化（`highp` / `mediump`）
6. 每个 shader 必须有跨平台一致性测试（见 §9）

### 4.5 Platform-Native 层四条硬约束

1. **永远可选**：任何效果必须先有 Portable 实现，特化只能作为加速路径
2. **一致性测试**：特化 vs portable，PSNR ≥ 36dB、SSIM ≥ 0.98
3. **收益门槛**：帧时间改善 < 20% 不予合入（否则只是多一份要维护的重复代码）
4. **位置约束**：只在 `pal/<platform>/shaders/`，不得进 `shaders/src/` 或 core 层

### 4.6 反射与绑定

Portable 层由 SPIRV-Cross 输出 JSON 反射信息，构建脚本生成绑定代码。**绑定号由工具生成，不由人维护。**
Platform-Native 层自行管理绑定，但必须与 portable 版本声明相同的 uniform 语义。

---

## 5. RenderGraph

效果链（变换→抠像→美颜→美型→调色→滤镜→转场→合成）天然是 DAG。用 `RenderGraph` 而不是逐 pass 手写：

```
RenderGraph 的职责：
  1. 节点依赖分析与拓扑排序
  2. Pass 合并：相邻且输出仅被下一 pass 消费的节点合并为单 pass
  3. 中间纹理生命周期分析与复用（别名分配），受内存预算约束
  4. LOD：预览模式可跳过标记了 `expensive` 的节点（超分、降噪）
  5. 导出模式禁用 LOD，全量执行
```

**为什么必须有**：原调研文档把效果链描述为 10 个独立 pass，若真按此实现，4K 下每帧要在纹理之间搬运数十 MB，带宽成为瓶颈，60fps 不可能达到。Pass 合并是刚需而不是优化。

---

## 6. 效果节点接口

所有效果实现同一接口，保证可替换（原文档在这点上是散的）：

```cpp
class RenderNode {
public:
    virtual ~RenderNode();
    // 声明输入/输出与所需资源，供 RenderGraph 做拓扑与内存规划
    virtual Status declare(NodeDeclaration& out) = 0;
    // 每帧执行：只更新 uniform 与绑定，不做分配
    virtual Status evaluate(const FrameContext&, CommandEncoder&) = 0;
    // 能力探测：本节点在当前设备是否可用，不可用时返回降级方案
    virtual CapabilityRequirement requirements() const = 0;
};
```

美型的 Mesh Warp / UV Offset Map 两种实现即同一接口的两个子类，切换不换调用方（对应 RESEARCH-001 C5）。

---

## 7. Compute Shader 风险（必须现在就定策略）

**风险**：`OpenGL ES 3.0 没有 compute shader`，`GLES 3.1` 才有。Android 基线 API 26 对应 GLES 3.1，理论上可用，但**部分机型/ROM 上存在实现缺陷与驱动 bug**。

注意：这不是"低端机适配"。即使在中端机上，也可能遇到 compute 实现缺陷，所以这条安全网必须保留。

**策略**：
1. 美颜磨皮、频率分解等核心效果，**Portable 层必须有 fragment shader 等价实现**；compute 版本作为加速路径（可以是 Platform-Native 层的特化，也可以是 portable 层的条件编译变体）。
2. 运行时通过 `cq_query_capability(CQ_CAP_COMPUTE_SHADER)` 决定走哪条，并支持**运行时降级**：compute 路径出现错误（特定错误码或连续 N 帧校验失败）→ 自动切 fragment 并上报。
3. 设备黑名单：CI 与线上维护已知问题机型清单，命中即强制走 fragment。
4. 两条路径的输出必须通过同一组一致性测试（PSNR ≥ 40dB，见 §9）。

不这样做，结果是：Apple 端一切正常，Android 端某批机型花屏/黑屏，且无法快速定位。

---

## 8. 色彩管理

缺乏统一色彩管道会导致"预览 vs 导出"、"iOS vs Android"颜色不一致，这是视频编辑器最难查的 bug 类型之一。

定义：
- **Working color space**：线性 `scene-linear` 或 `BT.2020 linear`（待定，需 ADR）。所有效果在 working space 内计算。
- **输入转换**：解码帧按素材标记的色彩属性（prime/transfer/matrix, HDR10/PQ/HLG）转换到 working space。
- **输出转换**：按目标（SDR 显示 / HDR 显示 / SDR 导出 / HDR 导出）转换。
- **LUT**：`.cube` 在 working space 的既定位置应用，顺序固定（先校正后风格化）。
- **跨端一致性**：同一份色彩转换代码（C++ 实现或 shader 实现）在三端共用，不允许各端自己写。

HDR：Phase 1 走系统自动色调映射（不精确但不出错）；Phase 2 实现显式 EDR/HDR 管道与导出时 HDR/SDR 选择。

---

## 9. 跨端数值一致性与容差

**必须承认的事实**：不同 GPU 的浮点实现、纹理过滤、色彩转换精度不同，**同一项目在 iOS 与 Android 导出的像素不可能 bit-identical**。

定义验收标准（写进测试，不要靠肉眼）：

| 指标 | 阈值 | 适用 |
|---|---|---|
| 全画面 PSNR | ≥ 40 dB | 同一平台前后版本回归 |
| 全画面 PSNR（跨平台） | ≥ 36 dB | iOS vs Android 同项目导出对比 |
| SSIM | ≥ 0.98 | 同上 |
| 关键区域（人脸/文字）PSNR | ≥ 34 dB | 分区域校验，避免局部瑕疵被全画面均值掩盖 |
| alpha 边缘（抠像） | 单独定义 | 边缘是最容易出差异的地方 |

Golden frame 样本库：10 段覆盖素材（人像/风景/文字/绿幕/HDR/低光/高速运动/4K/竖屏/透明），每次发版前跑全量。

---

## 10. 支持的设备档位与内存预算

> **2026-09-23 修订**：明确**不适配低端机**（传哲确认）。低端机不做降级适配，而是**明确不支持**。

### 10.1 支持档位

| 档位 | 定位 | 具体门槛 |
|---|---|---|
| **高端** | 必须流畅：目标 60fps 全效果链 | iPhone 13 Pro 及以上 / A15+；M1 及以上 Mac；骁龙 8 Gen1+ / 天玑 9000+；RAM ≥ 8GB |
| **中端** | 必须可用：允许降预览分辨率 | iPhone 12 / A14；骁龙 7 系 / 天玑 8000；RAM ≥ 6GB |
| **低端** | **不支持** | 低于上述门槛 → 安装/启动时明确提示，不做降级适配 |

**不适配低端机的具体含义**（避免歧义）：
- 不为低端机写专用降级路径（如极简效果链、超低分辨率代理）
- 不做 4GB RAM 设备的内存裁剪
- 低端设备命中门槛以下 → 给出清晰的不支持提示，而不是"能装但卡死"

**仍然保留的安全网**（这不是低端适配，是防御性设计）：
- 能力缺失降级（无硬解 → 软解；无 compute → fragment）：**保留**，因为中端机也可能缺某项能力
- 内存逼近预算时的 LRU 回收与降预览分辨率：**保留**，这是防止 OOM 的基本机制，不是低端优化

### 10.2 内存预算（按中端机为下限定）

| 场景 | 预算（峰值） | 超出时策略 |
|---|---|---|
| 1080p 三轨预览 | ≤ 400 MB | 缩减帧缓存 LRU |
| 4K 三轨预览 | ≤ 1.2 GB | 自动降预览分辨率至 1080p（代理帧） |
| 4K 导出 | ≤ 1.5 GB | 降低并发解码路数 |

预算以**中端机为下限**设定（不是以高端机），保证中端可用；高端机天然宽裕。

**预算是硬约束，写进 CI 性能门禁**；OOM 在视频编辑器里不是"偶发崩溃"，是必现问题。

---

## 11. 与任务系统的对应

落地任务见 `TASK-BACKLOG.md` 的 `GFX-0xx`（抽象层与后端）、`SHADER-0xx`（工具链）、`RENDER-0xx`（RenderGraph 与效果）、`COLOR-0xx`（色彩）、`QA-0xx`（一致性测试）。
