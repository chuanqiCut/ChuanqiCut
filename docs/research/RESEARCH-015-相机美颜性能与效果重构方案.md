# RESEARCH-015：相机美颜性能与效果重构方案（含 iOS 系统能力对照）

> 日期：2026-10-11 深夜；来源：传哲三轮反馈（磨皮慢+效果差 / 没发挥 iOS 优势 / 要求出最佳方案）
> 状态：**待传哲拍板**；拍板后经 cq-spec-authoring 出 SPEC、cq-task-planning 拆卡
> 证据基础：真机日志批（2026-10-11，见池 [15]）+ 代码全链阅读 + baselines 在册数字

## 1. 问题定义（真机日志+代码实证）

### 1.1 性能（"卡"）

真机日志已证：预览渲染链零失败、磨皮引擎 INSTALLED 且无 FALLBACK（黏性回落排除）。
慢的构成 = 四件叠加：

| # | 构成 | 量级 [E] | 证据 |
|---|---|---|---|
| ① | 检测桥 30Hz × 3~4 Vision 全请求常开 | 6-15% CPU/ANE | VisionDetector.swift:35/141-151 |
| ② | 每帧 1~2 次全帧 CIBlendWithMask + 美白 2 filter | 全帧混合 ×2 | CameraBeauty.apply 磨皮/美白各 blended 一次 |
| ③ | 美颜链全分辨率（1080p）跑 | 蒙版链像素数 ×4 | process() 在采集 buffer 坐标直接跑 |
| ④ | 录制时同链在录制队列再跑一遍 | 预览+录制双份 | CameraRecorder.swift:269 |
| ⑤ | Vision landmark 模型疑似 ANE 部分层回退 CPU（Pool width 告警） | 使 ① 更贵 | 真机日志（池 [15] 已勘误归因） |

### 1.2 效果（"差"）

| # | 根因 | 细节 |
|---|---|---|
| A | 磨皮=亮度域双边滤波（半分辨率）+ σr≤0.11 保守上限 | 磨不净 + 细节软；每像素 4 次 exp 也是 ALU 大头 |
| B | 蒙版=脸框椭圆（外扩 0.15） | 只盖脸框、不含额际外/颈/耳前；边界断层感 |
| C | 无皮肤语义 | 眼/唇/眉全靠 `cq_beauty_protect` 色域兜底，能力有限 |
| D | 无细节回注 | 磨完发闷（CAM-029 ①细节回注未做，模块册在案） |
| E | 美白=线性曝光+亮度 | 高光易死白、肤色发灰（塑料感） |
| F | 检测时有时无的帧直通 | 磨皮断续感（算法驱动定则下 nil=直通） |

### 1.3 iOS 系统能力对照（"没发挥优势"）

| 系统能力 | 现状 |
|---|---|
| `AVCaptureMetadataOutput` 系统人脸框（采集栈原生持续输出，**零 Vision 调用**） | **未用**——磨皮蒙版只需要脸框，现在却每秒 30 次 Vision |
| `VNGeneratePersonSegmentationRequest`（iOS 15+，GPU 人像分割） | 未用（CAM-027 只落了 landmarks 注入点，语义蒙版接线已回退） |
| ANE 合理利用（按需请求，而非全家桶抢 ANE） | 未做 |
| MetalFX 升采样 / VideoToolbox 零拷贝 / ProMotion | 已用 / 已用（32BGRA）/ 自然生效 |
| beauty_harness 剖面工具 | 已有，真机定标就绪 |

## 2. 方案总纲

**一句话：采集栈送的脸框喂磨皮（免费），Vision 只为打开的功能跑（按需），磨皮内核换引导滤波
（更便宜更干净），蒙版升级语义分割（更准），整链半分辨率（更快）——全部在现有 CI 链内完成，
不自建管线（管线随 RENDER-001）。**

### 决策 1：人脸检测分两级（性能最大一刀）

- **一级（磨皮/美白蒙版）**：改用 `AVCaptureMetadataOutput`（`AVMetadataObjectTypeFace`）
  —— 采集会话原生输出脸框，独立于视频帧回调持续送帧，**零 Vision 调用、零图像转换**。
  脸框 EMA 平滑沿用 FaceMask.smoothedBox。
- **二级（美型/贴纸锚点）**：landmark 468 点 Vision 请求**仅当美型或贴纸开启时** 30Hz 跑；
  关闭时零 Vision。
- **条件请求**：HumanBodyPose 仅美体开启；Animal 仅宠物贴纸选中；AnimalBodyPose 仅 iOS17+
  且宠物贴纸。
- 全关闭 = 预览零检测开销（只剩 metadata faces，采集栈侧成本可忽略 [E]）。
- 兜底：metadata faces 与 Vision 框坐标系需真机标定一次（metadata 输出 0...1 归一化坐标，
  与 CAM-011 契约同构）；metadata 不可用（老机型/异常）回落 Vision faceRectangles
  （比 landmarks 便宜——单阶段无对齐）。

### 决策 2：磨皮内核换「引导滤波 + 高频保留」（效果主刀）

```
结构层 S = guidedFilter(I, I, r, eps)      // box filter 可分离，两 pass H/V
输出   O = S + (I − S) × k                 // k = 纹理保留系数（滑杆映射，单调）
皮肤蒙版 M 内才压高频；M 外直通
```

- **为什么比双边好**：①保边更干净（引导滤波以原图为引导，边缘天然保留）；②box filter
  无 exp（现 kernel 每像素 4 次 exp 是 ALU 大头）→ **磨皮 pass 预期快 3-5×**[E]；
  ③k 显式控制"磨多狠/保多少细节"——滑杆语义从 σr（抽象）变成"纹理保留"（直观），
  强度上限不再被保边约束卡死（σr≤0.11 那条线废除）。
- 与现契约兼容：输入图+强度 → 输出图，extent 不变；半分辨率跑不变。
- 参数定标：r/eps/k 三参数用 beauty_harness 真机剖面（平坦区方差压降、边缘保持率、
  高频保留曲线）定标，替换估算 [E]。
- 细节回注（CAM-029 ①）自然包含在 k 项里——磨完不闷。

### 决策 3：蒙版升级「语义分割 ∩ 脸框」（断层感根治）

- `VNGeneratePersonSegmentationRequest`（.balanced，GPU/ANE，3-5ms [E]）产出人像 mask，
  与脸框椭圆取交集 → 覆盖"脸+额际+颈"的皮肤区，排除背景与衣物——比现椭圆蒙版覆盖面
  大、边界准。
- mask 15Hz 低频跑 + 帧间 EMA（脸动得慢），磨皮关闭时不跑。
- 眼/唇/眉保护：沿用色域兜底（决策 2 的 k 系数让高纹理区自然少磨，眼唇眉压力下降）。
- landmark 蒙版精修（CAM-027 老方向）不做——系统无皮肤分割，引入 MediaPipe 多类分割
  是依赖变更，v2 再议（依赖走 manifest + 门禁）。

### 决策 4：CI 链瘦身

- 磨皮+美白结果**合成后单次** BlendWithMask（省一次全帧混合）。
- 蒙版构造从 4 节点（黑底+椭圆+composite+crop）换成 2 节点（分割 mask 缩放+羽化）。
- 美白重做：亮度域曲线（高光保护防死白）+ 肤色饱和度微降（防塑料），并入磨皮同链
  半分辨率 pass [E]。
- 录制链（决策⑤不变项）：录制锁参同链，半分辨率算法+上采样混合对 1080p 成片观感
  无损 [E]；WYSIWYG 语义保留。

### 决策 5：分期（三卡，各自独立可验收）

| 期 | 内容 | 预期收益 | 写集 |
|---|---|---|---|
| **P1 检测裁剪** | 决策 1 全部 + 决策 4 合并 Blend | 美颜全关时检测≈0；开磨皮时 CPU/ANE 大幅下降；合并省一次全帧混合 | VisionDetector / CameraManager(metadataOutput) / CameraBeauty |
| **P2 磨皮内核** | 决策 2 引导滤波 + k 滑杆 + harness 定标 | 磨皮 pass 3-5×、观感换代（磨得净+有细节） | beauty_bilateral.metal（新文件）/ BeautyKernel / 滑杆映射 |
| **P3 蒙版语义** | 决策 3 分割蒙版 + 决策 4 美白重做 | 断层感根治、美白换代 | PortraitSegmentation（新）/ FaceMask / CameraBeauty |

P1 先行（性能止血）；P2/P3 各自独立，可与 P1 隔帧验收。全部完成前**CI 链冻结新特效**。

## 3. 验收标准（拍板后进 SPEC 细化）

- 处理耗时（DEBUG 浮层 processing ms）：美颜全开 @1080p ≤ 5ms [E]（P1+P2+P3 后真机）；
  美颜全关 ≤ 1ms [E]。
- 检测：美颜全开但美体/贴纸关闭时，Vision 请求只剩分割（15Hz）；全关时零 Vision 调用
  （日志验证）。
- 观感（beauty_harness 真机）：平坦区方差压降 ≥50×、边缘保持率 ≥70%（现 60%）、
  k 曲线单调；蒙版羽化带宽 ≥ 框宽 20%。
- 稳定性：预览渲染零失败维持（真机日志 1920 帧 0 失败为基线）；录制链双跑不超时。
- 传哲目检：磨皮断续感消失、脸缘无断层、美白不塑料——人工终验。

## 4. 风险与边界

| 风险 | 缓解 |
|---|---|
| metadataOutput 脸框频率/坐标抖动 | EMA 平滑 + Vision faceRectangles 兜底开关（真机标定一次） |
| 分割 mask 帧间闪烁 | 15Hz + EMA + 羽化；闪烁可感知则降 quality 档或回椭圆蒙版（开关保留） |
| 引导滤波参数真机表现未定 | beauty_harness 先行定标，不达标不换（现 kernel 保留为降级路径） |
| iOS 16 部署目标：VNGeneratePersonSegmentation iOS15+ 可用 | 无门控风险（15 < 16） |
| 与 RENDER-001 边界 | 本方案全部在现 CI 链内，不建新管线；kernel/蒙版为纯函数节点，RENDER-001 落地时平移复用 |

## 5. 参考实现（详见会话记录，引用前现场核）

- 引导滤波原典：OpenCV `ximgproc::guidedFilter`（Apache-2.0，C++ 可下沉 core 参考）
- 高通磨皮参照：YUCIHighPassSkinSmoothing（MIT，纯 CI 逐步骤可单测）
- 管线形态参照：MetalPetal（MIT）/ GPUImage3（BSD）/ Apple AVCamFilter 官方示例

## 6. 拍板项

1. 三期分卡是否认可（P1 检测裁剪 / P2 磨皮内核 / P3 蒙版语义）？
2. P1 是否需要单独真机验证（建议：P1 落地即真机一趟，processing ms 前后对比留档 baselines）？
3. 效果优先级：P2（磨得干净）与 P3（蒙版自然）哪个先行？（默认 P2——"效果差"的主要抱怨
   是磨不净+断层，k 系数对两者都有缓解）
