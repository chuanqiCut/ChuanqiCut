> 🗄️ **历史素材（第一代调研）**：本文档已经 [`RESEARCH-001`](../RESEARCH-001-现有调研文档批判性评审与事实核验.md) 批判性评审，其结论被 ADR 与 ARCH 方案**吸收、修正或废弃**。其中的性能数字一律为估算 [E]、选型结论不得直接引用；有效结论以 `docs/research/RESEARCH-001` §5 处置表、`docs/specs/`、`docs/decisions/` 为准。

# 系统 API 的局限性分析 & FFmpeg 取舍

> 核心问题：纯 Apple 系统 API 在 Seek 和变速场景下到底够不够用，
> 什么时候会碰壁，以及实际产品（FCP/CapCut）是怎么处理这个矛盾的。

---

## 一、先承认：你说得对。纯系统 API 确实有局限

我在上一份文档里的表述太绝对了。"不需要 FFmpeg" 这个说法放在**视频编辑器**这个场景下，不完全成立。

关键在于**视频编辑的两条不同管线**，对 Seek 的要求完全相反：

```
播放预览管线（AVPlayer / AVComposition）:
  源帧顺序 → 1 → 2 → 3 → 4 → 5 → 6 → ...
  用户操作:       ← seek → 向前/向后跳
  AVPlayer 擅长: 可以跳到任何时间点，但跳到关键帧附近然后向前解码
  
导出渲染管线（逐帧输出）:
  ┌──────────────────────────────────────────────────┐
  │ 正常播放: source frame 0,1,2,3,4,5,6...         │
  │   → AVAssetReader 顺序读取 → ✅ 完美              │
  │                                                   │
  │ 2x 变速: source frame 0,2,4,6,8,10...           │
  │   → AVAssetReader 顺序读取 + 隔帧取 → ✅ 仍完美   │
  │                                                   │
  │ 0.5x 慢放: source frame 0,0,1,1,2,2,3,3...     │
  │   → AVAssetReader 顺序读取 + 每帧重复 → ✅ 仍完美 │
  │                                                   │
  │ 速度曲线（加速→减速→加速）:                        │
  │   source frame 0,1,3,6,10,15,10,6,3,1,0...     │
  │   → 需要反复跳回之前的帧 → ❌ AVAssetReader 不行  │
  │   → 需要 random access → ❌ 系统 API 局限         │
  └──────────────────────────────────────────────────┘
```

**问题核心三个字：回、头、读。**

---

## 二、系统 API 的边界——具体哪里不行

### 2.1 AVAssetReader：只向前，不回头

```
AVAssetReader 的设计是"流式读取"：
  创建 → seek to start → 逐帧 read → 读完 → 销毁

它的局限：
  ❌ 不能倒退（没有 readPreviousSampleBuffer）
  ❌ 不能随机跳到后面再跳回前面
  ❌ 不能从同一个 reader 实例跳到另一个时间点重新开始
      （必须销毁重建一个新的 AVAssetReader）

重建 AVAssetReader 的成本：
  ├── 解析文件头（moov box）
  │     ├── 短视频（< 5min）：~5-10ms
  │     ├── 长视频（> 1h 4K）：~50-200ms（大 moov 在末尾要全文件扫描）
  │     └── 远程文件（URL）：更慢，需要本地缓存
  │
  ├── 创建解码 session：~10ms
  ├── 解码到目标帧（从最近的 keyframe 开始解到 target frame）
  │     └── 跳 10 秒可能需要多解码几十帧
  └── 总计：每一次 seek 跳转大约 20-200ms

这意味着：
  如果你的速度曲线在 1 秒内来回跳 5 次 →
    每次重建 reader + 解码 = 5 × 50ms = 250ms 秒的开销
    而你要输出 30 帧（每帧 33ms）= 整个 1 秒可能花 2 秒去渲染
    → 速度曲线越复杂，导出越慢
```

### 2.2 AVSampleBufferGenerator（Apple 的"随机访问"答案）

iOS 14+ / macOS 11+ 引入的 API，**专门为这个场景设计**：

```swift
// AVSampleBufferGenerator — 随机时间点解码
let generator = AVSampleBufferGenerator(asset: asset, timebase: .init())

// 在任意时间点创建样本请求
let request = AVSampleBufferRequest(
    direction: .forward,    // 或 .reverse
    preferredSample: .earliest   // 最近的样本
)

// 拿到指定时间的样本
let sampleBuffer = generator.generateSampleBuffer(for: request)
```

| 维度 | AVAssetReader | AVSampleBufferGenerator |
|---|---|---|
| 读取方向 | 只向前 | ✅ 前后都可 |
| 随机访问 | ❌ 重建 | ✅ 直接跳到目标时间 |
| 性能 | 连续读取快 | 随机跳转快 |
| 支持平台 | iOS 8+ / macOS 10.10+ | iOS 14+ / macOS 11+ |
| 成熟度 | 极高 | 中等（偏新，文档少） |

```
AVSampleBufferGenerator 的局限：
  1. iOS 14+ / macOS 11+ 才能用（大版本要求不高但 iPhone 6s 不支持）
  2. 不支持反向 - 只能跳正向后读，不能从后面往前读
  3. 每个生成的样本是独立的，不跨帧做优化
  4. 对 H.264/H.265 仍然需要解码到目标帧（只是帮你跳过了 reader 重建）
  5. API 设计偏底层，用来做帧序列不如 AVAssetReader 方便
```

**结论**：AVSampleBufferGenerator 缓解了"重建 reader 慢"的问题，但没解决"从 keyframe 解码到目标帧"的固有开销。而且它不支持真正反向读取。

### 2.3 AVPlayer.seek 用在导出中——也不行

```swift
// AVPlayer 的 seek 用于预览非常快
player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
```

但 AVPlayer **不是为逐帧渲染设计的**：
- 它是播放器，不是帧解码器
- seek 的回调是异步的，不能用在同步渲染循环里
- 不能精确控制每个 seek 的输出帧
- 不支持同时 seek 多个源

### 2.4 VTDecompressionSession 直接控制

最底层的方式，可以绕过 AVAssetReader：

```swift
// 前提：你需要从 AVAssetReader 或 FFmpeg 拿到压缩的 CMSampleBuffer
// 然后用 VTDecompressionSession 解码

VTDecompressionSessionDecodeFrame(
    session,
    sampleBuffer: compressedSample,  // 压缩数据
    flags: [],
    frameParameters: nil,
    infoFlagsOut: nil
)
```

这样可以：
- **复用同一个解码 session，不需要重建**
- 往 session 里喂压缩数据，得到解码帧
- 喂到什么帧、什么顺序，完全由你控制

**问题变成了"谁提供压缩数据（CMSampleBuffer 或压缩包）？"**

这里有两种选择：

```
路线 A: AVAssetReader + VT（纯系统 API）
  AVAssetReader → CMSampleBuffer → VTDecompressionSession → CVPixelBuffer
  ↑ 局限性：reader 只能向前，seek 要重建 reader

路线 B: FFmpeg demux + VT decode（混合方案）
  FFmpeg (av_read_frame) → compressed packet → VTDecompressionSession
  ↑ FFmpeg 可以 av_seek_frame 到任何位置
  ↑ 复用一个 VTDecompressionSession
  ↑ 解出来的 CVPixelBuffer 仍然可以和 Metal 零拷贝
```

---

## 三、具体场景分析——每个场景到底能不能用纯系统 API

### 场景 1：基础剪辑（裁头去尾、拼接）

```
用户需求：
  把一段视频从 10s 开始、30s 结束，接到另一段视频前面

工作方式：
  AVComposition 描述：clip1[10s-30s] → clip2[0s-20s]
  AVPlayer / AVAssetExportSession 自动处理

纯系统 API 是否能做：✅ 完全足够
  AVFoundation 天生为这个设计
  不需要任何 seek/random access
  导出时 AVCompositionExportSession 自动处理
```

### 场景 2：恒速变速（全部 2x 或 0.5x）

```
AVMutableCompositionTrack.scaleTimeRange(
    range, 
    toDuration: range.duration / speed
)

导出时 AVAssetExportSession 按时间线渲染，自动变速

纯系统 API 是否能做：✅ 完全足够
  但变速后的帧怎么取？
  - 2x: 取 0, 2, 4, 6...（每隔一帧）— AVAssetReader 顺序读完全够
  - AVComposition 在播放/导出时自动做了这件事
```

### 场景 3：速度曲线（加减速 + 变速再减速）

```
时间线上一段 clip，从 1x 加速到 3x 再回到 1x

export 时的时间映射：
  output_time → source_time
  0.00s → 0.00s (1x)
  0.50s → 0.75s (2x)
  1.00s → 2.00s (3x)
  1.50s → 2.75s (2x)
  2.00s → 3.00s (1x)

source_frame 访问模式：0, 0, 1, 2, 4, 6, 9, 12, 15, 18, 15, 12, 9, 6,...  
                                                          ↑ 这里开始往回跳了

纯系统 API 是否能做：⚠️ AVAssetReader 不能回头
  AVComposition 只能做恒速变速
  速度曲线必须自己实现渲染引擎

解决方案：
  方案 A: FFmpeg 随机 seek + VT 解码
  方案 B: 预解码整段到内存（4K 10s ≈ 330MB，可以接受短片段）
  方案 C: AVSampleBufferGenerator（每个时间点独立生成，不重建 reader）
```

### 场景 4：倒放（反向播放）

```
从视频最后一段到第一段逐帧反向输出

source_frame 访问模式：N, N-1, N-2, ..., 2, 1, 0
                              全部是反向的

纯系统 API 是否能做：❌ AVAssetReader 只能向前
  AVComposition 不支持速度反转

解决方案：
  方案 A: FFmpeg + VT decode（唯一实用方案）
  方案 B: 正序全部解码到内存，然后逆序输出（N × 33MB——内存爆炸）
  方案 C: AVAssetWriter 配合逐帧重建 reader（奇多次 seek，极慢）
```

### 场景 5：多段裁剪（一段视频里取 10 个片段）

```
同一个 1 小时视频文件，取了 10 个 5s 片段

source_frame 访问模式：
  clip1: 0s-5s, clip2: 30s-35s, clip3: 120s-125s, clip4: 10s-15s...
           ↑                       ↑            ↑
          每转一个 clip 就要 seek 到新的位置

纯系统 API 是否能做：⚠️ 效率差
  每转一个 clip 重建 AVAssetReader
  10 个 5s 片段就是 10 次 reader 创建
  每次都要解析文件头 + 解码到对应 I-frame
  
  但对短文件（< 30分钟）来说，重建 ~20ms 可以接受
```

### 场景 6：倒放 + 变速组合

```
反向 0.5 倍速 + 中途正向 2x

source_frame 访问模式：
  前半（倒放+慢放）: N, N-0.5, N-1, N-1.5, ...
  后半（正向快放）: 中间某帧正确序 + 跳帧
  
  混合方向访问

纯系统 API 是否能做：❌ 不行
  必须用 FFmpeg 做随机寻址
```

### 场景 7：VFR（可变帧率）素材

```
iPhone 在某些录像模式下产生 VFR（60fps 降 30fps 时）
每帧的 duration 不固定

FFmpeg 逐帧解析，每帧有准确的时间戳
AVAssetReader 也支持 VFR——它返回的 CMSampleBuffer
  自带准确的 presentationTimeStamp

但：
  AVComposition 在处理 VFR 素材的变速时有偏差
  在 VFR 素材的倒放场景下，AVFoundation 的行为不可控

纯系统 API 是否能做：
  普通剪辑：✅ 够用
  变速倒放：❌ 行为不可控
```

---

## 四、产品实际做法——FCP 和 CapCut 分别怎么选

### Final Cut Pro（纯 Apple，无 FFmpeg）

FCP 完全基于 AVFoundation + VideoToolbox，不内嵌 FFmpeg。它怎么绕开这些局限？

```
FCP 的策略：

1. 后台自动转 ProRes Proxy
   导入时把任何格式→ProRes Proxy（编辑用的轻量文件）
   └── 解码开销只发生一次（转代理时）
   └── 编辑时接触的始终是 ProRes（帧内编码，seek 极快）
   └── 导出时切回原始素材

2. 不支持速度曲线（严格说支持得非常有限）
   └── FCP 只支持恒速变速 + 简单的变速段（保持速度不变再变）
   └── 没有"从 1x 平滑加速到 3x 再回来"这种高级速度曲线

3. 只支持简单 Retime（快放/慢放/倒放）
   └── 倒放的实现靠它自己的后台渲染引擎缓存帧
   └── 它的渲染引擎 + 代理 ProRes 让随机访问性能够用

4. 渲染引擎有帧缓存池
   └── 渲染过的帧不丢弃，放在缓存里
   └── 来回跳时间点时从缓存取，不解码新的

所以 FCP 的做法本质上是：
  "用 ProRes Proxy 把 seek 成本降到几乎为零"
  "不做复杂的 speed ramp"
  "接受这些局限，换零额外开源依赖"
```

### CapCut（C++ 核心 + FFmpeg + 平台硬解）

```
CapCut 的策略：

1. C++ 核心层用 FFmpeg 做解封装和 seek
   └── av_seek_frame 任意跳转
   └── 支持速度曲线、倒放、任意时间映射

2. 解码走平台硬解
   └── FFmpeg 拿到压缩包 → iOS 走 VTDecompressionSession
   └── Android 走 MediaCodec
   └── 不经过 FFmpeg 的软解

3. 用于：
   └── 速度曲线渲染
   └── 倒放
   └── VFR 变速
   └── 多片段从同一源文件高效裁剪

CapCut 的做法：
  "FFmpeg 只做解封装和 seek"
  "编码解码全走平台硬件"
  "C++ 核心层保证 Android/iOS 代码共享"
```

### 两张方案的实际开销对比

```
导出 10 分钟 1080p 30fps 视频，含：
  - 从 2 小时长视频里取的 5 个片段
  - 其中一个有速度曲线（1x→3x→1x）
  - 另一个有倒放

纯 AVFoundation 方案（类似 FCP）:
  5 个片段 → 5 次 reader 创建（慢但可接受）
  速度曲线 → 模拟方式实现：逐帧 reader.seek（慢）
  倒放 → 缓存到内存或创建反向 reader（内存大或慢）
  总时间：估算 12-15 分钟导出 + 预处理时间

FFmpeg + VT 混合方案（类似 CapCut）:
  5 个片段 → av_seek_frame 无代价
  速度曲线 → 逐帧 av_seek_frame（快）
  倒放 → 从后向前 seek（快）
  总时间：估算 8-10 分钟导出

如果你有速度曲线 + 倒放场景，混合方案比纯系统 API 快 30-50%。
如果你只有基础剪切 + 恒速变速，差距几乎为零。
```

---

## 五、对你的项目的实际建议

### 核心结论：**不是非此即彼，是分层的**

```
┌─────────────────────────────────────────────────┐
│  你的渲染引擎                                     │
│                                                   │
│  需要"给我源文件在时间 T 的帧"这个能力               │
│                                                   │
│  ┌──────────────────┐   ┌───────────────────┐    │
│  │ 方案 A（纯系统）   │   │ 方案 B（混合）      │    │
│  │                  │   │                   │    │
│  │ AVAssetReader    │   │ FFmpeg            │    │
│  │ + frame cache    │   │ + VTDecodeSession │    │
│  │ + 缓存 LRU 策略   │   │（推荐）            │    │
│  └──────────────────┘   └───────────────────┘    │
│                                                   │
│  编码、封装 → 系统 API（VT+AVAssetWriter）         │
└─────────────────────────────────────────────────┘
```

### 我更新后的推荐——分阶段来

**Phase 1（MVP）**：纯系统 API 够用

```
功能范围：
  ├── 基础剪裁/拼接
  ├── 恒速变速（0.5x / 2x / 4x）
  ├── 多轨叠层
  └── 简单转场

需要 seek 的场景：
  ├── 时间线拖动预览 → AVPlayer.seek（系统，完美）
  ├── 导出恒速变速 → AVComposition（系统，完美）
  └── 不需要速度曲线或倒放

结论：MVP 阶段纯系统 API 完全够用，没有问题。
```

**Phase 2（速度曲线 + 倒放）**：引入 FFmpeg 做解封装和 seek

```
新增功能：
  ├── 速度曲线（加减速平滑变化）
  ├── 倒放
  ├── 从长视频取多个片段的高效导出
  └── VFR 素材的精确变速

需 FFmpeg 做的事：
  ┌─────────────────────────────────────────────┐
  │ FFmpeg (libavformat)          ← 只做解封装   │
  │   │                                          │
  │   ├── avformat_open_input                    │
  │   ├── av_seek_frame (任意时间点)              │
  │   │                                          │
  │   ├── av_read_frame → AVPacket (压缩数据)     │
  │   │     │                                     │
  │   │     └──→ VTDecompressionSession（硬件解码）│
  │   │             → CVPixelBuffer               │
  │   │             → MTLTexture（零拷贝）         │
  │   │                                          │
  │   └── AVAssetWriter（封装编码后数据）          │
  └─────────────────────────────────────────────┘

数据流动：
  FFmpeg demux (seek) → AVPacket → VT Decode → CVPixelBuffer → Metal
  ↑     全是压缩数据         ↑   硬件解     ↑    UMA 零拷贝  ↑
  FFmpeg 只在解封装层，不碰像素数据
```

**引入 FFmpeg 的合规成本**（很多人在意）：

```
选项 A: 静态链接（ffmpeg 编译为 .a）
  └── LGPL 要求用户能替换库
  └── iOS 无法动态链接 → 需要提供 .a 的源码和相关编译脚本
  └── 很多 App Store 应用这么做了，但律师会多问几句

选项 B: 动态链接（通过 BUNDLE 或系统装）
  └── iOS 上不可行（不能装外部动态库）

选项 C: 只在必要功能用 FFmpeg，用 System API 包装
  └── 推荐做法：写一个 FrameProvider 协议
  └── 底层可以换 SwiftAVPlayer、FFmpeg、或 AVAssetReader
  └── 上层不关心

实际业界做法：
  ├── CapCut → FFmpeg（自有 C++ 核心层，合规团队处理过）
  ├── VN → FFmpeg
  ├── 剪映专业版 → FFmpeg
  ├── 美图 → FFmpeg（部分自研）
  └── FCP → 不用 FFmpeg（它自研 ProRes 代理绕过了需求）
```

### 最务实的建议

**不要一开始就纠结 FFmpeg 的合规问题，先把产品做出来。**

```
推荐的分层设计：

protocol FrameProvider {
    func seek(to time: CMTime) async throws
    func nextFrame() async throws -> Frame  // Frame = CVPixelBuffer + metadata
    func preload(from: CMTime, to: CMTime) async throws
}

// Phase 1: AVFoundation 实现
class AVAssetFrameProvider: FrameProvider {
    // 用 AVAssetReader + VT + Frame Cache
    // 不支持速度曲线和倒放，但 MVP 已经够
}

// Phase 2: FFmpeg 实现  
class FFmpegFrameProvider: FrameProvider {
    // 用 FFmpeg demux + VT decode
    // 支持所有 seek 模式
    // 内部封装 LGPL 合规逻辑
}

// 渲染管线不关心底层用哪个：
func renderFrame(at time: CMTime) async throws -> MTLTexture {
    let frame = try await frameProvider.seek(to: time)
    return try await metalRenderer.render(frame)
}
```

**MVP 开发线（我的建议）：**

```
第 1-2 周：跑通 Metal + AVAssetReader 解码→渲染→预览管线
          → 用 AVAssetReader（纯系统 API）
          → 支持基础剪裁、过渡、恒速变速
          → 验证 UMA 零拷贝管线性能

第 3-4 周：加入 FFmpeg（可选）
          → 抽象 FrameProvider 协议
          → FFmpeg 实现在底层换掉 AVAssetReader
          → 支持速度曲线、倒放
          → 合规问题专门处理

MVP 上线时哪怕只有纯系统 API： 
  - CapCut 能做的东西你基本都能做（速度曲线除外）
  - 很多用户根本不会用速度曲线
  - 第一批用户更关心基础剪辑流畅度和剪映没有的功能
```

---

## 六、总结

| 场景 | 纯系统 API | +FFmpeg demux | 差距 |
|---|---|---|---|
| 基础剪辑/拼接 | ✅ 完美 | ✅ 冗余 | 无 |
| 恒速变速 | ✅ 完美 | ✅ | 无 |
| **速度曲线** | ⚠️ 需要帧缓存 | ✅ 简单 | **大** |
| **倒放** | ❌ 不可行 | ✅ | **不可逾越** |
| 多片段源文件 | ⚠️ 慢但可用 | ✅ 快 | 中 |
| VFR 变速 | ⚠️ 行为不可控 | ✅ 可控 | 中 |
| 时间线拖动预览 | ✅ 完美 | ✅ | 无 |
| 编码输出 | ✅ VT 硬编 | ✅ VT 硬编 | 无 |

**真实建议**：不是"用不用 FFmpeg"，是**什么时候用**。

- MVP 阶段（无速度曲线、无倒放）→ **纯系统 API，零依赖**。快、稳、合规没问题。
- 扩展阶段（加速度曲线、倒放等）→ **FrameProvider 协议抽象，FFmpeg 只做 demux + seek**。解码/编码仍然走 VT 和 AVAssetWriter，FFmpeg 不碰像素数据。
- 这不矛盾。先用 Option A 快速上线验证产品，Option B 在架构上预留好扩展位就行。

