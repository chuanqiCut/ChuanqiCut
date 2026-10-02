# TASK-BIND-003：C ABI 预览接口（含取帧接入 session）

> 日期：2026-10-02
> 状态：**待实现**（调研完成，按子步骤推进）
> 依赖：MODEL-001 ✅、GFX-002 ✅、PALA-011 ✅、PALA-002 ✅、MEDIA-020 ✅
> 验收：`cq_preview_render_frame(pts)` 能按时间线解出该时刻的帧并显示

---

## 一、现状（2026-10-02 核实）

| 能力 | 状态 | 位置 |
|---|---|---|
| 时间线模型 | ✅ 已实现 | `core/src/model/timeline.cpp` |
| GFX 渲染 | ✅ 已实现 | `core/src/gfx/gfx_device.cpp` |
| 取帧（Open/Seek/AcquireFrame） | ✅ 已实现 | `system_frame_provider.h`（内联）+ `.cpp` 工厂 |
| 硬解后端 | ✅ 已实现 | `pal/apple/media_decode.mm` |
| CVPixelBuffer → GPU 纹理（零拷贝） | ✅ 已实现 | `pal/apple/gfx_metal.mm` + PALA-002 |
| **素材管理**（asset_id → 媒体源） | ❌ **无** | 需新建 |
| **C ABI 预览接口** | ❌ **无** | 需新建 |

`SystemFrameProvider` 构造需 `PalPtr<IMediaDemuxer>` + `IFrameDecoder*`，
两者 PAL Apple 后端都已提供 —— 所以**取帧链路是通的，缺的是"谁来持有、按什么时间取"**。

## 二、为什么必须顺带做素材管理

`MediaRef` 只有 `asset_id`（见 MODEL-001），没有路径。预览拿到 pts 后：

```
pts → Timeline::FindClipAt() → Clip.MediaRef.asset_id → ??? → 媒体源 → 解帧
                                                         ↑
                                                    这一环不存在
```

若只做 C ABI 接口而不补这一环，接口必然只能渲染测试图案 —— 又回到
「接口做完了但预览没内容」的老问题。**故素材管理与接口必须一起做。**

## 三、设计

### 3.1 素材表（新增，`core/include/cq/media/asset_registry.h`）

```cpp
class AssetRegistry {
    Status Register(uint64_t asset_id, const MediaSource& src);
    Status Unregister(uint64_t asset_id);
    const MediaSource* Find(uint64_t asset_id) const;
};
```

只做 id → MediaSource 的映射，**不负责打开/缓存**（生命周期与解码器归属留给
预览渲染器），保持职责单一。

### 3.2 预览渲染器（新增，`core/src/preview/preview_renderer.cpp`）

持有：Timeline（引用）+ AssetRegistry（引用）+ GFX device + 离屏 RenderTarget。

```
RenderFrame(pts):
  1. 遍历轨道，对每个 video track 调 Timeline::FindClipAt(track, pts) → Clip
  2. 素材内时间 = clip.source.source_in + (pts - clip.start)
  3. AssetRegistry.Find(clip.source.asset_id) → MediaSource
  4. FrameProvider::Seek(素材内时间, kExact) → AcquireFrame → MediaFrame
  5. MediaFrame（CVPixelBuffer）→ INativeImageImporter::Import → TextureHandle
     （PALA-002 零拷贝，不经过 CPU 拷贝）
  6. 用 GFX 把该纹理绘制到离屏 RenderTarget
  7. 导出 RenderTarget 背后的平台纹理句柄
```

⚠️ 导出用**中性句柄**（`void*`），Swift 侧 reinterpret 为 `MTLTexture`。
**不要**走"读回像素 → Swift 再上传"：CPU 往返每帧一次会直接毁掉预览帧率。

### 3.3 C ABI（`cq_sdk.h` 扩展，不改动已有接口）

```c
typedef struct CQPreview CQPreview;

CQPreview* cq_preview_create(void);
void       cq_preview_destroy(CQPreview*);

int32_t cq_preview_register_asset(CQPreview*, uint64_t asset_id, const char* path);
int32_t cq_preview_add_clip(CQPreview*, uint64_t track_id, /* clip 参数 */);

// 渲染 pts 处一帧到离屏目标；out_texture 返回可显示的平台纹理句柄
int32_t cq_preview_render_frame(CQPreview*, int64_t pts_value, int32_t pts_timescale,
                                void** out_texture);
void    cq_preview_release_texture(CQPreview*, void* texture);
```

## 四、子步骤（建议按此推进，每步可独立验证）

| # | 内容 | 验证方式 |
|---|---|---|
| 1 | `AssetRegistry` + 单测 | CTest：注册/查询/重复注册/未注册返回错误 |
| 2 | 取帧接入：给定素材 + pts，取到 MediaFrame | CTest：用真实素材文件，断言帧非空且尺寸正确 |
| 3 | 纹理导入：MediaFrame → TextureHandle | CTest：断言 IOSurface ID 与源一致（PALA-002 已有手法） |
| 4 | 预览渲染器：按时间线取帧并绘制到离屏 RT | CTest：读回像素断言非背景色 |
| 5 | C ABI 封装 + C 编译测试 | `test_c_abi.c` 扩展 |
| 6 | UIA-003：Swift 侧 MTKView 嵌入 | macOS 编译 + 启动冒烟 |

## 五、风险

- **精确 seek 的 B 帧语义**：`frame_provider.h` 已标注「展示区间归属 vs PTS 最近匹配」
  待评审（hypothesis）。预览按区间归属实现，若评审拍板另一种，改策略映射即可。
- **多轨合成**：本期只渲染**第一条命中的视频轨**，多轨叠加/转场合成留给 RenderGraph
  落地后（RENDER-001）再补。这点要显式标注，不能假装支持。
- **性能未实测**：预览帧率、seek 开销均无实测数据，PERF-001 未做。

## 六、写集

| 文件 | 层 |
|---|---|
| `core/include/cq/media/asset_registry.h` + `core/src/media/asset_registry.cpp` | MEDIA |
| `core/include/cq/preview/preview_renderer.h` + `core/src/preview/preview_renderer.cpp` | 新增 preview 层 |
| `core/include/cq/cq_sdk.h` + `core/src/cq_sdk.cpp` | BIND |
| `tests/unit/test_*.cpp` | 测试 |
