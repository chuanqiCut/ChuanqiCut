# ARCH-005：UI 层策略与工程结构

> 版本：v1.0（待 Review）
> 日期：2026-09-23
> 核心立场：**UI 层不跨平台共享，共享的是会话状态与命令。**

---

## 1. 为什么 UI 不共享

考虑过 Flutter / Compose Multiplatform / 自绘 UI 统一三端。否决：

| 方案 | 否决理由 |
|---|---|
| Flutter | 引擎自带渲染上下文，与编辑器主 GPU 上下文争抢资源；包体与内存开销大；手势/拖拽在编辑器高频交互下不占优；原方案"为了学 Flutter"更不是工程理由 |
| Compose Multiplatform | iOS 端成熟度不足，Skia 与 Metal 互操作同样有上下文问题 |
| 自绘 UI 统一（如内嵌自研 UI 引擎） | 工作量等同于做一个 UI 框架，偏离主业 |

**编辑器的 UI 恰恰是最需要"平台原生手感"的部分**：iOS 的滚动阻尼与手势、macOS 的窗口/菜单/键盘快捷键、Android 的返回键与手势导航、鸿蒙的分布式交互。用一套 UI 抹平这些，用户体验是净损失。

---

## 2. 各端 UI 选型

| 平台 | 框架 | 说明 |
|---|---|---|
| iOS / macOS | **SwiftUI** | 两个 target + `SharedUI` Swift package，共享 ≥80% |
| Android | **Jetpack Compose** | Kotlin |
| HarmonyOS（P2） | **ArkUI (ArkTS)** | 预留 |

---

## 3. 共享的是"会话"，不是"界面"

下沉到 C++ 的 UI 相关状态：

```
EditorSession（C++）
  ├── TimelineModel          轨道/片段/转场/效果
  ├── SelectionState         当前选中、多选
  ├── PlayheadState          播放头位置、播放/暂停、循环
  ├── CommandHistory         Undo/Redo
  ├── PreviewState           当前帧、缩放、适应模式
  └── ExportState            进度、取消、错误
```

UI 层只做三件事：**呈现状态 / 收集输入 / 发出命令**。

```
用户手势
   │
   ▼
UI (SwiftUI / Compose)
   │  execute(Command)
   ▼
EditorSession (C++)  ── 变更模型 ──▶ 状态快照
   │                                    │
   │                                    ▼
   └─────────── 状态变更通知 ────────▶ UI 刷新（diff 更新）
                                    │
                                    └──▶ 渲染请求 ──▶ RenderGraph
```

**铁律：UI 不得直接修改模型。** 所有变更必须走 `Command`，这是 Undo/Redo 能工作的前提，也是三端行为一致的前提。

---

## 4. 绑定层设计

### 4.1 对外 ABI 是 C

`core/include/cq/cq_sdk.h` 是唯一的跨语言边界，纯 C 接口：

```c
// 句柄式、无 STL 类型、无异常、无平台类型
CQSessionHandle cq_session_create(const CQSessionConfig*);
CQStatus        cq_session_execute(CQSessionHandle, CQCommand*);
CQStatus        cq_session_get_snapshot(CQSessionHandle, CQSnapshot* out);
void            cq_snapshot_release(CQSnapshot*);
```

理由：Swift/Java/ArkTS 都能直接调用 C；C++ 的 ABI 不稳定且无法被 Swift 直接消费。

### 4.2 状态通知

- 采用**快照 + 版本号**而非回调风暴：`cq_session_get_snapshot` 返回不可变快照，UI 按 version 判断是否需要刷新。
- 高频信息（播放头、导出进度）用独立的轻量轮询或节流回调，不进快照。
- 快照对象由内核分配、UI 释放，生命周期规则写进头文件注释。

### 4.3 预览视图的嵌入

| 平台 | 载体 |
|---|---|
| iOS/macOS | `MTKView`（或 Metal 绘制的 `UIViewRepresentable` / `NSViewRepresentable`） |
| Android | `SurfaceView` / `TextureView` + NDK 侧 `ANativeWindow` |
| HarmonyOS | `XComponent`（P2） |

内核通过 PAL 拿到原生窗口句柄，直接绘制。**预览画面不经过 UI 框架的合成路径**，避免额外拷贝。

---

## 5. 时间线 UI 的性能要求

时间线是最容易做烂的部分。约束：

1. **不把每个片段做成一个 UI 组件**。片段数量可达数百，SwiftUI/Compose 的组件开销会直接导致拖拽掉帧。
2. **自绘**：时间线整体作为一个自绘视图（Metal / Canvas / Compose `Canvas`），按可见区域裁剪绘制。
3. **缩略图与波形异步加载**，主线程不解码。波形数据由内核侧预分析并缓存（项目包内 `cache/waveform`）。
4. **拖拽只更新一个"拖拽预览层"**，拖拽结束才提交 Command。

---

## 6. 工程结构（落地版）

```
apps/apple/
├── ChuanqiCut.xcworkspace
├── packages/
│   └── SharedUI/                  # SwiftUI 共享包（Package.swift）
│       ├── Sources/SharedUI/
│       │   ├── Editor/            # TimelineView / PreviewView / PropertyPanel
│       │   ├── ProjectList/
│       │   ├── Export/
│       │   └── Settings/
│       └── Tests/
├── iOSApp/                        # iOS target（App 生命周期、权限、文档选择）
└── MacApp/                        # macOS target（窗口、菜单、快捷键）

apps/android/
├── app/                           # Compose UI
├── cqbind/                        # JNI 绑定 module
└── build.gradle.kts

apps/ohos/                         # 预留（本期为空目录 + README）
```

**高冲突文件治理**（多 Agent 并行时必冲突）：
- `*.pbxproj`、`build.gradle.kts`、`CMakeLists.txt`、公共模型头文件、`cq_sdk.h`
- 规则：**串行修改**，或先落一个"契约 PR"再让下游基于该提交开发（见 `AI-COLLAB-001`）。

---

## 7. UI 层的验收标准

| 项 | 标准 |
|---|---|
| 预览帧率 | 1080p 三轨 + 基础效果：高端机稳定 ≥ 55fps；中端机 ≥ 30fps（可降预览分辨率）。**低端机不适配** |
| 拖拽响应 | 时间线拖拽期间 UI 无卡顿，主线程单帧耗时 < 16ms |
| 首帧时间 | 打开项目到预览出画面 < 1.5s（1080p，高端机） |
| 三端一致性 | 同一项目在三端的编辑结果一致（PSNR 阈值见 ARCH-003 §9） |
| Undo/Redo | 所有用户可见操作可撤销；连续 100 次 undo 后状态与初始一致 |

> 性能基线以**中端机为下限**设定，保证中端可用；高端机天然宽裕。低端机明确不支持（ARCH-004 §7）。
