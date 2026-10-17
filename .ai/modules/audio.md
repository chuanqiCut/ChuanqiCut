# 模块：音频

> **归属**：C 线（内核/媒体/渲染） —— 归属表见 docs/tasks/PLAN-三线并行.md §1a / ADR-0029（双机分工与门禁跑批，2026-10-07）

**边界**：`engine/core/cq/audio/`（契约 + 实现同域共置，ADR-0033）、`engine/platform/apple/{base,media}/` 的音频实现、`platform/<platform>/audio_*`

## 结构
```
engine/core/cq/audio/     # 跨平台音频类型与接口（零平台类型）
├── chq_audio_types.h     # ChqAudioBuffer（可变 data，Platform 边界做 PcmBuffer 平凡适配）/ ChqAudioGraphSpec
├── chq_audio_graph.h     # ChqIAudioNode / ChqAudioGraph（Prepare 校验+拓扑 / Process 无锁遍历）
├── chq_pcm_pool.h        # ChqAudioBlockPool（预分配槽位 + tag Treiber freelist + per-slot 状态双保险）
├── chq_spsc_ring.h       # ChqSpscSampleRing（2 的幂预分配、全有或全无、SPSC 专用）
├── chq_track_reader.h    # AUDIO-002：ChqIAudioTrackReader 读取器接缝（平台 demux+解码一体）
├── chq_preview_mixer.h   # AUDIO-002：预览混音器（时间线→PCM 编排；样本数学走 chq_mix）
├── chq_mix.h             # AUDIO-004：多轨混音原语（增益累加 + 硬削波，纯函数零分配）
└── chq_sdk_audio.cpp     # AUDIO-002：音频预览 C ABI（引用 Platform 音频工厂符号的唯一 TU）
```

## 落地状态
- **AUDIO-001 ✅**（2026-10-05）：四件套地基 + 单测 `core_audio_pcm` / `core_audio_graph`。
  音频线程零分配以**全局 operator new 计数实测增量 0** 验收（kAudio 标记线程全路径）。
- **AUDIO-002 ✅**（预览音频全链）：读取器接缝 + 预览混音器 + C ABI + Swift 接入。
- **AUDIO-004 🔧**（2026-10-13 编码轮）：`chq_mix.{h,cpp}` 混音原语
  （`MixAccumulateRange` 增益累加 / `MixClipRange` 硬削波，非有限值按 0），
  预览混音器的内联求和/削波已切换为该实现 —— **全仓只有一套混音路径**。
  单测 `core_audio_mix`（57 检查）。轨增益取点已留（模型无音量字段前恒 1.0）。
- **AudioGraph 拓扑限制 = 单链**（每节点入度≤1、出度≤1、必须连通）：
  AUDIO-001 时曾预期"多输入汇点是 AUDIO-004 的扩展点"，**该预期已修正** ——
  混音是 N 进 1 出的总线操作，预览路径不经图（AUDIO-002 自带编排），导出路径未立卡；
  给没有消费方的接口改验证框架是投机。图的多输入扩展随「图装配音频链」的卡一起做
  （裁决全文见 docs/tasks/TASK-AUDIO-004.md 范围裁决表）。
- **未落地**：AUDIO-002 时间拉伸（backlog 号与已提交的预览音频全链撞号，见下）、
  AUDIO-003 变声、AUDIO-010 fx、PALA-030（AVAudioEngine 后端）、
  MEDIA-030（音画同步时钟）。AIEDIT-003（音频解码+特征）已立卡未开工。
- **号段实况**：BACKLOG §4.2 表里 AUDIO-002 写的是"时间拉伸节点"，但 2026-10-08
  提交的 `4ee6b8b AUDIO-002：预览音频全链` 已占用该号 —— **以提交历史为准**，
   backlog 表待集成机修订；时间拉伸实际未立项（依赖 DEPS-020 signalsmith-stretch）。

## 时间拉伸与变声：signalsmith-stretch（MIT）
替代原方案的 SoundTouch（**LGPL v2.1，原文档误标为 MIT** —— 见 RESEARCH-001 F1 / ADR-0004）。

## 已知坑（必须规避）
1. **Apple Clang 16.0.0 + `-ffast-math` 会生成错误 SIMD 代码** → 构建配置必须规避该组合
2. Debug 构建下性能极慢（可达 10 倍）→ 该模块单独开启优化
3. 存在 inputLatency + outputLatency → **导出路径必须做延迟补偿**，否则时长有偏差
4. 时间拉伸质量在 0.75x–1.5x 区间外下降 → 超出范围需评估

## 硬约束
1. **音频线程无锁、无分配**；buffer 一律 `AudioBlockPool` 预分配，
   跨线程通道一律 `SpscSampleRing`（严格 SPSC，违规 = 数据竞争）
2. 变速后输出时长误差 ≤ 1 帧（写进测试）
3. 变声需支持 pitch 与 formant 独立控制（这正是 `AVAudioUnitTimePitch` 做不到的）
4. 三端共用同一份 C++ 音频算法代码

## 验证
```bash
ctest -R audio                  # 音频全量：core_audio_pcm / core_audio_graph /
                                #   core_audio_preview_mixer / core_audio_mix（+ Apple muxer audio）
ctest -R core_audio_mix         # AUDIO-004：多轨电平与溢出（57 检查）
ctest -R core_audio_graph       # AUDIO-001：零分配实测（kAudio 线程 operator new 增量 0）
```
未落地项的入口（立卡后再补）：时间拉伸 / 变声的 ctest 名随卡定，不预先占用。

## 相关
ADR-0004、ARCH-002 §7（依赖清单）、ARCH-001 §6（线程模型/铁律 2）、
CORE-006 冻结的 `cq/platform/audio.h`（PcmBuffer/IAudioEngine 契约）

---

## 模块册（ADR-0030：任务/进度/测试门禁记录按模块归口）

> 本节由归属线更新（一机一线，天然单写者）；BACKLOG / pitfalls / baselines 等
> 全局册零直写（集成机阶段批落账）。新调研/规格/审查落 docs/ 原位，但必须在此登记指针。

### 任务与进度（在飞 + 近期；全量 DAG 见 TASK-BACKLOG）

| Task ID | 标题 | 状态 |
|---|---|---|
| AUDIO-001 | 音频图骨架 | ✅ 2026-10-05（TASK-AUDIO-001） |
| AUDIO-002 | 预览音频全链 | ✅ 2026-10-08（commit 4ee6b8b；backlog 表号段待修订） |
| AUDIO-004 | 多轨混音原语 | 🔧 2026-10-13 编码轮（TASK-AUDIO-004） |
| AUDIO-005~009 / 010 | 号段 | 预占 |

### 测试与门禁记录（阶段批）

| 日期 | 阶段/范围 | 结论（数字） |
|---|---|---|
| 2026-10-13 | AUDIO-004 编码轮自查（本机 Intel x86_64） | `build_core.sh` Debug/Release -Werror 0 error 0 warning；`ctest` **Debug 52/52**（批前 51，+core_audio_mix）；`ctest -R audio` **5/5**；`core_audio_mix` **57 检查 0 失败**；头门禁 43 头 0 违规 |
| 2026-10-16 | `audio_engine.mm` iOS-only 编译破坏修复（集成机 hotfix，P146） | 引入者 `b471b8c`（#18 打断恢复）：`RegisterSessionObservers()` 的第二个 block 形参 `note` 未用 → `-Werror,-Wunused-parameter` @ `engine/platform/apple/media/audio_engine.mm:252`。该函数整段在 `#if TARGET_OS_IPHONE`（:212-271）里，**`build_core.sh --platform=apple` 走 macOS 切片编不到**，所以 core-dbg/core-rel 一路绿、只有 `apple-xcframework` 段红。修复＝形参改匿名 `/* note */`（与 :239 同写法）；重跑 `tools/build/build_core_apple.sh --config=Release` → **exit 0**，三切片齐 + consumer smoke-link `ChuanqiCut version = 0.1.0`，`build/apple/ChuanqiCut.xcframework` 4.5M |
| 2026-10-05 | AUDIO-001 收尾 | Debug/Release 44/44（含 core_audio_pcm / core_audio_graph） |

### 调研 · 决策 · 池指针

- ADR-0004（signalsmith-stretch）
