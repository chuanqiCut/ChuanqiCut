# CocoaPods 集成（Engine 层）与 App 依赖策略

> 建立日期：2026-09-30；重构：2026-10-02（INFRA-009）、**2026-10-09（INFRA-024 / ADR-0033：拆 CChuanqiCut + ChuanqiCutEngine）**
> 范围：`engine/CChuanqiCut.podspec`、`engine/ChuanqiCutEngine.podspec`、
> `apps/apple/packages/*/*.podspec`、`apps/apple/{ios,mac}/` 双工程。

## 1. 现行拓扑（ADR-0033 起）

```
engine/                              ← pod 根（两个本地 spec 同目录）
├── CChuanqiCut.podspec              ← C ABI + C++20 内核 + Apple Platform（唯一 public 头 core/cq/cq_sdk.h）
├── ChuanqiCutEngine.podspec         ← Swift 适配层（依赖 CChuanqiCut）
├── core/cq/<功能>/                  ← 内部 C++ 头与实现共置（base/audio/command/gfx/media/model/platform/preview/session/ai）
├── platform/apple/{base,gfx,media}/      ← Apple 私有头与实现共置（shader 随 gfx）
└── bindings/swift/                  ← SPM 测试宿主（App 不使用 SPM）
```

依赖链：

```
App → ChuanqiCutEngine (Swift) → CChuanqiCut (C ABI module) → 系统框架
App → SharedUI / 功能 Pod → ChuanqiCutEngine
```

两条硬规矩：

- 两个本地 spec 必须都在 Podfile 里显式给 `:path`，否则 CocoaPods 会为传递依赖
  去远端 spec repo 找 `CChuanqiCut`（:path 目录里存在同名 podspec 不代表会用它）。
- 同一份源码不要既引 pod 又引 SPM（重复符号）。SPM 只作 `swift test` 宿主。

## 2. 头文件可见性（不再靠补丁）

| 层 | 如何可见 |
|---|---|
| Swift / App | `import ChuanqiCutEngine`，经正常 Pod 依赖解析 |
| Engine public C ABI | `CChuanqiCut` Pod 的 `public_header_files = core/cq/cq_sdk.h` |
| Engine 内部 C++/Apple 头 | 与实现同目录，在 `CChuanqiCut` Pod 内编译并可浏览，**不进 module umbrella、不进主工程** |

已删除的三处补丁（ADR-0033 起因）：

1. 主工程 `project.yml` 的 `engine/core/include` folder reference；
2. `apps/apple/pods_post_install.rb` 往 Pods 工程补 PBX 头文件引用；
3. 各 UI Pod 手工传播 `SWIFT_INCLUDE_PATHS`。

⚠️ 仍有效的老禁令：**禁止新增与系统头同名的头文件**（headermap 按基名映射，重名会顶掉
系统 `<time.h>` 级联崩；7 个历史重名头已改名）。

## 3. 编译设置

`CChuanqiCut` 现场编译 C++20 内核与 ObjC++ Platform，设置在 podspec 内手工重建
（不经 CMake）：C++20 / 禁异常 / 禁 RTTI / 系统框架列表（IOSurface 仅 macOS）/
版本宏 `CQ_VERSION_*` 从 `s.version` 注入。

**门禁只在 CMake 路径**（-Werror 警告集不进 pod 编译）；漂移时以
`cmake/CompileOptions.cmake` 为准，回来同步 podspec。

XCFramework 分发（SPM 宿主用）：

```bash
tools/build/build_core_apple.sh --config=Release   # 只把 cq_sdk.h 打进 Headers
engine/bindings/swift/prepare.sh
```

## 4. 环境与日常工作流

```bash
cd apps/apple/ios
xcodegen generate
bundle install
bundle exec pod install      # 变更 podspec/Podfile 后必须跑：Pods.xcodeproj 是文件清单快照
open ChuanqiCut.xcworkspace
```

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
| License | 两份 spec 均为 `Proprietary` 占位；FFmpeg LGPL 静态链接处置未定 | owner + 法务（ADR-0010） |
| `s.homepage` / `s.source` | 无 git remote，`REPLACE_ME.invalid` 占位（`CQ_POD_SOURCE_GIT` lint 逃生口） | owner |
| XCFramework 分发 | 产物不入库，需 CI 生成后随 pod 发布 | 依赖治理（ADR-0008） |
