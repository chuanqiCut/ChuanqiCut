# TASK-CAM-012：美颜升级——Metal 磨皮替换高斯近似（B 期）

```yaml
id:          TASK-CAM-012
layer:       UI(iOSApp)
goal:        磨皮从 A 期"高斯+锐化近似"升级为保边正经算法(Metal kernel:引导滤波或双边滤波),滑杆接口不变
input:       [SPEC-CAM-001 v1.1 §3 B 期, RESEARCH-002 §5, CameraBeauty.swift(既有接口)]
output:      [apps/apple/ios/iOSApp/Camera/Effects/BeautyKernel.swift, Effects/*.metal(编译期内嵌 MSL),
             SharedUI CameraBeauty.apply 改为薄封装(算法参数由原生侧注入)]
write_set:   apps/apple/ios/iOSApp/Camera/Effects/, SharedUI/Camera/CameraBeauty.swift(仅封装层),
             SharedUITests(用例适配)
read_set:    CameraRenderer.swift, CameraRecorder.swift
deps:        [TASK-CAM-003]
acceptance:
  - 磨皮输出对滑杆单调、off 恒等直通(既有单测口径不变,算法实现可替换)
  - 1080p 单帧磨皮 ≤ 8ms [E,真机实测后回填 baselines];不掉帧(≥30fps 维持)
  - 肤色区域平滑、发丝/眼缘/唇线保边(真机人工验收项,归传哲)
verification:
  - swift test + iOS 构建;真机帧率/耗时埋点入 baselines
risk:        引导滤波需要 downsample 金字塔,复杂度高于双边;先双边后引导,以真机帧率定案
parallel:    false
```

## 实现要点

- Metal fragment kernel 双 pass:下采样 → 域变换模糊(亮度域双边)→ 上采样 → 与原图按强度混合;
  混合强度 = 磨皮滑杆。MSL 直接写在 `Effects/` 目录(App 层资产,ADR-0014 §3 红线 #6 边界)。
- `CameraBeauty.apply` 的公开语义(单调/off 恒等)**不变**,调用方(预览/拍照/录制)零改动;
  原生侧在 process 链中用 kernel 版本替换纯 CI 版本。

## 进度（2026-10-04 完成，本机验证 + 宿主 GPU 实证）

| 子步骤 | 状态 |
|---|---|
| CIKernel API 对表（ObjC 头 + typecheck 探针） | 完成——iOS 17.2 SDK **无源码串初始化器**，只有 `CIKernel(functionName:fromMetalLibraryData:)`；落地方修正为 `.metal` 随 Xcode 编译期内建（原卡 output 写法即此意，P40） |
| `Effects/beauty_bilateral.metal`（双 pass 亮度域双边） | 完成；`metal -fcikernel` 一步编译通过，kernel 名可加载 |
| `Effects/BeautyKernel.swift`（metallib 加载 + profile 映射 + 引擎闭包） | 完成 |
| SharedUI `CameraBeauty.swift` 薄封装 + `CameraBeautyEngine` 注入点 | 完成；默认 CI 高斯保留为兜底（macOS/引擎放弃时走），公开语义（单调/off 恒等）不变 |
| CameraViewModel 安装引擎（一行） | 完成 |
| SharedUITests 用例适配 | 完成：既有 3 用例未动 + 新增 4 用例（注入生效/off 不触碰引擎/仅美白不走引擎/引擎放弃回落） |
| macOS 宿主 GPU harness（`tools/qa/beauty_harness/`） | 完成，**ALL PASS**（证据见下） |
| 真机帧率/耗时 + 视觉人工验收 | **未做**（归传哲，新 Xcode 机器 + 真机） |

### 写集追加（超出原卡的改动与原因）

- `CameraViewModel.swift`（+8 行）：引擎安装一行 + `import UIKit` + wireCallbacks
  引用局部化（后者为存量编译错误修复，见 P41）。
- `CameraRenderer.swift` / `CameraRecorder.swift` / `CameraView.swift`：**A 期存量
  编译错误修复**（这些文件此前只过过 `-parse`，从未 typecheck；本卡首次全量
  typecheck 抓出 7 处，任何机器首编必挂，清单见 pitfalls P41）。无行为变更
  （render API 换成 SDK 实际存在的等价变体）。
- `tools/qa/beauty_harness/`（新增）：宿主验证 harness，可重复执行。

### 验证证据（2026-10-04，第二开发机 macOS 13.7 / Xcode 15.2）

1. **iOS typecheck（P39 技法）**：相机模块 9 文件 + SharedUITests 全量 `-typecheck`
   （iphonesimulator 17.2 SDK / ios16.0 目标，stub SharedUI + EditorScreen shim），
   **0 错**（修复 7 处存量错误后）。
2. **宿主 GPU harness**（真 .metal + 真 BeautyKernel.swift + 真 CameraBeauty.swift，
   `metal -fcikernel` 编译，Intel Iris Plus 640 实跑）：
   - profile 单调性（taps/σr/mix）PASS；halfExtent 奇数取整 PASS
   - 方差对强度单调不增 + 严格下降：0.006115 → 0.000082（s=1.0，75×）
   - 边缘过渡宽度（10-90%）：s=0.5 → 2.0px、s=1.0 → 4.0px（门限 3.5/4.5px）
   - 平台对比度保持率：101.6% / 103.3%（门限 85%）
   - 1080p 单帧耗时（best-of-3，render→GPU 完成，不含回读）：kernel 引擎
     s=0.5 → **9.85ms**、s=1.0 → 18.01ms；A 期默认 CI 高斯 s=0.5 → 19.12ms（对照）
3. **swift test / iOS 构建：本机阻塞**（P39/P36b，同 CAM-011 口径），用例与工程侧
   已就绪；首次真机构建需确认 default.metallib 入包（xcodegen 对 .metal 的
   sources 相机自动归类，冒烟时核对 bundle）。

### 剩余风险与待办

- **σr 语义按未标记 BGRA 的 gamma 域表现定标**（CPU 仿真 + GPU 剖面对照推断）；
  若真机上 CI 工作空间表现不同（如颜色管理差异），滑杆高段保边表现可能偏移，
  真机冒烟时用 `CQ_DEBUG_PROFILE=1` 同法复核（harness 内置诊断）。
- ≤8ms 真机指标未实测（估算 [E] 维持）；本机数字见 baselines（**非真机**，仅参考）。
- 强度映射（taps 2...5 / σr 0.03+0.08s / mix=s）为可用起点，视觉浓淡归传哲
  真机定案；调参只动 `BeautyKernelProfile`，结构不动。
- harness 的保边指标曾在迭代中两次误判（最大邻接差把 2× 上采样内建插值
  误判为磨边；逐行 10% 穿越被残留噪声抖动）——现用跨行平均剖面 + 10-90%
  宽度 + 平台对比度三件套，改指标前先读 main.swift 注释里的定标说明。
