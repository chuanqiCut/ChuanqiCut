# CocoaPods 集成（Engine 层）与 App 依赖策略

> 建立日期：2026-09-30；重构：2026-10-02（INFRA-009）、**2026-10-09（INFRA-024 / ADR-0033：拆 CChuanqiCut + ChuanqiCutEngine）；2026-10-11（ADR-0038：CChuanqiCut 更名 ChuanqiCutCore + FFmpeg 独立 Pod）**
> 范围：`engine/ChuanqiCutCore.podspec`、`engine/ChuanqiCutFFmpeg.podspec`、
> `api/swift/ChuanqiCutEngine.podspec`、`ui/*/*.podspec`、`apps/apple/{ios,mac}/` 双工程。
> 目录三次搬家（INFRA-031 `apps/apple/packages` → 顶层 `ui/`；INFRA-032 `engine/bindings/swift`
> → `api/swift/`；INFRA-033 `shaders/src` → `engine/shaders/portable`）后的现状由本文件描述，
> 布局契约见 `docs/decisions/ADR-0044*`。

## 1. 现行拓扑（ADR-0033 起）

```
engine/                              ← pod 根（Core + FFmpeg 两份本地 spec 同目录）
├── ChuanqiCutCore.podspec              ← C ABI + C++20 内核 + Apple Platform（唯一 public 头 core/cq/cq_sdk.h）
├── ChuanqiCutFFmpeg.podspec         ← FFmpeg vendored 独立 Pod（LGPL，ADR-0038）
├── core/cq/<功能>/                  ← 内部 C++ 头与实现共置（base/audio/command/gfx/media/model/platform/preview/session/ai）
├── platform/apple/{base,gfx,media}/      ← Apple 私有头与实现共置（shader 随 gfx）
└── shaders/{portable,native}/       ← Portable GLSL 基线 + 平台特化预留（INFRA-033；生成产物落 build/，不入库）

api/swift/                           ← pod 根（INFRA-032 自 engine/bindings/swift 外提；SPM package 根 = 同目录）
├── ChuanqiCutEngine.podspec         ← Swift 适配层（依赖 ChuanqiCutCore）
├── Sources/ChuanqiCut/              ← 门面 Swift（8 个文件）
├── Sources/ChuanqiCutCore/          ← C target：cq_sdk.h 是指向 engine/core/cq/cq_sdk.h 的相对符号链接
└── Frameworks/ChuanqiCut.xcframework ← SPM binaryTarget 用；prepare.sh 从 build/apple/ **复制**（产物，不入库）

ui/<Module>/                         ← 6 个功能 Pod（SharedUI + Editor/Player/Import/Camera/Draft）

# ⚠️ Core 与 FFmpeg 的 pod 根**必须**留在 engine/：`vendored_frameworks` / 头文件路径按
#    pod 根相对解析，且 Engine 的 pod 根已外提 —— 再动就是 ADR-0044 决策 4 的范围。
```

依赖链：

```
App → ChuanqiCutEngine (Swift) → ChuanqiCutCore (C ABI module) → 系统框架
                                                  └→ ChuanqiCutFFmpeg (vendored, LGPL)
App → SharedUI / 功能 Pod → ChuanqiCutEngine
```

两条硬规矩：

- 两个本地 spec 必须都在 Podfile 里显式给 `:path`，否则 CocoaPods 会为传递依赖
  去远端 spec repo 找 `ChuanqiCutCore`（:path 目录里存在同名 podspec 不代表会用它；
  现在 spec 分居 `engine/`（Core、FFmpeg）与 `api/swift/`（Engine）两处，Pod 按名匹配）。
- 同一份源码不要既引 pod 又引 SPM（重复符号）。SPM 只作 `swift test` 宿主。

## 2. 头文件可见性（不再靠补丁）

| 层 | 如何可见 |
|---|---|
| Swift / App | `import ChuanqiCutEngine`，经正常 Pod 依赖解析 |
| Engine public C ABI | `ChuanqiCutCore` Pod 的 `public_header_files = core/cq/cq_sdk.h` |
| Engine 内部 C++/Apple 头 | 与实现同目录，在 `ChuanqiCutCore` Pod 内编译并可浏览，**不进 module umbrella、不进主工程** |

已删除的三处补丁（ADR-0033 起因）：

1. 主工程 `project.yml` 的 `engine/core/include` folder reference（旧布局，ADR-0033 前；现无该目录，头与实现共置于 `engine/core/cq/`）；
2. `apps/apple/pods_post_install.rb` 往 Pods 工程补 PBX 头文件引用；
3. 各 UI Pod 手工传播 `SWIFT_INCLUDE_PATHS`。

⚠️ 仍有效的老禁令：**禁止新增与系统头同名的头文件**（headermap 按基名映射，重名会顶掉
系统 `<time.h>` 级联崩；7 个历史重名头已改名）。

## 3. 编译设置

`ChuanqiCutCore` 现场编译 C++20 内核与 ObjC++ Platform，设置在 podspec 内手工重建
（不经 CMake）：C++20 / 禁异常 / 禁 RTTI / 系统框架列表（IOSurface 仅 macOS）/
版本宏 `CQ_VERSION_*` 从 `s.version` 注入。

**门禁只在 CMake 路径**（-Werror 警告集不进 pod 编译）；漂移时以
`cmake/CompileOptions.cmake` 为准，回来同步 podspec。

XCFramework 分发（SPM 宿主用）：

```bash
tools/build/build_core_apple.sh --config=Release   # 只把 cq_sdk.h 打进 Headers
api/swift/prepare.sh
```

## 4. 环境与日常工作流

**壳工程已冻结入库（ADR-0037，2026-10-11，XcodeGen 退役）**：`ChuanqiCut.xcodeproj` /
`.xcworkspace` 是手工源文件——Xcode 里可视化改的一切（target 配置、Info.plist、scheme、
build phase）**直接保存、直接提交**，不再有任何生成步骤会冲掉它。

```bash
cd apps/apple/ios            # 或 apps/apple/mac
bundle install               # 仅首次（Gemfile.lock 已入库钉住工具链）
bundle exec pod install      # clone 后 + 每次变更 podspec/Podfile 后必须跑
open ChuanqiCut.xcworkspace  # 注意开 workspace，不是 xcodeproj
```

- **podspec 增删源文件后必须重跑 pod install**：Pods.xcodeproj 是文件清单快照，
  旧清单会编已改名/已删除的文件（2026-10-11 实踩：旧清单编已不存在的
  `pal_frame_provider.cpp`，iOS 壳构建红；pod install 刷新即愈）。
- **app 目标源码已升级 synchronized groups（buildable folders，ADR-0037 台阶 2）**：
  **app 内加/删文件 = 纯文件系统操作**（放进 iOSApp/ 或 MacApp/ 即自动进编译，
  已实测），不需要动工程文件；Info.plist 已设成员例外（同目录不会误收进资源）。
- **Agent 通道（ADR-0037 台阶 1）**：禁止裸编 `project.pbxproj` 文本；结构化改动
  （构建设置 / 脚本阶段 / 文件引用）走 `tools/build/edit_project.rb`（xcodeproj gem，
  与 pod install 同库，round-trip 安全）。
- 禁止任何工具重新生成/覆盖 `ChuanqiCut.xcodeproj`——它不是产物，是真源。
- Ruby 工具链：本机 `~/.rubies/ruby-3.4.11`；**Gemfile.lock 必须入库**（无 lock 会解析到
  不兼容的 CFPropertyList 3.0.9，P12）。gem 源用清华镜像（直连 rubygems.org 502）。

## 5. 验证状态（2026-10-09 实测，机器 macOS 26.7.1 / Swift 6.3.3）

| 项 | 状态 |
|---|---|
| core CMake Debug 全量 ctest | ✅ 46/46（含 `platform_header_gate`） |
| `cq_core` + `cq_platform_apple` 构建 | ✅ 零错误 |
| ChuanqiCutCamera `swift test` | ✅ 62/62（新增 5 例 format 选择） |
| 双壳 `pod install` + `xcodebuild -scheme ChuanqiCutApp` | ⏳ **待跑**（按传哲约定先询问，属阶段批范围） |

## 6. 待定项（发布前必须落实）

| 项 | 现状 | 谁拍板 |
|---|---|---|
| License | 两份 spec 均为 `Proprietary` 占位；~~FFmpeg LGPL 静态链接处置未定~~ → 已定：ADR-0036（ARCH-002 §5.1 路径 1，App 内声明 + 源码可获得 + 可重链接归档，负责人 2026-10-11 确认）；vendored 义务载体 = `engine/NOTICE.md` | SDK 本体 License 仍待定 |
| `s.homepage` / `s.source` | 无 git remote，`REPLACE_ME.invalid` 占位（`CQ_POD_SOURCE_GIT` lint 逃生口） | owner |
| XCFramework 分发 | 产物不入库，需 CI 生成后随 pod 发布 | 依赖治理（ADR-0008） |
| FFmpeg 产物本地构建 | **首次 pod install 前必须跑** `tools/build/build_ffmpeg_demux.sh` 5 个 slice（产物 `*.a` 不入 git，P84；缺失时 podspec 直接报错并给出指引） | —— |
| SBOM / 公共头第三方符号扫描工具 | ARCH-002 §5.2 规划的 `tools/compliance/gen_sbom.py` / `scan_headers.py` **尚未实现**，现以 `tools/deps/deps.py check` + 手工 grep 代替（ADR-0036 登记） | 依赖治理 |

## 附注（2026-10-11，TASK-INFRA-025 收尾实测）：Pods 集成三件与聚合 target 位置

1. **CocoaPods 1.17 把聚合 target（`Pods-<App>`）放进 `Pods/Pods.xcodeproj`**，不在用户
   工程。用户工程必须有「远程依赖三件」：`containerPortal`（指向 Pods.xcodeproj 的
   PBXFileReference）+ `PBXContainerItemProxy` + `PBXTargetDependency`。缺件时
   `pod install` **静默 no-op 不报错**，构建图只剩 App（`Target dependency graph
   (1 target)`），Pods 永不构建——增量 DerivedData 有旧产物时表现为"假绿"（P85 家族，
   详见 pitfalls **P108**）。
2. 补件通道：`tools/build/edit_project.rb add-remote-dependency <project> <target>
   <remote_project> <remote_target>`（幂等，本次新增子命令；ADR-0037 通道扩展）。
   双壳已各补一条（MacApp→Pods-ChuanqiCutMacApp / App→Pods-ChuanqiCutApp）。
3. **pod 一律 `bundle exec pod`**（Podfile 头部既有规则，本次裸跑 `pod` 踩过一遍）。
4. pod install 后自查两条：`grep containerPortal ChuanqiCut.xcodeproj/project.pbxproj`
   应 ≥1；干净构建（清 DerivedData）才算验收口径。
5. mac 通用双架构构建当前被 CP 1.17 Swift Compatibility Header 共享路径坑
   （`unsupported Swift architecture`，池 [14]）；本地验证口径 = 单原生架构
   （`-destination 'platform=macOS,arch=x86_64' ARCHS=x86_64 ONLY_ACTIVE_ARCH=YES`）。

## 7. 功能 Pod 的第三方 UI 依赖（ADR-0041，2026-10-14）

`ChuanqiCutEditor`（UI 功能 Pod）是首个引入**第三方 UI 布局库**的功能 Pod：

- **依赖**：`s.ios.dependency 'SnapKit', '~> 5.7.0'`（**iOS 专属**；版本钉 `5.7.1`，MIT）。
- **作用域**：SnapKit 只被 `#if os(iOS)` 的 UIKit 布局代码 `import`；`ChuanqiCutEditor.podspec`
  用 `s.ios.dependency` 声明，**macOS 端不拉入**（mac 构建/测试完全不感知 SnapKit）。
- **为何不引 SPM**：`api/swift/Package.swift` 只是 macOS `swift test` 宿主，而本机 macOS SPM
  **整文件跳过 `#if os(iOS)`**（P129），引了也编不到；且 UIKit 改动的最小自证是两端壳构建，不是 SPM。
- **落地现状（2026-10-14）**：iOS 端 `bundle exec pod install` 已落地 SnapKit 5.7.1（两端 Podfile.lock
  钉死）；mac 端 mac 专属依赖不拉入、`pod install` 通过、壳构建 `BUILD SUCCEEDED`。
- **纪律**：今后给功能 Pod 加第三方依赖，必须先确认作用域（iOS / macOS / 双端），并在 Podfile.lock
  钉版本；podspec 变动后两端各跑一次 `bundle exec pod install`（P129 教训）。
