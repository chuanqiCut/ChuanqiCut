# ADR-0021：CoreImage Metal kernel 不走 Xcode 内建 Metal 阶段

- 状态：Accepted（2026-10-05）
- 影响面：`apps/apple/ios/project.yml`、CIKernel 类 shader 资产（当前仅
  `iOSApp/Camera/Effects/beauty_bilateral.metal`，CAM-012）
- 相关：ADR-0014（相机模块采用 iOS 原生栈）、pitfalls P52 / P53

## 背景

CAM-012 的磨皮 kernel 是 **CoreImage CIKernel**（`coreimage::sampler`），不是普通
Metal kernel。iOS 上 `CIKernel(source:)` 不可用，只能走
`CIKernel(functionName:fromMetalLibraryData:)`，即编译期必须产出一个合法的 metallib
并打进 bundle。

该文件此前**从未被编译过**（11 个源文件因工程产物陈旧被漏收录，见 P54），
首次编译即暴露整条链路不成立。

## 决策

CIKernel 的 .metal **排除在 Xcode 内建 Metal 编译阶段之外**，改由
`postBuildScripts` 自己编，产物直写 `.app`：

1. `sources` 里 `excludes: ["**/beauty_bilateral.metal"]`（glob 写法，见 P53-b）；
2. 脚本用 `metal -fcikernel` **编译 + 链接两步**（都带 `-fcikernel`），
   target triple 按 `PLATFORM_NAME` 区分 simulator / device；
3. 输出 `$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/beauty_bilateral.metallib`
   （`BeautyKernel` 扫 bundle 内任意 .metallib，不要求叫 `default.metallib`）。

## 为什么不能用 Xcode 内建阶段

- 内建阶段不带 `-fcikernel`，链接必报
  `air-lld: symbol(s) not found`（`coreimage::Sampler::sample/coord/extent`）。
- 给 target 设 `MTL_OTHER_FLAGS = -fcikernel` **无效**：`showBuildSettings` 看得到，
  但不出现在 metal 命令行（P53-c）；source 级 `compilerFlags` 也不落地。
- 只给编译阶段加 `-fcikernel`、链接用 `xcrun metallib`，会产出 **96 字节空壳**
  （只有 `MTLB`+`ENDT`，零函数符号），**链接退出码 0、编译全绿**，但运行时
  `CIKernel.kernelNames` 查不到 → `BeautyKernel.init?` 返回 nil → 静默回落默认
  CI 实现。这是"能打包 ≠ 能用"的又一个实例。

## 验收硬要求

产出的 metallib **必须检查内容与大小**，不能只看退出码：

```
strings <metallib> | grep cq_beauty      # 必须看到两个 kernel 名
ls -l   <metallib>                       # ~8.4KB；96B = 空壳
```

已验证：`iphonesimulator` 8399B、`iphoneos` 8367B，两个 kernel 符号齐全；
产物与手工链接样本 `cmp` IDENTICAL。

## 代价与风险

- 该 .metal 不再享受 Xcode 的语法/类型检查报错定位，错误只在脚本里以
  `metal` 的 stderr 形式出现（可接受：`set -euo pipefail` 会让构建失败）。
- 脚本在资源拷贝后写 `.app`：依赖"签名在所有 build phase 之后"这一 Xcode 行为。
  Debug / 免签名构建已验证；**发布签名构建尚未实测**（剩余风险）。
