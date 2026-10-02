# TASK-INFRA-009：Apple 端双工程拆分 + CocoaPods 源码集成

> Owner 决策（2026-10-02）：iOS 与 macOS 项目**单独维护** Gemfile + Podfile；
> SDK **默认源码导入**（便于调试和分析问题）；SPM 无法依赖 pod，故 Swift 代码
> （SharedUI）一并 podspec 化。本任务把该决策落为仓库结构。

```yaml
id:          TASK-INFRA-009
layer:       基建
goal:        apps/apple 拆分 iOS / macOS 两个独立 Xcode 工程，各自维护
             Gemfile + Podfile；SDK 以 ChuanqiCut/Source（现场编译）为默认集成
             方式；SharedUI 由本地 SPM 包改为 pod，App 依赖链整体脱离 SPM
input:       [docs/COCOAPODS.md, TASK-UIA-002 产物, ChuanqiCut.podspec,
             ADR-0010（平台基线 iOS 16 / macOS 15.4）]
output:      [apps/apple/{ios,mac}/ 双工程, 双 Podfile + 双 Gemfile(+lock),
             SharedUI.podspec, ChuanqiCut.podspec 修订, 文档回写]
write_set:   apps/apple/**, ChuanqiCut.podspec, Gemfile, Gemfile.lock,
             .gitignore, docs/tasks/TASK-INFRA-009.md,
             docs/tasks/TASK-BACKLOG.md（追加行）, docs/COCOAPODS.md,
             .ai/modules/ui-apple.md, .ai/memory/pitfalls.md
read_set:    bindings/swift/**, core/include/**, core/src/**（只读！编译验证）,
             pal/apple/**, cmake/*.cmake, docs/tasks/TASK-UIA-002.md
deps:        [INFRA-002, UIA-002]
acceptance:
  - apps/apple/ios 与 apps/apple/mac 各自独立：project.yml / Podfile /
    Gemfile / Gemfile.lock 四件套齐全，根目录不再有 Gemfile
  - `bundle exec pod install` 在两个目录均成功，SDK 走 Source subspec
    （现场编译 core C++20 + ObjC++ PAL + Swift 绑定，不依赖预构建 xcframework）
  - macOS App 全量编译通过（xcodebuild -workspace … -scheme ChuanqiCutMacApp）
  - iOS App 编译通过（xcodebuild -destination 'generic/platform=iOS'
    CODE_SIGNING_ALLOWED=NO；真机运行不在本任务范围）
  - App 源码零改动完成迁移（ChuanqiCutApp.swift / MacApp 入口与 SharedUI
    视图文件内容不变，仅目录位置变化）
verification:
  - cd apps/apple/ios  && bundle install && bundle exec pod install
  - cd apps/apple/mac  && bundle install && bundle exec pod install
  - xcodebuild build -workspace apps/apple/mac/ChuanqiCut.xcworkspace
    -scheme ChuanqiCutMacApp -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
  - xcodebuild build -workspace apps/apple/ios/ChuanqiCut.xcworkspace
    -scheme ChuanqiCutApp -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
risk:        podspec 的 Source 编译设置与 cmake 存在漂移面（版本宏、警告集）——
             缓解：版本宏由 podspec 从 s.version 注入；-Werror 门禁仍只在
             CMake 路径，pod 编译是调试便利不是门禁，此差异显式文档化
parallel:    false   # 与 GFX/MEDIA 系列共享 core 编译产物，且触碰高冲突目录结构
```

## 背景

- SPM 依赖图与 CocoaPods 互不相通：podspec 声明不了 SPM 包，Package.swift
  声明不了 pod。SharedUI 依赖 ChuanqiCut 绑定层，一旦 App 改走 pod 引 SDK，
  SharedUI 必须 pod 化，否则 Swift 绑定源码被两边各编一次 → 重复符号。
- UIA-002 交付的是**单工程双 target**（apps/apple/project.yml）。要"iOS 与
  macOS 单独维护 Podfile"，必须拆成两个独立工程（一个 Podfile 绑一个工程，
  CocoaPods 不支持一个工程挂两套互不相干的 Podfile 集成）。
- 现阶段内核快速演进，调试价值 > 构建速度；Source 模式还免除了
  「先 build_core_apple.sh + prepare.sh 才能开 App」的前置步骤。

## 实现要点

1. **pod 模块结构**（对齐 SPM 的 target 划分，同一份源码两种消费方式）：
   - 单 podspec 内 Swift 绑定源码要 `import CChuanqiCut`，而 CocoaPods 一个
     target 只能一个 module。实证（apps/apple/Pods 2026-09-30 残留）：直接设
     `s.module_map` 会让 pod 的 module 变成 CChuanqiCut，App 的
     `import ChuanqiCut` 断裂。
   - 解法：**不设** `s.module_map`（让 CocoaPods 生成名为 ChuanqiCut 的 pod
     module），改在 `pod_target_xcconfig.SWIFT_INCLUDE_PATHS` 指向
     bindings/swift/Sources/CChuanqiCut/include/（现有 module.modulemap +
     cq_sdk.h 符号链接，与 SPM 共用同一份文件）→ Swift 编译期可见独立 C
     module，App 侧照常 `import ChuanqiCut`。
2. **Source 默认**：`default_subspecs = 'Source'`；Podfile 显式写
   `pod 'ChuanqiCut/Source'`。Binary subspec 保留（发布期用）。
3. **版本宏**：cq_sdk.cpp 裸用 CQ_VERSION_MAJOR/MINOR/PATCH（CMake 注入）。
   Source subspec 必须 `GCC_PREPROCESSOR_DEFINITIONS` 注入，值从 s.version
   派生，避免与 CMake 漂移。
4. **双工程**：apps/apple/{ios,mac}/ 各含 project.yml（xcodegen 单 target）、
   Podfile、Gemfile(+lock)。SharedUI 留在 apps/apple/packages/SharedUI，
   两个 Podfile 都以 `:path` 引用。
5. **SharedUI 双定义**：podspec 是 App 集成真源；Package.swift 保留仅作
   `swift test` 测试宿主（UIA-002 验收测试），不进 App 依赖链。漂移风险
   显式写在两个文件头注释。
6. **工程再生成流程**（clone 后 / project.yml 变更后）：
   `xcodegen generate && bundle install && bundle exec pod install`，
   打开生成的 .xcworkspace（不是 .xcodeproj）。

## 验收

对应 acceptance 逐条：前两条由 `pod install` 输出证明（Analyzing
dependencies / Pod installation complete，且无 xcframework 前置）；第三、四条
由 xcodebuild `** BUILD SUCCEEDED **` 证明；第五条由 `git status` 显示
iOSApp/MacApp 为 rename（内容未改）证明。

## 回写

- `.ai/modules/ui-apple.md`：工程结构、依赖链、验证命令更新 ✅
- `docs/COCOAPODS.md`：分工、目录、模式默认值、验证状态更新 ✅
- `.ai/memory/pitfalls.md`：P9~P13 新增（hmap 基名劫持 / module_map 覆盖 /
  消费方 module 可见性 / Gemfile.lock 必须入库 / iOS 分支首次编译暴露）✅
- baselines：无实测性能数据，不涉及

## 验证记录（2026-10-02 实测）

| 验证项 | 命令 | 结果 |
|---|---|---|
| 语法 | `ruby -c` 两份 podspec / 双 Podfile / Gemfile | 全部 Syntax OK |
| 工具链 | `bundle install`（ios、mac，lock 起始自 HEAD 恢复的已知良品） | Bundle complete，CocoaPods 1.17.0 |
| 集成 | `bundle exec pod install`（ios、mac） | 均成功，2 pods，Source 模式 |
| macOS 编译 | `xcodebuild build -workspace …ChuanqiCutMacApp -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | **BUILD SUCCEEDED**（首跑曾失败：P9 hmap 劫持 / P10 module_map / P11 消费方可见性，逐一修复） |
| macOS 运行冒烟 | 启动产物二进制 4s 存活检查 | PASS（内核 Session 创建成功） |
| iOS 编译 | `-sdk iphoneos18.4` 四目标（ChuanqiCut / SharedUI / Pods-ChuanqiCutApp / ChuanqiCutApp） | **全链 BUILD SUCCEEDED**；destination 模式被"iOS platform runtime 未安装"挡住（`xcodebuild -downloadPlatform iOS` 本机网络受限，未完成，非本任务阻塞项） |
| SPM 测试宿主 | `cd packages/SharedUI && swift test --disable-sandbox` | 4/4 passed（验证保留 Package.swift 未破坏测试路径） |
| 跳过项 | `pod lib lint` | 未跑（双 :path podspec 需 --include-podspecs；App 真编译已覆盖同等编译面） |

**附带修复**（写集内）：`SharedUI/Editor/EditorLayout.swift` iOS 分支加
`@ViewBuilder`（UIA-002 遗留潜伏 bug，首次 iOS 编译暴露，pitfalls P13）。

**遗留风险**：
1. Source subspec 与 CMake 的警告集漂移（-Werror 只在 CMake 门禁）——已文档化。
2. FFmpeg 接入后 Source subspec 需补 prebuilt 链接（COCOAPODS.md §6）。
3. iOS platform runtime 包未装齐，真机 destination 构建与运行待网络恢复后
   `xcodebuild -downloadPlatform iOS` 补齐。
