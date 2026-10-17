# TASK-SHADER-010：Portable 基础变换 shader（平移 / 旋转 / 缩放 / 裁剪 + 逐层 alpha）

```yaml
id:          TASK-SHADER-010
layer:       跨平台
goal:        给 Portable 层补上变换 shader，让"第二层画在哪、多大、多不透明"有三端一致的实现
input:       [红线 6（shader 双层）、ADR-0040 B5.5、RENDER-010 与 RENDER-011 的共同前置]
output:      [portable 变换 shader、生成链注册、恒等变换回归夹具、模块册更新]
write_set:   engine/shaders/portable/transform.{vert,frag}（新建）、
             tools/shaders/build_shaders.py（注册第二个 shader 与产物名）、
             engine/platform/apple/CMakeLists.txt、engine/ChuanqiCutCore.podspec 的 script_phases（两套构建写同一份幂等产物）、
             tests/golden/（恒等变换回归夹具）、.ai/modules/shader.md
read_set:    engine/shaders/portable/blit.{vert,frag}、engine/platform/apple/gfx/{blit_pass.mm,gfx_metal.mm}
deps:        [SHADER-001]
acceptance:
  - 六条 Portable 约束逐条过：GLSL 4.50 Vulkan 语义、`layout(binding=)` 显式、精度限定符显式、
    零平台专属扩展、无分支依赖的纹理采样、生成产物不入库
  - 恒等变换（translate 0 / scale 1 / rotate 0）下输出与现有 blit **逐像素一致**（golden 回归，同平台 ≥40dB）
  - 清空 `build/` 后仍能一次产出 MSL —— 这条是 P160 的案底，必须真清一次而不是"看起来绿"
  - 两个构建入口（CMake custom command 与 podspec script_phases）产出**字节相同**的产物（幂等自证，P162）
verification:
  - python3 tools/shaders/build_shaders.py --repo-root . --out-dir build/generated/shaders
  - tools/build/build_shader_toolchain.sh        # 装配入口唯一，别手搓 glslang
  - "${PYTHON_BIN:-python3}" tests/golden/verify.py --json
  - tools/ci/check_apple_shells.sh               # podspec 侧接线只有双壳能判红
  - ⚠️ **`tools/shaders/build.sh` / `lint.sh` / `tools/qa/golden_compare.sh` 都不存在**
    （skill 文档里列的这三条是空头命令）→ 别把它们写进脚本或判据，恒不命中的判据比没有更坏（P162）
risk:        绑定号本该由反射生成（SHADER-002），而**反射未落地** → 本卡沿用 blit 的显式手写 binding 口径，
             并把"两处手写、将来必须对齐反射"登记成明账，不假装反射已经有了。
             Android / HarmonyOS 切片在本机无法验证（Intel Mac 只有 Apple 切片）→ 明确写"跨端未验"，
             不得拿本卡数字当三端一致的证据。
parallel:    false
```

## 背景

传哲 2026-10-17 裁定多轨画面在 v0.2.0 要交付到"能定位、能缩放"的画中画档 → 链上补两张：
本卡（变换 shader）+ [TASK-RENDER-010](TASK-RENDER-010.md)（TransformNode），排在
[TASK-RENDER-011](TASK-RENDER-011.md) 之前。

SHADER-001 已经把链跑通一次：`engine/shaders/portable/blit.{vert,frag}` → glslang → SPIRV-Cross →
构建期生成 MSL。本卡是这条链上的**第二个 shader**，顺带第一次检验"多 shader 管理"是不是纸面能力。

## 必须挂的分析

改 Portable 层 → 强制走 `cq-shader-portability` 的 A 节（编写约束 + 一致性阈值 + 关键区域单独校验）。
本卡**不碰** Platform-Native 层（`engine/shaders/native/` 本期为空，红线 6：Portable 必须先行，
特化收益 < 20% 不予合入）。

## 回写

`.ai/modules/shader.md`（第二个 shader + 多 shader 管理实况）、`.ai/memory/baselines.md`
（恒等变换回归数字 + 清 `build/` 后重产一次的耗时）、`docs/tasks/TASK-BACKLOG.md` §3.1 行状态。

## 落地记录（2026-10-18，集成机编码轮）

状态：**编码完成 + 本机窄检绿**。L3 不在本卡（随 v0.2.0 批末一趟）。

产物：`transform.vert` / `transform.frag`（顶点不做任何变换算术，几何由 core 烘焙 ——
理由写在 transform.vert 头部）；`build_shaders.py` 从单 shader 泛化成 `SHADER_GROUPS`，
新增一组只加一行；`engine/platform/apple/CMakeLists.txt` 与 podspec 两个构建入口都注册了
`transform_msl.h`。

幂等自证（本卡第一项，也是"多 shader 管理不是纸面能力"的证据）：改链后重跑，
**`blit_msl.h` md5 与改前逐位相同** = `93d6e0bf4f8bfc475c997c2cbd22d941`（1689 B）；
`transform_msl.h` = 1867 B。MSL 侧 `[[attribute(0/1/2)]]` 与 `texture(0)`/`sampler(0)` 由
spirv-cross 生成，与管线顶点布局逐项对齐。

两条偏差声明（不静默）：

1. **验收第 2 条换了形式**：`golden 回归 ≥40dB` 在本仓**没有可执行判据** —— `verify.py` 只校验
   夹具齐备性，`tools/qa/golden_compare.sh` 不存在（卡片 verification 里已声明）。换成同帧走
   两条路径（`Encode()` vs `EncodeLayer()`）读回整张 RT 逐像素相减，见
   `tests/unit/preview/test_layer_identity.cpp`。实测最大通道差 **0**（64×64，逐位相同）。
   恒不命中的判据比没有更坏（P162），所以这里是换判据而不是"降标"。
2. **`--groups` 之类的选择器没加**：多组一次生成，增量由 CMake `OUTPUT` 列表决定。
   ⚠️ 新增一组要同时改 `SHADER_GROUPS` 与 CMake 的 `CQ_SHADER_MSL_HEADERS` + `DEPENDS`；
   `DEPENDS` 少写一个源文件 = 增量构建假绿（已写进 CMakeLists 注释）。

跨端未验（risk 条照旧）：本机只有 Apple 切片。Android / HarmonyOS 侧这份 GLSL 没跑过。
