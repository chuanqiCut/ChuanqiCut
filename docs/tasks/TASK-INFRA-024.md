# TASK-INFRA-024：Engine 源码按功能共置 + C/Swift 双 Pod 拆分

```yaml
id:          TASK-INFRA-024
layer:       基建 / Engine
status:      in_progress
goal:        撤销把 Engine 头文件硬挂进主工程/Pods 导航器的补丁式方案；内核头与实现按功能共置；仅公开 C ABI 头；Swift 适配独立 Pod spec
input:       [传哲 2026-10-09 反馈, TASK-INFRA-021/022, ADR-0033]
output:      [engine/core/cq/**, engine/platform/apple/{base,gfx,media}/**, CChuanqiCut.podspec, ChuanqiCutEngine.podspec]
deps:        [INFRA-022]
parallel:    false
```

## 写集

- 目录迁移：`engine/core/{include/cq,src}/**` → `engine/core/cq/**`；`engine/platform/apple/**` 按 `base/gfx/media` 分组。
- 构建：`engine/core/CMakeLists.txt`、`engine/platform/apple/CMakeLists.txt`、`tests/CMakeLists.txt`、`tools/build/build_core_apple.sh`、Swift C shim 头链接。
- CocoaPods：新增 `engine/CChuanqiCut.podspec`；重写 `engine/ChuanqiCutEngine.podspec` 为 Swift-only adapter；双 Podfile、依赖 Engine 的功能 podspec、`apps/apple/pods_post_install.rb`、双 `project.yml`。
- 规则/文档：`ADR-0033`、`docs/COCOAPODS.md`、`.ai/source/AGENTS.root.md` 及生成产物、相关模块册/交接/坑点/日志。

## 验收

1. `engine/core/cq/<功能>/` 内 `.h/.cpp` 共置；Apple Platform 按 `base/gfx/media` 共置。
2. `CChuanqiCut` Pod 只公开 `engine/core/cq/cq_sdk.h`；其余 C++/Apple 头均为 private，但与实现同组可浏览。
3. `ChuanqiCutEngine` Pod 只编 Swift binding，并依赖 `CChuanqiCut`；删除手工 `SWIFT_INCLUDE_PATHS` 传播链。
4. 主工程不再引用 `engine/core/include`；post_install 不再给 Pods 工程补头文件。
5. CMake core 相关测试通过；CocoaPods install 后生成模块拓扑为 `CChuanqiCut -> ChuanqiCutEngine -> UI Pods`。
6. 全量门禁、真机按传哲约定另行确认后执行。

## 进度 1（2026-10-09 完成编码 + 模块级验证）

| 子步骤 | 状态 | 证据 |
|---|---|---|
| 内核头/实现按功能共置 `engine/core/cq/**` | ✅ | `git mv` 全量迁移；`engine/core/CMakeLists.txt` 源路径全改 `cq/**`，include root 改 `core` |
| Apple Platform 按 `base/gfx/media` 共置 | ✅ | `engine/platform/apple/CMakeLists.txt` 源路径与三个 include dir 同步 |
| 测试/CMake/脚本路径重定基 | ✅ | `tests/CMakeLists.txt`（`engine/core`、`engine/core/cq`、`engine/platform/apple`）、`tools/platform/check_platform_headers.py`、`tools/build/build_core_apple.sh` |
| XCFramework 只打包 public 头 | ✅ | `build_core_apple.sh` 新增 `build/apple/public-headers`，只拷 `core/cq/cq_sdk.h`；`smoke_link.cpp` 改用 C ABI（输出 `ChuanqiCut version = 0.1.0`） |
| 拆 `CChuanqiCut` / `ChuanqiCutEngine` | ✅ | 两份 podspec；双 Podfile 显式 `:path`；UI Pod 去掉手工 `SWIFT_INCLUDE_PATHS` |
| 撤掉三处补丁 | ✅ | 删 `apps/apple/pods_post_install.rb`；双 `project.yml` 去掉 `engine/core/include` folder reference |
| 规则真源同步 | ✅ | `AGENTS.root.md` 红线 7 + 两个 tpl；`sync_context.py` 重生成 5 份产物；`docs/COCOAPODS.md` 重写 |
| CMake Debug 全量 ctest | ✅ **46/46**（机器 macOS 26.7.1 / AppleClang 21 / Swift 6.3.3） | `ctest --test-dir build/core-check` |
| Camera `swift test` | ✅ **62/62**（新增 5 例） | MultiCam format 选择器回归 |
| 双壳 `pod install` + App 构建 | ✅ **双绿** | iOS `-scheme ChuanqiCutApp -sdk iphoneos -destination 'generic/platform=iOS'` BUILD SUCCEEDED；macOS `-scheme ChuanqiCutMacApp -arch x86_64` BUILD SUCCEEDED（不加 `-arch` 会挂，P96：Intel universal + SDK 26.5 缺 arm64 预编译模块，与本次改动无关） |
| Pod 头边界实测 | ✅ | 双壳 `Pods/Headers/Public/CChuanqiCut` 均只有 `cq_sdk.h`（+ umbrella/modulemap），其余按功能落在 Private |
| 遗留警告 | ⚠️ 无害 | `Skipping duplicate build file in Copy Headers build phase`（P97：`core/cq/gfx/gfx.h` 与 `core/cq/platform/gfx.h` 同名；两文件在 Private 下各落其位，不影响编译）。**不要为消它改 podspec/改名** |

### 收尾补记（2026-10-09 晚）

- 壳工程里那个「engine 头文件文件夹」溯源到 **c49a16b（2026-10-07，INFRA-022）**：
  为响应当时「头文件在工程看不到」加的 `type: folder` + `buildPhase: none` 浏览补丁。
  ADR-0033 迁走 `engine/core/include` 后它变成悬空引用；已从双 `project.yml` 删除并
  `xcodegen generate` 重生成（两个 pbxproj 中 `engine/core` 残留均为 0）。
- `CChuanqiCut.podspec` 去掉显式 `private_header_files`（非 public 头默认即 private，
  与 `source_files` 重复声明无收益）。
- **注意顺序**：改 `project.yml` 后必须 `xcodegen generate` **再** `pod install`——
  xcodegen 会覆盖 Pods 往 `.xcodeproj` 注入的集成（本轮第一次就踩了这个顺序）。

## 风险

- 大规模路径迁移必须同步 CMake、测试、脚本、modulemap 符号链接；残留旧路径会产生假绿或发布包漏头。
- 两个本地 podspec 同目录时，Podfile 必须显式声明 `CChuanqiCut` 的 `:path`，否则传递依赖会去 spec repo 解析。
