# ADR-0037 — 壳工程冻结入库，退役 XcodeGen

> 状态：已采纳（2026-10-11，传哲拍板）
> 关联：ADR-0031（壳工程七 Pod）、ADR-0014（iOS 原生不经 Platform/C ABI）、
> COCOAPODS.md §4、pitfalls P12/P85/P96

## 背景

壳工程链路原为三步生成三明治：`project.yml`（XcodeGen 规格）→ `xcodegen generate`
（产出 .xcodeproj/.xcworkspace，不入库）→ `bundle exec pod install`（注入七 Pod 集成）。

两个实际问题：

1. **顺序坑（2026-10-09 实测踩过）**：`xcodegen generate` 会覆盖 CocoaPods 注入到
   .xcodeproj 的集成（xcconfig / [CP] build phases）；先 pod install 再 xcodegen =
   集成被抹掉，构建必挂。
2. **可视化改动不保存（传哲 2026-10-11 提出为主要痛点）**：工程是生成产物——在 Xcode
   里改 target 配置、Info.plist、加 capability，下次 `xcodegen generate` 全部冲掉；
   Info.plist 的 properties 也由 project.yml 生成，不存手工副本。

## 决策

1. **冻结生成物为手工源文件**：`apps/apple/{ios,mac}/ChuanqiCut.xcodeproj` 与
   `.xcworkspace` 提交入库，成为壳工程的**唯一真源**。Xcode 可视化改动即生效、
   即提交，不再有任何重新生成步骤。
2. **退役 XcodeGen**：删除两份 `project.yml`；`.gitignore` 相应排除规则移除；
   禁止任何工具重新生成/覆盖该工程。
3. **CocoaPods 职责不变**：仍是唯一的依赖管理器。链路收敛为
   `clone → bundle install（首次）→ bundle exec pod install → open .xcworkspace`。
4. 既有资产原样随工程入库：metallib CIKernel 编译脚本阶段（-fcikernel 两阶段纪律，
   ADR-0021/0031 案底，`basedOnDependencyAnalysis=false`）、双端共享 scheme
   （INFRA-018 假成功案底的修复）、Gemfile.lock（P12）。
5. `xcuserdata/` 沿用全局 ignore（用户界面状态不入库）；`Pods/` 仍由 pod install
   生成、不入库。

## 后果

**得**：

- 顺序坑结构性消失（会改工程的命令只剩 pod install 一个）；少一个外部工具。
- 传哲可在 Xcode 直接可视化维护壳工程（原需求）；Info.plist 回归普通文件。
- 多 agent 场景不再需要记忆/执行两步顺序——该类事故（2026-10-09）不可复发。

**失 / 新增注意**：

- pbxproj 成为手工维护的合并面（高冲突文件，归集成机单写——与既有分工一致）。
- 「YAML 即真相」的可复现性降为「pbxproj 即真相」：工程损坏时无生成物可重跑，
  只能靠 git 历史回滚。
- **podspec 增删源文件后必须重跑 pod install**（此规则不变且更关键——2026-10-11
  实踩：旧 Pods 清单编已不存在的 `pal_frame_provider.cpp`，iOS 壳构建红）。

## 验证（冻结当日的构建证据，2026-10-11，Intel macOS 26.7 / Xcode 26.6）

- macOS：`xcodebuild -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutMacApp
  -arch x86_64 ONLY_ACTIVE_ARCH=YES` → **BUILD SUCCEEDED**（P96 口径）。
- iOS：`xcodebuild -scheme ChuanqiCutApp -destination 'generic/platform=iphoneos'`
  → **BUILD SUCCEEDED**（先 pod install 刷新过期 Pods 清单后）。
- metallib 产物：beauty_bilateral.metallib **9391B**（kernel：cq_beauty_down_h /
  cq_beauty_up_v_mix）、face_warp.metallib **7123B**（cq_face_warp）——非 96B 空壳。
- 工程可移植性：pbxproj / contents.xcworkspacedata 零绝对路径。

## 附录（2026-10-11 下午）：agent 友好性两台阶（传哲拍板「台阶 1+2」）

冻结后剩余的 agent 不友好面 = app target 构建设置 / build phase / 新 target / app 内加文件
（历史全部低频；Pod 源文件与 Info.plist 本就 agent 友好）。两台阶落地：

1. **台阶 1 — agent 结构化编辑通道**：`tools/build/edit_project.rb`（xcodeproj gem 1.28.1，
   与 pod install 同库，round-trip 安全）。**规则：agent 禁止裸编 project.pbxproj 文本，
   结构化改动一律走脚本**（COCOAPODS.md §4）。
2. **台阶 2 — app 目标升级 synchronized groups（buildable folders）**：iOSApp/ 与 MacApp/
   转为 `PBXFileSystemSynchronizedRootGroup`（工程本就 objectVersion 77），**app 内加/删
   文件 = 纯文件系统操作，零工程改动**（已实测：新增 Swift 文件未动工程即编译出 .o）。
   pbxproj 缩至仅剩构建设置 + metallib 脚本阶段 + plist 例外。

### 台阶 2 踩坑（P107）

- **`sourceTree` 大小写敏感**：`"<Group>"`（大写 G）让同步组解析失败 → Sources 零文件 →
  `_main` undefined 链接失败；必须 `"<group>"`（全工程既定 casing）。
- **Info.plist 必须加成员例外**：同步组会自动把目录内 Info.plist 收进资源 →
  `Multiple commands produce ...Info.plist`；用 `PBXFileSystemSynchronizedBuildFileExceptionSet
  { target, membershipExceptions = [Info.plist] }` 排除（双端都已设）。

### 验证（台阶 2 落地当日，全绿）

- macOS：`xcodebuild -arch x86_64 ONLY_ACTIVE_ARCH=YES` → **BUILD SUCCEEDED**。
- iOS：`-destination 'generic/platform=iphoneos'` → **BUILD SUCCEEDED**；
  metallib 双产物 9391B/7123B 不回归。
- **加文件冒烟**：iOSApp/ 新增 Swift 文件、零工程改动 → 自动编译出 AgentSyncProbe.o，
  BUILD SUCCEEDED（探针已删）。
- pbxproj 净变化 ±50 行/端（同步组替换 per-file 引用）。
