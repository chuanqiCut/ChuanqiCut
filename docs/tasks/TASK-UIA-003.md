# TASK-UIA-003：MTKView 预览视图嵌入

> 日期：2026-10-01（完成：2026-10-03）
> 状态：**已完成（首里程碑：MTKView 嵌入 + 真实帧上屏链路）**
> 前置（MODEL-001 / GFX-002 / BIND-003 子步骤 1~5）均已就绪，走方案 A2。
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

## 四、验收方式（2026-10-03 实测回填）

- **像素级（SharedUI 测试，macOS 实跑）**：
  - `testIdentityBlitPreservesOrientationAndChannels` —— 已知源纹理（顶红底蓝）
    blit 后逐字节断言：不上下颠倒、通道不错位（锁定与 PAL blit 同源的几何约定）。
  - `testGoldenFrameRendersThroughDisplayPath` —— Previewer 渲染 golden 素材
    0.5s → 中性句柄 reinterpret → blit 到可读纹理 → 非黑像素断言（预览区
    非黑屏的像素级证据，替代 GUI 截图：XCTest 无窗口宿主，drawable 机制不可靠）。
- **内核门禁**：Debug 34/34、Release 34/34（含 `GetColorTexture` 接口缺陷修复）。
- **绑定层**：`swift test` 13/13（Previewer 契约 6 用例，含 `lastFramePts` 语义）；
  `run_smoke.sh` PASSED。
- **macOS**：`xcodebuild build` SUCCEEDED（Swift 告警 0）；带
  `CQ_DEMO_VIDEO` 启动冒烟：进程存活、干净退出。
- **iOS**：`-sdk iphoneos` 编译 SUCCEEDED；真机验证待设备（本机无模拟器运行时）。

> 诚实说明：App 级「预览区非黑屏」由 SharedUI 像素级用例证明（同一代码路径）；
> GUI 冒烟只验证「启动 + 渲染不崩溃」，不做截图断言。

---

## 五、写集（实际落地）

| 文件 | 层 |
|---|---|
| `bindings/swift/Sources/ChuanqiCut/Previewer.swift` + `Time.swift` | BIND（Swift 投影） |
| `bindings/swift/Package.swift` / `run_smoke.sh`（链接清单，P23） | BIND |
| `core/include/cq/pal/gfx.h` + `pal/apple/gfx_metal.mm`（GetColorTexture 缺陷修复，P20） | PAL |
| `apps/apple/packages/SharedUI/Sources/SharedUI/Editor/PreviewFrameRenderer.swift` | UIA |
| `apps/apple/packages/SharedUI/Sources/SharedUI/Editor/MetalPreviewView.swift` | UIA |
| `apps/apple/packages/SharedUI/Sources/SharedUI/Editor/PreviewZone.swift` / `EditorView.swift` / `AppEntry.swift` | UIA |
| `apps/apple/{mac,ios}` App 入口（DEBUG 冒烟钩子） | App |
| `bindings/swift/Tests/` + `apps/apple/packages/SharedUI/Tests/` | 测试 |

> C ABI 本体（`cq_sdk.h`）在子步骤 5 已就绪，本任务**未改动**。
