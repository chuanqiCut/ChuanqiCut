---
name: cq-shader-portability
description: 新增或修改 shader 时必须跑。Portable 层保证三端一致，Platform-Native 层允许用满平台特性但受四条硬约束。
---

# Shader 改动检查

## 触发
新增 / 修改 `shaders/src/*.glsl`（Portable）或 `pal/<platform>/shaders/*`（Platform-Native）。

## 先判断改的是哪一层

| | Portable | Platform-Native |
|---|---|---|
| 位置 | `shaders/src/*.glsl` | `pal/<platform>/shaders/*` |
| 语言 | GLSL 4.50 Vulkan 方言 | 平台原生（MSL / GLES 扩展…） |
| 能否用平台特性 | **禁止** | 可以，无限制 |
| 是否必需 | 是（跨平台基线） | 否（可选加速） |

---

## A. 改 Portable 层

### 编写约束
- 只用 GLSL 4.50 core 与 Vulkan 语义，`layout(binding=)` / `layout(set=)` 显式化
- **禁止平台专属扩展**（要用平台特性就去写 Platform-Native）
- 避开 SPIRV-Cross 支持不佳的特性：几何/细分着色器、复杂子组操作、8/16-bit 存储类型
- 禁止分支依赖的纹理采样
- 精度限定符必须显式（`highp` / `mediump`）
- 绑定号由反射生成，禁止手写

### 验证
```bash
tools/shaders/build.sh --all        # 三端产物都能编译
tools/shaders/lint.sh               # 禁用特性检查
tools/qa/golden_compare.sh --case=shader_<name>
```
阈值：同平台回归 PSNR ≥ 40dB；跨平台 PSNR ≥ 36dB、SSIM ≥ 0.98。
关键区域（人脸/文字/alpha 边缘）单独校验，别被全画面均值掩盖。

---

## B. 改 / 新增 Platform-Native 层

### 四条硬约束（缺一不可，否则驳回）
1. **必须先有 Portable 实现** —— 特化只能是加速路径，不能是唯一实现
2. **一致性**：特化 vs portable，PSNR ≥ 36dB、SSIM ≥ 0.98
3. **收益门槛**：帧时间改善 **≥ 20%**，否则只是多一份要维护的重复代码
4. **位置**：只在 `pal/<platform>/shaders/`，不得进 `shaders/src/` 或 core 层

### 验证
```bash
tools/qa/golden_compare.sh --case=shader_<name> --compare=native_vs_portable
tools/perf/render_bench --shader=<name> --variant=portable,native
```
PR 必须附：收益数据 + 一致性报告 + 为什么值得维护两份代码的说明。

---

## C. Compute Shader 专项
GLES 3.0 无 compute；ES 3.1 可用但部分机型有缺陷（**中端机也可能中招**）。
- Portable 层必须有 fragment 等价实现
- 运行时 `CQ_CAP_COMPUTE_SHADER` 查询 + 自动降级 + 设备黑名单
- 两条路径过同一组一致性测试

---

## 检查清单
- [ ] 已明确改的是哪一层
- [ ] Portable：遵守全部编写约束、lint 通过、三端可编译、一致性达标
- [ ] Native：四条硬约束全部满足，附收益数据
- [ ] 未手改生成产物
- [ ] 实测数据已记录（**不要写估算值**）

## 输出
PR 附：三端编译结果 + golden 对比报告 + 实测耗时（含 native vs portable 收益）。
