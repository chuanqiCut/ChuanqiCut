# TASK-CORE-006：PAL 接口定义冻结

> **本任务拆两个会话执行，不得合并。**
> 上半：只出头文件 → 停 → 人工评审。
> 下半：评审通过后才写实现（实现部分另立任务 CORE-006B）。

```yaml
id:          CORE-006
layer:       跨平台（SDK 内核）
goal:        冻结 core/ 与 pal/ 之间的全部接口契约，作为三端实现的唯一依据
input:       [CORE-001~005, ARCH-001 §4 PAL 契约, ARCH-003 GFX, ARCH-004 平台矩阵]
output:      [core/include/cq/pal/*.h（8 个契约头）, 接口评审纪要, 编译期契约检查 target]
write_set:   core/include/cq/pal/{gfx,media,audio,inference,fs,clock,log,capabilities}.h,
             tests/contract/pal_contract_test.cpp
read_set:    docs/specs/ARCH-001, docs/specs/ARCH-003, docs/specs/ARCH-004,
             .ai/modules/{pal-apple,pal-android}.md, .ai/source/AGENTS.root.md
deps:        [CORE-001, CORE-002, CORE-003, CORE-004, CORE-005]
acceptance:
  - 八个契约头（GFX / Media / Audio / Inference / FS / Clock / Log / Capabilities）全部定义完毕
  - **头文件零平台类型**：全文不得出现 CVPixelBuffer、AHardwareBuffer、VkImage、MTLDevice、jobject 等；
     用 grep 白名单校验，命中即失败
  - 公共头只用 C 类型 + opaque 句柄，不得出现任何第三方库类型
  - 能力查询统一走 `cq_query_capability()`，头文件中不得出现任何编译期平台宏推断
  - 有一份编译期契约检查：PAL 实现不满足接口时编译失败（不是运行失败）
  - 评审纪要记录了每个接口的：所有权语义、线程归属、错误码、取消语义
verification:
  - tools/qa/check_pal_headers.sh        # 平台类型 / 第三方类型扫描
  - cmake --build build --target pal_ohos_stub   # 鸿蒙桩编译检查（ADR-0007）
  - ctest -R pal_contract
risk:        **全工程杠杆率最高、返工成本最大的一个任务。** 它是 core 与 pal 的接缝，
             定错一个接口，三端实现全部要改。缓解：强制两段式（先出头文件评审，再写实现），
             并在评审前**不写任何实现代码**——写了就容易被实现细节反向绑架接口设计。
parallel:    false
```

## 背景

`core/` 必须与平台无关，`pal/` 做适配。两者的接缝如果在实现过程中临时演化，会退化成"接口跟着实现长"，最终三端各有一套事实标准。本任务的目的就是在任何人写 PAL 实现之前，把这条线钉死。

## 实现要点

- **句柄而非继承**：跨 ABI 边界用 opaque 句柄（`CQGfxDevice*`），不要暴露 C++ 类继承体系。C++  ABI 在跨编译器/跨标准库时不稳定。
- **所有权显式**：每个创建/销毁函数成对出现，注释写明谁持有、谁能释放。
- **错误码统一**：沿用 CORE-002 的 `Status`，PAL 不得自己定义一套错误码。
- **取消语义**：所有可能长耗时的接口（seek、decode、infer）必须接受 `CancelToken`（来自 CORE-005）。
- **线程归属**：头文件注释写明每个接口允许在哪个线程调用。音频接口必须标注 realtime-safe（无锁、无分配）。
- **能力查询**：`CQ_CAP_*` 枚举 + 运行时查询，禁止 `#if __APPLE__` 推断功能。
- 鸿蒙桩（`pal/ohos/` 只声明不实现）必须能编译，这是 ADR-0007 要求的架构预留验证手段。

## 评审清单（上半结束后逐项过）

- [ ] 八个契约头是否覆盖了三端已识别的全部能力差异
- [ ] 是否存在"某个接口在鸿蒙上根本不可能实现"的情况（若有，现在改比以后改便宜十倍）
- [ ] 能力降级路径是否都在接口层表达（无硬解→软解、无 compute→fragment）
- [ ] 无平台类型 / 无第三方类型扫描通过

## 验收

逐条对应 acceptance，附扫描脚本输出与评审纪要。

## 回写

- 接口定稿 → `.ai/modules/core.md`、`.ai/modules/pal-apple.md`、`.ai/modules/pal-android.md`
- 若评审推翻了某个接口设计 → 记录进 `.ai/memory/pitfalls.md`，并考虑是否要提 ADR
- 冻结后任何接口变更 → **必须**走 ADR，不接受就地改
