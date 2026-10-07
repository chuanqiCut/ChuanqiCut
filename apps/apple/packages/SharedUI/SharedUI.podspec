# SharedUI.podspec — SwiftUI UI 基座（Theme/通用组件；UIA-002 建立，INFRA-009 pod 化）
#
# 定位：
#   * App 集成的**真源**是本 podspec（ios/ 与 mac/ 的 Podfile 均以 :path 引用）。
#   * 同目录 Package.swift 仅保留作 `swift test` 测试宿主（UIA-002 验收测试），
#     **不在 App 依赖链上**。两份构建定义描述同一份 Sources/SharedUI 源码，
#     改动源码接口时两边都要顾到；App 侧行为以 pod 路径为准。
#
# 迁出注记（ADR-0031 壳工程与功能 Pod 分治；2026-10-07 全域迁出完成）：
# 本 Pod 已是**终态 UI 基座**——仅 Common/（Theme 配色 + 三个注入器
# PlayerPreviewInjector / EditorEntryInjector / MediaLibraryInjector）。
# 功能域去向：Player → ChuanqiCutPlayer（阶段 1）· Camera → ChuanqiCutCamera
# （阶段 4，iOS 专属）· MediaPicker → ChuanqiCutImport（阶段 2）·
# Editor+Timeline+EditorViewModel → ChuanqiCutEditor（阶段 5）· 测试随域迁出
# （SharedUI 无独立测试，由门禁 swift build + 双壳构建兜底）。
# ChuanqiCutAssets 不从本 Pod 拆——素材逻辑与 EditorViewModel 不可分，
# 待 LIB-001~005 素材库契约落地后建域（INFRA-017 已改挂 LIB 依赖）。
#
# 为什么 SharedUI 必须跟 ChuanqiCut 一起走 pod：
#   SPM 依赖图与 CocoaPods 互不相通（podspec 引不了 SPM 包，反之亦然）。
#   SharedUI 大量使用 SDK 类型，App 一旦从 pod 引 SDK，SharedUI 若仍走 SPM，
#   Swift 绑定源码会被 pod 与 SPM 各编一次 → 重复符号。
#
# 用法（App 的 Podfile）：
#   pod 'SharedUI', :path => '../packages/SharedUI'   # 相对 ios/ 或 mac/ 目录

Pod::Spec.new do |s|
  s.name          = 'SharedUI'
  s.version       = '0.1.0'
  s.summary       = 'ChuanqiCut SwiftUI shared editor components (iOS/macOS)'
  s.description   = <<-DESC
    Shared SwiftUI editor shell (three-zone layout, EditorViewModel) for the
    ChuanqiCut iOS and macOS apps. Consumes the ChuanqiCut SDK pod.
  DESC

  # ⚠️ 仓库当前没有 git remote（2026-09-30 核实），用显式占位而非编造 URL；
  #    本地 `:path =>` 引用不用 source。跑完整 lint 时用本地仓库覆盖：
  #      git tag v0.1.0 && CQ_POD_SOURCE_GIT="$PWD" pod lib lint SharedUI.podspec
  s.source        = { :git => ENV.fetch('CQ_POD_SOURCE_GIT',
                                        'https://REPLACE_ME.invalid/SharedUI.git'),
                      :tag => s.version.to_s }
  s.homepage      = 'https://REPLACE_ME.invalid/ChuanqiCut'
  s.license       = { :type => 'Proprietary',
                      :text => 'License not finalized. See ADR-0010.' }
  s.author        = { 'zhuning' => 'REPLACE_ME.invalid' }

  # 平台基线：ADR-0010（iOS 16 / macOS 15.4）
  s.ios.deployment_target = '16.0'
  s.osx.deployment_target = '15.4'
  s.swift_version  = '6.1'

  s.source_files = 'Sources/SharedUI/**/*.swift'

  # UIA-003：预览视图用 MTKView 直绘（SwiftUI 系统框架会被 Swift 自动链接，
  # 但 MetalKit 属显式 import，声明出来不依赖自动链接行为）。
  s.frameworks = 'Metal', 'MetalKit'

  # ⚠️ ChuanqiCut 的 Swift 公开 API 引用了 CChuanqiCut（C module）里的类型，
  #    SharedUI `import ChuanqiCut` 时 Swift 要求该 module 可见。App target 由
  #    ChuanqiCut.podspec 的 user_target_xcconfig 提供路径；pod 形态的消费方
  #    （本 spec）不受其影响，必须自行声明（2026-10-02 实测）。
  #    路径：本目录向上四级到仓库根。
  s.pod_target_xcconfig = {
    'SWIFT_INCLUDE_PATHS' => '$(inherited) "$(PODS_TARGET_SRCROOT)/../../../../engine/bindings/swift/Sources/CChuanqiCut/include"'
  }

  # 不锁版本：仓库内本地 :path 集成，与 App 用同一份仓库。
  s.dependency 'ChuanqiCutEngine'
end
