# preview 层（预览渲染器，BIND-003 子步骤 4/5）

> 建立：2026-10-02
> 位置：`core/include/cq/preview/` + `core/src/preview/`
> 上游：MODEL-001（时间线）、AssetRegistry（素材表）、MEDIA-020（取帧）、PAL（GFX / 导入）

## 1. 职责

回答一个问题：**时间线在 pts 这一刻，画面是什么。**

```
Timeline::FindClipAt(pts)          → 哪个片段
AssetRegistry::Find(asset_id)      → 片段指向哪个文件
FrameProvider::AcquireFrame(src_t) → 取出该时刻的帧（精确 seek）
INativeImageImporter::Import       → 零拷贝导入成纹理
IBlitPass::Encode                  → 画到离屏 RenderTarget
                                   → 导出 RT 背后的纹理句柄给 UI
```

## 2. 文件

| 文件 | 作用 |
|---|---|
| `core/include/cq/preview/preview_renderer.h` + `src/preview/preview_renderer.cpp` | 预览渲染器本体（平台无关） |
| `core/src/preview/cq_sdk_preview.cpp` | 预览的 C ABI 实现（**独立 TU**，原因见 ADR-0011） |

## 3. 依赖全部是**注入的非拥有指针**

```cpp
PreviewRenderer(IGfxDevice* gfx, IBlitPass* blit, IFrameProviderFactory* providers,
                const Timeline* timeline, const AssetRegistry* assets, const Config& cfg);
```

本类自己持有：importer（`PalPtr<INativeImageImporter>`）、离屏 RenderTarget、
`asset_id → FrameProvider` 映射、**上一帧导入的纹理**（逐帧 `ReleaseTexture`）。

## 4. 返回值语义（不要伪造成功）

| 返回 | 含义 |
|---|---|
| `kOk` | 命中片段并完成渲染 |
| `kIoNotFound` | pts 处是空隙（无片段覆盖）；**已清屏为黑**，`out_texture` 仍有效 |
| `kInvalidArgument` | 命中了片段但 `asset_id` 未注册 |
| 其它 | 解码 / 导入 / 渲染失败原样透传 |

空隙返回 `kIoNotFound` 而非 `kOk`：调用方必须能区分「黑帧」与「渲染失败」。

## 5. 诊断量（不是渲染结果本身）

`LastHitClip()` / `LastImportCpuFallback()` / `LastSourceTime()` / **`LastFramePts()`**。

⚠️ `LastFramePts()` 是**唯一**能证明「渲染的确实是 t 时刻那一帧」的量。
golden 素材 `gf_1080p_h264.mp4` 是**静态**彩条，不同时刻的像素完全相同 ——
像素断言无法区分「精确 seek 生效」与「反复复用同一帧」（pitfalls P16）。

`LastImportCpuFallback()` 稳定态应为 false；持续为 true 说明零拷贝链路断了。

## 6. 本期明确**不支持**（已写进头文件，不要假装支持）

- **多轨合成** —— 只渲染第一条命中的视频轨；叠加 / 转场合成等 RenderGraph
  （RENDER-001）落地后再补。
- **变速 / retime** —— MODEL-001 无该字段，时间线时长与素材时长 1:1。
- **宽高比适配** —— 当前「拉伸铺满」，无 letterbox / fit 模式。

## 7. 零拷贝链路（不能退化的部分）

```
MediaFrame.video.image (CVPixelBuffer)
  → INativeImageImporter::Import   # Metal 兼容 → CVMetalTexture，共享 IOSurface
  → TextureHandle
  → IBlitPass::Encode
  → 离屏 RT
  → out_texture（中性句柄，Swift 侧 reinterpret 为 MTLTexture）
```

⚠️ **绝不要**走「读回像素 → UI 再上传」：每帧一次 CPU 往返会直接毁掉预览帧率。
`gfx_metal_internal.h` 的 `ReadRenderTargetPixels` **只该出现在测试里**。

上一帧的导入纹理必须逐帧 `ReleaseTexture`，否则每帧泄漏一张（还额外锁住
解码帧的 IOSurface）。见 pitfalls P14。

## 8. 装配（C ABI 侧，见 `cq_sdk_preview.cpp`）

```
CreateGraphicsDevice(PAL) → CreateGfxDevice(pal, gfx)   # GFX 接管 PAL 所有权
CreateBlitPass(gfx->PalDevice(), kRGBA8, blit)
PalFrameProviderFactory                                  # 内部经 CreateFrameProvider
        ↓
PreviewRenderer(gfx, blit.get(), &factory, &timeline, &assets, cfg)
```

任一 PAL 后端缺失 → `cq_preview_create` 返回 `NULL`（运行时失败，不是崩溃）。

## 9. 验证

```bash
./tools/build/build_core.sh --platform=apple --config=Debug --test
ctest --test-dir build -R preview_renderer   # 35 项：像素真值 / 方向 / 零拷贝 / 空隙 / Resize
ctest --test-dir build -R c_abi_preview      # 32 项：真正的 C TU，契约与诊断量

cd bindings/swift && swift test --disable-sandbox          # Previewer 契约 + golden 帧
./bindings/swift/run_smoke.sh                              # 链接级 + 空隙语义
cd apps/apple/packages/SharedUI && swift test --disable-sandbox
#   MetalPreviewViewTests：恒等映射逐字节 + golden 帧上屏链路非黑（像素级）
#   ⚠️ 读回必须 blit→Shared Buffer→contents；本机 getBytes 读不到 GPU 写入（P21）
```

实测（2026-10-02）：中心像素 `0,190,0,255` ≈ smptebars 真值 `0,188,0,255`；
t=1.0s 实际帧 pts = `120000/120000`（偏差 0）；连续 12 帧全部零拷贝。

## 10. Swift 侧装配（UIA-003，2026-10-03）

```
SwiftUI PreviewZone
  → MetalPreviewView（UIView/NSViewRepresentable，SharedUI/Editor/）
      → PreviewMTKView（MTKView，isPaused + enableSetNeedsDisplay，按需单帧）
          draw(in:):
            1. previewer.renderFrame(pts)            # 内核 seek+解码+导入+离屏绘制
            2. unsafeBitCast(handle, MTLTexture)     # 中性句柄 → 原生纹理（不 retain）
            3. PreviewFrameRenderer.blit(drawable)   # 恒等映射 GPU 拷贝 + present
```

要点：
- **Swift 绑定类型名是 `Previewer`**（不是 `Preview`，与 SwiftUI 撞名，见 pitfalls P22）。
- MSL 几何与 `pal/apple/shaders/blit_fullscreen_msl.h` **逐值一致**（uv(0,0)=左上），
  两侧必须同步改（SharedUI 像素级用例锁定）。
- 视图是「单帧按需渲染」；连续播放须由上层异步推进 pts，**不得**在视图内加渲染循环。
- `GetColorTexture` 现在返回**裸原生纹理**（id<MTLTexture>），不是 CqTexture* 包装
  （接口缺陷修复，见 pitfalls P20）；「导出用」与「SetTexture 用」两种句柄语义已
  在 pal/gfx.h 写清。
- 设备一致性（hypothesis，2026-10-02 本机实测）：内核与 MTKView 的设备同为
  `MTLCreateSystemDefaultDevice()` 的进程内缓存实例。
- 调试演示：`CQ_DEMO_VIDEO=<视频路径>` 环境变量（DEBUG 构建）启动即载入 5s 片段。

## 11. 验证（UIA-003 之后）
## 12. 读路径收口（UIA-009 子步骤 2，2026-10-03 完成）

**CQPreview 本地 Timeline/AssetRegistry 已退役。** 渲染输入 =
`IModelSnapshotProvider`（preview_renderer.h 定义的接口），生产实现
`SessionSnapshotProvider` 包装 `EditorSession::CurrentModelSnapshot()`。

- **装配**：`cq_preview_create(CQSession*, w, h)` —— 挂 session；session 无内建
  模型（注入自定义 ISessionState）返回 NULL。CQPreview **不拥有** session
  （Swift 侧 Previewer 强持有 Session，对象图保证顺序）。
- **一致性**：每次 RenderFrame 入口加载一次配对快照（Timeline+AssetRegistry
  同版本），本帧全程用同一快照渲染；session 线程再变更不影响本帧，下帧自然
  切新快照（最终一致）。
- **provider 缓存失效**：`asset_id → (FrameProvider, opened_path)`；素材重注册
  为新路径时关闭旧解码会话重建（防旧 demux/decoder 滞留）。
- **已删除的 ABI**：`cq_preview_register_asset` / `cq_preview_add_clip`
  （Swift Previewer 同步删除；装配唯一入口 = cq_session_*）。
- **生命周期**：preview 必须先于 session 销毁（C TU 用例有断言路径）。

### 媒体管线六问（cq-media-pipeline，2026-10-03）

1. **线程**：渲染仍在调用方线程（主线程同步单帧，既有取舍）；新增快照读取
   mutex 持锁 = 指针拷贝（纳秒级）；session 线程变更 + 发布（拷贝量线性于实体数）。
2. **时序**：RationalTime 全程不变；快照配对发布，无版本撕裂。
3. **内存**：快照最多存活 2~3 份（渲染即取即用）；导入纹理逐帧释放不变；
   provider 缓存上界 = 素材数，路径变更即重建。
4. **取消**：CancelToken 语义不变（本任务未触解码路径）。
5. **错误码**：素材缺失 kInvalidArgument、快照缺失 create 返回 NULL（诚实暴露）。
6. **一致性**：同 seek 请求结果不变；Android/ohos 无后端仍为 create 返回 NULL。

## 12. 相关

ADR-0011（core 调 PAL 工厂的隔离规则）、`docs/tasks/TASK-BIND-003.md`、
`.ai/modules/pal.md`、`.ai/modules/gfx.md`

---

# UIA-010 落地（2026-10-03）：播放时钟

`core/include/cq/preview/player_clock.h` —— **只算时间，不取帧不渲染**。
取帧渲染仍归 `PreviewRenderer`，两者由调用方串起来（`currentTime` → `render_frame`）。

| 主题 | 约定 |
|---|---|
| 时刻来源 | **墙钟的函数**：`t = anchor + (now - anchor_wall)`，误差不累积（不是帧数累加） |
| 量化 | 时刻恒为**整帧**（帧网格，29.97fps = 1001/30000），全程整数 |
| 线程 | 内部 mutex，可跨线程读；**时钟自己不跑线程**，由调用方按帧 `Tick()` |
| 状态 | kStopped / kPlaying / kPaused；**停止态时刻恒 0**（含播完自然结束） |
| 边界 | `Tick()` 判定：到时长末尾 → loop 开则回绕，否则停止回 0 |
| 边界来源 | `cq_session_timeline_duration`（Timeline::Duration）—— UI 不自己累加片段 |

C ABI：`cq_player_create/destroy/set_duration/set_loop/play/pause/stop/seek/
is_playing/current_time/tick` + `cq_session_timeline_duration`。
⚠️ `cq_player_is_playing` 返回 **0/1 数据**，不是状态码（P26）。

Swift：`Player` 类 + `Session.timelineDuration()`。
SharedUI：ViewModel 的 `togglePlayback/stopPlayback` + `Timer` 驱动（30Hz）。

⚠️ **MVP 未达标项**：取帧与渲染仍在**主线程**（Timer → setPlayhead → MTKView
按需渲染），帧率受单帧解码耗时限制，**未实测**。下一步把取帧/渲染挪到播放
线程，主线程只做 blit + present。

守卫：`ctest -R player`（core_player_clock 29 断言 + c_abi_player 33 断言）。
