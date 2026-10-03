# HANDOFF-003：编码阶段会话交接

> 建立：2026-10-02
> 覆盖：2026-09-29 ~ 2026-10-02（多 session 协作）
> 前置阅读：`.ai/source/AGENTS.root.md`（真源）、`docs/HANDOFF-002-*.md`（更早的上下文）

新会话**先读本文件 + `.ai/source/AGENTS.root.md`**，再动手。

---

## 1. 当前项目状态

| 环节 | 任务 | 状态 |
|---|---|---|
| 内核 | CORE-007 能力查询实现 | ✅ |
| 内核 | CORE-008 线程模型与队列骨架 | ✅ |
| 内核 | CORE-009 EditorSession 门面与快照 | ✅ |
| 绑定 | BIND-001 `cq_sdk.h` 纯 C ABI 冻结 | ✅ |
| 绑定 | BIND-002 Swift 绑定层（SPM） | ✅ |
| 基建 | INFRA-009 iOS/macOS 双工程 + CocoaPods 源码集成 | ✅ |
| 模型 | MODEL-001 时间线数据模型 | ✅ |
| 渲染 | GFX-002 `IGfxDevice` 直连 PAL | ✅ |
| 媒体 | BIND-003 子步骤 1 素材表 | ✅ |
| 媒体 | BIND-003 子步骤 2 取帧链路验证 | ✅ |
| 预览 | 子步骤 3 纹理导入（零拷贝） | ✅ **PALA-002 已覆盖**（2026-09-26） |
| 预览 | 子步骤 4 预览渲染器 | ✅ |
| 预览 | 子步骤 5 C ABI 封装 | ✅ |
| UI | 子步骤 6 / UIA-003 MTKView 嵌入 | ✅（2026-10-03，像素级验收） |
| 预览 | Swift 绑定（Previewer + RationalTime） | ✅（2026-10-03） |
| 模型 | MODEL-002 Command/CommandHistory（Undo/Redo） | ✅（2026-10-03，门禁 35/35） |
| UI | UIA-004 时间线自绘视图（Canvas 单次绘制） | ✅（2026-10-03，0.663ms/500 片段） |
| 模型 | UIA-009 子步骤 1：Session 级模型状态 + 查询 ABI | ✅（2026-10-03） |
| **下一步** | **UIA-009 子步骤 2（预览收口）→ 子步骤 3（导入 UI）** | ⏭️ **下一步** |
**门禁**：`Debug 36/36`、`Release 36/36`（含 c_abi_session）；Swift 绑定 **16/16**；SharedUI **10/10**（含像素级与布局性能）；
macOS App 编译 SUCCEEDED（Swift 告警 0）+ 启动冒烟通过；iOS `-sdk iphoneos` 编译 SUCCEEDED。

**本轮新增的架构决策**：
- **ADR-0011**（core 调用 PAL 工厂的隔离规则）—— core 从不调 PAL 工厂的惯例被开口子，
  条件是**隔离在独立 TU**（静态库按 archive member 拉符号）。
  实证守卫：`cq_tests_c_abi` 只链 cq_core、不链 cq_pal_apple 必须通过。
- **判断抽象放哪层的规则**：看实现必然落在哪。只能用平台原生能力实现的
  （shader 源码 / 平台 SDK）→ 抽象放 PAL（如 `IBlitPass` 已从 GFX 层移到 `pal/gfx.h`）。
命令：`./tools/build/build_core.sh --platform=apple --config=Debug --test`

> ⚠️ 旧版 HANDOFF 把「子步骤 3 纹理导入」标为下一步，是**错的**：
> PALA-002（2026-09-26，commit 76fce6b）已做完零拷贝导入，
> `pala_native_image` 用例含 IOSurface ID 一致性 + 真实解码帧渲染读回 +
> 零拷贝/CPU 退化耗时代差（≈1400×）。子步骤 3 无需再做，直接进 4。

---

## 2. 下一步：UIA-004（时间线自绘）→ UIA-009（素材导入）

子步骤 6 / UIA-003 已完成（2026-10-03）：
- Swift 绑定 `Previewer`（`bindings/swift/Sources/ChuanqiCut/Previewer.swift`；
  ⚠️ 不叫 `Preview`，与 SwiftUI 撞名，pitfalls P22）+ `RationalTime`（Time.swift）。
- SharedUI `MetalPreviewView`（MTKView 直绘，单帧按需渲染）+ `PreviewFrameRenderer`
  （恒等映射 blit，MSL 与 PAL blit 几何逐值一致，**两侧不得单独改**）+ `PreviewZone` 接入。
- 接口缺陷修复：`IRenderTarget::GetColorTexture` 曾返回 CqTexture* 包装而非裸
  id<MTLTexture>，契约承诺 reinterpret 但首用即崩（pitfalls P20）。
- 调试演示：DEBUG 构建设 `CQ_DEMO_VIDEO=<视频>` 环境变量启动即有画面。

**MODEL-002 已完成（2026-10-03）**：`core/include/cq/command/command.h` +
`core/src/command/command.cpp`，6 命令覆盖 Timeline 变更面，`RestoreTrack/RestoreClip`
支持原 id 回放；门禁 35/35。语义与不变量见 `.ai/modules/model.md`。
⚠️ BACKLOG 编号订正：UIA-005 = 片段拖拽/裁剪（依赖 UIA-004 + MODEL-002），
「素材导入 UI」不是 BACKLOG 现有编号，归入 UIA-004/005 一起做。

接下来（按优先级）：
1. **UIA-009 子步骤 2：预览收口** —— PreviewRenderer 输入切到
   `EditorModelState::CurrentTimeline()` 不可变快照，CQPreview 本地模型退役；
   **实现前跑 cq-media-pipeline 专项分析**（线程/时序/取消）。
2. **UIA-009 子步骤 3：导入 UI** —— 文件选择（NSOpenPanel/fileImporter）→
   registerAsset → addClip Command → 时间线/预览可见。
3. **UIA-005 拖拽/裁剪交互**：结束提交 Move/Trim Command；拖拽连续命令合并
   （coalescing）届时设计；实帧率真机验证。
4. **UIA-008 Undo/Redo 入口**（含 undo/redo 的 C ABI）。
5. **播放驱动**：异步任务推进 playhead（主线程同步解码不可用于连续播放）。
6. letterbox / fit、多轨合成（等 RENDER-001）。

⚠️ Swift 侧**绝不要**「读回像素再上传」：每帧一次 CPU 往返会直接毁掉预览帧率。
   直接把 `void*` 句柄 reinterpret 成 `MTLTexture` 交给 MTKView 绘制。

⚠️ **绝不要**走"读回像素 → Swift 再上传"：CPU 往返每帧一次会直接毁掉预览帧率。
    `gfx_metal_internal.h` 的 `ReadRenderTargetPixels` 只该出现在测试里。

---

## 3. 已打通的关键链路（硬证据）

```
时间线 pts → FindClipAt → asset_id → AssetRegistry → MediaSource
   → SystemFrameProvider(PALA-010 demuxer + PALA-011 VideoToolboxDecoder)
   → Seek(kExact) + AcquireFrame → MediaFrame(CVPixelBuffer)
```

实测（`tests/golden/frames/gf_1080p_h264.mp4`）：
```
t=0.5s → 1920x1080, pts=60000    (0.5s × 120000，精确对应)
t=2.0s → 1920x1080, pts=240000
```
不同时刻取到不同帧 → 精确 seek 真生效。

GFX 渲染同样有像素级证据：
```
清屏 → 中心像素 (0,0,0,255)
采样 2x2 四色纹理 → 四角 红/绿/蓝/黄（uv 未上下颠倒）
```

---

## 3b. 预览渲染器（子步骤 4）装配形状

```
cq::CreateGraphicsDevice(PAL) → cq::CreateGfxDevice(pal, gfx)   // GFX 接管 PAL 所有权
cq::apple::CreateBlitPass(gfx, kRGBA8)                          // 全屏拷贝（MSL）
cq::apple::CreateAppleFrameProviderFactory()                    // PALA-010+011 装配
        ↓
PreviewRenderer(gfx, blit, factory, &timeline, &assets, cfg{256,256,kRGBA8})
        ↓
RenderFrame(pts) → out_texture（中性句柄）
```

`PreviewRenderer` 依赖全是**注入的非拥有指针**；它自己持有 importer / 离屏 RT /
asset_id→provider 映射 / 上一帧导入的纹理（逐帧 `ReleaseTexture`）。

可观测量（诊断用，不是渲染结果）：`LastHitClip()` / `LastImportCpuFallback()` /
`LastSourceTime()` / `LastFramePts()`。
⚠️ `LastFramePts()` 是**唯一**能证明「渲染的确实是 t 时刻那一帧」的量——
彩条这类静态素材的像素相同，无法区分「取对了帧」与「复用旧帧」。

## 3c. C ABI 预览（子步骤 5）为什么放 core、以及隔离手段

矛盾：C ABI 门面要装配预览就得拿平台能力，但 **core 从不调 PAL 工厂**
（全库 grep 确认：调用只发生在 tests/ 与 pal/）。若按平台分裂实现 C ABI，
`cq_sdk.h` 作为「唯一对外边界」就废了。

解法：
- `IBlitPass` + `CreateBlitPass` 移入 **`pal/gfx.h`**（它必然是平台原生 shader，
  本就属 PAL；且 PAL 不能反向依赖 GFX，故 `IGfxEncoder` 补 `PalEncoder()` 逃生口）。
- 落地 `pal/media.h` 里**悬空 7 天**的 `CreateFrameProvider`；core 侧
  `PalFrameProvider` 把 PAL `IFrameProvider` 适配成 core `FrameProvider`。
- 调 PAL 工厂的 TU（`pal_frame_provider.cpp` / `cq_sdk_preview.cpp`）**必须独立**：
  静态库按 archive member 粒度拉符号，独立 TU 才能保证「不用预览的目标」
  不被牵出 PAL 依赖。实证：`cq_tests_c_abi` 只链 `cq_core`、不链 `cq_pal_apple`，
  仍链接通过并运行成功。

诊断量（C 侧可查）：`cq_preview_last_hit_clip` / `last_cpu_fallback` / `last_frame_pts`。
⚠️ `last_frame_pts` 是**唯一**能证明「渲染的确实是 t 时刻那一帧」的量——
静态彩条像素相同，无法区分「取对了帧」与「复用旧帧」。

## 4. 本机环境（已配置完成）

| 项 | 位置 / 版本 |
|---|---|
| Ruby | `~/.rubies/ruby-3.4.11`（`.zshrc` 已配 PATH） |
| CocoaPods | 1.17.0 |
| xcodegen | `~/tools/xcodegen/` |
| 模拟器 | **无 iOS 运行时**（`xcrun simctl list runtimes` 为空）→ iOS 只能真机，或用 `-sdk iphoneos` 编译 |

⚠️ 系统 Ruby 2.6 仍在 `/usr/bin/ruby`，但不要用它装 gem（`~/.gem` 有权限限制）。
   新版 CocoaPods 依赖链（ffi 要 Ruby≥3.0、drb 要 ≥2.7）在 2.6 下装不了。

---

## 5. 关键坑（近期新增，详见 `.ai/memory/pitfalls.md`）

- **P7** SPM 本地包身份取**目录名**（`bindings/swift` → `package: "swift"`），不是 Package.swift 里的 name
- **P8** `*State(wrappedValue:)` 是非 throwing autoclosure，包不住 `try` → "先建值后包装"
- **P9~P13** CocoaPods 集成类（hmap 基名劫持 / `module_map` 会被 pod module 覆盖 / 消费方 module 可见性 / Gemfile.lock 必须入库 / iOS 分支首次编译才暴露的 bug）
- **`CreateFrameProvider`（PAL）只有声明没实现** —— PALA-011 实现的是 core 层的 `IFrameDecoder`（`VideoToolboxDecoder`），要走 `SystemFrameProvider` 编排。链接期会报 symbol not found
- **`VertexAttribute{location, offset, format}`** 的 location 必须对应 MSL `[[attribute(n)]]`，写错会让 `CreatePipeline` 失败
- **SSO 陷阱** `MediaSource` 只存 `const char*` 裸指针 → 素材表必须用**堆上** `unique_ptr<string>` 保管路径
- **"只声明未接入"** 本项目踩过 4 次：`cq_build_anchor`、能力查询实现、BIND-001 实现、
  以及 `test_media_decode_apple.cpp`（已修）。**写完测试要确认它真的接进了 CMake**

---

## 6. 工程结构（INFRA-009 之后）

```
apps/apple/
├── ios/     project.yml / Podfile / Gemfile / Gemfile.lock / ChuanqiCut.xcodeproj(产物)
├── mac/     同上（两套独立，各自 pod install）
└── packages/SharedUI/
    ├── SharedUI.podspec   ← App 集成真源（pod）
    └── Package.swift      ← 仅作 swift test 测试宿主（不进 App 依赖链）
```

⚠️ 两者是同一份源码的两种消费方式，**不可同时进 App 依赖链**（重复符号）。
SDK 默认 `Source` subspec（现场编译 C++20 + ObjC++ PAL，免除"先打包 xcframework"的前置）。

---

## 7. 待定项（不要擅自决定）

1. **License**：FFmpeg LGPL 静态链接处置未定（目标文件归档 / 商业授权 / 动态链接 / 不接入）。podspec 里是 `Proprietary` 占位，需 owner + 法务拍板
2. **精确 seek 语义**：`frame_provider.h` 标注「展示区间归属 vs PTS 最近匹配」待评审（hypothesis）。当前实现按区间归属
3. **性能基线**：PERF-001 未做，所有性能数字仍是估算

---

## 8. 验证命令速查

```bash
# 内核门禁（Debug + Release 都要过）
./tools/build/build_core.sh --platform=apple --config=Debug --test
./tools/build/build_core.sh --platform=apple --config=Release --test

# Swift 绑定（SPM）
cd bindings/swift && swift test --disable-sandbox
./bindings/swift/run_smoke.sh

# SharedUI（测试宿主，含预览像素级验收）
cd apps/apple/packages/SharedUI && swift test --disable-sandbox

# macOS App 启动冒烟（DEBUG 演示素材；先 xcodebuild build）
APP=$(find ~/Library/Developer/Xcode/DerivedData -name ChuanqiCutMacApp.app -path "*Debug*" | head -1)
CQ_DEMO_VIDEO="$PWD/tests/golden/frames/gf_1080p_h264.mp4" "$APP/Contents/MacOS/ChuanqiCutMacApp"

# App 工程（macOS 可编译；iOS 需真机或用 -sdk iphoneos）
cd apps/apple/mac && xcodegen generate && bundle install && bundle exec pod install
xcodebuild build -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutMacApp \
    -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```
