# ADR-0038 — 引擎 Pod 重命名与 FFmpeg 独立 Podspec（提案，待实施）

> 状态：**已采纳并实施**（2026-10-11，传哲「开干」指令 + 真机在场；DEPS-012 先收口 de5b625 解锁写集）
> 关联：ADR-0033（Engine 两 Pod 边界，本 ADR 修订其命名）、ADR-0036（FFmpeg vendored + LGPL 处置）、
> ADR-0034（批次纪律：上一批未验收不叠加）、TODO-POOL [11]（FFmpeg 真机验证项）

## 背景（传哲 2026-10-11 两条设计意见）

1. **`CChuanqiCut` 的 C 前缀不该有**——它不是「C 语言版」的意思，只是当年「C ABI Pod」的
   谜之前缀；应该叫 Engine 或 Core。
2. **FFmpeg 应该有独立的 podspec**——现在 FFmpeg 的 vendored xcframework、LGPL 声明、
   头文件搜索路径全部内联在 `CChuanqiCut.podspec` 里，内核 Pod 背着第三方细节。

## 决策

### 1. 重命名：`CChuanqiCut` → `ChuanqiCutCore`

- **不叫 Engine**：`ChuanqiCutEngine` 已是 Swift adapter Pod（ADR-0033 两层边界），撞名。
- **叫 Core**：与 SPM 侧既有 binaryTarget 名 `ChuanqiCutCore`（libChuanqiCut.a）对齐，
  一词双关「内核」。
- 纯包装层改名：ABI（函数符号）、头文件内容、版本号零变化。

改名清单（实施时逐项勾）：

| 项 | 文件 | 说明 |
|---|---|---|
| podspec 本体 | `engine/CChuanqiCut.podspec` → `engine/ChuanqiCutCore.podspec` | `s.name` + 文件名 |
| Swift 模块名 | `s.module_name = 'ChuanqiCutCore'` | Pod 名即模块名，随 Pod 改 |
| import 消费点 | `engine/bindings/swift/Sources/ChuanqiCut/*.swift`（8 处 `import CChuanqiCut`） | 机械替换 |
| SPM C target | `engine/bindings/swift/Sources/CChuanqiCut/` → `ChuanqiCutCore/` + module.modulemap + Package.swift target 名 | 与 Pod 模块名对齐 |
| Podfile | `apps/apple/{ios,mac}/Podfile` 各 1 行 | `pod 'ChuanqiCutCore', :path => '../../../engine'` |
| 工程集成 | `bundle exec pod install`（双端） | 冻结工程下唯一命令 |
| 文档/台账 | COCOAOPODS.md、BUILD.md、ADR-0033 附注、HANDOFF | 引用更新 |

### 2. FFmpeg 独立 Podspec：`ChuanqiCutFFmpeg`

- 新 `engine/ChuanqiCutFFmpeg.podspec`：vendored binary Pod——
  `vendored_libraries = third_party/prebuilt/ffmpeg/9.0.2/demux/libffmpeg.xcframework`、
  **`s.license = 'LGPL-2.1-or-later'`**（本 Pod 只装 FFmpeg，许可证如实声明，合规归属
  比现在「Proprietary Pod 背 LGPL 注释」更干净；义务载体仍为 NOTICE.md）、
  头文件搜索路径内聚在本 Pod。
- `ChuanqiCutCore.podspec` 回归**零第三方**：`s.dependency 'ChuanqiCutFFmpeg'`；
  `ffmpeg_probe.cpp` 的 include 路径改由依赖 Pod 的 Headers/Public 机制或消费端
  xcconfig 显式指向（实施时按 CocoaPods 1.17 实测定）。
- CMake 侧 `cq_ffmpeg` target（源码集成/ctest）**不动**——本 ADR 只动 CocoaPods 打包层。
- 门禁：`media_ffmpeg_probe`（ctest）与 Pod 侧探测冒烟（池 [11]）在重构后**合并验证一次**。

## 时序约束（硬）

`engine/CChuanqiCut.podspec`、`Podfile` ×2 正是 **DEPS-012 线的未提交写集**（vendored
接线 + NOTICE），且其真机验证（池 [11]）未跑。**现在动手 = 同文件对撞 + 验证作废重来**
（ADR-0034：一批未验收不得叠加）。

**实施时点**：DEPS-012 提交收敛后的第一批；其真机验证直接在新形状上跑（一次覆盖，
不做两遍）。实施后合并快检：`build_core.sh` + pod install 双端 + 双壳构建 + 契约单测。

## 后果

- 语义归位：`ChuanqiCutCore` = 内核（C ABI + C++ + Platform），`ChuanqiCutEngine` = Swift
  adapter，`ChuanqiCutFFmpeg` = 可选第三方后端——三层各自可独立演进、独立声明许可。
- 消费端 `import ChuanqiCutEngine`（App 侧）**不变**——只有绑定层内部 import 改。
- 改名不迁移历史卡号（PALA-xxx 先例：改了断链）；文档旧引用在收口批次统一 grep 清理。

## 实施记录（2026-10-11 下午，集成机会话）

改名与拆分全部落地，验证全绿：

- 绑定层：`Sources/CChuanqiCut` → `ChuanqiCutCore`（git mv）、module.modulemap、
  8 处 import、Tests/SwiftSmoke、Package.swift（C target → `ChuanqiCutCore`；
  binaryTarget 让位改名 `ChuanqiCutCoreBinary`）。
- Podspec：`ChuanqiCutCore.podspec`（s.name 改名 + FFmpeg 段摘除 +
  `s.dependency 'ChuanqiCutFFmpeg', '9.0.2'`）；新增 `ChuanqiCutFFmpeg.podspec`
  （LGPL-2.1-or-later 如实声明 + `ffmpeg/License.md` 资源包随 App 分发 =
  ADR-0036「App 内声明」义务落地）；`ChuanqiCutEngine.podspec` 依赖名更新。
- Podfile 双端：`pod 'ChuanqiCutCore'` + `pod 'ChuanqiCutFFmpeg'`。

### 实施踩坑（三处，全部实测定位）

1. **无源 vendored Pod 不产生链接产物**：ChuanqiCutFFmpeg 最初只带
   vendored_libraries（无 source_files）→ CocoaPods 生成 xcconfig-only target
   （无 Copy XCFrameworks、无 ldflags 聚合），`-l"ffmpeg"` 不进 App 链接行。
   解法：vendored 接线留在有源的 ChuanqiCutCore（已验证路径），FFmpeg Pod
   承载许可与义务（resource bundle = App 内声明载体）；ADR-0038 附录记录
   迁移条件（CocoaPods 支持无源 vendored 后迁回）。
2. **vendored_libraries 必须相对 podspec**：绝对路径被校验拒绝
   （File patterns must be relative）。
3. **本地 :path Pod 的头路径用 `PODS_TARGET_SRCROOT`**：`PODS_ROOT/<PodName>/`
   对本地 Pod 不存在（不拷贝进 Pods/）；且 xcconfig 值引号成对（一处 `""$(` 笔误
   让 CocoaPods shellsplit 直接崩）。

### 验证（实施当日，真机在场）

- pod install 双端 0 错误；Podfile.lock：`ChuanqiCutCore (0.1.0) → ChuanqiCutFFmpeg (9.0.2)`；
  App 聚合 xcconfig 含 `-l"ffmpeg"`；ChuanqiCutCore 头路径含 vendored Headers。
- macOS BUILD SUCCEEDED（x86_64/P96 口径）；iOS generic device **BUILD SUCCEEDED**。
- 真机 iPhone 17 Pro：**安装成功 + 启动运行**（com.chuanqi.cut，进程存活）；
  真机产物含 `_cq_audio_preview_create`（音频链）与
  `ChuanqiCutFFmpegLicense.bundle/License.md`（合规义务随包）。
  FFmpeg 符号未进二进制 = 预期（archive 成员按需拉取，MEDIA-021 落地后拉入；
  `-l"ffmpeg"` 链接闭合由 ctest media_ffmpeg_probe 证明）。
- SPM 路线 sanity：SharedUI swift build 通过（绑定模块改名后链路完好）。
- 遗留：SPM 绑定 xcframework 重构建（池 [12]，bindings swift test 需要它链接）。

## 勘误（2026-10-15，集成机）：vendored 属性写错，链接行从未带上 FFmpeg

**原记载有误的两处**（上文 §2 与 §验证）：

1. §2 写 `vendored_libraries = …/libffmpeg.xcframework` —— **这个写法 CocoaPods 完全不认**。
   xcframework 只能走 `vendored_frameworks`（CocoaPods 按 `File.extname == '.xcframework'`
   识别，见 `sandbox/file_accessor.rb` 的 `vendored_xcframeworks`）。
2. §验证 写「App 聚合 xcconfig 含 `-l"ffmpeg"`」—— 2026-10-15 实测**没有**（见下），
   该记载无法复现，判定为当时核对不严。

**实测（修前）**：`Pods-ChuanqiCutApp.debug.xcconfig` 的 `OTHER_LDFLAGS` 无 `-l"ffmpeg"`、
`LIBRARY_SEARCH_PATHS` 无 XCFrameworkIntermediates 路径、`Pods.xcodeproj` 中 `vendor` 0 命中。
掩盖原因：静态库按需拉成员，当时无人调用 FFmpeg 符号 → 缺 `-l` 也 BUILD SUCCEEDED。

**为何结论早已有却没落地**：`TASK-DEPS-012.md`（2026-10-12）已写「vendored_libraries 不认
xcframework 目录 → 终版 = `vendored_frameworks`」，但 podspec 里始终是 `vendored_libraries`。
**文档定案 ≠ 代码落地**，本次按 ADR-0034「不急于求成/做全做透」补上落地与实证。

**修后（2026-10-15）**：`engine/ChuanqiCutCore.podspec` 改 `s.vendored_frameworks`。
证据链（全部实测，非推断）：

| 项 | 结果 |
|---|---|
| 双端 `bundle exec pod install` | 0 错误（iOS 14 pods / macOS 7 pods） |
| App 聚合 xcconfig `OTHER_LDFLAGS` | 双端均含 `-l"ffmpeg"` |
| `LIBRARY_SEARCH_PATHS` | 双端均含 `${PODS_XCFRAMEWORKS_BUILD_DIR}/ChuanqiCutCore` |
| `[CP] Copy XCFrameworks` 阶段 | 生成并执行，脚本 `ChuanqiCutCore-xcframeworks.sh` |
| 拷贝产物 slice | iOS=arm64 2.8MB；macOS=x86_64+arm64 fat 5.4MB（`lipo -info` 核对） |
| 双壳构建 | iOS generic device **BUILD SUCCEEDED**；macOS x86_64 **BUILD SUCCEEDED** |
| 链接实证 | `xcrun -sdk iphoneos clang` 最小 TU（调 `avformat_open_input`）+ `-l"ffmpeg"` + App 现有 framework 集合 → 链出可执行文件，`nm` 得 775 个 `_av*` 符号；**无需补 -lz/-lbz2/-liconv**（MEDIA-021 开工时的链接依赖结论） |

**仍然成立的事实**：App 运行时**依旧不使用 FFmpeg**（无调用点，MEDIA-021 未开工），
本次只是把「接线」修成可用状态，不产生任何运行时行为变化。
