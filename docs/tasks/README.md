# tasks/ — 任务层使用说明与已建卡登记表

> 任务事实源 = [`TASK-BACKLOG.md`](TASK-BACKLOG.md)（118 任务 DAG 总账）+ 本目录 `TASK-<ID>.md`（单卡）。
> 本表只登记**已生成的卡**；BACKLOG 里没建卡的行仍是"待建卡"状态。
> **进度与测试/门禁记录不更新这里**——按模块归口写 `.ai/modules/<模块>.md` 的「模块册」节
> （ADR-0030）；BACKLOG 与本表由集成机阶段批对账（全局册单写者）。

## 建卡流程

1. 取号前 `git fetch` 核对远端已用号（编号纪律见 [ADR-0019 §4](../decisions/ADR-0019-文档体系分层与归档规则.md)）；
2. 按 [`../../.ai/templates/task.md`](../../.ai/templates/task.md) 建卡，写集不得与其他在飞任务相交；
3. 在 BACKLOG 对应行标注 ✅（完成后）；在本表登记一行。

## 已建卡登记表（66 张，2026-10-07）
### 基建 INFRA / DOC
| 卡 | 标题 |
|---|---|
| [INFRA-001](TASK-INFRA-001.md) | monorepo 目录骨架与 CMake 顶层 |
| [INFRA-002](TASK-INFRA-002.md) | 内核 CMake 构建 + CTest（桌面） |
| [INFRA-009](TASK-INFRA-009.md) | Apple 端双工程拆分 + CocoaPods 源码集成 |
| [INFRA-013](TASK-INFRA-013.md) | 壳工程改造：Pods 骨架 + 双 Podfile + 门禁逐 Pod 测试段（ADR-0031 阶段 0）✅ |
| [INFRA-015](TASK-INFRA-015.md) | ChuanqiCutPlayer Pod 迁移（ADR-0031 阶段 1 样板）✅ |
| [DOC-001](TASK-DOC-001.md) | 文档体系统一分层与归档（ADR-0019 落地） |

### 内核 CORE / MODEL / MEDIA
| 卡 | 标题 |
|---|---|
| [CORE-001](TASK-CORE-001.md) | RationalTime 与有理数时间运算 |
| [CORE-006](TASK-CORE-006.md) | PAL 接口定义冻结 |
| [CORE-007](TASK-CORE-007.md) | 能力查询 `ICapabilities` 与枚举（实现） |
| [CORE-008](TASK-CORE-008.md) | 线程模型与队列骨架 |
| [CORE-009](TASK-CORE-009.md) | EditorSession 门面与快照机制 |
| [CORE-010](TASK-CORE-010.md) | 日志按「链路（workflow）」筛选 + 排障日志沉淀进受控设施（MEDIA-027 后续） |
| [MODEL-001](TASK-MODEL-001.md) | 时间线数据模型（Timeline / Track / Clip / Transition） |
| [MODEL-002](TASK-MODEL-002.md) | Command 模式与 CommandHistory（Undo/Redo） |
| [MEDIA-021](TASK-MEDIA-021.md) | 顺序取帧不必每帧 seek（预览帧率的真瓶颈） |
| [MEDIA-027](TASK-MEDIA-027.md) | 播放 5 秒后永久冻结 + 内存 3.4GB 被 jetsam（真因与修复） |

### 音频 AUDIO（跨平台层，BACKLOG §4.2）
| 卡 | 标题 |
|---|---|
| [AUDIO-001](TASK-AUDIO-001.md) | 音频图骨架与 PCM 缓冲管理（预分配池 / SPSC 无锁环 / 拓扑骨架） |

### 绑定 BIND
| 卡 | 标题 |
|---|---|
| [BIND-001](TASK-BIND-001.md) | `cq_sdk.h` 纯 C ABI 冻结 |
| [BIND-002](TASK-BIND-002.md) | Swift 绑定层（SPM package） |
| [BIND-003](TASK-BIND-003.md) | C ABI 预览接口（含取帧接入 session） |

### UI（Apple）UIA
| 卡 | 标题 |
|---|---|
| [UIA-002](TASK-UIA-002.md) | 编辑器主框架（预览 + 时间线 + 属性面板） |
| [UIA-003](TASK-UIA-003.md) | MTKView 预览视图嵌入 |
| [UIA-004](TASK-UIA-004.md) | 时间线自绘视图（Canvas，非组件堆叠） |
| [UIA-005](TASK-UIA-005.md) | 片段拖拽/裁剪交互（含 undo/redo C ABI） |
| [UIA-009](TASK-UIA-009.md) | 素材导入流程（含 Session 级素材表收口） |
| [UIA-010](TASK-UIA-010.md) | 播放驱动（播放时钟 + 播放/暂停入口） |
| [UIA-011](TASK-UIA-011.md) | 相册素材导入（PhotosPicker 入口） |
| [UIA-012](TASK-UIA-012.md) | 相册多选批量导入 |
| [UIA-013](TASK-UIA-013.md) | 自研相册浏览器（伞任务，B 期） |
| [UIA-014](TASK-UIA-014.md) | 预览宽高比适配（letterbox / fit；编号两次让位 011→012→014） |
| [UIA-015](TASK-UIA-015.md) | 独立视频播放器 MVP（AVPlayer 过渡 + 接缝；Spec UIA-020 + ADR-0022） |
| [UIA-016](TASK-UIA-016.md) | 播放器系统级播控补完（章节 + PiP 占位 + AirPlay；进阶版 P1） |
| [UIA-017](TASK-UIA-017.md) | 播放器画面捏合缩放与拖移（进阶版 P1） |
| [UIA-018](TASK-UIA-018.md) | 播放器外挂字幕 v1（SRT/WebVTT；开工前补 ADR-0023；进阶版 P1） |
| [UIA-021](TASK-UIA-021.md) | 播放器最近播放（bookmark 持久化；进阶版 P1；跳 019/020 见 PLAN §5） |
| [UIA-022](TASK-UIA-022.md) | 播放器播放列表与连续播放（进阶版 P1） |
| [UIA-023](TASK-UIA-023.md) | 播放器设置页 + macOS PiP + 快捷键扩充（进阶版 P1） |
| [UIA-024](TASK-UIA-024.md) | 播放器网络流播放（URL/HLS 点播；进阶版 P2，拍板项） |
| [UIA-025](TASK-UIA-025.md) | 播放器外挂字幕 v2（ASS/SSA 样式子集；进阶版 P2，拍板项） |
| [UIA-026](TASK-UIA-026.md) | 编辑器素材库 → 播放器联动（进阶版 P2，拍板项，跨域卡） |
| [UIA-027](TASK-UIA-027.md) | macOS mini player（MenuBarExtra + 生命周期上移；进阶版 P2，拍板项） |
| [UIA-032](TASK-UIA-032.md) | iOS 编辑页剪映式重构（**原 UIA-015，2026-10-07 撞号裁定让位改号**；SPEC-UIA-032） |
| [UIA-033](TASK-UIA-033.md) | Theme 令牌扩展增量（**原 UIA-016，同批让位改号**） |

### 相机 CAM（iOS 原生域，ADR-0014）
| 卡 | 标题 |
|---|---|
| [CAM-001](TASK-CAM-001.md) | 相机契约冻结（**已回退留档**：ADR-0014 转向 iOS 原生） |
| [CAM-002](TASK-CAM-002.md) | 相机采集管理器（AVCaptureSession） |
| [CAM-003](TASK-CAM-003.md) | 相机预览渲染链路 + 滤镜（MTKView + Core Image） |
| [CAM-004](TASK-CAM-004.md) | 首页 + 相机页 UI + EditorViewModel 惰性化 |
| [CAM-005](TASK-CAM-005.md) | 录制 + 产出（AVAssetWriter） |
| [CAM-011](TASK-CAM-011.md) | Vision 检测桥 + 帧间平滑（B 期） |
| [CAM-012](TASK-CAM-012.md) | 美颜升级——Metal 磨皮替换高斯近似（B 期） |
| [CAM-013](TASK-CAM-013.md) | 美型——人脸关键点驱动的 MeshWarp（B 期，**下一张**） |
| [CAM-014](TASK-CAM-014.md) | 贴纸 + 头部道具锚定（B 期） |
| [CAM-015](TASK-CAM-015.md) | 相机预览 CI→drawable 渲染修复 + 帧计数去伪绿 ✅（渲染线，先入库保留） |
| [CAM-016](TASK-CAM-016.md) | 相机预览方向修复（颠倒 + 横竖屏 + aspect-fill）✅ |
| [CAM-018](TASK-CAM-018.md) | 美颜色彩空间修正 + 录制对齐 + 引擎诊断日志 ✅ **曾号 CAM-015**（撞号让位；SPEC-CAM-018-019） |
| [CAM-019](TASK-CAM-019.md) | 美白/磨皮人脸区域化 ✅ **曾号 CAM-016**（同批让位） |

### 智能成片 AIEDIT（2026-10-04 立项，ADR-0020）
| 卡 | 标题 |
|---|---|
| [AIEDIT-000](TASK-AIEDIT-000.md) | 智能成片批次总览（伞卡） |
| [AIEDIT-001](TASK-AIEDIT-001.md) | 智能成片契约冻结（FeatureReport / EditPlan / LLM 接口 + 校验器） |
| [AIEDIT-002](TASK-AIEDIT-002.md) | 视觉特征提取管线（镜头边界/运动/质量） |
| [AIEDIT-003](TASK-AIEDIT-003.md) | 音频解码扩档 + 音频特征提取（静音/响度/能量包络） |
| [AIEDIT-004](TASK-AIEDIT-004.md) | PAL 网络传输 + LLM 客户端（URLSession / SSE） |
| [AIEDIT-005](TASK-AIEDIT-005.md) | Prompt 管线与决策解析/修复 |
| [AIEDIT-006](TASK-AIEDIT-006.md) | EditPlan→Command 执行器 + 新增命令类型 |
| [AIEDIT-007](TASK-AIEDIT-007.md) | C ABI 扩展与 Swift 绑定（Integrator） |
| [AIEDIT-008](TASK-AIEDIT-008.md) | 智能成片向导 UI（首页入口 + 三步向导） |
| [AIEDIT-009](TASK-AIEDIT-009.md) | 对话式调整（文字 + 语音输入） |
| [AIEDIT-010](TASK-AIEDIT-010.md) | AI 脚本成片（脚本→分镜→素材匹配→成片）【P1 伞占位】 |
| [AIEDIT-011](TASK-AIEDIT-011.md) | 本地规则引擎降级（离线成片） |

---

## 待他人接手（非任务卡，2026-10-07）

| 文件 | 内容 | 状态 |
|---|---|---|
| [TODO-POOL-门禁真机待办池.md](TODO-POOL-门禁真机待办池.md) | **门禁/真机待办唯一入口（ADR-0029）**：开发机收工登记（append-only），集成机日批消化（守门 + 真机一趟多单）；在飞：[1] 播放器真机 5 检查点、[2] CAM-018/019 真机 5 项（可同趟执行） | 常设池；[1][2] 待真机 |
| [TODO-2026-10-07-播放器域收尾待他人接手.md](TODO-2026-10-07-播放器域收尾待他人接手.md) | UIA-015/016 撞号裁定与清理（**✅ 2026-10-07 已裁定：编辑器线让位改 UIA-032/033/034~037**） / 真机（iPhone 17 Pro）验证（→**移交待办池 [1]**） / `tools/perf/` 入库（✅ 已入册） | TODO-1/3 完成，TODO-2 移交待办池 |
| [TODO-2026-10-07-撞号归一轮收尾待接手.md](TODO-2026-10-07-撞号归一轮收尾待接手.md) | 构建机门禁复验（**✅ 2026-10-07 14:46 PASS=9/FAIL=0/SKIP=0，零回归**）/ CAM-018/019 真机验收（→**移交待办池 [2]**，清单见 HANDOFF-007） | TODO-1 完成，TODO-2 移交待办池（可与 [1] 同一趟） |

> 备注：这些待办**故意不占 UIA/CAM 序列号**（ADR-0019 §4 编号纪律）。UIA 撞号裁定已落地、
> 序列恢复取号；CAM-015/016 撞号亦已裁定归一（渲染线留 015/016，美颜线改 018/019）。
> **2026-10-07 起**，后续门禁/真机待办一律进 TODO-POOL（ADR-0029），不再新开单件 TODO 文件。
