# 模块：GFX 抽象与平台后端

**边界**：
- 接口定义（跨平台层，GFX-001）：`core/include/cq/gfx/*.h`
- 跨平台实现（RENDER-001 / GFX-002 阶段）：`core/src/gfx/`
- 平台实现（PALA-/PALD-）：`pal/<platform>/gfx_*`

**权威契约**：`docs/specs/ARCH-003`（薄 GPU 抽象 + Shader 策略）、
`docs/specs/PAL-接口契约.md` §4.1（12 概念映射）。
**本文件**：模块运行记录 + 设计取舍摘要（GFX-001 落地于 2026-09-25）。

## 两层架构（2026-09-25 确立，关键边界）

GFX 抽象分两层，混淆会导致 RenderGraph 直接依赖平台类型，必须写清：

| 层 | 头文件 | 是什么 | 谁实现 |
|---|---|---|---|
| **PAL GFX HAL** | `core/include/cq/pal/gfx.h`（CORE-006 冻结） | 平台能力 HAL：逐概念 1:1 映射 Metal/Vulkan/GLES，越薄越好 | 各平台后端 PALA-001 / PALD-001 / PALD-002 |
| **GFX 编排层** | `core/include/cq/gfx/*.h`（GFX-001） | RenderGraph 之上的编排门面：池化 / 预算 / 帧执行 / 导入编排，跨平台 | 跨平台 core 实现（RENDER-001 / GFX-002 阶段） |

- PAL `IGraphicsDevice` = **平台能力**（Metal/Vulkan/GLES 进代码库的唯一入口）。
- GFX `IGfxDevice` = **上层编排**（持有 PAL 设备，向 RenderGraph 暴露渲染 API）。
- RenderGraph（RENDER-001）**只依赖 GFX 层**（`IGfxDevice` / `IGfxEncoder` / `FrameContext`），不直接依赖 PAL 编码器类型。
- 把「池化 / 预算 / 帧执行 / 导入编排」放 GFX 层，避免每个平台后端重复实现（ARCH-003 §2.3 硬约束 2：显存分配不隐藏，TexturePool 在 core 统一池化，后端只真实分配）。

## 12 概念映射表（对齐 ARCH-003 §2.2；GFX 层如何呈现每个 PAL 概念）

| PAL 概念 (`pal/gfx.h`) | GFX 层呈现 (`gfx/*.h`) |
|---|---|
| Device `IGraphicsDevice` | `IGfxDevice::PalDevice()` 持有并复用 |
| CommandQueue / CommandBuffer / Fence | 由 `IGfxDevice::RenderFrame` 内部隐式管理（不向 RenderGraph 暴露） |
| Encoder `ICommandEncoder` | `IGfxEncoder`（RenderNode 只绑定到此，不碰 PAL） |
| Texture `ITexture` | `IGfxDevice::AcquireTexture`（经 `ITexturePool` 池化） |
| Buffer `IBuffer` | 经 PAL 创建后由 RenderNode 直接绑定 |
| RenderTarget `IRenderTarget` | `IGfxDevice::CreateRenderTarget`（1:1 复用） |
| Pipeline / ShaderModule / Sampler | `IGfxDevice::Create*` 委托 PAL |
| ExternalImage `INativeImageImporter` | `IGfxDevice::CreateNativeImageImporter`（GFX-003 接入点，委托 PAL） |

## GFX-001 交付内容（接口，零实现）

| 文件 | 内容 |
|---|---|
| `gfx/gfx_device.h` | `FrameContext`（每帧上下文）、`IGfxEncoder`（渲染编码器抽象，对应 PAL ICommandEncoder）、`IFrameEncoderClient`（帧编码回调 seam，避免 GFX 反向依赖 RENDER）、`ITexturePool`（GFX-002 钩子）、`IGfxDevice`（渲染后端门面，GFX-001 核心）、`CreateGfxDevice` 工厂签名 |
| `gfx/gfx.h` | 聚合头 |

## 为下游留的接口位置

- **GFX-002（TexturePool + 预算）**：实现 `ITexturePool`（write_set `core/src/gfx/pool.*`），
  接 `IGfxDevice::SetTexturePool`；预算接 CORE-004 `TextureBudget`（字节/张数上界，超预算
  `Acquire` 返回 `kResourceExhausted`）。
- **GFX-003（INativeImageImporter）**：接口已在 PAL `pal/gfx.h` 定义（含 `out_cpu_fallback`
  退化语义）；GFX 层仅通过 `IGfxDevice::CreateNativeImageImporter` 暴露接入点，委托 PAL 实现。

## 硬约束满足方式

1. **零平台类型**：仅用 base 层 + PAL 的 opaque 指针句柄；无 Metal/Vulkan/GLES/AVFoundation
   类型，无平台头 include。门禁脚本 `tools/pal/check_pal_headers.py` 已扩展覆盖 `cq/gfx/`
   （见 `pal_header_gate` ctest）。
2. **零 FFmpeg 类型**：GFX 层不涉及任何 AV* 类型。
3. **统一 base 类型**：时间 `RationalTime`、错误 `Status`、长任务 `CancelToken`、资源 `PalPtr`。
4. **`-Werror` 零警告**：编译验证 TU `tests/unit/gfx_headers_compile.cpp` 在
   `-Wall -Wextra -Wconversion -Wshadow -Wold-style-cast` 下干净编译。
5. **内核禁用异常**：无 `throw`，错误一律 `Status`；`kCancelled` 非错误（取消是独立停止信号）。

## 待评审 / 风险（已标出）

- `IGfxDevice` 默认实现尚未落地（RENDER-001 / GFX-002 阶段，跨平台 core）——本任务只定义接口。
- 帧执行 seam 用回调 `IFrameEncoderClient` 解 GFX↔RENDER 循环依赖；若评审倾向把 RenderGraph
  直接拿 PAL 编码器，需改接口（但会破坏分层，不推荐）。
- `RenderFrame` 为 flush 模式（预览主线程）。导出/并行的多缓冲模式预留（未来可加 `RenderFrameAsync`）。

## 验证（2026-09-25 真跑）
```bash
CMAKE_BIN=/Users/zhuning/.workbuddy/binaries/cmake/CMake.app/Contents/bin/cmake
$CMAKE_BIN -S . -B build -DCMAKE_BUILD_TYPE=Debug
$CMAKE_BIN --build build -j4
$(dirname $CMAKE_BIN)/ctest --test-dir build   # 原 8 + gfx_headers_compile + media_* + 门禁
```
- 门禁自测：`check_pal_headers.py` 对 `cq/gfx/` / `cq/media/` 零违规（EXIT=0）。
- 编译 TU 固化：opaque 指针、IPalResource 继承、base 类型契约、SeekPolicy 等。

## 相关
ADR-0002、ARCH-003 §2/§3/§7、PAL-接口契约 §4.1、BACKLOG GFX-001/002/003 / PALA-001 / RENDER-001

---

# 2026-10-02 追加（BIND-003 子步骤 4/5 / GFX-002 之后）

## `IGfxEncoder` 新增 `PalEncoder()`

```cpp
virtual ICommandEncoder* PalEncoder() = 0;   // 返回底层的 PAL 编码器
```

为什么需要：某些 pass（如 `IBlitPass`）**必然**由平台原生 shader 实现，按红线 #6
只能落在 PAL 层；而 PAL 不能反向依赖本层的 `IGfxEncoder`。故这类 pass 收 PAL 的
`ICommandEncoder`，由本方法取出后传入 —— 与既有的 `IGfxDevice::PalDevice()` 同一套路。

⚠️ 这是**逃生口**，不是常规路径。日常 RenderNode 仍应只用 `IGfxEncoder` 的 GFX 方法
（`SetPipeline` / `SetTexture` / `Draw` …），不要绕过。

## `IGfxEncoder` 新增 `SetViewport`（UIA-011 / ADR-0015，2026-10-04）

```cpp
virtual void SetViewport(float x, float y, float width, float height) = 0;
```

PAL `ICommandEncoder` 同名方法（additive 扩展，语义见 pal/gfx.h 注释）的 1:1 转发。
约定：**像素、原点 = target 左上**、矩形可大于目标（超出被光栅化丢弃）、
**不调用 = 整目标**（Metal 默认 viewport 即 framebuffer，故 stretch 路径
完全不触碰视口状态，与引入前逐字节一致）。Apple 实现直映射 `MTLViewport`
（z 用 {0,1}）；未来 GLES `glViewport` / Vulkan `vkCmdSetViewport` 天然对应。

引入缘由：预览宽高比适配（FitMode stretch/contain/cover 三种模式都能用
「视口矩形」一个原语表达，不需要 shader 分支/uniform/第二 pass）。
备选取舍（blit uniform / UI 层适配）见 ADR-0015。
验收：`ctest -R gfx_device` 用例 C（视口内外像素断言）+ `preview_renderer` [8]。

## `IBlitPass` 已移出本层

原 `core/include/cq/gfx/blit_pass.h` 的 `IBlitPass` 已移入 **`pal/gfx.h`**，
工厂改为 `cq::CreateBlitPass(IGraphicsDevice*, TextureFormat, PalPtr<IBlitPass>&)`。
理由见 `.ai/modules/pal.md`（判断规则：抽象放哪层，看实现必然落在哪）。

## 预览渲染器（新增 preview 层）

`core/include/cq/preview/preview_renderer.h` —— 见新建的 `.ai/modules/preview.md`。
它位于 GFX 之上、UI 之下，是「时间线在 pts 这一刻画面是什么」的收口。
