# 真机问卷：2026-10-12 真机日志纠偏批（导入耗时 / 美型复活 / 预览 drawable 防御）

> 依据 `ADR-0034` §5：写代码 → 出真机问卷 → 传哲实测 → 集成机纠偏登记。
> 本批**不是新功能**，是 2026-10-12 传哲回传真机日志暴露的三个确定性缺陷的修复验证。

---

## 0. 本批基本信息

| 项 | 值 |
|---|---|
| 批号 | `B-2026-10-12-日志纠偏` |
| 主题 | 导入探测 967ms 主线程阻塞 / 美型 warp 一直跳过 / 预览 drawable 退化崩溃 |
| 关联 | pitfalls P122 / P123 / P124；池 [17]；LEDGER-W42 |
| 提交 | `32895d3` |
| 机器侧填写人与时间 | 集成机（WorkBuddy），2026-10-12 12:10 |
| 集成机环境 | macOS 26.7.1 / Xcode 26.6 / Swift 6.3.3 / **Intel x86_64**（无 ANE、无 ProRes 硬编） |

## 1. 这批改了什么（面向人）

一句话：**导入相册视频不再卡顿近 1 秒；美型（瘦脸/大眼那一档）从「一直静默跳过」改成真的加载；
相机预览拿到退化 drawable 时不再触发 Metal 断言。**

| 文件 | 变更类型 | 说明 |
|---|---|---|
| `engine/core/cq/platform/chq_media.h` | 修改 | 新增 `CreateMediaDemuxerLight` 声明（**契约层**） |
| `engine/platform/apple/media/media_demux.mm` | 修改 | 实现轻量工厂：构造 + `OpenLight`，**不做全量 Open** |
| `engine/core/cq/media/chq_media_probe_abi.cpp` | 修改 | `cq_media_probe_duration` 改走轻量工厂 |
| `tests/unit/test_media_demux_apple.cpp` | 修改 | +4 项断言，把「轻量 = 不建 reader」钉成回归锁 |
| `apps/apple/packages/ChuanqiCutCamera/.../Effects/face_warp.metal` | 修改 | 首参 `float2` → `coreimage::destination`，取 `dest.coord()` |
| `apps/apple/packages/ChuanqiCutCamera/.../Effects/FaceWarp.swift` | 修改 | 注释补契约（防第三次踩同一个坑） |
| `apps/apple/packages/ChuanqiCutCamera/.../CameraRenderer.swift` | 修改 | draw 入口校验 drawable 尺寸/格式，退化则跳过并打 error |

**热点文件与 ABI 影响**：未触碰 `cq_sdk.h` / CMake / podspec / Podfile / project。
新增的是 Platform 契约层的自由函数（内部 ABI），C 公共 ABI `cq_media_probe_duration`
**签名不变**，无需重跑 `pod install`、无需重生成 API 参考。

## 2. 机器侧证据

| 命令 | 结果 | 备注 |
|---|---|---|
| `bash tools/ci/run_gate.sh` | **PASS=14 FAIL=0 SKIP=0**（22m14s） | 传哲 2026-10-12 指定跑全量 |
| `ctest` core-dbg / core-rel | **48/48 / 48/48** | `platform_apple_demux`（#28）含新增 4 项轻量工厂断言，Passed |
| `swift test`：bindings / camera / import / editor / player | 26 / 77 / 16 / 65 / 52，**全 0 failure** | CameraRenderer 的 Swift 改动由此编译验证 |
| `cd apps/apple/ios && xcodebuild -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutApp -destination generic/platform=iOS build` | **BUILD SUCCEEDED**（1m31s） | 壳工程在 `apps/apple/ios/`，不在仓库根。`face_warp.metallib` 已重建（12:12，5808B），`-fcikernel` 两阶段编译通过 |
| `python3 tests/golden/verify.py --json` | PASS | |

**没跑的项目**：真机项（无可用设备，归传哲）。
⚠️ **门禁不含 App 壳构建**（池 [18]）——上面第 4 行是手跑补的，不是门禁产物。
并且：**metallib 编译通过 ≠ CIWarpKernel 能加载**，签名对不对只有真机那一行
`warp engine INSTALLED` 能证明（P123）。

**Mac 壳未跑**：本批未触达 macOS 专属路径（`apps/apple/mac`），相机/导入链路属 iOS 壳。

## 3. 已知偏差与本期明确不做

- 已知偏差（知道但不改，登记在池 [17]）：
  - `importMedia` 仍是 @MainActor **同步**调用；修完只剩毫秒级，但 `OpenLight` 内部仍用
    `dispatch_semaphore_wait` 等 Default QoS 回调 —— 优先级反转的结构没变，只是时长短了。
  - `PHAssetOriginalMetadataProperties` 仍在主队列按需取（Photos 自己警告会掉帧）。
  - 播放段 footprint 188→282MB 的成因**未取证**，jetsam（signal 9）根因未定位。
- **本期明确不做**：
  - 不改导入链路为异步（要动 @MainActor 边界与 `sequencedImport` 语义，单独建卡）。
  - 不加临时内存埋点（先靠 Xcode Memory Graph 取证，取证前不改代码）。
- 上机前注意事项：
  - 需要**相册里一段 1080×1920 竖屏视频**（上次那个 967ms 就是这样来的；小素材测不出差别）。
  - 美型要开到能触发的档位（滑杆非零）才走 warp 路径。

## 4. 真机检查点（传哲填写）

> 编号 `Q-1012-nn`。请如实写「实际」，现象描述比"感觉卡"有用。

| 编号 | 操作步骤 | 预期 | 实际（留白） |
|---|---|---|---|
| `Q-1012-01` | 从相册导入一段 1080×1920 竖屏视频，看控制台 | `[import] probe` 应从 ~970ms 降到两位数 ms（预期 < 100ms） | |
| `Q-1012-02` | 同上，导入瞬间 | 界面**无明显卡顿**（原先会顿近 1 秒）；Thread Performance Checker 不再报 demux 优先级反转 | |
| `Q-1012-03` | 打开相机 → 把美型任一滑杆拉到非零 | 控制台出现 `warp engine INSTALLED`，**不再**出现 `Warp kernel function 'cq_face_warp' does not have a coreimage:destination argument` | |
| `Q-1012-04` | 美型滑杆从 0 拉到最大再回 0 | 画面随滑杆**连续形变**（脸/下巴区域），无撕裂、无跳变；拉回 0 恢复原状 | |
| `Q-1012-05` | 相机预览长跑 2 分钟以上（期间可切前后摄/转屏） | 不再出现 `MTLTextureDescriptor has invalid pixelFormat (0)` 断言 | |

### iOS 端专属

| 编号 | 操作步骤 | 预期 | 实际（留白） |
|---|---|---|---|
| `Q-1012-I01` | 导入 → 播放 30s → 切到相机页长跑 2min | 进程**不被 signal 9 杀掉**；DEBUG 浮层 footprint 曲线应走平，不是单调上升 | |
| `Q-1012-I02` | 同上，切回编辑页 | 编辑页预览仍正常出画（验证切页没把会话搞坏） | |

## 5. 主观评价（传哲填写，可选但很有用）

- 手感：导入还顿不顿？
- 观感：美型开启后形变是否自然（现在是真跑起来了，第一次能看效果）
- 相对对标 App 的差距：
- 有没有出现你没想到的问题：

## 6. 回收与纠偏（集成机在传哲回复后填写）

| 编号 | 传哲反馈 | 判定 | 处置 |
|---|---|---|---|
| | | | |

- 本批结论：
- 未通过项是否阻塞下一批：
- LEDGER 纠偏条目：`docs/reports/LEDGER-W42.md` 追加于（回收后回填）
