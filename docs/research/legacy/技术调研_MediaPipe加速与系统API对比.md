> 🗄️ **历史素材（第一代调研）**：本文档已经 [`RESEARCH-001`](../RESEARCH-001-现有调研文档批判性评审与事实核验.md) 批判性评审，其结论被 ADR 与 ARCH 方案**吸收、修正或废弃**。其中的性能数字一律为估算 [E]、选型结论不得直接引用；有效结论以 `docs/research/RESEARCH-001` §5 处置表、`docs/specs/`、`docs/decisions/` 为准。

# MediaPipe 加速方案 & 系统 API 对比

> 核心问题：MediaPipe 468 点能跑到剪映的速度吗？
> Apple 系统 Vision API 更快吗？够用吗？

---

## 一、先把数字摆出来

### 一条完整美颜管线，每帧都在做什么

```
MediaPipe 默认方案（纯 CPU TFLite）:
                         耗时 (iPhone 15 Pro)
┌────────────────────────────┐
│ Face Detection            │  ~2ms   ← MediaPipe internal
├────────────────────────────┤
│ Face Landmark (468pt)     │  ~5ms   ← MediaPipe internal  
├────────────────────────────┤
│ 数据后处理 (CPU)          │  ~0.5ms ← 468点坐标整理
├────────────────────────────┤
│ Delaunay 三角剖分 (CPU)   │  ~1ms   ← 生成 ~900 个三角形
├────────────────────────────┤
│ 上传网格到 GPU            │  ~0.3ms ← MTLBuffer create + write
├────────────────────────────┤
│ Mesh Warp (Vertex Shader) │  ~0.2ms ← GPU 变形渲染
├────────────────────────────┤
│ 磨皮 (Compute Shader)     │  ~0.5ms ← GPU 并行的频率分解
├────────────────────────────┤
│ 总计                     │  ~9.5ms ← 60fps 预算 16.6ms, 余 ~7ms
└────────────────────────────┘
```

```
剪映自研方案（传闻数据，基于行业共识估算）:
                         耗时 (iPhone 15 Pro)
┌────────────────────────────┐
│ Face Detection (ANE)      │  ~0.5ms ← CoreML 小模型 ANE 推理
├────────────────────────────┤
│ 稀疏 Landmark (ANE)       │  ~1ms   ← 精简 ~100 点 + 分割
├────────────────────────────┤
│ UV Offset 合成 (GPU)      │  ~0.3ms ← 没有 Delaunay，Compute Shader
├────────────────────────────┤
│ 磨皮 (Compute Shader)     │  ~0.3ms ← 频率分解 + 分割 mask
├────────────────────────────┤
│ 总计                     │  ~2.1ms ← 60fps 预算 16.6ms, 余 ~14ms
└────────────────────────────┘
```

**差额 ~7ms。主要原因不是"MediaPipe 的模型慢"，而是有三个结构性差异。**

---

## 二、MediaPipe 加速的三个杠杆

### 杠杆 1：转换到 CoreML → ANE 运行（最大的单一优化）

MediaPipe 默认在 iOS 上走 **TFLite CPU 推理**。TFLite → CoreML 转换是唯一能让模型跑在 ANE 上的方法。

```
TFLite CPU 推理:
  ┌──────────────────┐
  │  解码帧           │
  │  CVPixelBuffer    │
  │      ↓            │
  │  TFLite CPU       │  推理芯片: CPU 核心
  │  (c++ 推理)       │  功耗：~2W
  │      ↓            │  速度：~5-7ms
  │  输出 float[]     │
  └──────────────────┘

TFLite GPU 推理 (MediaPipe GPU Delegate):
  ┌──────────────────┐
  │  解码帧           │  
  │  CVPixelBuffer    │
  │      ↓            │
  │  TFLite Metal     │  推理芯片: GPU
  │  (Metal shader)   │  功耗：~1W
  │      ↓            │  速度：~3-5ms
  │  输出 float[]     │  问题：GPU 被占用，和渲染冲突
  └──────────────────┘

CoreML ANE 推理:
  ┌──────────────────┐
  │  解码帧           │
  │  CVPixelBuffer    │
  │      ↓            │
  │  CoreML ANE       │  推理芯片: Neural Engine
  │  (ANE 专用硬件)    │  功耗：~0.3W
  │      ↓            │  速度：~1-2ms
  │  输出 float[]     │  优势：不占 CPU/GPU，同时渲染不受影响
  └──────────────────┘
```

**MediaPipe 换 CoreML ANE 后：5-7ms → 1-2ms，功耗降低 5 倍。**
这是你单体上能做的最大优化，而且影响范围最小。

**怎么做：**

```bash
# MediaPipe face landmark 的 TFLite 模型位置：
# mediapipe/modules/face_landmark/face_landmark.tflite

# 用 coremltools 转换：
pip install coremltools

python << 'EOF'
import coremltools as ct
import tensorflow as tf

# 加载 TFLite 模型
tflite_path = "face_landmark.tflite"
model = ct.convert(
    tflite_path,
    source="tensorflow",
    convert_to="mlprogram",  # CoreML 程序格式
    minimum_deployment_target=ct.target.iOS15,
    # 关键：指定 ANE 计算单元
    compute_units=ct.ComputeUnit.ALL,  # CPU+GPU+ANE
)

# 保存为 CoreML 模型
model.save("FaceLandmark.mlpackage")
EOF
```

```
集成到 Swift:
let model = try MLModel(contentsOf: faceLandmarkURL)
// MLModel 会自动选择 ANE 运行（如果 CoreML 认为合适）
let prediction = try model.prediction(from: input)
// post-process → 468 点
```

**注意事项：**

| 问题 | 说明 |
|---|---|
| **ANE 可能不跑** | CoreML 的模型编译/选择算法不保证所有模型都跑在 ANE 上。如果模型结构 ANE 不支持（比如太多自定义 op），会回退到 GPU 或 CPU |
| **转换损失** | TFLite→CoreML 转换有些 op 不完全兼容，可能需要调整模型 |
| **版本更新** | MediaPipe 模型更新后需要重新转换 |

### 杠杆 2：裁剪输入区域

第二个大优化：**MediaPipe 默认对全图做推理**。但人脸只占画面的一部分。

```
全图推理输入：640×640 = 409,600 像素
人脸区域推理：128×128 = 16,384 像素（如果先检测人脸再裁剪）

计算量差距：25 倍

怎么做：
  Step 1: Vision face detection（ANE，~0.5ms）→ 拿到人脸 bounding box
  Step 2: 从 CVPixelBuffer 裁剪人脸区域
  Step 3: CoreML 只对裁剪后的小图做 landmark（~0.3ms 输入变小）
  Step 4: 把 468 点坐标映射回原图坐标系

总时间: 0.5ms (Vision 检测) + 0.3ms (裁剪推理) + 0.3ms (后处理) ≈ ~1ms
```

**这个优化可以和 CoreML 转换叠加使用，效果相乘。**

### 杠杆 3：用 UV Offset Map 代替 Delaunay 三角剖分

第三个瓶颈是 CPU 上的 Delaunay 剖分（~1ms）。去掉它的方法：

```
Delaunay 路线（每帧 CPU 剖分）:
  landmark → Delaunay 三角剖分（~1ms CPU）→ 上传三角索引 → vertex shader

UV Offset Map 路线（离线预计算 + GPU 插值）:
  1. 以标准脸为基准，预生成偏移纹理（float2 texture）
  2. 每帧 landmark 算出偏移调整参数（不是重做剖分，是插值）
  3. Compute shader 用偏移纹理直接重映射像素
  4. 没有传三角形索引，没有 Delaunay

节省：~1ms CPU + ~0.3ms 上传
```

但 UV Offset Map 实现比 Mesh Warp 复杂，MVP 阶段可以先不优化，后面再改。

---

## 三、Apple Vision API：快，但点数不够

### 先看数据

| API | 输出点数 | ANE 加速 | 速度 | 够做美型吗 |
|---|---|---|---|---|
| `VNDetectFaceRectanglesRequest` | 0（只有框） | ✅ | ~0.5ms | ❌ |
| `VNDetectFaceLandmarksRequest` | **65 点** | ✅ | **~1ms** | ⚠️ **不够** |
| `VNGeneratePersonSegmentationRequest` | 分割 mask | ✅ | ~3ms | ✅ 磨皮用 |

**65 点具体分布**（对比 468 点）：

```
Apple Vision 65 点布局:
  ┌────────────────────────────────────────────┐
  │                                            │
  │  左眉: 9pt     右眉: 9pt                    │
  │                                            │
  │  左眼: 12pt    右眼: 12pt                   │
  │                                            │
  │  鼻子: 5pt                                 │
  │                                            │
  │  嘴外层: 12pt  嘴内层: 6pt                   │
  │                                            │
  │  脸轮廓: 7pt（只有半张脸！！）                │
  │              ↑                              │
  │        硬伤在这里                             │
  └────────────────────────────────────────────┘

MediaPipe 468 点布局（对比关键差异）:
  脸轮廓: 17pt + 15pt + 12pt（分三行，整张脸）
  鼻子: 32pt（包含鼻翼两侧的精细控制）
  嘴唇内轮廓: 20pt（可以仿真唇形调整）
```

### 为什么 65 点不够

| 美型操作 | 需要的最少点数 | Vision 65 点满足吗 |
|---|---|---|
| 瘦脸（下颌内收） | 脸轮廓 ≥ 20 点 | ❌ 只有 7 点，且只有半张脸 |
| 大眼 | 眼周 ≥ 10-12 点/眼 | ⚠️ 12 点/眼，够但边缘会有锯齿 |
| 小脸（整体缩放） | 脸轮廓 ≥ 30 点 | ❌ |
| 下巴调整 | 下巴区域 ≥ 5 点 | ⚠️刚好但精度不够 |
| 微笑唇 | 嘴角 4 点 + 唇型 8 点 | ✅ 够 |
| 调整鼻翼 | 鼻翼两侧 ≥ 6 点 | ❌ 0 点（没有鼻翼点） |
| 眉形调整 | 每眉 ≥ 6 点 | ✅ 9 点够 |

**核心结论：Vision 65 点能做基础美颜（磨皮、调色、简单调唇），但做不了精细美型（瘦脸、大眼、鼻翼调整、脸型修改）。**

### Vision 的最佳使用定位

```
Vision API 在美颜管线里的合理角色：

  不是主力，是前置加速器。

  推荐组合（MVP 最优方案）:

  ┌──────────────────────────────────────┐
  │ 1. Vision face detect (ANE, 0.5ms)   │
  │    → 精确的人脸 bounding box          │
  │                                     │
  │ 2. 根据 bounding box 裁剪 CVPixelBuffer│
  │    → 只处理人脸区域，跳过背景          │
  │                                     │
  │ 3. CoreML 转换后的 MediaPipe 468     │
  │    只在人脸小图上推理 (ANE, 1-2ms)    │
  │    → 得到完整 468 点                 │
  │                                     │
  │ 4. Metal compute shader 做美颜美型   │
  │    → GPU 上完成，不占 CPU             │
  └──────────────────────────────────────┘
  总耗时: ~2-3ms/帧 → 60fps 绰绰有余
```

---

## 四、能不能追上剪映

### 分阶段预期

```
优化阶段                          每帧耗时      60fps 余量
────────────────────────────────────────────────────────
未优化（TFLite CPU + Delaunay）   ~9.5ms        16.6-9.5 = 7.1ms ✅
第一步: CoreML ANE 转换          ~5-6ms        16.6-6 = 10.6ms ✅
第二步: + 裁剪输入区域            ~2-3ms        16.6-3 = 13.6ms ✅
第三步: + UV Offset 替代剖分      ~2ms          16.6-2 = 14.6ms ✅

剪映参考水平                     ~2ms           14.6ms ✅
```

```
什么时候接近剪映？
  第一步做完就已经接近了（5-6ms vs 剪映 2ms）。
  但"接近"不是"追上"。

  剩下的差距来自：
    1. 模型大小（MediaPipe 通用模型 vs 剪映定制模型）
    2. 模型内容（MediaPipe 468 点 vs 剪映精简点 + 分割一起输出）
    3. 管线一体化（MediaPipe 需要你拼接各组件 vs 剪映全定制）
```

```
对用户的实际体感差异：
  
  9.5ms（未优化）: 60fps 余量 7ms，简单场景流畅，多轨渲染时可能掉帧
  5ms（CoreML）:   余量 11ms，多轨特效渲染时仍然流畅
  2ms（优化完全）: 几乎不可能掉帧

  实际上在 60fps 下，9ms 的管线已经够流畅了。
  真正的瓶颈不是这个，而是"数据在 CPU/GPU 之间来回拷贝"。
  只要数据和 Metal 管线在统一内存（UMA）上不拷贝，就不会慢。
```

### 用户真实体感

```
60fps 一帧的预算 16.6ms。
如果美颜管线占 5ms:
  剩下的 11.6ms 留给解码 + 变换 + 多轨合成 + 上屏
  完全够（解码 ~0.3ms，变换 ~0.05ms，合成 ~0.2ms，上屏 ~0.2ms）
  余量 ~10ms

这就是 Metal + UMA 给的底气——管线里真正的重活是逐帧解码和 AI 推理，
而这两样都在专用硬件上跑（Media Engine + ANE），不占 CPU/GPU 渲染时间。
所以"和剪映差几毫秒"对用户体验基本没有可感知的影响。
```

---

## 五、综合对比表

### 三个方案的完整对比

| 维度 | 1. 纯 MediaPipe (TFLite CPU) | 2. 纯 Vision API | 3. MediaPipe Convert to CoreML + ANE |
|---|---|---|---|
| **Landmark 点数** | 468 点 | 65 点 | 468 点 |
| **美型能力** | ✅ 充分 | ❌ 不够 | ✅ 充分 |
| **推理硬件** | CPU | ANE | **ANE** |
| **速度** | ~5-7ms | ~1ms | **~1-2ms** |
| **不占用 GPU** | ✅ | ✅ | **✅ 最佳** |
| **集成复杂度** | 低（官方 SDK） | **最低（系统框架）** | 中（转换 + 桥接） |
| **模型定制力** | ❌ 不能改 | ❌ 不能改 | **✅ 可自训替代** |
| **协议合规** | Apache 2.0 | 系统框架 | 取决于转换来源 |

### 我的推荐路线

```
Phase 1（MVP 最快落地）:
  ┌────────────────────────────────────────────┐
  │ Vision Face Detection (框) — 0.5ms ANE     │
  │     ↓                                      │
  │ 原版 MediaPipe 468 TFLite CPU — 5ms CPU     │
  │     ↓                                      │
  │ Metal mesh warp + 磨皮                     │
  │ 总计: ~6ms，60fps 有 10ms 余量              │
  └────────────────────────────────────────────┘
  1-2 天集成，先跑起来

Phase 2（性能优化）:
  ┌────────────────────────────────────────────┐
  │ Vision Face Detection — 0.5ms ANE          │
  │     ↓                                      │
  │ 裁剪人脸区域                                │
  │     ↓                                      │
  │ CoreML 转换后的 468 landmark — 1ms ANE      │
  │     ↓                                      │
  │ Metal mesh warp + 磨皮                     │
  │ 总计: ~2ms (优化开始)                       │
  └────────────────────────────────────────────┘
  需要 CoreML 模型转换工作

Phase 3（自训模型替代 MediaPipe — 可选）:
  ┌────────────────────────────────────────────┐
  │ 自训练 CoreML 模型（检测+landmark+分割合一） │
  │ 全 ANE 推理 — 1ms                          │
  │     ↓                                      │
  │ UV Offset 替代 Delaunay                    │
  │ Metal compute shader 全管线                 │
  │ 总计: ~1.5ms（和剪映同一水平线）             │
  └────────────────────────────────────────────┘
  需要训练数据和时间
```

## 六、结论

**1. MediaPipe 加速到剪映水平？可以接近，但不是同一个方案。**

把 MediaPipe 模型转换到 CoreML + ANE + 裁剪输入区域，你能跑到 **~2ms**。剪映大概 **~1.5-2ms**。差距缩小到 0.5ms 以内——用户体感无差别。

**2. 系统 API（Vision）更快，但点数不够。**

Vision 65 点跑 ANE 只要 1ms，但做不了瘦脸/大眼/鼻翼调整。Vision 的最佳角色是**前置加速器**——用它快速定位人脸 bounding box，让后面更重的 468 点推理只在人脸小区域跑。

**3. 真正让你接近剪映的是这个组合：**

- Vision Face Detection（框，ANE）→ 裁剪
- CoreML 转换 MediaPipe 468（裁剪后小图，ANE）
- UV Offset Map（GPU，无 Delaunay）
- 所有效果在单条 Metal Compute Pipeline 完成

**4. 但说句实话：MVP 阶段不需要追这个差距。**

6ms（原版 MediaPipe 非优化）的美颜管线在 60fps 下余量 10ms——多轨渲染时也不会掉帧。应该先让功能跑起来，再追这 4ms 的优化。

