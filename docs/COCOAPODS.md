# CocoaPods 集成（SDK 层）与 App 依赖策略

> 建立日期：2026-09-30；**重构日期：2026-10-02（INFRA-009，owner 决策落地）**
> 范围：`ChuanqiCut.podspec`、`apps/apple/packages/SharedUI/SharedUI.podspec`、
> `apps/apple/{ios,mac}/` 双工程（Podfile + Gemfile 各自独立）。

## 1. 现行架构（INFRA-009 起）

**Owner 决策（2026-10-02）**：iOS 与 macOS 项目单独维护 Gemfile + Podfile；
SDK 默认**源码导入**（便于调试和分析问题）；SPM 无法依赖 pod，Swift 代码
（SharedUI）一并 podspec 化。

```
仓库根
├── ChuanqiCut.podspec                  # SDK 层：C++20 内核 + ObjC++ PAL + Swift 绑定
└── apps/apple/
    ├── packages/SharedUI/
    │   ├── SharedUI.podspec            # SwiftUI 编辑器组件（App 集成真源）
    │   └── Package.swift               # 仅保留作 swift test 测试宿主，不在 App 依赖链
    ├── ios/                            # iOS 独立工程
    │   ├── project.yml                 # xcodegen（单 target ChuanqiCutApp）
    │   ├── Podfile / Gemfile(.lock)    # 本目录独立维护
    │   └── iOSApp/
    └── mac/                            # macOS 独立工程
        ├── project.yml                 # xcodegen（单 target ChuanqiCutMacApp）
        ├── Podfile / Gemfile(.lock)    # 本目录独立维护
        └── MacApp/
```

依赖链：`App → SharedUI (pod) → ChuanqiCut (pod) → CChuanqiCut (clang module)`
App **不使用 SPM**；`bindings/swift/Package.swift` 仅作绑定层 `swift test`
测试宿主。

**硬规矩**：ChuanqiCut 不要同时在 pod 与 SPM 两侧引入——同一份 Swift 绑定
源码被各编一次会重复符号。

## 2. 两种集成模式（subspec）

```ruby
pod 'ChuanqiCutEngine/Source', :path => '../../..'   # 源码模式（**默认**；pod 名 2026-10-07 起带 Engine 后缀）
pod 'ChuanqiCutEngine/Binary', :path => '../../..'   # 二进制模式（发布期/提速）
```

| subspec | 内容 | 适用场景 |
|---|---|---|
| `Source`（默认） | 现场编译 `core/src/**/*.cpp` + `pal/apple/**/*.mm` + Swift 绑定 | 日常开发、调试内核、分析问题；**无 xcframework 前置** |
| `Binary` | `bindings/swift/Frameworks/ChuanqiCut.xcframework` + Swift 绑定 | 发布期；不编译 C++ |

Source 模式的编译设置在 podspec 内**手工重建**（不经 CMake）：
- C++20 / 禁异常 / 禁 RTTI / 系统框架列表（IOSurface 仅 macOS）
- 版本宏 `CQ_VERSION_*` 从 `s.version` 注入（cq_sdk.cpp 裸用，正常由 CMake
  注入；两处以 podspec 派生保持一致）
- **门禁仍只在 CMake 路径**：-Werror 警告集不进 pod 编译，pod 构建是调试
  便利不是门禁。漂移时以 `cmake/CompileOptions.cmake` 为准，回来同步 podspec。

Binary 模式前置（需要分发产物时）：
```bash
tools/build/build_core_apple.sh --config=Release
bindings/swift/prepare.sh     # 把 xcframework 拷到 bindings/swift/Frameworks/
```

## 3. Swift 绑定的 C module（CChuanqiCut）如何暴露

一个 pod target 只能有一个 module；pod 自身的 module 由 CocoaPods 生成
（名 `ChuanqiCut`），**不要**设 `s.module_map`（会整体替换，见 pitfalls P10）。
CChuanqiCut clang module 靠三处 `SWIFT_INCLUDE_PATHS` 指向与 SPM 共用的
`bindings/swift/Sources/CChuanqiCut/include/`（module.modulemap + cq_sdk.h
符号链接，零复制）：

| 谁 | 在哪声明 |
|---|---|
| ChuanqiCut pod 自身编译 | `ChuanqiCut.podspec` `pod_target_xcconfig` |
| App target（ios/mac） | `ChuanqiCut.podspec` `user_target_xcconfig` |
| pod 消费方（SharedUI） | `SharedUI.podspec` `pod_target_xcconfig` |

另两条实测红线（详见 pitfalls P9/P11）：
- **头文件一律不声明**进 podspec 文件集——headermap 按基名映射会让
  `time.h` 劫持系统 `<time.h>`；C++ 头靠 `-I` 搜索路径即可。
- SDK 的 Swift 公开 API 触及 CChuanqiCut 类型时，消费方必须能看到该 module。

## 4. 环境与日常工作流

```bash
# clone 后 / project.yml 或 Podfile 变更后（在 ios/ 或 mac/ 下）：
cd apps/apple/ios
xcodegen generate            # 生成 ChuanqiCut.xcodeproj（~/tools/xcodegen/bin/xcodegen）
bundle install               # 按 Gemfile.lock 装工具链（CocoaPods 版本钉死）
bundle exec pod install      # 生成 ChuanqiCut.xcworkspace 并集成
open ChuanqiCut.xcworkspace  # ⚠️ 开 workspace，不是 xcodeproj
```

- Ruby 工具链：本机 `~/.rubies/ruby-3.4.11`（源码编译安装，见
  ios-dev-setup skill）。**Gemfile.lock 必须入库**——无 lock 时 bundler 会
  解析到不兼容的 CFPropertyList 3.0.9（pitfalls P12）。
- gem 源用清华镜像（本机直连 rubygems.org 502），网络可直连可改回官方源。
- 历史（2026-09-30，当时 CocoaPods 装不上）：系统 Ruby 2.6 过老（ffi 要
  ≥3.0）+ `~/.gem` 路径权限问题叠加；Intel Mac 无 Homebrew bottles。
  Ruby 3.4 源码编译到 `~/.rubies` 后解决。教训：`Operation not permitted`
  先换路径做对照实验，不要直接断言"环境不支持"。

## 5. 验证状态

| 项 | 状态 |
|---|---|
| `ruby -c` 两份 podspec + 双 Podfile + Gemfile | ✅ 语法通过 |
| `bundle install`（ios / mac） | ✅ CocoaPods 1.17.0 |
| `pod install`（ios / mac） | ✅ 2 pods（Source 模式，现场编译内核） |
| macOS App 全量编译 | ✅ `xcodebuild -workspace … ChuanqiCutMacApp` BUILD SUCCEEDED（2026-10-02，含 core 17 cpp + pal 6 mm + Swift 绑定 + SharedUI）；4s 启动冒烟存活（内核 Session 初始化成功） |
| iOS App 编译 | ✅ BUILD SUCCEEDED（2026-10-02，arm64 `-sdk iphoneos18.4 CODE_SIGNING_ALLOWED=NO`，ChuanqiCut + SharedUI + Pods-ChuanqiCutApp + App 四目标全链编译链接；destination 模式需 `xcodebuild -downloadPlatform iOS` 补装 runtime 包，本机网络受限未完成）。顺带修复 UIA-002 遗留：EditorLayout iOS 分支 opaque 类型不匹配（pitfalls P13） |
| `pod lib lint` | ⬜ 未做——双 podspec 有 `:path` 互相依赖，lint 需 `--include-podspecs`；App 真编译已覆盖同等路径，lint 补做见 TASK-INFRA-009 验收外项 |
| SharedUI `swift test`（SPM 宿主） | ⬜ 依赖 xcframework 构建产物，本任务未重跑（测试代码未动） |

## 6. 待定项（发布前必须落实，与 2026-09-30 版一致）

| 项 | 现状 | 谁拍板 |
|---|---|---|
| **License** | 两份 podspec 均为 `Proprietary` 占位；FFmpeg LGPL 静态链接处置未定 | owner + 法务（ADR-0010） |
| `s.homepage` / `s.source` | 无 git remote，`REPLACE_ME.invalid` 占位（提供 `CQ_POD_SOURCE_GIT` lint 逃生口） | owner |
| XCFramework 分发 | 产物不入库，需 CI 生成后随 pod 发布 | 依赖治理（ADR-0008） |
| Source subspec 接入 FFmpeg | core 尚未引用 FFmpeg 符号；demux 落地时 Source subspec 需补 prebuilt 库链接 | MEDIA 系列任务 |


---

## 附：Pods 导航器（docs 混入 / 头文件不可见）—— 2026-10-07 定案（目录重构后修订）

**现象**：Pods 工程 ChuanqiCutEngine 组下，docs/** 全树被挂进来（182 条）而 core 头文件一条没有。

**机制（源码实证，CocoaPods 1.17.0）**：
1. docs 混入 = 本地 pod 的「开发辅助」特性（`add_developer_files` → docs glob `doc{s}{*,.*}/**/*`，
   相对 **pod 根**）。设计假设 pod 根 = 独立库目录。
2. 头文件不可见 = 1.17 对 `private_header_files` 只写编译阶段、不生成导航条目；公开声明则
   C++ 头被卷进自动生成的 umbrella Clang module → ObjC 上下文编 `<cstddef>` → 级联崩。

**解决（两层）**：
1. **目录重构（INFRA-022，根治）**：core/pal/bindings 收拢 `engine/`，pod 根 = `engine/`——
   docs/apps/tools 天然在 pod 根之外，docs 探测从此扫不到东西。
2. **post_install 钩子**（`apps/apple/pods_post_install.rb`，双 Podfile 共享）：1.17 对
   private 头不生成导航条目，钩子补 `core/include` 头文件树（42 条，只读浏览不参与编译）；
   docs 删除段保留作兜底（重构后应为 0 条）。

**前置与禁令**：与系统头重名的 7 个头已改名（rational_time/logging/pal_log/pal_clock/
pal_common/media_cache/session_snapshot；137 文件 include 同步）——headermap 按基名映射
无视目录，重名会顶掉系统 `<time.h>` 级联崩（2026-10-02 案底）。**禁止新增与系统头同名
的头文件。**

**曾试并否决**：podspec 挪子目录（pod 根外源文件静默丢弃）；符号链接（Ruby glob 不穿）；
`exclude_files`（不作用于 developer_files）。
