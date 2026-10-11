# ADR-0038 — 引擎 Pod 重命名与 FFmpeg 独立 Podspec（提案，待实施）

> 状态：**提案**（2026-10-11 传哲提出方向，本 ADR 定案设计；实施排 DEPS-012 提交收敛后第一批）
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
