# QUESTIONNAIRE-B0-B0渲染地基三块

> 立依据：`ADR-0034` §5。**未经本问卷回收，B0 不得标记完成。**

---

## 0. 本批基本信息

| 项 | 值 |
|---|---|
| 批号 | `B0` |
| 主题 | B0 渲染地基三块：RENDER-001（RenderGraph）+ SHADER-001（Portable shader 链）+ MODEL-003（效果属性系统） |
| 关联卡 | TASK-RENDER-001 / TASK-SHADER-001 / TASK-MODEL-003；红线 #9 / #6 / #4 / #5；ADR-0014（不复刻两套路径） |
| 提交 range | **未提交**（合并快检须传哲先同意；本问卷基于工作树状态） |
| 机器侧填写人与时间 | 集成机（Step 模型），2026-10-12 22:55 |
| 集成机环境 | macOS 26.7.1 / Xcode 26.6 / Swift 6.3.3 / **Intel x86_64**（无 ANE、无 ProRes 硬编） |

## 1. 这批改了什么（面向人 readable，不贴代码）

一句话：**预览的渲染路径从「手写一次 blit」换成「RenderGraph 装配 + 执行」，blit shader 改从
Portable GLSL 构建期转译而来；另外立好了「片段挂效果、效果带参数」的数据与撤销链 ——
但本批**不应用效果**（画面应与改前逐像素一致），效果参数要等到 B7 才看得见。**

| 文件 | 变更类型 | 说明 |
|---|---|---|
| `engine/core/cq/render/*`（7 头 + 4 实现） | 新增 | RenderGraph：节点 DAG / 拓扑 / 指纹 / 三用途装配器 / 两阶段执行器 / 时钟源 / 视口计算 |
| `engine/core/cq/model/chq_property.{h,cpp}` | 新增 | 属性值/属性袋/效果栈（MODEL-003） |
| `engine/core/cq/model/chq_timeline.{h,cpp}` | 修改 | ChqClip 挂效果栈 + 7 个效果方法 |
| `engine/core/cq/command/chq_command.{h,cpp}` | 修改 | 4 条属性命令（Do/Undo/Redo） |
| `engine/core/cq/model/chq_editor_model_state.cpp` | 修改 | digest 混入效果栈指纹 |
| `engine/core/cq/session/chq_editor_session.{h,cpp}` | 修改 | 4 个 Submit* |
| `engine/core/cq/cq_sdk.{h,cpp}` | 修改 | **热点（C ABI）**：11 个函数 + 2 个查询结构体 |
| `engine/core/cq/preview/chq_preview_renderer.{h,cpp}` | 修改 | 改走 RenderGraph（删除本地视口计算与 BlitClient） |
| `shaders/src/blit.{vert,frag}`、`tools/shaders/build_shaders.py` | 新增 | Portable shader + 转译链 |
| `engine/platform/apple/gfx/blit_pass.mm` | 修改 | 消费生成 MSL（手写 MSL 退役） |
| `engine/platform/apple/gfx/shaders/blit_fullscreen_msl.h` | 删除 | 被 Portable 链取代 |
| `engine/ChuanqiCutCore.podspec` | 修改 | **热点**：script_phases + header search path → **两端须重跑 `pod install`** |
| `engine/core/CMakeLists.txt`、`tests/CMakeLists.txt` | 修改 | 登记新 TU 与两个新用例 |
| `tests/unit/test_render_graph.cpp`、`test_model_property.cpp`、`test_c_abi_property.c` | 新增 | 单测 |

**热点文件与 ABI 影响**：是 —— `cq_sdk.h` 纯 C 新增（既有函数零改动，Swift 绑定不受影响）；
podspec 改了（script phase + search path）→ **两端都已重跑 `bundle exec pod install`**；
`docs/api/engine-api.md` 未重生成（该文件生成源路径本就失效，属已知漂移，另卡处理）。

## 2. 机器侧证据（必须真实执行的命令与数字）

| 命令 | 结果 | 备注 |
|---|---|---|
| `tools/build/build_core.sh --platform=apple --config=Debug` | **PASS** | 0 error / 0 warning（-Werror） |
| `tools/build/build_core.sh --platform=apple --config=Release` | **PASS** | 0 error / 0 warning |
| `ctest --test-dir build`（Debug） | **51/51 Passed**（76.8s） | 批前基线 48 |
| `ctest --test-dir build`（Release） | **51/51 Passed**（74.9s） | |
| `ctest -R render_graph` | Passed | 含新增 effects_dropped 两例 |
| `ctest -R model_property` | Passed | **179 checks, 0 failures** |
| `ctest -R c_abi_property` | Passed | **76 checks, 0 failures** |
| `ctest -R preview_renderer` | Passed | 51 项：像素一致（contain 清屏黑 / 真值像素） |
| `ctest -R platform_header_gate` | Passed | 新模型头 float 用法合规 |
| `xcodebuild -scheme ChuanqiCutApp -destination generic/platform=iOS build` | **SUCCEEDED**（1m14s） | pod install 后 |
| `xcodebuild -scheme ChuanqiCutMacApp -arch x86_64 ONLY_ACTIVE_ARCH=YES build` | **SUCCEEDED**（48s） | Intel 必须带 arch |

**没跑的项目必须在此列出并写明原因**：
- **全量 `run_gate.sh` 未跑** —— 按约定须传哲明确同意才跑（约 22 分钟）。
- **真机未跑** —— 设备在传哲手里，本问卷就是交付给传哲跑的。
- **golden `verify.py` 未跑** —— 本批不产出新 golden 帧（预览像素由 preview_renderer 断言守）。
- **音频线 AUDIO-004 未写** —— agent 429 限流（重置 2026-10-13 10:38 UTC+8），零产出。

## 3. 已知偏差与本期明确不做

- 已知偏差（知道但不改）：
  - UI 侧 `PreviewFrameRenderer.swift` 仍持有一份手写 MSL，未并入 Portable 链（本批只动 core 侧 blit）；
  - Xcode script phase 无 outputs → 每次构建都重跑生成（约百毫秒，换「永远新鲜」）；
  - `docs/api/engine-api.md` 未随新 ABI 重生成（生成源路径失效，另卡）。
- **本期明确不做**（排期决定，不是遗漏）：
  - 效果**应用**（RENDER-011/B7）、多轨合成（B7）、导出编排（B4）、效果目录 EFFECT-001、
    关键帧/动画（anim 模块）、音频多轨混音（AUDIO-004，限流阻塞）。
- 上机前注意事项：安装用 Debug 构建即可；测试素材用库里任意视频；
  本批是**回归型**问卷 —— 预期「什么都看不出来」，看出来就是Bug。

## 4. 真机检查点（传哲填写）

> 编号格式 `Q-B0-<序号>`。每条写下「怎么操作」「应该看到什么」「**实际**」。
> **本批核心预期：与改前逐像素一致 + 不卡。** 任何"看起来变了"都请记录。

| 编号 | 操作步骤 | 预期 | 实际（留白） |
|---|---|---|---|
| `Q-B0-01` | iOS：导入一个视频，进编辑器，拖动播放头扫过整段 | 画面与以往完全一致（无黑闪/无花屏/无上下颠倒） | |
| `Q-B0-02` | iOS：播放 30 秒以上，观察帧率与音画同步 | 不卡顿；音频不抢拍不拖拍（本批换了渲染路径，重点看有没有变卡） | |
| `Q-B0-03` | iOS：切换画布比例（9:16 / 1:1 / 横屏）各播放几秒 | 三种比例下画面适配正常（contain 留黑边、cover 裁剪、stretch 铺满行为不变） | |
| `Q-B0-04` | iOS：快速来回拖拽播放头（seek 压力） | 画面跟手，无残留旧帧、无绿屏/紫屏等异常色 | |
| `Q-B0-05` | iOS：首页 → 导入 → 编辑 → 返回，反复 5 次 | 无崩溃、无内存报警（关注jetsam） | |
| `Q-B0-06` | iOS：锁屏/切后台再回编辑器 | 恢复后预览正常（RenderGraph 每帧重建，不应有状态残留） | |

### Mac 端专属

| 编号 | 操作步骤 | 预期 | 实际（留白） |
|---|---|---|---|
| `Q-B0-M01` | macOS：同样导入播放、拖播放头、切比例 | 与 iOS 预期一致（Intel 机型，无 ANE/ProRes，不作性能结论） | |
| `Q-B0-M02` | macOS：连续播放 5 分钟 | 内存平稳无泄漏增长（RenderGraph 每帧装配，重点看有没有每帧涨） | |

### iOS 端专属

| 编号 | 操作步骤 | 预期 | 实际（留白） |
|---|---|---|---|
| `Q-B0-I01` | iOS：低电量模式下播放 2 分钟 | 不异常发热/掉帧（Intel Mac 数字不作数，真机才算） | |

## 5. 主观评价（传哲填写，可选但很有用）

- 手感：（跟手吗 / 有无迟滞 / 意外触发）
- 观感：（是否与预期一致 —— 本批预期"看不出变化"）
- 其他：

## 6. 回收区（集成机回填）

- 回收时间：
- 结论：符合 / 不符合（清单）：
- 纠偏登记（LEDGER-W42 追加条目）：
