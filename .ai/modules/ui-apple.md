# 模块：Apple UI（SwiftUI）

**边界**：`apps/apple/packages/SharedUI/`、`apps/apple/iOSApp/`、`apps/apple/MacApp/`、`apps/apple/project.yml`

## 原则
**UI 不跨平台共享，共享的是会话状态与命令**（ARCH-005）。

```
用户手势 → SwiftUI → submit(Command) → EditorSession(C++) → 快照 → UI diff 刷新
                                                          └→ 渲染请求 → RenderGraph
```

## 工程结构（INFRA-009 拆分版，2026-10-02；替代 UIA-002 单工程形态）

```
apps/apple/
├── packages/SharedUI/             # SwiftUI 共享包
│   ├── SharedUI.podspec           # App 集成真源（pod）
│   ├── Package.swift              # 仅 swift test 测试宿主，不在 App 依赖链
│   ├── Sources/SharedUI/
│   │   ├── AppEntry.swift         # EditorViewModel（Session 唯一持有者）
│   │   ├── Editor/                # EditorView / EditorLayout / 三区桩视图
│   │   └── Common/Theme.swift
│   └── Tests/SharedUITests/
├── ios/                           # iOS 独立工程
│   ├── project.yml                # xcodegen 真源（ChuanqiCutApp，iOS 16+）
│   ├── Podfile / Gemfile(.lock)   # 本目录独立维护
│   └── iOSApp/
└── mac/                           # macOS 独立工程
    ├── project.yml                # xcodegen 真源（ChuanqiCutMacApp，macOS 15.4+）
    ├── Podfile / Gemfile(.lock)   # 本目录独立维护
    └── MacApp/                    # 窗口 1280×720 / 最小 960×540
```

**依赖链**（INFRA-009 起，全部走 CocoaPods，App 不用 SPM）：
App → SharedUI (pod) → ChuanqiCut (pod，**默认 Source 模式**：现场编译
C++20 内核 + ObjC++ PAL + Swift 绑定) → CChuanqiCut (clang module，
经 SWIFT_INCLUDE_PATHS 共用 `bindings/swift/Sources/CChuanqiCut/include/`)。
`bindings/swift/Package.swift` 仅作绑定层 `swift test` 测试宿主。
集成细节与红线见 `docs/COCOAPODS.md` 与 pitfalls P9~P12。

**工程生成**（clone 后 / project.yml 或 Podfile 变更后，在 ios/ 或 mac/ 下）：
```bash
xcodegen generate            # 本机装在 ~/tools/xcodegen/xcodegen/bin/
bundle install               # Gemfile.lock 钉住 CocoaPods 1.17.0（lock 必须入库）
bundle exec pod install      # 生成 .xcworkspace；打开 workspace 而非 xcodeproj
```
Info.plist 由 project.yml 的 `info:` 段生成，仓库不存手工副本。
ChuanqiCut.xcodeproj / .xcworkspace 均为生成产物（.gitignore 已排除）。

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
# SharedUI 包（macOS 宿主，需先产出 xcframework：build_core_apple.sh && prepare.sh）
cd apps/apple/packages/SharedUI && swift test --disable-sandbox

# macOS App（INFRA-009 起，workspace 编译）
cd apps/apple/mac && xcodegen generate && bundle install && bundle exec pod install
xcodebuild build -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutMacApp \
    -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO

# iOS App：编译用 -sdk iphoneos18.4（platform runtime 缺失时 destination 解析不了；
# legacy -target 模式绕过 destination，需把 pod 目标与 app 目标建到同一 BUILD_DIR）
cd apps/apple/ios && xcodegen generate && bundle install && bundle exec pod install
xcodebuild build -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutApp \
    -sdk iphoneos18.4 CODE_SIGNING_ALLOWED=NO
# 上式 destination 报"not installed"时的等价 legacy 链（BUILD_DIR 三者一致）：
#   for T in ChuanqiCut SharedUI Pods-ChuanqiCutApp; do \
#     SYMROOT="$PWD/build" BUILD_DIR="$PWD/build" xcodebuild build \
#       -project Pods/Pods.xcodeproj -target $T -sdk iphoneos18.4; done
#   xcodebuild build -project ChuanqiCut.xcodeproj -target ChuanqiCutApp \
#     -sdk iphoneos18.4 CODE_SIGNING_ALLOWED=NO
# 运行仅在真机可用时（xcodebuild -destination 'platform=iOS'）
```

## 相关
ARCH-005、TASK-UIA-002、pitfalls P7/P8


---

# UIA-004 落地（2026-10-03）：时间线自绘

- `apps/apple/packages/SharedUI/Sources/SharedUI/Timeline/EditorTimelineView.swift`
  （⚠️ 不叫 TimelineView —— SwiftUI 有同名系统类型，P22 同款）
- 几何纯函数 `TimelineLayout`（时间↔像素 / 可见裁剪 / 标尺自适应）——可单测可 measure
- **单 Canvas 绘制**（轨道行/片段/标尺/播放头），非组件堆叠
- 数据流：快照 observer → 版本推进 → Session.queryTracks/queryClips（主线程直读
  内核快照）→ EditorViewModel.timeline（@Published）→ Canvas
- 实测：500 片段布局 0.663 ms/帧（< 16ms 预算的 4%，见 baselines）
- 拖拽/裁剪/选择交互归 UIA-005；波形成略图等媒体分析后续任务


# UIA-009 子步骤 3 落地（2026-10-03）：素材库面板与导入流程

- **PropertyPanelZone 重写**：素材库（fileImporter 导入按钮 + 列表 + 失效标记）
  + 属性桩保留（UIA-006 接真实参数）。签名改为无参 + `@EnvironmentObject`。
- **EditorViewModel.importMedia(url)**（主线程，用户动作低频）：
  security scope（iOS）→ `probeMediaDuration`（同步探测时长）→ `registerAsset`
  （id 本地单调分配）→ 目标轨道（第一条视频轨，无则建 + RunLoop 泵等 id）→
  `addClip` 追加到该轨末尾（追加式不重叠）。失败全链路干净返回（探测失败/
  提交失败不留半截状态）。
- **失效标记（D3 决策的落地）**：MVP 引用原路径不拷贝 —— `LibraryAsset.exists`
  由 FileManager 实时判定，文件被移走显示「⚠ 文件不在原路径（已失效）」，
  渲染侧届时以 kInvalidArgument 暴露。素材库整理（拷入沙箱）后续任务。
- 媒体类型白名单：movie/video/mpeg4Movie。
- **测试路径 helper 唯一真源**：`RepoPath`（SharedUI）/`TestPaths`（bindings），
  #filePath 上溯链**不得在新测试里手写**（本轮两次踩层数错误，P30）。
