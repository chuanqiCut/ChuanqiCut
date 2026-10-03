# TASK-UIA-009：素材导入流程（含 Session 级素材表收口）

```yaml
id:          TASK-UIA-009
layer:       UI + BIND + 跨平台
goal:        用户能从文件选择器导入视频素材，片段经 Command 进入 Session 模型，时间线与预览可见
input:       [docs/tasks/TASK-BACKLOG.md §3.5 UIA-009, docs/tasks/TASK-BIND-003.md（预览装配现状）, .ai/modules/session.md, .ai/modules/model.md, .ai/modules/preview.md, docs/tasks/TASK-MODEL-002.md]
output:      [Session 级素材表与片段 Command 的 C ABI, 预览读 Session 模型的收口, SharedUI 导入 UI, Swift 封装, 测试]
write_set:   见「子步骤拆分」（按子步骤声明，互相不相交；`cq_sdk.h` 为高冲突文件，改动窗口内禁止其他任务触碰）
read_set:    core/include/cq/{command,preview,media,session}/*.h, bindings/swift/Sources/ChuanqiCut/*.swift
deps:        [MODEL-002 ✅, UIA-004（子步骤 3 的时间线显示依赖它；子步骤 1/2 不依赖，可先行）]
acceptance:
  - 通过 UI 导入一段视频 → 片段出现在时间线（UIA-004 视图）且预览渲染其画面
  - 导入的素材注册在 **Session 级**：同一 asset 在预览与后续导出路径可见（非 CQPreview 私有）
  - 片段创建走 CommandHistory（撤销后片段消失、模型指纹回到导入前）
  - C ABI 新增函数有真正的 C TU 测试（沿用 test_c_abi*.c 手法）
  - `cq_tests_c_abi` 只链 cq_core 仍通过（session 新 TU 不引 PAL 符号）
verification:
  - ./tools/build/build_core.sh --platform=apple --config=Debug --test
  - ctest --test-dir build -R c_abi_session
  - cd bindings/swift && swift test --disable-sandbox
  - cd apps/apple/packages/SharedUI && swift test --disable-sandbox
  - macOS App xcodebuild build + 启动冒烟（导入 → 预览可见）
risk:  预览读 Session 模型的线程安全（子步骤 2 的核心设计，见下）；
       cq_sdk.h 高冲突文件串行修改；
       iOS 文件导入的沙箱路径（security-scoped resource）真机才能验。
parallel:    false（子步骤 1 改 cq_sdk.h；子步骤 2 改预览 TU；子步骤 3 改 SharedUI —— 串行推进）
```

## 进度（2026-10-03）

| 子步骤 | 状态 |
|---|---|
| 1 契约（Session 级模型 + 查询 ABI） | ✅ |
| 2 预览收口（cq_preview 挂 session 快照，删除本地装配 ABI） | ✅ |
| 3 导入 UI（文件选择 → 入表 → Command 建片段） | ⏭️ 下一步 |

## 背景

- 用户侧导入流程此前**没有任务编号**（BACKLOG 缺口，2026-10-03 与传哲确认补建）。
  底层能力链已通：素材表（BIND-003 子步骤 1）→ 取帧（子步骤 2）→ 预览上屏（UIA-003）；
  缺的是「文件选择 → 入表 → 建片段 → 可见」的端到端流程。
- 架构矛盾（BIND-003 遗留的阶段性形状）：AssetRegistry 与 Timeline 目前挂在
  `CQPreview` 内部（预览私有装配视图）。真正导入流程下素材必须 **Session 级**共享，
  片段创建必须走 Command（红线 #5）。本任务同时完成这个收口。

## 关键架构决策（实现子步骤 1/2 前先读）

### D1：素材表上收到 Session（已定方向，2026-10-03 传哲确认）

Session 的 `ISessionState` 真实实现改为 **Timeline + AssetRegistry + CommandHistory**
（CORE-009 留的扩展点，此前只有测试桩）。CQPreview 的本地 Timeline/AssetRegistry
退役，预览只保留「渲染器 + 帧提供器装配」。

### D2：预览怎么读 Session 模型（子步骤 2 的核心设计，hypothesis 待实现验证）

预览渲染不在 session 线程（渲染耗时会阻塞命令队列），而 Timeline 会被命令修改 ——
直接共享指针有数据竞争。**采用不可变快照**：session 线程每次命令成功后重建
`std::shared_ptr<const Timeline>`（Timeline 拷贝是小型向量拷贝，每次命令一次，
可接受）并原子发布；预览渲染时原子加载最新快照。替代方案（渲染投递到 session
线程 / 加锁）分别有阻塞与锁竞争问题，不采用。

### D3：导入的文件是引用还是拷入库

MVP **引用原路径**（不拷贝）：文件被移动/删除后素材失效，UI 届时按
`cq_preview_last_*` 同款诊断路径暴露错误。素材库整理（拷贝入沙箱、相对路径）
留待后续任务，卡片不假装已支持。

## 子步骤拆分（串行推进）

| # | 内容 | 写集 | 验证 |
|---|---|---|---|
| 1 | **✅ 已完成（2026-10-03）**：EditorModelState（Timeline+AssetRegistry+CommandHistory，不可变快照发布）+ C ABI（register_asset/add_track/add_clip/query_*，查询返回状态码+out_count）。C TU 测试 c_abi_session；digest 转真实指纹。undo/redo C ABI 仍留 UIA-008 |`EditorSession` 挂 Timeline+AssetRegistry+CommandHistory；`cq_sdk.h` 补 `cq_session_register_asset` / `cq_session_add_clip`（内部转 `InsertClipCommand` 进 CommandHistory）/ `cq_session_timeline_fingerprint`（digest 用真实指纹，替换「恒为 0」）；undo/redo 的 C ABI **不在本任务**（归 UIA-008）。新增测试 `test_c_abi_session.c` | `core/include/cq/session/editor_session.h`、`core/src/session/editor_session.cpp`、`core/include/cq/cq_sdk.h`、`core/src/cq_sdk.cpp`、`tests/unit/test_c_abi_session.c`、`tests/CMakeLists.txt`（登记） | ctest -R c_abi_session；门禁 Debug+Release |
| 2 | **✅ 已完成（2026-10-03）**：PreviewRenderer 改 IModelSnapshotProvider（D2 方案落地：渲染入口加载配对快照，本帧全用同一快照）；CQPreview 本地模型退役；register_asset/add_clip **直接删除**（Swift 同步改，无双写漂移）；provider 缓存按路径变更失效；CQSession 定义抽私有共享头 cq_session_impl.h | `core/include/cq/preview/preview_renderer.h`、`core/src/preview/preview_renderer.cpp`、`core/src/preview/cq_sdk_preview.cpp`、`bindings/swift/Sources/ChuanqiCut/Previewer.swift`（API 同步）、相关测试 | 预览渲染测试 + 绑定 swift test 全绿；**实现前跑 cq-media-pipeline 专项分析**（线程/时序/取消） |
| 3 | **导入 UI**：macOS `NSOpenPanel` / iOS `fileImporter` → `registerAsset` → `addClip` Command → UIA-004 时间线视图显示 + 预览可见；素材库最小面板（列表 + 失效标记，D3） | `apps/apple/packages/SharedUI/Sources/SharedUI/**`（MediaLibrary 面板 + EditorViewModel 扩展）、App 入口、`bindings/swift/Sources/ChuanqiCut/Session.swift`（新 ABI 封装）、测试 | swift test + macOS App 编译 + 启动冒烟（导入 → 预览可见）；iOS 真机验沙箱路径 |

## 验收（对应子步骤）

1. UI 导入 golden mp4 → 时间线出现片段、预览显示画面（macOS 冒烟 + 截图证据可选）
2. 撤销（经 UIA-008 或调试入口）→ 片段消失、fingerprint 回到导入前
3. 新 C ABI 有 C TU 测试；`cq_tests_c_abi` 只链 cq_core 回归通过
4. 素材表 Session 级：`cq_session_register_asset` 注册的素材，预览渲染直接可用
   （不再需要 `cq_preview_register_asset`）

## 回写

- Session 级模型状态 / 快照机制 → `.ai/modules/session.md`；预览收口 → `.ai/modules/preview.md`
- D2 线程方案验证结论（hypothesis → verified/unverified）→ `.ai/memory/pitfalls.md` 或 baselines
- 导入流程的坑（沙箱路径、文件失效）→ pitfalls
