# TASK-CAM-015：相机预览 CI→drawable 渲染修复 + 帧计数去伪绿

```yaml
id:          TASK-CAM-015
layer:       UI(iOSApp)
goal:        修掉「CI 直接渲进 MTKView drawable → 每帧静默失败（黑屏）」并把帧计数改成
             绑定「真的出了画」的口径
input:       [2026-10-05 运行时日志实证, SPEC-CAM-001 A5(真机帧率验收), P60]
output:      [apps/apple/ios/iOSApp/Camera/CameraRenderer.swift,
             apps/apple/ios/iOSApp/Camera/CameraVideoView.swift]
write_set:   apps/apple/ios/iOSApp/Camera/CameraRenderer.swift,
             apps/apple/ios/iOSApp/Camera/CameraVideoView.swift
read_set:    SharedUI/Editor/PreviewFrameRenderer.swift(同类 blit 既存形态),
             Apple MTKView.framebufferOnly 文档, Apple MTLTextureUsage.shaderWrite 文档
deps:        [TASK-CAM-003(预览链路)]
acceptance:
  - 控制台不再出现 CIRenderDestination / The destination is nil 两行
  - 相机预览出画（模拟器/真机目测）
  - os_log subsystem=com.chuanqi.cut category=camera.preview：每 120 帧一条摘要，失败=0
  - 故意改回 CI 直写 drawable 时本 Avatar 的失败计数必须 > 0（伪绿探针有效）
verification:
  - xcodebuild -scheme ChuanqiCutApp -sdk iphonesimulator（注意：不是 -scheme ChuanqiCut，
    那个是 Pods 静态库 target，不会编 iPhoneApp 源文件）
  - 模拟器/真机人工：进「拍摄」页看是否出画 + 日志是否有 (info) 成功=…失败=0
risk:        framebufferOnly=false 已采纳（P65 翻案），代价 = 失去 CoreAnimation
             显示优化。真机帧率不达标时替代方案 = blit 换 render pass，
             不得凭直觉优化
parallel:    false
```

## 背景（现象 → 根因）

传哲贴的运行时日志里这两行每帧刷几十上百条：

```
-[CIRenderDestination initWithMTLTexture:commandBuffer:] texture usage must include MTLTextureUsageShaderWrite.
-[CIContext(CIRenderDestination) _startTaskToRender:toDestination:forPrepareRender:forClear:error:] The destination is nil.
```

根因四条证据（见 pitfalls P60）：

1. `CameraVideoView` 显式 `framebufferOnly = true`；
2. Apple 文档：`framebufferOnly=true` 时 drawable 纹理**只带 `renderTarget`**，不能读写；
3. 本机实测 usage：`true` → `0x04`，`false` → `0x17`（ShaderRead|ShaderWrite|RenderTarget|PixelFormatView）；
4. CI 的 `-to:commandBuffer:` 路径内部构造 `CIRenderDestination`，要求 usage 含 `ShaderWrite`
   → init 返回 nil → 这一帧什么都没画。

**二次伤害（比黑屏更坏）**：`render(...)` 非 throws，`destination nil` 不落到
`commandBuffer.error`，而旧代码在 draw 末尾无条件 `renderedFrameCount &+= 1` ——
于是黑屏也能报满帧率。这个计数是 SPEC-CAM-001 A5 真机帧率验收的依据。

## 决策：选 B 案（中间纹理 + blit），不选 A 案（改 framebufferOnly=false）

| 案 | 做法 | 代价 | 取舍 |
|---|---|---|---|
| A | `framebufferOnly = false` | drawable 失去 CoreAnimation 显示优化（Apple 明写 "at a cost to performance"） | 一行改动，链路最短 |
| **B（采纳）** | CI 渲进自建中间纹理（usage 含 ShaderWrite）→ blit 进 drawable | 每帧一次全屏 GPU 拷贝 | drawable 得以保留 framebufferOnly；与编辑器预览「离屏 RT → blit」形态统一 |

~~B 案前提已本机实测：`MTLBlitCommandEncoder.copy` 写进 usage=0x04 的 drawable **无 error**
（framebufferOnly 禁的是 shader read/write，不禁 blit / render pass 写入）。~~

**⚠️ 2026-10-05 23:09 翻案（pitfalls P65）**：那句「实测无 error」是校验层**关闭**状态下
取得的，不算证据 —— Metal 规范**禁止对 framebufferOnly 纹理做 blit**，真机 DEBUG
（Metal API Validation）下 blit 处第一帧硬断言 SIGABRT、100% 复现。
终态改为：**中间纹理保留（CI 落脚点）+ `framebufferOnly = false`（即原 A 案）**，blit
合法化；代价 = 失去 CoreAnimation 显示优化。「blit 换 render pass（全屏 quad 采样
中间纹理）」登记为真机帧率不达标时的替代方案，**不是改回 framebufferOnly = true**
（那条路已被规范封死）。

## 实现要点

- 中间纹理按**帧尺寸**分配（不是 drawable 尺寸），`pixelFormat` 取 drawable 的同款（blit 要求同格式），
  `usage = [.shaderWrite, .shaderRead]`、`storageMode = .private`；尺寸/格式变化就重建。
- blit 尺寸按 drawable 实际尺寸截断 —— 保持改动前「1:1 不缩放」的视觉语义，**不做 leak/letterbox**（那是 UI 需求）。
- 计数改由 command buffer 完成回调按成功/失败分流，加 `renderFailureCount`；
  新增 os_log 埋点（每 120 帧摘要 / 失败按 30 次节流打 error），供真机验收。

## 验证状态

- [x] iOS App 目标编译（iphonesimulator SDK，scheme = ChuanqiCutApp）
      → **BUILD SUCCEEDED，改动文件 0 error 0 warning**（2026-10-05 22:27）
- [x] Swift 6 严格并发：首次实现在 `addCompletedHandler` 里捕获 `self` 触发
      `capture of 'self' with non-Sendable type` 警告 —— 已改为捕获 Sendable 的
      `FrameStats`（同 CameraViewModel RecorderBox 写法，P49 同族）
- [x] 编译真做 effective：CameraRenderer.o 重建（22:27）且产物含 `camera.preview` 埋点字符串
      ⚠️ 过程中发现 **`-scheme ChuanqiCut` 是 Pods 静态库 target，编不到 iOSApp 源文件**，
      却能 BUILD SUCCEEDED 零告警假绿 —— 已登记 pitfalls P61
- [x] 模拟器安装 + 冷启动无崩（App 装到 Booted 的 iPhone 16 Pro，launch 日志正常）
- [ ] **进「拍摄」页看是否真出画 + 日志无 CIRenderDestination 报错 —— 归传哲人工验收**
      （相机页需点击「拍摄」并过摄像头授权弹窗，自动化代价高于收益；App 已装好）
- [x] **2026-10-05 23:09 真机 DEBUG 二段坑（P65 翻案）**：blit 写 framebufferOnly
      drawable 校验断言 SIGABRT（第一帧必炸、100% 复现）→ `CameraVideoView` 改
      `framebufferOnly = false` + CameraRenderer 两处错误注释勘误（原 B 案前提证伪）。
      验证：SharedUI 精确签名 stub + 真 SDK `swiftc -typecheck`，两文件 **0 error
      0 warning**（TYPECHECK_OK）。全量 `xcodebuild` 此刻被并行会话 MEDIA-022 未提交
      中间态阻塞（`Timeline.swift:273` `Status` 未实现 `Error`，非本卡写集，未动），
      待其落定后由收尾门禁覆盖。
- [ ] 真机复验：进「拍摄」页出画 + DEBUG 校验层下不再 SIGABRT —— 归传哲
- [ ] 真机帧率实测（iPhone 17 Pro，帧数 / GPU 占用；不达标 → blit 换 render pass）
- ⚠️ `tools/ci/run_gate.sh`（门禁**不覆盖 iOSApp**，跑它是为了确认没波及内核侧）：
  **PASS=2 FAIL=1 SKIP=0** —— `core-dbg` 42 条里 `core_thread_model` 红（「执行计数为 1」）。
  与本次改动无关（改的是 iOS Swift），根因是核心侧负载相关竞态，已登记 **pitfalls P63**：
  测试等的是任务体里的 flag，而 `TaskRunner` 的 `executed_` 在**任务返回之后**才自增。
  实测：单跑 5/5 绿、空载 20 次红 1、CPU 负载 30 次红 1（复现率 ~4%）。
  门禁一票否决后后续步骤**未执行**（摘要里 core-rel / swift / sharedui 那几行是上一跑的
  陈旧回显：日志时间戳 22:20，本跑 22:29）。**修复属 core 写集，本卡未动，等拍板。**

## 未做（显式登记，不在本卡）

- 画面铺满 / letterbox fit：属 UI 需求，改之前先问。
- `CameraVideoView` 的 `contentScaleFactor` 与 drawable 尺寸策略一并处理：同上。
