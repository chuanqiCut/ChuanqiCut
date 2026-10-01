# 模块：Apple UI（SwiftUI）

**边界**：`apps/apple/packages/SharedUI/`、`apps/apple/iOSApp/`、`apps/apple/MacApp/`、`apps/apple/project.yml`

## 原则
**UI 不跨平台共享，共享的是会话状态与命令**（ARCH-005）。

```
用户手势 → SwiftUI → submit(Command) → EditorSession(C++) → 快照 → UI diff 刷新
                                                          └→ 渲染请求 → RenderGraph
```

## 工程结构（UIA-002 落地版，2026-10-01）

```
apps/apple/
├── project.yml                    # xcodegen 工程定义（真源，入库）
├── ChuanqiCut.xcodeproj           # 生成产物（不入库）
├── packages/SharedUI/             # SwiftUI 共享包
│   ├── Sources/SharedUI/
│   │   ├── AppEntry.swift         # EditorViewModel（Session 唯一持有者）
│   │   ├── Editor/                # EditorView / EditorLayout / 三区桩视图
│   │   └── Common/Theme.swift
│   └── Tests/SharedUITests/
├── iOSApp/                        # ChuanqiCutApp（iOS 16+）
└── MacApp/                        # ChuanqiCutMacApp（macOS 15.4+，窗口 1280×720 / 最小 960×540）
```

**依赖链**：App → SharedUI（本地 SPM 包）→ ChuanqiCut 绑定（`bindings/swift`，
本地包身份是目录名 `swift`，见 pitfalls P7）→ 内核 XCFramework（构建产物，
`tools/build/build_core_apple.sh && bindings/swift/prepare.sh`）。

**工程生成**：`cd apps/apple && xcodegen generate`（本机未装 brew 时可从
GitHub Releases 下 xcodegen artifactbundle；当前装在 `~/tools/xcodegen/`）。
Info.plist 由 project.yml 的 `info:` 段生成，仓库不存手工副本。
**CocoaPods 未启用**：Podfile 仍是模板；SDK 经 SharedUI→ChuanqiCut SPM 链消费，
出现真正需要的第三方 Pod 时再激活（届时需要 xcworkspace）。

## 硬约束
1. **UI 不得直接改模型**，一切变更走 `EditorViewModel.submit()`（Command）
2. **时间线必须自绘**（Metal/Canvas），不得把每个片段做成 UI 组件 —— 数百片段会直接掉帧
3. 拖拽只更新"拖拽预览层"，拖拽结束才提交 Command
4. 缩略图与波形异步加载，主线程不解码
5. **预览画面不经 UI 合成路径**：`MTKView` 直接绘制（UIA-003）
6. 平台差异（iOS 手势 vs Mac 菜单/快捷键）收敛在 `EditorLayout.swift`，业务视图不写条件编译
7. App 入口必须 `ChuanqiCut.markMainThread()`；可抛构造进 `*State(wrappedValue:)`
   前**先建值后包装**（见 pitfalls P8）

## 当前状态（UIA-002 完成）
- 三区布局（Preview / Timeline / PropertyPanel）均为**桩视图**，架构位已留：
  - UIA-003 替换 PreviewZone → MTKView
  - UIA-004 替换 TimelineZone → 自绘时间线
  - UIA-006 替换 PropertyPanelZone → 真实参数（走 Command）
- `EditorViewModel`：@MainActor，唯一持有 `ChuanqiCut.Session`；快照 observer
  经 `Task { @MainActor }` 回流；`refreshCapabilities()` 缓存能力查询
- **iOS 构建策略：只跑真机**（用户决策 2026-10-01），不建模拟器版本；
  真机（iPhone 17 Pro）当前 unavailable，iOS 侧停在"代码已生成"

## 性能验收
- 时间线拖拽期间主线程单帧 < 16ms
- 1080p 三轨预览 ≥ 55fps（高端机）
- 打开项目到出画面 < 1.5s（1080p）

## 验证
```bash
# SharedUI 包（macOS 宿主）
cd apps/apple/packages/SharedUI && swift test --disable-sandbox

# macOS target
cd apps/apple && xcodegen generate
xcodebuild build -project ChuanqiCut.xcodeproj -scheme ChuanqiCutMacApp \
    -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO

# iOS target：仅在真机可用时构建运行（xcodebuild -destination 'platform=iOS'）
```

## 相关
ARCH-005、TASK-UIA-002、pitfalls P7/P8
