# ChuanqiCutCamera.podspec — 相机域 Pod（ADR-0031 阶段 4，INFRA-018；iOS 专属）
#
# 定位：
#   * 相机全域（采集/预览渲染/录制/检测/美颜美型特效 + 契约层），2026-10-07 自
#     iOSApp/Camera（App target 直编）与 SharedUI/Camera（契约层）迁出
#     （ADR-0014 相机 = App 层资产域，不经 PAL/C ABI；UIA/CAM-001~005/011~019）。
#   * **iOS 专属**：不声明 osx deployment target，mac 壳 Podfile 不引（SharedUI/
#     Editor 不引用相机契约，横向零依赖，ADR-0031 决定 3）。
  #   * 依赖：仅 SharedUI 基座（CameraView 经 EditorEntryInjector 进入编辑器域，
  #     编辑器本体由壳层装配——功能 Pod 横向零依赖，ADR-0031 决定 3）；不依赖 ChuanqiCut SDK。
  #
  # ⚠️ metallib 构建链（ADR-0021）：编译与链接**都要** `-fcikernel`（只给编译阶段时
  #   产出 96 字节空壳：MTLB/ENDT 无函数符号、不报错、运行时 kernelNames 查不到 →
  #   静默回落默认实现）。必须用 `metal -fcikernel` 链接，产物 ~8.4KB 且含
  #   cq_beauty_down_h / cq_beauty_up_v_mix。验收 = 查产物大小 + kernelNames。
  #
  # ⚠️ 管线位置（INFRA-018 实测定案，2026-10-07）：**留在壳工程**（iOS project.yml
  #   postBuildScripts，SRC 指向本 Pod 的 .metal 源）。不在 podspec 用 script_phase
  #   的原因：①静态库 Pod 的 script 产物进的是 Pod 资源暂存目录，Copy Pods Resources
  #   只拷 install 期声明的资源 → 构建期生成的 metallib 到不了 App bundle（实测假绿）；
  #   ②script_phase 未声明 inputs/outputs 时增量构建会被跳过。壳工程装配资源符合
  #   ADR-0031「壳负责装配」。BeautyKernel 加载侧双 bundle 扫描兜底。
#
# 测试宿主：同目录 Package.swift（仅契约层在 macOS 上跑契约单测；实现层 iOS 专属
# 不进 SPM target）。App 不使用 SPM（INFRA-009）。
#
# 用法（App 的 Podfile，仅 iOS）：
#   pod 'ChuanqiCutCamera', :path => '../packages/ChuanqiCutCamera'

Pod::Spec.new do |s|
  s.name          = 'ChuanqiCutCamera'
  s.version       = '0.1.0'
  s.summary       = 'ChuanqiCut 相机域（iOS 原生采集/渲染/录制/特效；ADR-0014）'
  s.description   = <<-DESC
    Camera domain for ChuanqiCut: AVCaptureSession pipeline, Metal preview
    rendering, recording, Vision detection, beauty effects and the shared
    contract layer. Ships the CoreImage beauty + face-warp kernel metallibs
    via a script phase (ADR-0021: -fcikernel for BOTH compile and link).
  DESC

  s.homepage      = 'https://REPLACE_ME.invalid/ChuanqiCut'
  s.source        = { :git => ENV.fetch('CQ_POD_SOURCE_GIT',
                                        'https://REPLACE_ME.invalid/ChuanqiCutCamera.git'),
                      :tag => s.version.to_s }
  s.license       = { :type => 'Proprietary',
                      :text => 'License not finalized. See ADR-0010.' }
  s.author        = { 'zhuning' => 'REPLACE_ME.invalid' }

  # iOS 专属（ADR-0014）：不声明 osx，mac 壳不引
  s.ios.deployment_target = '16.0'
  s.swift_version  = '6.1'

  # 契约层 + 实现层 **Swift 源**。⚠️ .metal 绝不能进 source_files：CocoaPods 会把
  # 它挂进 Xcode 内建 Metal 编译阶段（无 -fcikernel → air-lld 未解析 coreimage::
  # Sampler 符号，ADR-0021 明令禁止）。.metal 只作为下方 script_phase 的输入。
  s.source_files = 'Sources/ChuanqiCutCamera/**/*.swift',
                   'Sources/ChuanqiCutCameraImpl/**/*.swift'

  # 显式 import 的系统框架（采集/录制/渲染/检测/CI 特效/MetalFX 升采样）
  s.frameworks = 'AVFoundation', 'CoreMedia', 'CoreVideo', 'CoreImage',
                 'Metal', 'MetalKit', 'MetalFX', 'Vision'

  # 基座依赖（版本不锁，仓库内本地 :path 集成）
  s.dependency 'SharedUI'

  # ⚠️ CChuanqiCut clang module 可见性（SharedUI.podspec 2026-10-02 实测同款）：
  #    SharedUI 公开接口引用 ChuanqiCut 类型，依赖它的 pod 必须自行把 C module
  #    的 include 路径注入 SWIFT_INCLUDE_PATHS，否则 import SharedUI 即报
  #    unable to resolve module dependency: 'CChuanqiCut'。路径：本目录向上四级到仓库根。
  s.pod_target_xcconfig = {
    'SWIFT_INCLUDE_PATHS' => '$(inherited) "$(PODS_TARGET_SRCROOT)/../../../../engine/bindings/swift/Sources/CChuanqiCut/include"'
  }
end
