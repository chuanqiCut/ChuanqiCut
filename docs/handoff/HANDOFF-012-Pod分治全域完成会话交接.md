# HANDOFF-012：壳工程 Pod 分治全域完成（会话交接）

> 2026-10-07 深夜三轮。[ADR-0031](../decisions/ADR-0031-主工程壳化与功能Pod分治.md) 六阶段
> 全部落地（阶段 0/1/4 见 HANDOFF-010/011；本轮完成阶段 2/5 并冻结阶段 3 的改挂决定）。

## 终态 Pod 拓扑（全部实测验证）

| Pod | 平台 | 依赖 | 测试 |
|---|---|---|---|
| ChuanqiCut（SDK） | 双端 | — | bindings 套 |
| SharedUI（基座） | 双端 | SDK | 无独立测试（swift build + 双壳兜底） |
| ChuanqiCutPlayer | 双端 | 无 | 52 |
| ChuanqiCutImport | 双端 | SharedUI（Theme） | 16 |
| ChuanqiCutCamera | **仅 iOS** | SharedUI（注入器） | 36（契约；实现随双壳） |
| ChuanqiCutEditor | 双端 | SDK + SharedUI | 36 |
| ChuanqiCutDraft | 未接线 | — | 骨架占位（PROJ-001 后填肉） |

**测试守恒**：迁移前 HEAD 140 = Player 52 + Camera 36 + Import 16 + Editor 36。
**基座终态**：SharedUI 仅 `Common/`——Theme（已公开化，唯一配色真源）+ 三个注入器
（PlayerPreview / EditorEntry / MediaLibrary）。壳装配点 = 双端 App.init。

## 关键决定（本轮）

- **INFRA-017 Assets 改挂 LIB 依赖**：素材面板/导入逻辑与 EditorViewModel 不可分
  （MediaSheet/importMedia），硬拆即假工程；随 LIB-001 素材库契约冻结建域，
  当前随 Editor Pod。ADR-0031 拓扑表的 Assets 语义由 LIB 轮兑现。
- **INFRA-020 Draft 为真骨架**：占位域符号，不进 Podfile；PROJ-005/UIA-029 落地时接线。

## 下一个会话怎么接手

1. **门禁基线 = 14 步**（deps/headers/artifacts/core-dbg/core-rel/xcframework/prepare/
   bindings/sharedui[build]/player/camera/import/editor/golden），数字见当日日志。
2. **UIA-032 编辑页重构**直接在 `packages/ChuanqiCutEditor` 内进行（Pod 迁移已就绪）。
3. **真机一趟两单**（池 [1] 播放器 + [2] CAM-018/019）——本轮新增 MediaLibraryInjector
   装配路径，走查含「素材面板→相册浏览器→批量导入」链。
4. 发号水位：ADR→0032；pitfalls→P86；INFRA 全部建卡完成。

## 验证

四包 swift test 全绿（数字上表）；iOS 模拟器 BUILD SUCCEEDED（6 pods + metallib 8431B
新鲜产物）；macOS BUILD SUCCEEDED（5 pods）；全量门禁 **PASS=14 / FAIL=0 / SKIP=0**（2026-10-07 18:34~18:48）。
