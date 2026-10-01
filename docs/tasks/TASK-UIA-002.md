# TASK-UIA-002：编辑器主框架（预览 + 时间线 + 属性面板）

> 日期：2026-10-01
> 状态：**已完成（macOS 验证通过；iOS 停在代码生成，待真机）**
> 依赖：BIND-002 ✅
> 验收：三区布局，Mac/iOS 自适应

---

## 写集

| 文件 | 操作 |
|---|---|
| `apps/apple/packages/SharedUI/Package.swift` | 新建 |
| `apps/apple/packages/SharedUI/Sources/SharedUI/Editor/EditorView.swift` | 新建 |
| `apps/apple/packages/SharedUI/Sources/SharedUI/Editor/EditorLayout.swift` | 新建 |
| `apps/apple/packages/SharedUI/Sources/SharedUI/Editor/PreviewZone.swift` | 新建 |
| `apps/apple/packages/SharedUI/Sources/SharedUI/Editor/TimelineZone.swift` | 新建 |
| `apps/apple/packages/SharedUI/Sources/SharedUI/Editor/PropertyPanelZone.swift` | 新建 |
| `apps/apple/packages/SharedUI/Sources/SharedUI/Common/Theme.swift` | 新建 |
| `apps/apple/packages/SharedUI/Sources/SharedUI/AppEntry.swift` | 新建 |
| `apps/apple/packages/SharedUI/Tests/SharedUITests/EditorViewModelTests.swift` | 新建 |
| `apps/apple/iOSApp/ChuanqiCutApp.swift` | 新建 |
| `apps/apple/iOSApp/Assets.xcassets/...` | 新建 |
| `apps/apple/MacApp/ChuanqiCutMacApp.swift` | 新建 |
| `apps/apple/MacApp/Assets.xcassets/...` | 新建 |
| `apps/apple/project.yml` | 新建 |
| `.gitignore` | 追加（生成工程 / SPM 构建目录 / CocoaPods 本地环境 / .zcode） |

不触碰：`core/`、`bindings/`、`pal/`、`CMakeLists.txt`、`cq_sdk.h`

## 实际写集与计划的偏差

- **未用 xcworkspace / 未激活 Podfile**：iOS + macOS 两个 target 放同一 project；
  SDK 经 SharedUI→ChuanqiCut SPM 本地包链消费，无需 CocoaPods。Podfile 仍为模板，
  出现真正第三方 Pod 时再激活。
- **无 ContentView.swift**：App 入口直接挂 `EditorView`，少一层无意义转发。
- **无独立 AdaptiveStack.swift**：布局容器落在 `Editor/EditorLayout.swift`（域内聚）。
- **Info.plist 不入库**：由 project.yml `info:` 段生成。
- **xcodegen 来源**：本机无 brew，从 GitHub Releases 装到 `~/tools/xcodegen/`（仓库外）。

## 验证记录（2026-10-01）

| 命令 | 结果 |
|---|---|
| `swift build --disable-sandbox`（SharedUI） | ✅ Build complete |
| `swift test --disable-sandbox`（SharedUI） | ✅ 4/4 通过 |
| `xcodegen generate` | ✅ 生成 ChuanqiCut.xcodeproj |
| `xcodebuild build -scheme ChuanqiCutMacApp -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | ✅ BUILD SUCCEEDED |
| Mac App 启动冒烟（跑 4s 后 kill） | ✅ 存活（Session 创建成功、窗口已起） |
| iOS target 构建 | ⏭️ **跳过**——用户决策只跑真机不建模拟器；真机 iPhone 17 Pro 当前 `unavailable`。代码已生成，真机就绪后 Xcode 选设备签名运行 |

### 验证中发现并已修复的问题

1. `StateObject(wrappedValue: try ...)` 编译错误（非 throwing autoclosure）→
   先建值后包装（pitfalls P8）
2. AppIcon "unassigned child" 告警 → appiconset `images: []`
3. SPM 本地包身份 = 目录名 `swift`（pitfalls P7）

## 剩余风险

- iOS 未编译过——Swift 6 并发/平台 API 在 iOS 分支（`iosLayout` 的
  GeometryReader/horizontalSizeClass）尚未过编译器，真机就绪后首次构建可能出小错
- SharedUI 包声明 `.macOS(.v15)` 但内核库按 15.4 部署目标构建，`swift test` 有
  "built for newer macOS version" 链接警告（App target 已设 15.4，不受影响；
  与 bindings 包同一已知现象）
- `EditorViewModel.init` 抛错路径在 App 里走 `fatalError`——内核断链即崩溃，
  属刻意选择（诚实失败），后续可换错误页

## 验证命令

```bash
# 1. 确保 XCFramework 就绪（clone 后首次）
tools/build/build_core_apple.sh --config=Release && bindings/swift/prepare.sh

# 2. 生成 Xcode 工程并编译 macOS
cd apps/apple && xcodegen generate
xcodebuild build -project ChuanqiCut.xcodeproj \
    -scheme ChuanqiCutMacApp -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO

# 3. SharedUI 单测
cd apps/apple/packages/SharedUI && swift test --disable-sandbox

# 4. iOS：仅真机（用户决策 2026-10-01，不建模拟器版本）
#    真机就绪后：Xcode 打开 apps/apple/ChuanqiCut.xcodeproj，
#    选 ChuanqiCutApp scheme + 真机，配置签名后 Run
```
