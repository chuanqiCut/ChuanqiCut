# ADR-0033：Engine 源码共置与 C/Swift 双 Pod 边界

- 状态：Accepted
- 日期：2026-10-09
- 决策者：传哲
- 关联：TASK-INFRA-021、TASK-INFRA-022、TASK-INFRA-024

## 背景

现有 `engine/core/include/cq/**` 与 `engine/core/src/**` 把同一功能的头和实现拆到两棵树。为了让头在 Xcode 可见，又叠加了三层补丁：主工程 folder reference、`pods_post_install.rb` 手工补 PBX 引用、Swift/下游 Pod 手工传播 `SWIFT_INCLUDE_PATHS`。结果是 Engine 内部头被当成工程资产展示，C ABI 模块仍依赖一条仓库相对路径，目录和发布边界都不真实。

## 决策

1. 内核改为 `engine/core/cq/<功能>/`：头文件和实现文件共置，功能目录保持 `base/audio/command/gfx/media/model/platform/preview/session/ai`；C ABI `cq_sdk.h/.cpp` 位于 `engine/core/cq/`。
2. Apple Platform 改为 `engine/platform/apple/{base,gfx,media}/`，平台内部头与 `.mm` 同目录；shader 跟随 gfx。
3. CocoaPods 拆成两个真实模块：
   - `CChuanqiCut`：C++ core + Apple Platform，只公开纯 C 头 `core/cq/cq_sdk.h`，其余头全部 private。
   - `ChuanqiCutEngine`：只含 Swift binding，依赖 `CChuanqiCut`，消费端继续 `import ChuanqiCutEngine`。
4. SPM 测试宿主保留，继续用自己的 `CChuanqiCut` shim/modulemap；它不进入 App 的 Pod 依赖链。
5. 删除主工程头文件 folder reference、Pods PBX 头文件注入、下游 `SWIFT_INCLUDE_PATHS` 路径传播。

## 理由

- 源码物理结构直接表达功能边界，不再靠生成工程里的虚拟组伪装共置。
- CocoaPods 生成的 `CChuanqiCut` module 正常暴露 public C ABI；Swift adapter 成为独立可替换层。
- 内部 C++ 头仍可在 Engine Pod 自身浏览和编译，但不会进入 App 公共模块或主工程。
- 保持 `import ChuanqiCutEngine`，避免 UI 层无意义改名。

## 后果

- CMake include root 从 `engine/core/include` 改为 `engine/core`，既有 `#include "cq/..."` 无需批量改写。
- XCFramework 打包需使用只含 `cq_sdk.h` 的 staging headers，不能把整个 `core/cq` 当 public headers。
- Podfile 必须同时以本地 path 声明 `CChuanqiCut` 与 `ChuanqiCutEngine`。
- 旧文档中的历史路径仅作历史记录；活跃模块册、构建脚本与规则真源更新为新路径。
