# TASK-UIA-012：预览宽高比适配（letterbox / fit）

> 建立：2026-10-04。> ⚠️ 原取号 UIA-011，与另一开发机已推送的「相册素材导入」撞号，合并时改为 UIA-012。来源：HANDOFF-004 §5 第 4 项；`preview_renderer.h`「本期不支持」
> 清单第 3 条（宽高比适配）转正 —— 用户已明确将其列为下一个编码任务（「优先编码」）。
>
> **状态：✅ 已完成（2026-10-04，同会话收口）**。决策 = ADR-0018。
> 门禁：Debug 42/42、Release 42/42、preview_renderer 51 项、c_abi_preview 78 项、
> gfx_device 30 项（含用例 C）、swift 23/23、SharedUI ×3 20/20（见下文「执行记录」）。

```yaml
id:          UIA-012
layer:       跨平台（core/GFX/PAL）+ UI（SharedUI 装配，竖切）
goal:        预览不再「拉伸铺满」：PreviewRenderer 支持 FitMode（stretch/contain/cover），
             非同比例素材按模式适配画布，bar 区为黑（清屏色）
input:       [preview_renderer.h「不支持」清单, cq_sdk.h:281 注释, ADR-0013（线程归属）,
              UIA-010 后的渲染装配（泵线程 / 共享队列）]
output:      [GFX/PAL 编码器视口原语, PreviewRenderer FitMode, C ABI setter,
              Swift Previewer.setFitMode, SharedUI AppEntry 装配 contain,
              单测（像素断言）, preview.md / gfx.md / pal.md 回写, ADR-0018]
write_set:   core/include/cq/pal/gfx.h, core/include/cq/gfx/gfx_device.h,
             core/src/gfx/gfx_device.cpp, pal/apple/gfx_metal.mm,
             core/include/cq/preview/preview_renderer.{h,cpp},
             core/src/preview/cq_sdk_preview.cpp, core/include/cq/cq_sdk.h,
             bindings/swift/Sources/ChuanqiCut/Previewer.swift,
             apps/apple/packages/SharedUI/Sources/SharedUI/Editor/AppEntry.swift,
             tests/unit/test_gfx_device.cpp, tests/unit/test_preview_renderer.cpp,
             tests/unit/test_c_abi_preview.c
read_set:    core/include/cq/preview/preview_pump.h, core/src/gfx/*（其余）,
             pal/apple/blit_pass.mm, bindings/swift 其余, SharedUI 其余,
             docs/HANDOFF-004, .ai/modules/{preview,gfx,pal-apple}.md
deps:        []（无前置任务；相机链路写集边界明确避开 cq_sdk.h / SharedUI，无冲突）
acceptance:
  - 默认行为不变：FitMode 默认 kStretch，既有全部像素断言不改一字通过
  - contain：16:9 素材（gf_1080p_h264.mp4）进 256x256 画布 → 上下各 ~56px 黑 bar，
    内容带像素 = smptebars 真值；bar 区像素 = 清屏色 (0,0,0,255)
  - cover：同素材同画布 → 无 bar、整幅被内容覆盖（画布边缘无清屏色）
  - stretch（默认）：同素材 → 整幅被拉伸内容覆盖（既有断言保持）
  - 非法 FitMode 经 C ABI 返回 kInvalidArgument(7000)
  - 视口原语有独立像素断言（gfx_device 用例：视口外为清屏色）
  - 泵线程模型不破坏：fit 状态为 atomic，主线程 setter 与泵线程 RenderFrame 无竞争
verification:
  - ctest --test-dir build -R gfx_device
  - ctest --test-dir build -R preview_renderer
  - ctest --test-dir build -R c_abi_preview
  - ./tools/build/build_core.sh --platform=apple --config=Debug --test（及 Release）
  - XCFramework 重建 + prepare.sh + swift test（bindings/swift 23 用例）
  - cd apps/apple/packages/SharedUI && swift test --disable-sandbox（20 用例）
risk:        cq_sdk.h 高冲突文件 —— 已核对相机链路写集边界（HANDOFF-004 §1），其避开
             cq_sdk.h 与 SharedUI，本任务期间无并行写者；PAL ICommandEncoder 为冻结
             接口，扩展必须 additive 且记录 ADR-0018
parallel:    false（本会话单任务串行）
```

## 背景

预览离屏画布（`cq_preview_create(w,h)`）与素材宽高比不同时，当前实现是**拉伸铺满**
（IBlitPass 全屏拷贝，无任何适配）—— 9:16 竖拍素材进 16:9 画布会变形。这是
`preview_renderer.h` 头注释里明示的「本期不支持」项，本任务把它转正。

## 实现要点

**接缝选择（ADR-0018 的核心决策）**：fit = 纯几何映射，三种模式都能用
「视口矩形」一个原语表达：

| FitMode | 视口 |
|---|---|
| kStretch（默认，现状） | 整个 RT |
| kContain | 源比例内切矩形居中（≤RT），bar 区不清屏色都不画 → 天然 letterbox |
| kCover | 源比例外接矩形居中（≥RT），超出部分被光栅化自动裁掉 |

- 视口原语加在 **GFX `IGfxEncoder` + PAL `ICommandEncoder`**（additive），
  Apple 实现直映射 `MTLRenderViewport`（原点=target 左上，z 用 {0,1}，文档写清）。
  **不动 IBlitPass 接口与 MSL**，RT→drawable 恒等 blit 及其与 SharedUI 的
  逐值锁定不变量不受影响。
- fit 几何计算在 `PreviewRenderer::RenderFrame`（`frame.video.width/height` 为源，
  已由解码器填充；0 值诚实退化 kStretch）；FitMode 存 `std::atomic<int>`，
  主线程 setter 与泵线程渲染读无竞争（泵模型不破坏）。
- 清屏色黑色 + 视口外不写 → bar 即黑，无需第二 pass。
- ABI：`cq_preview_set_fit_mode(CQPreview*, int32_t)`（0=stretch 1=contain 2=cover）。
- 产品装配：SharedUI AppEntry 创建后设 contain（默认仍 stretch，向后兼容与
  golden 断言不破）。

## 媒体管线六问（cq-media-pipeline）

1. **线程**：不改取帧/解码线程模型。新增 setter（主线程）↔ 渲染读（泵线程）
   经 atomic；视口在泵线程编码时设置，无跨线程 GPU 状态。
2. **时序**：RationalTime 路径不动；fit 只影响几何映射。
3. **内存**：零新增分配路径（视口是栈上 4 个 float）。
4. **取消**：CancelToken 语义不动。
5. **错误码**：非法 mode → kInvalidArgument；源尺寸未知 → 诚实退化 stretch（非错误）。
6. **一致性**：预览与导出同源（同一 RenderFrame 映射），红线 #9 不破。

## 验收

见 yaml acceptance。逐条：stretch 断言 = 既有用例一字不改全绿；contain/cover =
test_preview_renderer 新段（golden 16:9 素材 + 256x256 画布，bar/内容带像素断言）；
视口原语 = test_gfx_device 新段；非法值 = test_c_abi_preview 新断言。

## 执行记录（2026-10-04）

- **子步骤 1（契约）✅**：PAL `ICommandEncoder::SetViewport`（additive）+
  GFX `IGfxEncoder::SetViewport` 转发 + Metal `MTLViewport` 直映 + gfx_device
  用例 C（视口 (16,16,32,32) 内红/黄、外清屏黑）—— 30 项全过。
- **子步骤 2（实现+装配）✅**：`FitMode`（Config 字段 + atomic setter）、
  `ComputeFitViewport`、C ABI `cq_preview_set_fit_mode`、Swift `Previewer.setFitMode`
  （`FitMode` 枚举）、SharedUI AppEntry 显式 contain。preview_renderer [8]
  contain/cover 像素断言 + c_abi 契约段 —— renderer 51 项、c_abi 78 项全过。
- **实踩坑（已写进 preview.md §6.5）**：源尺寸必须在
  `provider->ReleaseFrame(frame)` **之前**捕获 —— lease 归约会把 frame 重置为
  `MediaFrame{}`，首版在归还后读 `frame.video.width` 得 0，fit 被诚实退化成
  stretch（像素断言抓到，诊断打印定位）。
- 门禁：Debug 42/42、Release 42/42；XCFramework 三切片重建 + prepare 后
  swift 23/23、SharedUI 全量 ×3 20/20（与 P33 修复 2 同轮验证）。
- **未实测项**：fit 为每帧一次整数几何计算 + 一次视口设置，无可测量性能项，
  baselines 不新增条目（明确标注不适用）。

## 回写

- 接口变更 → `.ai/modules/gfx.md`（视口原语）、`.ai/modules/pal-apple.md`、
  `.ai/modules/preview.md`（「不支持」清单移除该条 + FitMode 说明）
- 决策 → `docs/decisions/ADR-0018-预览宽高比的视口接缝.md`
- 本文件子步骤状态与写集实际核对
- 新坑 → `.ai/memory/pitfalls.md`；无新实测性能数字则 baselines 不动（fit 为
  一次性每帧整数计算，无可测量项，明确写「未实测/不适用」）
