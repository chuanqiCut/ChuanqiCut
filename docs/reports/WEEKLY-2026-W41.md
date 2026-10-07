# 周报 W41（2026-10-05 ~ 10-11）· 首刊

> 出刊节奏：每周一期，集成机在周度兜底门禁同轮出刊（ADR-0030 阶段批的"周"档）。
> 固定结构：项目介绍 / 当前架构 / 本周进度 / 关键数字 / 下周目标 / 风险。

## 1. 项目介绍

ChuanqiCut = **跨平台视频编辑 SDK + 各端原生 App**：C++20 共享内核（`core/`，
媒体/渲染/模型/序列化，对外纯 C ABI）→ 平台适配层（`pal/`）→ 原生 UI（`apps/`，
SwiftUI/UIKit）。目标 iOS+macOS（P0）→ Android（P1）→ 鸿蒙（P2 预留）。
双机并行开发：本机 = 集成机（唯一发号器、全量门禁与真机验收），远端 = 开发机
（编码优先，验证经待办池移交）。

## 2. 当前架构（Apple 端实况）

```
壳 App（apps/apple/ios + mac：AppEntry/路由/权限/装配，零业务）
 ├─ ChuanqiCutEngine   SDK（core C++20 + pal/apple + Swift 绑定；pod 名本周加 Engine 后缀）
 ├─ SharedUI           UI 基座（Theme 配色 + 三个跨域注入器，仅 Common/）
 ├─ ChuanqiCutPlayer   独立播放器（AVPlayer 过渡，ADR-0022）
 ├─ ChuanqiCutImport   素材导入（自研相册浏览器）
 ├─ ChuanqiCutCamera   拍摄（iOS 专属；metallib 管线留壳工程）
 ├─ ChuanqiCutEditor   编辑器（三件套+Timeline+EditorViewModel；UIA-034 起 UIKit 化）
 └─ ChuanqiCutDraft    草稿（骨架占位，待 PROJ-001）
功能 Pod 横向零依赖；跨域交接走基座注入器（壳装配）。
```

内核侧分层：base（时间/并发/日志）→ model+command（Undo/Redo）→ media/render/gfx/audio
→ session（EditorSession 门面）→ C ABI（`cq_sdk.h`，唯一对外接口）→ Swift 绑定。

## 3. 本周进度（10-05 ~ 10-07）

- **流程基建**：ADR-0029/0030/0031 三连——双机分工（模块归属表 A/B/C 三线 + 集成机）、
  模块册分册制（调研/任务/进度/测试门禁记录按模块归口，全局册单写者）、门禁改
  **阶段批**（合并快检必做 + 全量按阶段触发）；TODO-POOL 门禁真机待办池。
- **壳工程 Pod 分治全域完成**（INFRA-013~020，六阶段三天跑完）：SharedUI 从七子域
  大杂烩瘦身为基座；Player/Import/Camera/Editor 四功能 Pod + Draft 骨架落地，
  测试守恒 140 = 52+36+16+36。
- **编辑页 UIKit 重建（UIA-034~036）**：时间线换 UIScrollView+分层 CALayer+CADisplayLink
  播放头（每帧只动播放头层，SwiftUI 零参与——30Hz 整树重算的卡顿根因消除路径）；
  传输条/工具栏/空态引导 UIKit 化；模拟器冒烟四区渲染验证。
- **质量案底**：P83（SDK 常量凭记忆书写进主干）、P84（构建产物零入库 → 门禁 artifacts
  步）、P85（Pod 迁移三假绿：.metal 编译链/scheme 隐式依赖/script_phase 产物不可达）。
- **工程答疑沉淀**：pod 名加 Engine 后缀（module_name 保 import 稳定）；Pods 导航器
  docs/ 来自 CocoaPods 自动文档探测（pod 根=仓库根，无害无开关）；core 头文件以
  preserve_paths 进导航器（编译仍走 HEADER_SEARCH_PATHS，headermap 案底规避）。

## 4. 关键数字（本机实测）

| 项 | 数字 |
|---|---|
| 全量门禁 | PASS=14 / FAIL=0 / SKIP=0（本周三轮：10→12→14 步递增，新步=artifacts+三 Pod 测试） |
| core 单测 | Debug 45/45 · Release 45/45 |
| Swift 测试 | bindings + SharedUI(build) + Player 52 + Camera 36 + Import 16 + Editor 36 |
| 双壳构建 | iOS 模拟器 + macOS 均 BUILD SUCCEEDED（Engine 改名后复验） |
| metallib | 8431B，kernelNames 齐全（ADR-0021 验收口径） |

## 5. 下周目标（W42）

1. **UIA-037** 时间线缩略图（异步抽帧，主线程不解码）——UIKit 时间线收尾。
2. **真机一趟三单**（TODO-POOL 攒齐执行）：播放器 5 检查点 + CAM-018/019 五项 +
   UIKit 编辑页走查（播放头流畅度/拖拽手感/时间码/空态，<16ms/帧目标）。
3. **PROJ-001 项目序列化**启动（草稿地基，`core/src/project/` 零实现）；
   LIB-001 素材库契约冻结评审（ChuanqiCutAssets Pod 建域前置）。
4. 编辑页手势打磨（捏合缩放时间线、双指多选——UIA-035 后续）。

## 6. 风险

- UIKit 编辑页未上真机（模拟器冒烟≠手感）；播放头流畅度数字待真机剖面回填 baselines。
- 远端开发机产线（AIEDIT 智能成片 UI）尚未在新 Pod 拓扑下合入——首次合并时
  按 P85 教训做合并快检（双壳真编译）。
- Assets Pod 语义悬空（挂 LIB 依赖）：素材逻辑暂居 Editor Pod，LIB 契约评审前不动。
