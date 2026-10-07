# 模块：导出

> **归属**：C 线（内核/媒体/渲染） —— 归属表见 docs/tasks/PLAN-三线并行.md §1a / ADR-0029（双机分工与门禁跑批，2026-10-07）

**边界**：`core/src/export/`、`pal/<platform>/media_enc*`

## 职责
导出状态机、进度、取消、错误码、临时文件管理；与预览共用 RenderGraph。

## 硬约束
1. **导出与预览走同一张 RenderGraph**，只换输出目标（EncoderInput vs Swapchain）与时钟源（PresentationTime vs audio clock）
2. **导出不允许丢帧**，预览允许
3. 取消必须：在 pass 边界与解码边界检查 CancelToken；取消后**释放全部 GPU/媒体资源**并清理临时文件
4. 失败必须返回**稳定错误码**，UI 可据此给出明确提示
5. 编码/封装默认走系统 API：Apple `AVAssetWriter`、Android `MediaMuxer`、鸿蒙 `OH_AVMuxer`

## 平台注意
- iOS 后台导出：`beginBackgroundTask` + 低功耗约束处理
- macOS：沙箱导出走 `NSSavePanel` + 安全作用域 bookmark
- Android：MediaStore 插入或 SAF

## 验证
```bash
ctest -R export_cancel        # 取消后资源释放
tests/e2e/export_1080p.sh
tests/e2e/export_4k.sh
tools/qa/golden_compare.sh --case=export   # 与预览一致性 PSNR ≥ 40dB
```

## 相关
ARCH-001 §7、`EXPORT-0xx` 任务

---

## 模块册（ADR-0030：任务/进度/测试门禁记录按模块归口）

> 本节由归属线更新（一机一线，天然单写者）；BACKLOG / pitfalls / baselines 等
> 全局册零直写（集成机阶段批落账）。新调研/规格/审查落 docs/ 原位，但必须在此登记指针。

### 任务与进度（在飞 + 近期；全量 DAG 见 TASK-BACKLOG）

| Task ID | 标题 | 状态 |
|---|---|---|
| EXPORT-001/002 | 导出链 | 未做（P0 缺口：导出按钮置灰） |
| EXPORT-010/011 | GIF / LivePhoto 导出 | 预占（§13） |

### 测试与门禁记录（阶段批）

| 日期 | 阶段/范围 | 结论（数字） |
|---|---|---|
| — | 未实测（本模块无独立阶段批记录） | — |

### 调研 · 决策 · 池指针

- ADR-0028（预占）· AIEDIT 对导出的 P0.5 依赖
