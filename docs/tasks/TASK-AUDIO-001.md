# TASK-AUDIO-001：音频图骨架与 PCM 缓冲管理

> **状态：✅ 完成（2026-10-05）**。门禁：Debug 44/44、Release 44/44（含本任务新增
> `core_audio_pcm` / `core_audio_graph`）；零分配验收实测 operator new 增量 = 0。
> 吞吐/延迟未做 microbench（无验收阈值要求，未实测）。

```yaml
id:          AUDIO-001
layer:       跨平台
goal:        落地 core 层音频地基 —— 预分配缓冲池（lock-free freelist）、SPSC 无锁样本环、
             AudioGraph DAG 校验+拓扑遍历骨架 —— 为 AUDIO-002/003/004/010 与 PALA-030 提供公共底座
input:       [PAL audio.h 契约（CORE-006 冻结）, ARCH-001 §6 线程模型/音频线程铁律,
             .ai/modules/audio.md, TASK-BACKLOG §4.2]
output:      [cq/audio 头文件 + 实现, 单测 ×2, CMake 登记, .ai/modules/audio.md 更新]
write_set:   core/include/cq/audio/*(新)、core/src/audio/*(新)、tests/unit/test_audio_*.cpp(新)、
             core/CMakeLists.txt、tests/CMakeLists.txt
read_set:    core/include/cq/pal/{audio,common}.h、core/include/cq/base/{concurrency,alloc,time,status}.h、
             core/include/cq/session/thread_model.h、.ai/modules/{audio,core}.md
deps:        [CORE-006]
acceptance:
  - SpscSampleRing 跨线程压测：单生产者/单消费者往返 ≥10 万块，序号连续、无丢失无重复
  - AudioBlockPool 预分配后 Acquire/Release 往返正确；耗尽返回 kResourceExhausted，
    不回退堆分配；非法参数（未知格式/0 容量）返回 kInvalidArgument
  - AudioGraph：含环拓扑 Prepare() 返回 kInvalidArgument（DAG 校验）；
    合法拓扑 Process() 按拓扑序逐节点原位变换（用算术可验证的节点断言顺序）
  - 「音频线程零分配」可测：kAudio 标记线程上跑 ring/pool/graph.Process 全路径，
    以全局 operator new 计数器实测增量为 0
  - 时间轴全程 RationalTime（pts 穿透到每个节点），零浮点秒
  - tools/build/build_core.sh --platform=apple -Werror 通过；ctest -R audio 全绿
verification:
  - tools/build/build_core.sh --platform=apple
  - ctest --test-dir build -R audio
risk:        无平台后端可听感验证（PALA-030 未做）→ 本任务以数据结构/算法单测为准，
             听感与真实延迟验证推迟到 PALA-030；SPSC 环若并发压测暴露 ABA/内存序问题，
             修复优先于新功能
parallel:    true（write_set 与当前在办任务不相交）
```

## 背景

BACKLOG §4.2 音频线全部未开工（2026-10-05 核实：`core/src/audio/` 不存在）。
CORE-006 已冻结 PAL Audio 契约：`PcmBuffer`（POD）+ `IAudioEngine`，并明确分工 ——
**平台引擎只搬 PCM，混音/效果在 core 层做**。ARCH-001 铁律 2：音频线程无锁、无分配，
所有 buffer 预分配、通信用 lock-free ring buffer。

本任务是音频线的第一个实现任务：把"音频线程实时性"从文档约束变成**可测试的数据结构**。
已挂 `cq-media-pipeline` 分析要求（见下）。

## 实现要点

1. **AudioBlock（core 侧缓冲描述）**：字段与 PAL `PcmBuffer` 对齐，但 `data` 可变
   （效果节点要原位写样本）。PAL 边界处（PALA-030）做 AudioBuffer↔PcmBuffer 平凡适配，
   不把 const 语义问题留给下游。
2. **AudioBlockPool**：固定槽位预分配 + 置 tag 索引 Tre栈 freelist（CAS，ABA 安全）。
   Acquire/Release 全程原子操作；耗尽返回 `kResourceExhausted`，**绝不回退堆分配**。
3. **SpscSampleRing**：预分配 2 的幂字节容量，head/tail 原子序（acquire/release），
   单生产者单消费者；写满/读空返回 `kResourceExhausted`/`kInvalidArgument`，不阻塞、不加锁。
   这是音频线程与 session/decode 线程之间的唯一合法通道。
4. **AudioGraph**：节点接口 `OnPrepare(spec)` + `Process(AudioBuffer&, ctx)`；
   `Prepare()`（session 线程，允许分配）做 DAG 校验（成环 → `kInvalidArgument`）与拓扑排序；
   `Process()`（音频线程）只做预排好序的线性遍历 + 原位样本变换。
   多输入混音是 AUDIO-004 的扩展点：ctx 预留 inputs 视图，本任务只落单链传播。
5. **零分配的验证手段**：测试 TU 全局重载 `operator new/delete` 计数，
   kAudio 线程先热身一轮再测量（排除惰性初始化噪声），实测增量必须为 0。

### cq-media-pipeline 专项分析（实现时逐项过）

- **线程**：ring 仅 SPSC（违规使用 = UB，文档 + 单测断言生产/消费者各一）；
  graph.Process 不取锁、不碰 session 状态；pool freelist 用 tag 防 ABA。
- **时序**：pts 用 RationalTime 穿透；块时长 = frames/sample_rate，不引入浮点秒。
- **内存**：三件套全部预分配；耗尽路径返回 Status 而非动态扩容。
- **取消**：音频线程不等待、不取消（无阻塞点）；取消语义属于上游解码/下游 PALA-030。

## 验收

对应 acceptance 逐条：并发压测打印往返统计；零分配用例打印实测增量；
DAG 成环/合法两种拓扑分别断言；全部经 `ctest -R audio` 机器判定。

## 回写

- `.ai/modules/audio.md`：结构段落补"已落地"清单与文件地图
- `.ai/memory/pitfalls.md`：SPSC 内存序/ABA 相关坑（如踩到）
- `.ai/memory/baselines.md`：ring 往返吞吐、pool acquire 耗时实测
- 本文件子步骤进度表
