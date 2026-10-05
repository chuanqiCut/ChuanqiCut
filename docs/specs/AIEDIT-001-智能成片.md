# AIEDIT-001：智能成片（本地特征 → 大模型决策 → SDK 执行 → 导出/二次编辑 + 对话式调整）

> 版本：v1.0（2026-10-04 立项）
> 日期：2026-10-04
> 调研依据：`docs/research/RESEARCH-003-智能成片竞品调研.md`（竞品对比与差异化定位）
> 架构决策：`docs/decisions/ADR-0019-智能成片与大模型接入边界.md`（**先读它**，本 Spec 的分层全部由它约束）
> 上游依赖现状：UIA-011/012/013（导入链）、MODEL-002（Command 底座）、UIA-009/010（Session/预览）
> 任务拆解：`docs/tasks/TASK-AIEDIT-000.md`（伞卡 + DAG）

---

## 1. 背景与目标

**用户价值**：不会剪辑的用户，导入素材后 3 秒内得到一支"有结构、有节奏、可用"的成片草稿；不满意的地方用一句话（打字或说话）让 AI 继续改；满意了直接导出，或一键进入既有编辑器精修。

**成功行为**（可观察）：
1. 首页出现"智能成片"入口 → 选素材（复用 UIA-013 相册浏览器）→ 显示分析进度 → 出成片（自动播放预览）。
2. 成片页有对话框：输入"删掉中间那段糊的""前 5 秒卡点快一点"类指令，成片**增量**更新（每轮可撤销）。
3. 语音按钮按住说话，松开转文字进对话框（走系统 STT）。
4. 每条成片结构（片头/高潮/结尾划分）附带 AI 理由，可见、可逐条拒绝。
5. 断网时仍能出片（本地规则引擎降级，UI 明示"离线模式"）。

**定位**（RESEARCH-003 §5）：**素材不出设备的一键成片 + 对话式精修**。云端大模型只看特征摘要，不看原始素材——这是与剪映（上传素材给云端）的核心差异，也是隐私合规卖点。

## 2. 关键架构事实（现状盘点，2026-10-04 核对）

### 2.1 可直接复用（不需要新建）

| 设施 | 位置 | 对智能成片的意义 |
|---|---|---|
| Session/Command 底座 | `core/include/cq/command/command.h`（6 种命令 + CommandHistory）、`cq_session_submit`（异步、session 线程、ADR-0012） | AI 决策的执行通道，与人手编辑同一撤销栈 |
| 时间线模型 | `core/include/cq/model/timeline.h`（Track/Clip/MediaRef/TransitionKind；**timescale=120000**，ADR-0009） | EditPlan 的落点；转场字段已在（`in/out_transition`）但无命令 |
| 导入链 | `EditorViewModel.importMedia(url:)`（`AppEntry.swift:327`）→ probe → `registerAsset` → `addClip`；AssetRegistry | 特征提取挂在 probe 之后；素材 URL/asset_id 已有 |
| 取帧 | `core/include/cq/media/frame_provider.h` + Apple 实现（精确 seek） | 视觉特征抽帧的底座 |
| 端侧推理抽象 | `core/include/cq/pal/inference.h`（IInferenceBackend，零实现）+ `CQ_CAP_NPU_INFERENCE` | 后续端侧检测模型的挂点（P0 特征提取用算法实现，不依赖模型） |
| 相册选择 | UIA-013 `AlbumPickerScreen`（单击即插入/多选模式） | 智能成片的选素材 UI 直接复用，交付 URL 列表 |
| C ABI + 绑定模式 | `cq_sdk.h` + `bindings/swift` + SharedUI（UI 不共享、共享会话） | 新 ABI 照既有模式扩展 |

### 2.2 完全缺失（本批次新建）

1. **网络层**：core/pal 零网络设施，manifest 无网络依赖 → ADR-0019 决策 2：`pal/<platform>/net/`（Apple 用 URLSession 原生，不引第三方）。
2. **LLM 接入**：全仓无任何大模型代码/文档/任务 → `ILlmClient` 抽象 + Prompt 管线 + EditPlan 校验。
3. **特征提取**：无人脸/场景切分/运动/音频分析代码（CAM-011 Vision 桥是相机实时域 UI 层，不覆盖导入素材分析；AI-010 系列在 backlog 未排期）→ `core/src/ai/analysis/`。
4. **文件音频解码**：FFmpeg 仅 demux 档（无 decode），"文件→PCM"不可用 → AIEDIT-003 内扩档（走 cq-dependency-governance）。
5. **STT/TTS**：零存在 → 语音输入走各端系统 STT（iOS Speech Framework），UI 层能力。
6. **导出**：`core/src/export/` 不存在（BACKLOG EXPORT-001~003 未做）→ **P0 的"导出"按钮进入编辑器既有出口；`EXPORT-001` 落地前显示"导出即将支持"**（见 §9 阶段）。
7. **转场/配乐命令**：TransitionKind 字段在但无 Command；无 BGM 轨概念 → AIEDIT-006 新增 `SetTransitionCommand` / `RemoveRangeCommand`；BGM P0.5。

### 2.3 硬约束（红线对照）

- 除 UI 外一切下沉 C++（红线 1）：特征提取、Prompt、校验、执行映射全在 core；Swift 只做触发/展示/语音输入。
- PAL 零平台类型（红线 2）：`INetTransport`/`ILlmClient` 全 opaque + POD。
- 能力运行时查询（红线 3）：降级分支不写 `#if`，按 `cq_ai_llm_config` 配置与网络可达性运行时判定。
- 有理数时间（红线 4）：FeatureReport 与 EditPlan 的时间字段一律 `{"value", "timescale"}`；C++ 校验器**拒绝**浮点秒。
- UI 不直接改模型（红线 5）：AI 产物也走 Command。
- 主线程零阻塞（红线 8）：分析/请求全异步；决策应用走 `cq_session_submit` 天然异步。

## 3. 总体架构与数据流

```
┌─ SwiftUI（iOS/macOS）────────────────────────────────────────────┐
│ HomeView(+入口卡) → SmartCutWizard(选素材→分析→结果) → SmartCutChat │
│ 语音输入：Speech.framework（系统 STT）→ 文字进对话框                  │
└───────┬──────────────────────────────────────────────────────────┘
        │ C ABI（AIEDIT-007 扩展）
┌───────▼────────────── core（C++，三端共享）───────────────────────┐
│ ① ai/analysis  视觉：镜头边界/运动/质量/人脸占比                     │
│                音频：静音段/响度/能量包络（经音频解码 AIEDIT-003）     │
│ ② ai/feature   汇总 FeatureReport（JSON，KB 级）                    │
│ ③ ai/plan      Prompt 构建 → ILlmClient → EditPlan 校验/修复        │
│      │                        │失败≤2次                            │
│      │                        ▼                                    │
│      │               ai/fallback 本地规则引擎（离线降级）             │
│ ④ ai/executor  EditPlan.action[] → ICommand[]（经 cq_session_submit）│
└───────┬──────────────────────────────────────────────────────────┘
        │ INetTransport（PAL 抽象）
┌───────▼───────── pal/apple/net（URLSession，SSE 流式）──────────────┐
│  POST {endpoint}/chat/completions  Authorization: Bearer <key>      │
│  上行：FeatureReport + 用户消息 + 对话历史摘要（不传原始素材）          │
└────────────────────────────────────────────────────────────────────┘
```

**数据流（一键成片主路径）**：
1. 用户选 N 段素材 → 复用 `importMedia` 落 AssetRegistry（asset_id 就绪）。
2. `cq_ai_analyze_assets(asset_ids[])`：后台线程逐素材抽帧（FrameProvider，**采样密度见 §5.1**）+ 解码音频（§5.2）→ 产出 `FeatureReport`。
3. `cq_ai_generate_plan(feature_report_json, user_prompt?, history?)`：构建 Prompt → `ILlmClient` 非流式请求（决策 JSON 不需要逐字流式）→ C++ 校验修复 → `EditPlan`。
4. `cq_ai_apply_plan(plan_handle)`：action 列表 → Command 批次 → `cq_session_submit` → 快照 observer 通知 UI → 结果页自动播放。
5. 用户在对话框输入调整 → 重复 3–4（增量：Prompt 携带当前时间线摘要 + 上一版 plan 摘要 + 用户指令 → LLM 输出增量 actions）。
6. 出口：直接导出（§9）/「进编辑器」push 现有 `EditorView`（同一 Session，素材与时间线原样带过去）。

## 4. FeatureReport（本地特征，schema v1）

```jsonc
// cq.featurereport/1 —— 上云的只有这个 + 用户消息
{
  "schema": "cq.featurereport/1",
  "project": { "timescale": 120000 },
  "assets": [{
    "asset_id": "a1",
    "duration": {"value": 60000, "timescale": 120000},   // 0.5s
    "fps": {"num": 30, "den": 1},
    "resolution": {"width": 1920, "height": 1080},
    "video": {
      "shots": [{                       // 镜头段（场景切分）
        "start": {"value": 0, "timescale": 120000},
        "duration": {"value": 24000, "timescale": 120000},
        "motion": 0.72,                 // 0~1 运动强度（帧差均值）
        "quality": 0.81,                // 0~1 综合质量（曝光/模糊/噪声加权）
        "faces": {"count": 2, "area_ratio": 0.18, "front_facing": true}
      }],
      "brightness_trend": [-0.1, 0.3],  // 调性粗特征（可选）
      "dominant_colors": ["#3A5F8A"]    // 最多 3 个（可选）
    },
    "audio": {                          // AIEDIT-003 后可用，缺则置 null
      "lufs": -18.5,                    // 综合响度
      "silences": [{"start": {...}, "duration": {...}}],
      "speech_ratio": 0.6,              // VAD 粗判
      "energy_envelope": [0.2, 0.9, ...] // ~10Hz 包络，卡点用
    }
  }],
  "cross": {                            // 跨素材分析
    "quality_rank": ["a2", "a1"],       // 质量排序
    "duplicate_shots": [["a1:0", "a3:2"]], // 疑似重复镜头组
    "highlight_candidates": ["a2:1", "a1:3"] // 高光候选（质量×运动×人脸加权）
  },
  "extensions": {}                      // 版本化扩展位
}
```

- 特征全部为**聚合统计**，不含帧图像、不含可逆还原素材的信息——这是"素材不出设备"承诺的技术基础（ADR-0019 决策 1）。
- 人脸只报 `count/area_ratio/front_facing` 布尔级信息，**不做识别**、不报身份特征。
- P0 的视觉特征用经典算法实现（帧差/直方图/拉普拉斯方差 + 已规划的 AI-010 人脸检测模型若就绪则替换人脸项），**不引入新模型资产**（不触发 dependency-governance 重评审；模型替换是 P1 优化）。

## 5. 本地特征提取管线

### 5.1 视觉（AIEDIT-002）

| 特征 | 算法（P0，零模型依赖） | 采样策略 |
|---|---|---|
| 镜头边界 | 相邻采样帧 HSV 直方图 χ² 距离 + 像素差分双判据 | 均匀采样 ≤ 4fps，上限 600 帧/素材（长素材降密） |
| 运动强度 | 帧间差分均值（灰度、降采样 160px） | 同上，随镜头边界段聚合 |
| 质量分 | 拉普拉斯方差（清晰度）+ 直方图过曝/欠曝占比 + 噪声估计，线性加权 | 边界采样帧 + 段中帧 |
| 人脸占位 | P0 用 `null`（ honest 缺席）；AI-010 模型就绪后替换（运行时按能力查询决定，不走 `#if`） | — |

### 5.2 音频（AIEDIT-003）

- 前置：FFmpeg 加 decode 档（AAC/PCM 提取，16kHz 单声道重采样）——**依赖变更，过 cq-dependency-governance**。
- VAD 静音段：能量阈值 + 滞回（帧长 30ms）；响度：ITU-R BS.1770 简化实现（K 加权，C++ 纯算法）；能量包络：10Hz 均方根序列（BGM 卡点候选依据）。
- 节拍检测 P0 不做（[E] 误检率高、收益低），用能量包络近似"节奏感"。

## 6. EditPlan（大模型决策契约，schema v1）

### 6.1 设计原则（ADR-0019 决策 3）

LLM 输出**有界动词集的 action 列表**，不是时间线。动词集 P0 共 8 个：
`select_intro / select_highlight / select_outro`（语义标注，辅助叙事）、`place_clip`、`remove_range`、`trim_clip`、`reorder`、`set_transition`、`set_bgm_placeholder`（P0 仅记录意图，P0.5 执行）。

### 6.2 示例

```jsonc
{
  "schema": "cq.editplan/1",
  "based_on": { "assets": ["a1", "a2", "a3"], "timeline_rev": 0 },
  "actions": [
    { "op": "place_clip", "asset": "a2", "shot": 1,
      "timeline_start": {"value": 0, "timescale": 120000},
      "source_in": {"value": 12000, "timescale": 120000},
      "duration": {"value": 18000, "timescale": 120000},
      "reason": "质量最高（0.86）且有正面人脸，适合开场" },
    { "op": "set_transition", "at": {"value": 18000, "timescale": 120000},
      "kind": "cross_fade", "duration": {"value": 3000, "timescale": 120000},
      "reason": "两段调性接近，软切" }
  ],
  "narrative": {
    "structure": "开场-a2（人物）→ 发展-a1（风景推进）→ 高潮-a3（全景）",
    "dropped": [{ "asset": "a3", "shot": 2, "reason": "疑似重复 a1:0 且模糊" }],
    "assistant_message": "我用 3 段素材剪了一支 42 秒的片子，保留了人脸与高质量镜头，剔除了重复段。要调整节奏或换配乐风格可以直接说。"
  }
}
```

### 6.3 校验（C++ 唯一权威，`ai/plan/edit_plan_validator`）

1. JSON Schema 结构校验（手工实现的宽松校验器 + golden 样例集，P0 不引 JSON Schema 库）。
2. 语义校验：asset_id/shot 引用存在、`source_in + duration ≤ asset.duration`、时间线段不重叠、时间字段为 `{value, timescale}` 且 `timescale == 120000`（浮点秒字段直接判非法）。
3. 失败路径：把校验错误回传 LLM 自动修复重试（≤2 次）→ 仍失败 → 本地规则引擎（AIEDIT-011）。
4. 版本化：`schema` 字段不认识 → 拒绝并降级，绝不猜测解析。

### 6.4 增量对话（多轮调整）

- 每轮 Prompt = 系统提示（动词集 + schema + 风格约束）+ FeatureReport + **当前时间线摘要**（从 ModelSnapshot 序列化：轨/片段/时长/转场，含 `timeline_rev`）+ 最近 K 轮对话（K=6 [E]，可调）+ 用户指令。
- LLM 返回**增量 actions**（基于 `timeline_rev` 乐观校验：rev 不符则先要求 LLM 重新陈述或全量重排）。
- 每轮应用的命令批次整体可撤销（undo 一次回到上一轮）；UI 提供"逐条接受/全部接受"两种模式（学 Opus 的决策透明，RESEARCH-003 §4.4）。

## 7. 执行器（AIEDIT-006）

| EditPlan op | 映射 Command | 状态 |
|---|---|---|
| place_clip | `InsertClipCommand` | 已有 |
| trim_clip | `TrimClipCommand` | 已有（右缘裁剪语义） |
| reorder | `MoveClipCommand` ×N | 已有 |
| remove_range | **`RemoveRangeCommand`**（新：可跨 clip 切割删除，内部 = Trim+Split+Remove 复合） | 新增 |
| set_transition | **`SetTransitionCommand`**（新：写 clip.in/out_transition + transition_duration） | 新增 |
| select_* / set_bgm_placeholder | 不改模型，记入 Narrative 层（UI 展示 + P0.5 消费） | 新增（纯记录） |

- 一次 plan 应用 = 原子命令批次：任一命令失败即整批回滚（复合命令实现，参照 ADR-0012 失败不入栈语义）。
- 批次命名 `plan:<schema>@<rev>`，进 undo 栈供"撤销本轮 AI 调整"。

## 8. LLM 接入（AIEDIT-004/005）

- **接口**：`ILlmClient::Complete(LlmRequest) -> LlmResult`（同步语义、内部异步）；`INetTransport::PostJson/PostSse`。Apple 实现：URLSession + `AsyncSequence` 解析 SSE。
- **配置**：`cq_ai_llm_config{endpoint, model, api_key_ref, temperature, max_tokens}`——key 不落盘明文（iOS Keychain，绑定层职责）；配置为空 → 直接走降级引擎。
- **供应商**：协议收敛 OpenAI-compatible（ADR-0019 决策 5）。P0 只验证一家 [开放问题 §12.1]。
- **超时与重试**：连接 10s / 总 60s [E]，网络错误重试 1 次；用户可随时取消（CancelToken，与 inference.h 同款模式）。
- **降级规则引擎**（AIEDIT-011）：静音剔除 → 质量排序 → 高光优先 → 固定节奏模板（快-慢-快）→ 输出**同 schema** EditPlan（`"generator": "local_rules"` 标注，UI 显示"离线模式"）。无网也能出片（对标 iMovie 的离线可用，RESEARCH-003 §2.2）。

## 9. UI 流程（AIEDIT-008/009，Apple 端先行）

```
HomeView 新增入口卡「智能成片」(route: .smartCut)
  → SmartCutWizardView
      Step1 选素材：复用 AlbumPickerScreen（多选模式），显示已选与总时长
      Step2 分析：进度（逐素材：抽帧→特征→完成），可取消
      Step3 结果：预览自动播放（复用 cq_player）+ 结构时间条（片头/发展/高潮标注）
              + 每段 reason 抽屉 + 双出口按钮「导出」「进编辑器精修」
  → SmartCutChatView（结果页底部常驻半屏对话框）
      文字输入 + 语音按住说话（Speech.framework，权限 NSSpeechRecognitionUsageDescription）
      每轮回复：assistant_message + actions 逐条（接受/拒绝）+ 「撤销本轮」
```

- **导出**：`EXPORT-001` 未落地，P0 结果页"导出"按钮置灰并标注"导出模块上线后开放"；**主出口是"进编辑器精修"**（push 现有 EditorView，同一 Session）。这不损伤核心价值——竞品的"导出即终点"本来就是短板，我们的闭环在编辑器。
- 入口命名：**智能成片**（用户指定）。脚本分镜入口 `AI 脚本成片`（P1，单列，AIEDIT-010）。
- SharedUI 新目录：`SharedUI/Sources/SharedUI/SmartCut/`（Wizard/Chat/Result 三子目录），照 MediaPicker 的组织与测试方式。

## 10. 阶段划分

| 阶段 | 内容 | 出口 |
|---|---|---|
| **P0（本期）** | FeatureReport/EditPlan schema（001）、视觉特征（002）、ILlmClient+网络（004）、Prompt/校验（005）、执行器+新命令（006）、C ABI（007）、向导 UI（008）、对话+语音（009）、降级引擎（011）；音频特征（003）并行推进，就绪即合入 | 一键成片闭环（含离线降级），导出按钮置灰 |
| **P0.5** | 音频特征合入后的卡点/BGM 命令（`AddBgmCommand` + 音频轨渲染依赖 AUDIO 批次）、`EXPORT-001` 对接 | 配乐与真实导出 |
| **P1** | 脚本分镜入口（010）、转写驱动剪辑（STT 转写→字幕→文字删改）、人脸模型替换特征项、Android 端（pal/android/net + Compose UI） | 第二入口 + 第二端 |

## 11. 非目标（明确不做）

- ❌ **不上传原始素材/原始帧**（可选增强帧描述需显式授权，本期不实现，ADR-0019 决策 1）。
- ❌ 不做人脸识别/身份特征，只做检测计数（隐私红线）。
- ❌ 不做生成式视频/图像填充（Runway/即梦类；脚本分镜的缺口素材本期用"素材库匹配 + 占位卡"解决）。
- ❌ 不做 TTS 配音（P1 随脚本成片评估）。
- ❌ 不做节拍精确检测（用能量包络近似）。
- ❌ 不做 Android/鸿蒙端实现（架构预留，P1）。
- ❌ 不承诺成片质量指标（LLM 输出质量无法机器验收；验收只覆盖结构正确性、可撤销性、降级可用性——质量靠"对话收敛"机制兜底）。

## 12. 开放问题（不悄悄假设）

1. **默认 LLM 供应商与 key 分发**：国内合规（豆包/通义/月之暗面）vs 海外（Gemini/Claude） vs 服务端代理聚合——产品决策，影响 P0 联调对象。P0 用 OpenAI-compatible 假服务 + 真实 key 二选一联调。
2. **成本控制**：特征报告 token 量 [E]（3 素材 ~2–4k tokens）× 多轮对话的调用费用谁承担、是否限免。
3. **隐私合规申报**：App Store 隐私标签（"不收集" vs 网络传输内容申报）、中国《生成式 AI 服务管理暂行办法》备案是否适用（取决于用哪家模型/是否自建服务）——上线前法务确认。
4. **纯特征决策质量**：低维特征对"内容语义"（风景/聚会/美食）的判别力 [hypothesis]——P0 用 10 组真实素材人工评测（成片可用率 ≥ 60% 为继续纯特征路线的门槛 [E]），不达标启用增强帧描述（需过隐私评审）。
5. **语音 STT 的语言范围**：系统 STT 中文支持好但方言语种有限；是否需要多语言声明，随 P1 转写剪辑一起定。
6. **macOS 端形态**：Mac 无 iPhone 相册生态，入口卡是否保留（保留，走 fileImporter + 相册双路）——AIEDIT-008 内定。

## 13. 验收标准（可机器判定）

> 全部命令在真实构建机执行（本机 Swift 5.5 无法跑门禁，见 pitfalls 记录的环境约束）。

1. **内核单测**：`ctest --test-dir build -R ai_` 全绿，含：EditPlan 校验器 golden 样例集（≥40 例：合法/非法/边界/版本不识别）、特征提取对 golden 视频的镜头边界数与人工标注一致（±1）、执行器应用后 `cq_session_timeline_duration` 与 plan 声明总时长**有理数精确相等**、undo 一次完全还原（快照逐字段相等）。
2. **降级**：断网 + 空 key 配置下 `cq_ai_generate_plan` 返回 `"generator": "local_rules"` 的合法 EditPlan 且应用成功。
3. **编译门禁**：`tools/build/build_core.sh --platform=apple` 通过（-Werror）；绑定/SharedUI `swift test` 全绿；macOS App `xcodebuild build` 通过；`git diff --stat` 证明各任务 write_set 外零改动。
4. **红线检查**：`grep -rn "float.*second\|double.*seconds" core/src/ai/` 无时间字段浮点秒；`ILlmClient`/`INetTransport` 头文件无平台类型；AI 链路无直接改 ModelSnapshot 的调用（代码审查项）。
5. **真机项**（不阻塞编译门禁，随 UIA-011 真机恢复决策一并执行）：3 素材 30s 视频端到端出片 p95 < 30s [E]，实测回填 baselines.md；语音输入转写成功率人工验证。
6. **性能**：特征提取内存峰值 < 200MB [E]（采样上限保证）；分析不阻塞主线程（主线程零卡顿为 UI 冒烟观察项）。

## 14. 下一步

本 Spec 已按 cq-spec-authoring 检查清单自查（目标/非目标/可判定验收/模块影响/红线/开放问题/跨端影响）。任务拆解见 `docs/tasks/TASK-AIEDIT-000.md`（cq-task-planning 产物，P0 九个任务 + 依赖 DAG + 写集切分）。
