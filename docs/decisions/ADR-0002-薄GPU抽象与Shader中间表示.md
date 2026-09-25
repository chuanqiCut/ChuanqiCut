# ADR-0002：自研薄 GFX 抽象 + SPIR-V 作为 Shader 中间表示

- **状态**：提案（待批准）
- **日期**：2026-09-23
- **相关**：RESEARCH-001 C4、ARCH-003 §2/§4

## 背景

原调研三份文档对渲染核心给出三个不同结论：决策书「手写 Metal，不引入 MetalPetal」、管线决策表「强烈推荐 MetalPetal」、竞品分析「用 MetalPetal 作为基础或参考自研」。

在 ADR-0001（C++ 共享内核）成立之后，这个问题有了确定答案：**MetalPetal 是 Swift/Apple 单端框架，引入它等于把渲染核心锁死在 Apple 端，与共享内核直接冲突。**

随之而来的是 shader 问题：Metal Shading Language 只在 Apple 可用，Android 需要 GLSL ES / Vulkan，鸿蒙同理。

## 决策

1. **不引入 MetalPetal。** 自研 Thin GFX HAL（`IGraphicsDevice` 等约 12 个概念），每个平台一个后端实现：
   - Apple → Metal（保留 `CVPixelBuffer → CVMetalTextureCache → MTLTexture` 零拷贝原生路径）
   - Android → Vulkan（旗舰）+ GLES 3.1（基线，双后端）
   - HarmonyOS → Vulkan（P2）
2. **Shader 采用「双层」策略，而不是单一源一刀切**（2026-09-23 修订，见下）：
   - **Portable 层（默认，必须）**：GLSL 单一源 → glslang → SPIR-V → SPIRV-Cross → MSL / GLSL ES。这是跨平台基线，保证三端行为一致。
   - **Platform-Native 层（可选加速）**：针对特定平台手写的原生 shader，允许无保留地使用平台特性。
3. **不做 RHI 级别的过度抽象**。只抽象 device/queue/texture/buffer/renderTarget/pipeline/shader/sampler/fence/externalImage 等必要概念，目标 3–5k 行。
4. **绑定号由 SPIRV-Cross 反射信息自动生成**，禁止手写维护。仅对 Portable 层适用。

---

## 决策 2 详述：Shader 双层机制

> **修订记录 2026-09-23**：初版规定"禁止使用平台专属扩展"，即所有 shader 只能走 SPIR-V 最小公分母。
> 传哲指出 shader 层面应能**单独使用平台特性**。已采纳并重构为双层机制。
> 理由成立：iOS/macOS 是重点支持平台，若 shader 被限制在跨平台最小公分母，等于主动放弃 Apple 端的性能上限。

### 两层定义

| | **Portable 层** | **Platform-Native 层** |
|---|---|---|
| 源码位置 | `shaders/src/*.glsl` | `pal/<platform>/shaders/*` |
| 语言 | Vulkan 方言 GLSL 4.50 | 平台原生（MSL / GLSL ES / 平台扩展） |
| 生成方式 | glslang → SPIR-V → SPIRV-Cross | 直接编译，无中间表示 |
| 作用 | **跨平台基线，唯一必需实现** | **可选加速**，可完全不存在 |
| 能用平台特性 | ❌ 禁止 | ✅ 无限制（argument buffer、tile memory、SIMD、texture2d 优化…） |
| 维护成本 | 一份代码三端跑 | 每平台单独维护 |

### 选择机制

`RenderNode` 可声明平台特化实现，RenderGraph 运行时按能力选择：

```
RenderNode.declare()   → 声明 portable 实现（必需）
RenderNode.specialize(platform) → 可选返回平台特化实现

运行时：
  有特化实现且能力查询通过 → 用特化实现
  否则                    → fallback 到 portable 实现
```

### 四条硬约束（防止双层机制失控）

1. **Platform-Native 永远是可选的。** 任何效果都必须先有 Portable 实现，特化只能作为加速路径。否则该效果在其他平台无实现。
2. **两者必须通过同一组一致性测试。** 同平台回归 PSNR ≥ 40dB；特化 vs portable 对比 PSNR ≥ 36dB、SSIM ≥ 0.98。差异过大说明特化实现有 bug。
3. **加特化实现必须给出性能收益数据。** 收益不显著的（< 20% 帧时间改善）不予合入——它换来的是一份要长期维护的重复代码。
4. **特化 shader 不得出现在 `shaders/src/`，也不得进入 core 层。** 只在 `pal/<platform>/shaders/`。

### 这个设计的实际收益

iOS/macOS 作为重点支持平台，现在可以用满 Metal 特性做关键效果（美颜、调色、多轨合成）的特化版本，而 Android 继续跑 portable 版本。重点平台拿性能上限，其余平台拿一致性保证，两者不冲突。

## 备选方案

| 方案 | 否决理由 |
|---|---|
| 统一走 Vulkan（Apple 用 MoltenVK） | Android 仍需 GLES 后端 → 抽象层不可避免；MoltenVK 额外一层会使 Apple 端零拷贝路径复杂化，收益不确定 |
| 三端各写一套 shader | 行为一致性无法保证，维护 ×3 |
| 自研 shader DSL/编译器 | 工作量远超收益 |
| naga（Rust wgpu） | MSL 后端成熟度低于 SPIRV-Cross；引入 Rust 工具链 |
| MetalPetal | 锁死 Apple 端，与 ADR-0001 冲突 |

## 后果

**正面**
- Shader 单一源，跨平台一致性由工具链保证
- Apple 端保留原生 Metal 性能路径（零拷贝不被抽象层吃掉）
- SPIRV-Cross 是 Apache-2.0，且 MSL 后端被 MoltenVK 生产验证并持续维护

**负面 / 风险**
- GLSL→MSL 的自动转换无法覆盖 Metal 的全部特性 —— **已由 Platform-Native 层解决**（重点平台可手写原生 shader）
- 双层机制带来重复实现：同一个效果可能有两份代码，维护成本上升 —— 由硬约束 3（收益 ≥ 20% 才允许）控制数量
- 构建链增加两个构建期依赖（glslang、SPIRV-Cross）
- Shader 调试链路变长（需定位到生成后的源码）
- 抽象层本身有 bug 时，三端同时受影响

**缓解**
- Portable 层编写约束写入代码规范并由 CI 检查（禁用平台扩展、显式精度限定符、禁用支持不佳的特性）
- 生成产物保留可读源码并落盘，便于调试
- 每个 shader 必须有跨平台一致性测试；每个特化实现必须与 portable 版本对比测试
- `cq-shader-portability` 技能强制走完检查清单

## 反转条件

- SPIRV-Cross 的 MSL 后端停止维护或出现无法绕过的阻塞性缺陷；
- 实测证明抽象层导致 Apple 端性能损失超过 15% 且无法通过后端特化优化弥补。

## 落地任务
`GFX-0xx`、`SHADER-0xx`（含 `SHADER-0xx` 中的平台特化任务 `SHADER-1xx`）

## 修订记录
| 日期 | 变更 |
|---|---|
| 2026-09-23 | 初版：单一源 + 禁止平台扩展 |
| 2026-09-23 | 修订：采纳"shader 应能单独使用平台特性"，改为 Portable + Platform-Native 双层机制 |
