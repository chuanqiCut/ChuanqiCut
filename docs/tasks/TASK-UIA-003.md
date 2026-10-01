# TASK-UIA-003：MTKView 预览视图嵌入

> 日期：2026-10-01
> 状态：**阻塞 —— 前置依赖未就绪，已调研清楚，待传哲决策**
> 依赖：UIA-002 ✅、PALA-001 ✅、PALA-002 ✅
> 验收：预览画面不经 UI 合成路径（MTKView 直接绘制）

---

## 一、调研结论：A 路径（先扩展 C ABI 暴露渲染接口）卡在哪

传哲选择「先扩展 C ABI 暴露渲染接口，再接真实画面」。调研后发现，
**C ABI 不是第一道关卡**，真正的阻塞在更下面两层。

### 阻塞 1：PAL `RenderTargetDesc` 无法接纳外部 drawable

`core/include/cq/pal/gfx.h:71`：

```cpp
struct RenderTargetDesc {
    uint32_t width = 1;
    uint32_t height = 1;
    TextureFormat color_format = TextureFormat::kRGBA8;
};
```

**没有「外部原生纹理 / drawable」字段**。而 MTKView 的 `currentDrawable.texture`
必须由 MTKView 自己持有 —— 内核拿不到它，也就无法把渲染目标指向它。

`GraphicsDeviceDesc` 有个 `NativeImageHandle surface`（注释写"如 CAMetalLayer 内容"），
但那是**设备级**的可选字段，不是每帧 render target，且当前 `gfx_metal.mm` 未使用该字段。

### 阻塞 2：GFX 编排层未实现，预览只能走 PAL 直连

- `core/src/gfx/` **不存在** → `IGfxDevice`（gfx_device.h）只有接口声明，
  文件头明确写着"本任务只定义接口，不实现（实现由 RENDER-001 / GFX-002 阶段落地）"
- `pal/apple/gfx_metal.mm` **已实现**（PALA-001）
- 因此预览若现在做，只能直接调 PAL（`CreateGraphicsDevice` → `ICommandEncoder`），
  绕开尚未存在的 RenderGraph。这是阶段性可接受，但**必须在 RenderGraph 落地后回切**。

### 阻塞 3：即使接口通了，也没有真实帧可显示

预览要显示"当前播放头的画面"，需要：

| 前置 | 任务 | 状态 |
|---|---|---|
| 时间线模型（当前有什么片段、播放头在哪） | MODEL-001 | ❌ 未做 |
| 解码出该时刻的帧 | PALA-011 硬解 | ✅ 已实现（但未接入 session） |
| CVPixelBuffer → GPU 纹理（零拷贝） | PALA-002 | ✅ 已实现（同样未接入） |

**结论：就算把 C ABI 渲染接口做完，预览区也没有真实视频帧可显示** ——
它最多只能渲染一个纯色/测试图案，本质上还是"空壳"。

---

## 二、业界的通行解法（不走 RPC 式像素搬运）

渲染引擎渲染到**自己的离屏纹理**，再把它 blit / draw 到 MTKView 的 drawable。
两种落地方式：

| 方案 | 做法 | 代价 |
|---|---|---|
| A1 扩展 PAL | `RenderTargetDesc` 增加外部原生纹理字段，内核直接渲染到 drawable | 改动 PAL 冻结接口（CORE-006），需 ADR |
| A2 离屏 + 导出句柄 | 内核渲染到离屏 RT，C ABI 把结果纹理以**中性句柄**暴露给 Swift，Swift 侧 blit 到 drawable | 需新增 C ABI 导出接口；每帧一次 GPU blit（可接受，非 CPU 拷贝） |

A2 不破坏 PAL 冻结接口，代价更小，**建议走 A2**。

⚠️ 无论哪条，**都不要**用"读回像素 → Swift 再上传"的路子
（即 `gfx_metal_internal.h` 的 `ReadRenderTargetPixels`）：那是 CPU 往返，
每帧一次会直接毁掉预览帧率，只该出现在测试里。

---

## 三、建议的执行顺序（需传哲确认）

```
1. MODEL-001 时间线模型        ← 让预览"有东西可显示"
2. GFX-002 / RENDER-001        ← core/src/gfx 落地（或明确预览直连 PAL 的阶段性方案）
3. C ABI 预览接口（方案 A2）    ← cq_preview_create / render / export_texture
4. UIA-003 MTKView 嵌入        ← SharedUI 内 UIViewRepresentable / NSViewRepresentable
```

若坚持先做 3+4（接口先行），则预览区只能渲染测试图案，
需在代码与文档中**明确标注"真实帧待 MODEL-001 接入"**，不得伪装成已完成。

---

## 四、验收方式（待实现后填）

- CTest：离屏渲染一帧并读回像素断言颜色（同 PALA-001 测试手法）
- macOS：`xcodebuild build` + 启动冒烟，预览区确认非黑屏
- iOS：真机（iPhone 17 Pro）验证；本机无模拟器运行时，只能出代码

---

## 五、写集（预分配，待启动）

| 文件 | 层 |
|---|---|
| `core/include/cq/cq_sdk.h` + `core/src/cq_sdk.cpp` | BIND（C ABI 扩展） |
| `core/src/gfx/preview.cpp`（或并入 cq_sdk.cpp） | 内核 |
| `apps/apple/packages/SharedUI/Sources/SharedUI/Editor/MetalPreviewView.swift` | UIA |
| `apps/apple/packages/SharedUI/Tests/SharedUITests/` | UIA 测试 |
