# 模块：Shader（双层机制）

**可手改**：`shaders/src/*.glsl`（Portable）、`pal/<platform>/shaders/*`（Platform-Native）
**不可手改**：`shaders/generated/`（产物，不入库）

> **2026-09-23 修订**：初版规定"禁止平台扩展"。现改为双层：Portable（跨平台基线）+ Platform-Native（平台原生加速）。
> 传哲要求 shader 能单独使用平台特性 —— 重点平台（iOS/macOS）要能拿满性能上限。

---

## 一、Portable 层（必需）

```
shaders/src/*.glsl (GLSL 4.50 Vulkan 方言)
   → glslang      → *.spv
   → SPIRV-Cross  → *.metal (Apple) / *.glsl ES (Android) / *.json (反射)
```

### 编写约束（违反会导致三端行为不一致）
1. 只用 GLSL 4.50 core 与 Vulkan 语义，`layout(binding=)` / `layout(set=)` 显式化
2. **禁止平台专属扩展**（要用平台特性就去写 Platform-Native）
3. 避开 SPIRV-Cross 支持不佳的特性：几何/细分着色器、复杂子组操作、8/16-bit 存储类型
4. 禁止分支依赖的纹理采样
5. 精度限定符必须显式（`highp` / `mediump`）
6. 生成产物禁止手改、禁止入库
7. 绑定号由反射生成，禁止手写

---

## 二、Platform-Native 层（可选加速）

位置：`pal/apple/shaders/*.metal`、`pal/android/shaders/*.glsl`
直接编译，**可以用满平台特性**（argument buffer、tile memory、SIMD、texture2d 优化、厂商扩展…）

### 四条硬约束（防止失控）
1. **永远可选**：任何效果必须先有 Portable 实现，特化只作加速路径。否则其他平台无实现。
2. **一致性测试**：特化 vs portable，PSNR ≥ 36dB、SSIM ≥ 0.98
3. **收益门槛**：帧时间改善 < 20% 不予合入 —— 否则只是多一份要长期维护的重复代码
4. **位置约束**：只在 `pal/<platform>/shaders/`，不得进 `shaders/src/` 或 core 层

### 选择机制
```cpp
// RenderNode
virtual Status declare(NodeDeclaration&) = 0;                    // portable 实现（必需）
virtual std::unique_ptr<RenderNode> specialize(Platform) const   // 特化实现（可选）
{ return nullptr; }
```
RenderGraph 运行时：有特化 + 能力查询通过 → 用特化；否则 fallback portable。

---

## 三、每新增/修改 shader 必做

**Portable 层：**
```bash
tools/shaders/build.sh --all     # 三端生成产物都能编译
tools/shaders/lint.sh            # 禁用特性检查
tools/qa/golden_compare.sh --case=shader_<name>
```

**Platform-Native 层（额外）：**
```bash
tools/qa/golden_compare.sh --case=shader_<name> --compare=native_vs_portable
tools/perf/render_bench --shader=<name> --variant=portable,native   # 收益 ≥ 20%
```

## 四、Compute Shader 专项
GLES 3.0 无 compute；ES 3.1 可用但部分机型有缺陷（中端机也可能中招，不是低端专属问题）。
- Portable 层必须提供 fragment 等价实现
- 运行时 `CQ_CAP_COMPUTE_SHADER` 查询 + 自动降级 + 设备黑名单
- 两条路径过同一组一致性测试

## 相关
ADR-0002（含修订记录）、ARCH-003 §4、Skill `cq-shader-portability`
