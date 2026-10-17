# 模块：Shader（双层机制）

> **归属**：C 线（内核/媒体/渲染） —— 归属表见 docs/tasks/PLAN-三线并行.md §1a / ADR-0029（双机分工与门禁跑批，2026-10-07）

> **落地状态（2026-10-12，SHADER-001 / B0）**：Portable 层第一步已落地并**双壳构建
> 验证**：`engine/shaders/portable/blit.{vert,frag}` → glslang 16.0.0（SPIR-V）→ SPIRV-Cross（MSL）
> → 构建期生成 `blit_msl.h`（落 `build/generated/shaders/`，不入库）。工具链
> scope=build，**装配入口唯一** = `tools/build/build_shader_toolchain.sh`（INFRA-034 / P160：
> 这两个二进制曾长期只活在暖缓存 `build/tools/` 里，仓库没有产出脚本 → 清 `build/`、
> 新克隆机、CI runner 一律编不出内核）。出参目录**必须**是 `build/tools/glslang/` 与
> `build/tools/spirv-cross/`（全小写，`tools/shaders/build_shaders.py:111-113` 的默认查找路径），
> 大小写只在 APFS 上"碰巧能用"。
> **两端接线**：CMake custom command（`engine/platform/apple/CMakeLists.txt`）
> + podspec `script_phases`（Xcode/Pods 侧，`ChuanqiCutCore.podspec`）——
> 两套构建系统写同一份幂等产物。手写 MSL（`blit_fullscreen_msl.h`）已退役。
> 反射（*.json）/ 多 shader 管理 / Platform-Native 加速未做。

**可手改**：`engine/shaders/portable/*.glsl`（Portable）、`engine/shaders/native/<platform>/*`（Platform-Native，本期为空）
**不可手改**：`build/generated/shaders/`（产物，不入库；旧文档写的仓库根 `shaders/generated/` 从未真正落过东西，INFRA-033 已随目录搬家作废）

> **2026-09-23 修订**：初版规定"禁止平台扩展"。现改为双层：Portable（跨平台基线）+ Platform-Native（平台原生加速）。
> 传哲要求 shader 能单独使用平台特性 —— 重点平台（iOS/macOS）要能拿满性能上限。

---

## 一、Portable 层（必需）

```
engine/shaders/portable/*.glsl (GLSL 4.50 Vulkan 方言)
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

位置：`engine/shaders/native/<platform>/`（**本期为空**，仅 `native/README.md` 说明预留与边界）
直接编译，**可以用满平台特性**（argument buffer、tile memory、SIMD、texture2d 优化、厂商扩展…）

### 四条硬约束（防止失控）
1. **永远可选**：任何效果必须先有 Portable 实现，特化只作加速路径。否则其他平台无实现。
2. **一致性测试**：特化 vs portable，PSNR ≥ 36dB、SSIM ≥ 0.98
3. **收益门槛**：帧时间改善 < 20% 不予合入 —— 否则只是多一份要长期维护的重复代码
4. **位置约束**：只在 `engine/shaders/native/<platform>/`，不得进 `engine/shaders/portable/` 或 core 层

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

---

## 模块册（ADR-0030：任务/进度/测试门禁记录按模块归口）

> 本节由归属线更新（一机一线，天然单写者）；BACKLOG / pitfalls / baselines 等
> 全局册零直写（集成机阶段批落账）。新调研/规格/审查落 docs/ 原位，但必须在此登记指针。

### 任务与进度（在飞 + 近期；全量 DAG 见 TASK-BACKLOG）

| Task ID | 标题 | 状态 |
|---|---|---|
| TASK-INFRA-033 | Portable GLSL 从仓库根 `shaders/src/` 并入 `engine/shaders/portable/`，Platform-Native 落 `engine/shaders/native/<platform>/`（本期只建 `native/README.md` 说明预留），删空残壳 `shaders/`，修订红线 #6 路径措辞并重生成 5 个入口文件 | **本机窄检已绿**（模块级：清 `build/generated` 重生成 + `-Werror` 编译 + ctest 52/52）；全量门禁与双壳由末批 INFRA-034 统一跑 |

### 测试与门禁记录（阶段批）

| 日期 | 阶段/范围 | 结论（数字） |
|---|---|---|
| 2026-10-16 | **INFRA-033 shader 两半并入 `engine/shaders/`**（模块级窄检，本机=集成机） | tracked 形态：`git ls-files engine/shaders` = **3**（`portable/blit.{vert,frag}` + `native/README.md`）、`git ls-files shaders` = **0**（目录已不在磁盘上）。**防"增量复用假绿"**：先 `rm -rf build/generated` 再 `tools/build/build_core.sh --platform=apple --test` → exit 0，日志 `[27%] SHADER-001: glslang → SPIR-V → spirv-cross → MSL (blit)` 真实执行、`ctest 100% tests passed out of 52`、real **135.17s**、`error:` **0** 行。**产物逐字节核对**：`spv/blit.vert.spv` **960B**、`spv/blit.frag.spv` **548B**、`msl/blit.vert.metal` **418B**、`msl/blit.frag.metal` **410B** —— 四条与搬家前**完全相等** → 转译结果未被搬动污染；`blit_msl.h` **1665B → 1689B**（+24B 恰好等于 banner 两行路径字面各 +12B：`shaders/src/*.glsl`→`engine/shaders/portable/*.glsl`、`来源：shaders/src/blit.vert`→`来源：engine/shaders/portable/blit.vert`）→ 差额可解释，非代码变化。**GLSL 代码等价取证**：剥离 `//` 注释后 md5 与 `HEAD:shaders/src/*` 逐字相同（vert `568b81024e9e24d46e75f60fa0775eda`、frag `687a47617c0344e74f95f849726783d4`）→ 红线 #6「禁平台扩展」没被顺手破。**扫描根未误改**：`check_platform_headers.py` = `scanned 43 header(s) … 0 violation(s)`（与 INFRA-032 基线逐字相同），exit 0。**入口一致性**：`sync_context.py --check` → 所有入口文件与真源一致。⚠️ **本批未跑**：全量 15 步门禁、双壳 `pod install`、iOS/mac 真机（shader 只碰构建路径，归 034 末批一趟）。 |
| 2026-10-17 | **INFRA-034 · SHADER-001 构建期依赖出树**（本机=集成机，CI 等价复现顺手抓的 P160） | 清空 `build/` 复现 CI 才暴露：**仓库里从来没有产出 glslang/spirv-cross 的脚本**，两个二进制只活在历史会话的 `build/tools/` 里。新增 `tools/build/build_shader_toolchain.sh` 后从零实测：glslang **3 133 560B**（pin `a57276bf`，`CHANGES.md` 版本级核对 16.0.0，非 git 树故 commit 级**明打不可校验**）、SPIRV-Cross **4 155 984B**（pin `aa217aeb`），端到端 `blit_msl.h` = **1689B** 与 033 基线相等；`.github/workflows/ci.yml` 增加装配步（约束：**必须在 `build_core.sh` 之前**）。构建耗时：glslang ≈50s、SPIRV-Cross ≈65s（-j12，Intel x86_64）。 |
| 2026-10-17 | **P162：装配脚本的幂等/只读自证**（负向测试抓出来的两处自身缺陷） | 四遍干净复现全绿后跑 `--check-only` 负向测试，抓到：① 名义"只读"的模式里 `rm -rf` 分支照走（把探针连目录删了）；② 补丁指纹守卫拿 `SPVC_PATCH_FP:STRING=` grep cache，而裸 `-D` 在 cache 里落 `:UNINITIALIZED=` → **恒不命中** → 每次暖跑误判"补丁变了"、白删白重编 ~65s。两处修完复验：暖态完整跑两工具均 `产物已存在，跳过编译`、暖态 `--check-only` 产物 md5 前后一致、藏 `glslang` 则 rc=**1**。规则见 pitfalls P162。**对本模块的净效果**：SHADER-001 的构建期依赖第一次有了"入库脚本能从零产出 + 幂等 + 可只读校验"三件，`blit_msl.h` 四遍恒为 **1689B**。 |

### 调研 · 决策 · 池指针

- ADR-0002/0013/0021 · cq-shader-portability skill（Portable 禁平台扩展）
