# RESEARCH-014：主流 NLE 引擎架构综合调研与 RENDER-001 规划建议

- **状态**：完成（纯调研，**不开工**；RENDER-001 立卡待集成机拍板后走 cq-task-planning）
- **日期**：2026-10-11
- **范围**：渲染内核架构参照——GBU（Graph/Bin/Unit）综述、Final Cut Pro、Premiere Pro/Avid、DaVinci Resolve、该厂商系（对标 App/该厂商云服务/Vidi）公开资料
- **数字纪律**：本文无实测数字；引用的第三方数字一律 [E]；标 [hypothesis] 为未验证推测
- **动线**：`RENDER-001 未开工（关键路径）` → GBU 综述发现（2026-10-11 会话）→ 三路并行网络调研 → 本文

---

## 1. 结论速览

1. **自研方向被五家工业实现交叉印证**：track/clip 编辑模型 + 可配置渲染图 + 统一 GPU 抽象 + 导出快路径，是 Premiere / Resolve / 对标 App（综述）/ FCP（渲染侧）的共同形态。ARCH-003 与 gfx/media/render 模块既有设计**无需翻案**。
2. **RENDER-001 的真空白是"装配器"层**：GBU 综述里 Graph/Bin/Unit 三层，咱们 Unit（GFX 原语）、Bin 的单体形态（RenderNode）、载体（ChqFrameContext + lease）都已落地，缺的是"同一张图的三种装配（预览 / 导出 / 纯音频）+ 时钟源抽象"。
3. **Push vs Pull 是立卡前的头号必答题**：现状视频线（UIA-010 请求驱动）与音频线（AUDIO-002 push 30Hz）不一致，RENDER-001 统一时必须拍板。
4. **缓存分级对齐 Resolve 四级模型**（source/node/clip/sequence）：MEDIA-011 是 source 级，RENDER-002 应预留 node/clip 级缓存挂点。
5. **不引入任何依赖**：GStreamer/OTIO 只作阅读参照；OTIO 兼容导出登记为 P2 观察项（触发条件：出现外部交换需求）。

## 2. GBU（Graph/Bin/Unit）综述要点

> 来源：Patrick《解构视频剪辑引擎：一个现代 NLE 系统的完整剖析》(https://paaatrick.com/2024-11-24-nle-deep-dive)，作者自述做 某短视频平台 creative tools (https://paaatrick.com/about)。**性质：个人博客综述，文末免责声明"基于多个工业级 NLE 的研究总结，非特定产品实现细节"。GBU 命名引用时写"业内图引擎三层抽象（Patrick 综述）"，不得写"该厂商官方架构"。**

- **Graph**：渲染管线骨架 = 可配置处理图，概念模型 Source（产生数据）→ Processor（处理数据）→ Sink（消费数据）。
- **Bin**：图上职责容器节点。典型预览图装配：DriveBin（时钟）→ DecodeBin → GLSourceBin → EffectBin → CompositeBin → SequenceBin → OutputBin。
- **Unit**：Bin 内最小处理单元；数据以 Pipeline 对象（时间戳 + GPU 纹理 + 元信息）在 Bin 间传递。
- 与红线 9 的关系：文章说"导出和预览使用相同的渲染逻辑"，且预览/导出/纯音频是**同一图引擎的不同 Bin 组合**——比红线 9"只换输出目标与时钟源"多暴露了音频独立成图这一档（咱们 AUDIO-002 已天然形成音频图）。

## 3. 各家架构要点

### 3.1 Final Cut Pro（Apple 官方文档为主）

- **Magnetic Timeline = 无轨模型**：primary storyline 隐式 lane 0，connected clips 锚定主序列随动（插入自动 ripple），lane + role 组织上下层；role（Video/Dialogue/Music/Effects…）是与轨道正交的横切维度，用于混音分轨与批量导出（https://support.apple.com/guide/final-cut-pro/intro-to-the-magnetic-timeline-verd4c60eae/10.9/mac）。
- **FCPXML**：document→resources→event/project→sequence→spine；clip 带 offset（有理数，如 `35024990/120000s`）、lane、role，asset 经 ref 引用（https://developer.apple.com/documentation/professional-video-applications/fcpxml-reference）。spine+lane+offset+role 是无轨模型最好的持久化范式。
- **性能机制**：optimized media（转 ProRes 提升解码）与 proxy media（ProRes Proxy 剪辑、导出自动回全分辨率）为官方工作流（https://support.apple.com/guide/final-cut-pro/create-optimized-and-proxy-files-ver90ba5249/10.9/mac）；FxPlug 4 确认效果渲染走 Metal（https://developer.apple.com/documentation/professional-video-applications/fxplug）。第三方实测认为增益主要靠后台渲染 + 原生解码而非转码本身 [E]（https://fcp.co/final-cut-pro/articles/1798-transcode-to-optimized-media-to-improve-performance-of-dslr-footage）。
- **效果挂载 = 参数栈**（inspector 参数 + onscreen 控件 + 关键帧），非节点图；FxPlug 4 为 out-of-process + tile 渲染。
- Undo 内部实现**无公开资料**（仅快捷键文档）。

### 3.2 Premiere Pro / Avid / OTIO

- **Mercury Playback Engine**：同一 GPU 抽象层挂 Software/CUDA/OpenCL/Metal 四种渲染器（https://helpx.adobe.com/premiere/desktop/get-started/technical-requirements/enable-mercury-playback-engine-gpu-accelerated-renderer.html）；C++ SDK 效果按后端实现、帧可驻留 GPU 不回读（https://ppro-plugins.docsforadobe.dev/gpu-effects-transitions/gpu-effects-transitions）。
- **Smart rendering**：源与导出的编解码/尺寸/帧率/码率**全匹配**才跳过重压缩直通（比"Remux 五级决策树"的条件更严格、更可执行）（https://helpx.adobe.com/premiere/desktop/render-and-export/render-sequences-for-playback/smart-rendering-supported-formats.html）。
- **Media Cache**：conform/peaks 派生缓存 + 缓存数据库；proxy ingest/attach/一键切换（https://helpx.adobe.com/premiere/desktop/organize-media/ingest-proxy-workflow/ingest-and-proxy-workflow.html）。
- **Avid**：bin/sequence 组织 + AAF 交换 + Nexis 共享存储 bin locking（https://kb.avid.com/pkb/articles/en_US/Knowledge/import-dailies-into-MC）。
- **OTIO**：定位为剪辑信息交换格式 + API，**非编辑引擎**、不含媒体；数据模型 Timeline→Stack→Track→Clip/Gap/Transition，时间用 RationalTime；核心库是 C++（含零依赖 opentime）（https://github.com/AcademySoftwareFoundation/OpenTimelineIO、https://opentimelineio.readthedocs.io）。Premiere Beta 已有基础导入导出（半官方论坛回复）；Avid 支持仅三方说法 [hypothesis]。
- Undo 内部数据结构**无公开资料**（Premiere History panel 可跳任意状态、上限 100 级 [E]）。

### 3.3 DaVinci Resolve

- **混合模型**：Edit 页=轨时间线，Color 页=**每 clip 串行/并行/层叠节点图**，Fusion 页=节点合成树；GPU 处理模式（CUDA/OpenCL/Metal）全局统一设置（官方 18 参考手册 https://documents.blackmagicdesign.com/UserManuals/DaVinci_Resolve_18_Reference_Manual.pdf）。
- **四级缓存**：source / node / clip / sequence（https://timeinpixels.com）；替身媒体三类：render cache（播放中按需）、optimized/proxy（预生成）；开 proxy 后旧缓存需清理（https://filmmakingelements.com）。
- **色彩三层分离**：媒体色定义 / 时间线工作空间 / 输出空间（https://mixinglight.com）——与 render.md"working space 内计算 + 输入输出各转换一次"同构。

### 3.4 该厂商系（对标 App/该厂商云服务/Vidi）

- **对标 App内核无官方公开架构文章** [hypothesis：GBU 综述是当前最详尽的公开转述]。第三方逆向：草稿 = `draft_content.json`（画布配置 + materials + tracks/segments/关键帧分离；新版加密封存的逆向说法**未验证** [hypothesis]）（https://zhuanlan.zhihu.com、https://bbs.kanxue.com）。
- **对标 App Web 官方案例**（web.dev）：WASM 迁移超 100 万模板 + WebCodecs 硬编解码（（来源链接已移除））——"内核跨端 + 声明式草稿"形态的官方佐证。
- **该厂商云服务 Creation Kit**：自研音视频 SDK 服务对标平台/对标 App/西瓜，多轨道编辑、剪同款、模板、**端上合成**（https://www.该厂商云服务.com/product/creation-kit）；文档仅到"多轨道编辑"粒度，无内核白皮书。
- **Vidi-Edit**（官方论文）：LMM 生成**结构化 editing plan**（叙事结构/音频属性/视觉意图），交下游工具执行（https://arxiv.org/abs/2511.19529、（来源链接已移除））——"AI 生成 → 声明式草稿 → 渲染图执行"的上游接口形态。

## 4. 横向对比

| 维度 | 对标 App系（综述） | FCP | Premiere | Resolve | ChuanqiCut 现状 |
|---|---|---|---|---|---|
| 编辑模型 | Track/Clip 树 | spine+lane+role（无轨） | Track/Clip | Track/Clip + per-clip 节点图 | Track/Clip（MODEL-001）✅ |
| 持久化 | draft JSON（声明式） | FCPXML | 私有 + OTIO/AAF 导出 | 私有 DB | ChqTimeline 序列化 |
| 渲染架构 | Graph/Bin/Unit 可配置图 | Metal 直连 + 参数栈 | MPE 多后端 GPU 抽象 | 统一 GPU 抽象 + 多页面共用 | RenderNode + GFX 两层 HAL |
| 缓存/代理 | 预览降级 | optimized/proxy + 后台渲染 | Media Cache + proxy | **四级缓存** | MEDIA-011 LRU（source 级）+ proxy_quality flag |
| 导出快路径 | Remux 决策树 | 导出回全分辨率 | smart rendering（全匹配直通） | — | 规划中（EXPORT-001） |
| Undo | 快照+脏子树（综述） | 无公开 | History panel（结构无公开） | 无公开 | UIA-009 不可变快照 ✅ |
| GPU 后端切换 | — | Metal only | CUDA/OpenCL/Metal | CUDA/OpenCL/Metal | CORE-006 HAL（Metal 先行）✅ |

## 5. 落点：印证了什么、补什么

**印证（不改）**：红线 9 同一张图；两层 GPU HAL（对照 Mercury/Resolve 多后端）；working space 色彩管（对照 Resolve 三层）；快照式历史（UIA-009 已选，方向与综述一致；各家内部实现均未公开，无翻案依据）；lease/零拷贝（对照 MPE"帧驻留 GPU 不回读"）。

**补（RENDER-001 spec 必答题，立卡前拍板）**：
1. **Push vs Pull**：视频线=请求驱动（UIA-010），音频线=push 30Hz（AUDIO-002）——统一时二选一或分区（视频 pull / 音频 push 各写明理由）。
2. **装配器**：同一节点图的三种装配（预览 / 导出 / 纯音频），作为红线 9 的 spec 落点。
3. **时钟源接口**：预览=墙钟（PlayerClock）、导出=逐帧推进，抽象成同一 Clock 源接缝。
4. **Bin 层要不要进 spec**：RenderNode（Unit 语义）已定；"Bin=职责容器（Drive/Decode/Effect/Composite/Output）"是命名与组织约定，建议 spec 采纳但实现为 RenderNode 的组合约定，不新设抽象层。
5. **缓存挂点**：RENDER-002 spec 预留 node/clip 级缓存接口（对齐 Resolve 四级），实现后置。

**登记不开卡（池/备注级）**：
- **OTIO 兼容导出**（P2 观察项；触发=外部交换需求；opentime 与 ChqRationalTime 同构，成本可控）。
- **clip role 元数据**（FCP 启发，供混音分轨/导出筛选；MODEL 层小字段）。
- **proxy 媒体管理**（生成/attach/切换归媒体管理层，MEDIA-028/029 相邻域；proxy_quality flag 已在 ChqFrameRequest）。
- **AI editing plan 上游**（Vidi-Edit 形态：LMM → 结构化 plan → Command/草稿；长期方向）。

## 6. RENDER-001 重新规划建议（待拍板，不开工）

| 项 | 原 BACKLOG | 建议修订 |
|---|---|---|
| RENDER-001 范围 | 节点 DAG 与拓扑排序 | 拓扑/环检测 **+ 装配器（三图同源）+ 时钟源接口 + Source/Sink 拓扑段**；验收增加"预览图与导出图同一装配器产出" |
| RENDER-002 | Pass 合并 + 纹理别名 | 维持，spec 增加 node/clip 级缓存挂点预留 |
| 切卡方式 | — | 不新增卡号；范围修订写回 BACKLOG 后走 cq-task-planning 出 SPEC |
| 时机 | — | 当前批收尾后（INFRA-025 提交收口 + DEPS-012 门禁回填 + 池[12] 真机项），RENDER-001 为下一个大卡 |

## 7. 明确不采纳

- **GStreamer/GES 依赖**：LGPL、移动端体积重、管线模型与 RenderGraph 撞车（RESEARCH-006 已排除一次）。
- **无轨 Magnetic 模型改 MODEL**：MODEL-001 Track/Clip 已冻结并三端一致；spine+lane 仅为持久化范式参照。
- **FxPlug 式 out-of-process 效果**：进程边界与咱们的同进程 C ABI 内核相悖；仅借鉴其"参数栈 + tile 渲染"语义。
- **Resolve 式 per-clip 独立节点页**：产品无此需求；效果节点统一进同一张图（render.md 既有设计）。

## 8. 引用

- Patrick：https://paaatrick.com/2024-11-24-nle-deep-dive · https://paaatrick.com/2024-11-17-rtc-meets-nle · https://paaatrick.com/about
- Apple：Magnetic Timeline / FCPXML Reference / optimized+proxy / FxPlug（support.apple.com 与 developer.apple.com 对应页，见 §3.1）
- Adobe：MPE 渲染器选择 / smart rendering / Media Cache / proxy 工作流（helpx.adobe.com，见 §3.2）；PPRO SDK GPU 效果（ppro-plugins.docsforadobe.dev）
- OTIO：https://github.com/AcademySoftwareFoundation/OpenTimelineIO · https://opentimelineio.readthedocs.io
- Resolve：官方 18 参考手册 PDF · timeinpixels.com · mixinglight.com（见 §3.3）
- 该厂商系：（来源链接已移除） · https://www.该厂商云服务.com/product/creation-kit · https://arxiv.org/abs/2511.19529 · （来源链接已移除） · 草稿逆向（zhihu/kanxue，[hypothesis]）
