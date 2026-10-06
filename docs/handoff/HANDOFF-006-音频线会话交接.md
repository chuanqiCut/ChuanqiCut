# HANDOFF-006：音频线开工（AUDIO-001）会话交接

> 日期：2026-10-05
> 性质：**跨平台内核实现**（core/src/audio/ 四件套 + 双测试，无 UI/绑定改动）
> 下一会话：接音频线任选 `AUDIO-004`（混音）或 `PALA-030`（AVAudioEngine 后端）；
> 开工前照例读 AGENTS 真源 + `.ai/modules/audio.md` + `TASK-AUDIO-001.md` + 本文件。

## 1. 本轮做了什么

会话起点是核实「编辑模块音频链路是否未开始」——结论：**整体未开工**（`core/src/audio/`
不存在、预览无音频代码、导出侧只有 AAC 封装、AIEDIT 批次只有文档）。传哲确认「开干」，
选 AUDIO-001（上游 CORE-006 已冻结，AIEDIT-003 还压在未动工的 AIEDIT-001 后面）。

| 文件 | 内容 |
|---|---|
| `docs/tasks/TASK-AUDIO-001.md` | 建卡（BACKLOG §4.2 首张落地卡）+ 完成态注记 |
| `core/include/cq/audio/{audio_types,audio_graph,pcm_pool,spsc_ring}.h` | 类型 / 图骨架 / 预分配池 / SPSC 环 |
| `core/src/audio/{audio_graph,pcm_pool,spsc_ring}.cpp` | 对应实现 |
| `tests/unit/{test_audio_pcm,test_audio_graph}.cpp` | `core_audio_pcm` / `core_audio_graph` 两用例 |
| `core/CMakeLists.txt`、`tests/CMakeLists.txt` | 登记 3 源文件 + 2 测试 |
| `TASK-BACKLOG.md`、`tasks/README.md`（47 张）、`.ai/modules/audio.md`、pitfalls P60、baselines | 回写 |

## 2. 装配形状（一分钟版）

```
decode/session 线程 ──SpscSampleRing（全有或全无, SPSC 专用）──▶ 音频线程
音频线程: pool.Acquire → AudioGraph.Process(节点链原位变换) → IAudioEngine.Write(PAL) → pool.Release
           ▲ 全部预分配（Init 一次性），音频线程路径零锁零分配（operator new 计数实测 = 0）
AudioBuffer（core, data 可变）↔ PcmBuffer（PAL, data const）：PALA-030 在边界做平凡适配
```

## 3. 关键决策与理由（防新会话重新发明）

1. **AudioBuffer 与 PAL PcmBuffer 字段对齐但 data 可变**（新约定，`.ai/modules/audio.md`）——
   效果节点要原位写样本；const 语义差异由 PALA-030 在边界适配，不留给下游。
2. **AudioGraph 拓扑限单链**（入度≤1、出度≤1、必须连通，成环/断链 → kInvalidArgument）——
   AUDIO-001 只需要链式效果节点；多输入汇点（混音）留给 AUDIO-004 扩展 ctx 输入视图，
   Prepare 校验框架不变。
3. **耗尽一律 Status，绝不回退堆分配**——pool 满 → kResourceExhausted、ring 满/空 →
   kResourceExhausted；这是「音频线程无分配」的结构性保证，不是纪律约束。
4. **SPSC 环是音频线程与上游的唯一合法通道**——严格单生产者单消费者（违规 = 数据竞争），
   全有或全无语义（不做部分读写），块边界由调用方按恒定块规格维护。
5. **零分配必须可测**——测试 TU 重载全局 operator new/delete 计数（对整个测试进程生效，
   含静态库内的隐藏分配）；kAudio 标记线程热身后测，增量 = 0 才算过。

## 4. 下一步（按依赖序）

| 候选 | 依赖 | 说明 |
|---|---|---|
| **AUDIO-004 多轨混音** | AUDIO-001 ✅ | 放宽入度限制 + ctx 输入视图；`ctest -R audio_mix` 验收电平/溢出 |
| **PALA-030 AVAudioEngine 后端** | AUDIO-001 ✅ | 首条**可听**链路；Write/Read 接 AudioBuffer↔PcmBuffer 适配；延迟补偿坑见 audio.md |
| AUDIO-002 时间拉伸 | DEPS-020 | signalsmith-stretch 依赖引入（过 cq-dependency-governance） |
| AIEDIT-003 音频特征 | AIEDIT-001 | 智能成片批次 2，等契约冻结 |

## 5. 坑（本轮实测）

- **无锁容器先定并发模型再动手**：谁 push/pop、防 ABA（tag）、双重释放防护（per-slot 状态）、
  内存序四要素不齐不开写 —— 初版 Treiber 栈漏了 per-slot next，逻辑不自洽，自审重写
  （pitfalls P60）。
- **CAS 期望值是非 const 引用**：`const uint64_t head` 进 compare_exchange 直接编译错。
- **测零分配的窗口纪律**：窗口内不得 printf（printf 会 malloc）、不得含首次惰性初始化
  → 先热身一轮再测。
- 本机（第二台开发机）：`CMAKE_BIN=/Users/songdandan/Library/Python/3.9/bin/cmake`。

## 6. 门禁（本机实测，run_gate.sh 三轮终局 PASS=6/FAIL=1）

- deps 校验 ✅、PAL 头纯净性 ✅（36 头 0 违规，含新增 cq/audio/ 四头）、apple-prepare ✅
- 内核全量：**Debug 44/44、Release 44/44**（新增 core_audio_pcm / core_audio_graph）
- **XCFramework 三切片 ✅**（修复了合并遗留的 iOS 切片编译断裂，见 §5 与当日日志补记 2）
- swift-bindings FAIL = 本机环境上限（BIND-002 声明 tools 6.1，本机 Swift 5.9.2），
  非本轮引入，绑定层零改动；升级工具链需另立环境任务
