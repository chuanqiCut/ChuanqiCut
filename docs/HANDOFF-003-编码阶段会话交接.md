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
| **预览** | 子步骤 3 纹理导入（零拷贝） | ⏭️ **下一步** |
| 预览 | 子步骤 4 预览渲染器 | 待做 |
| 预览 | 子步骤 5 C ABI 封装 | 待做 |
| UI | 子步骤 6 / UIA-003 MTKView 嵌入 | 待做 |

**门禁**：`Debug 32/32`、`Release 32/32` 全绿。
命令：`./tools/build/build_core.sh --platform=apple --config=Debug --test`

---

## 2. 下一步：BIND-003 子步骤 3~6

**开工前必读**：`docs/tasks/TASK-BIND-003.md`（完整设计 + 6 个子步骤拆分）

| # | 内容 | 要点 |
|---|---|---|
| 3 | 纹理导入 | `VideoFrame.image` 已是 `NativeImageHandle`(CVPixelBuffer)，接 PALA-002 零拷贝导入；断言 IOSurface ID 与源一致，证明没有偷偷 CPU 拷贝 |
| 4 | 预览渲染器 | 新建 `core/src/preview/`：Timeline + AssetRegistry + GFX + 离屏 RT |
| 5 | C ABI 封装 | `cq_preview_*`；导出**中性句柄**（`void*`），Swift 侧 reinterpret 为 MTLTexture |
| 6 | UIA-003 | SharedUI 内 `UIViewRepresentable`/`NSViewRepresentable` 包 MTKView |

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

# SharedUI（测试宿主）
cd apps/apple/packages/SharedUI && swift test --disable-sandbox

# App 工程（macOS 可编译；iOS 需真机或用 -sdk iphoneos）
cd apps/apple/mac && xcodegen generate && bundle install && bundle exec pod install
xcodebuild build -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutMacApp \
    -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```
