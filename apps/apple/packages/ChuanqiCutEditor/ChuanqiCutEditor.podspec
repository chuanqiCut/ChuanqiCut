# ChuanqiCutEditor.podspec — 编辑器域 Pod（ADR-0031 阶段 5，INFRA-019）
#
# 定位：编辑器三件套（EditorView/EditorScreen/Timeline）+ EditorViewModel（内核
#   Session 门面，AppEntry.swift）+ 素材面板 MediaSheet（UIA-026 播放器联动经
#   PlayerPreviewInjector、相册浏览器经 MediaLibraryInjector 注入，横向零依赖）。
#   **UIA-032 编辑页对标 App式重构在新 Pod 内进行。**
#   注：素材表/导入逻辑（importMedia）当前与 EditorViewModel 不可分，随本 Pod；
#   LIB-001~005 落地后素材库真域另立 ChuanqiCutAssets（INFRA-017 改挂 LIB 依赖）。
#
# 用法：pod 'ChuanqiCutEditor', :path => '../packages/ChuanqiCutEditor'

Pod::Spec.new do |s|
  s.name          = 'ChuanqiCutEditor'
  s.version       = '0.1.0'
  s.summary       = 'ChuanqiCut 编辑器域（三件套 + Timeline + EditorViewModel）'
  s.homepage      = 'https://REPLACE_ME.invalid/ChuanqiCut'
  s.source        = { :git => ENV.fetch('CQ_POD_SOURCE_GIT',
                                        'https://REPLACE_ME.invalid/ChuanqiCutEditor.git'),
                      :tag => s.version.to_s }
  s.license       = { :type => 'Proprietary', :text => 'License not finalized. See ADR-0010.' }
  s.author        = { 'zhuning' => 'REPLACE_ME.invalid' }

  s.ios.deployment_target = '16.0'
  s.osx.deployment_target = '15.4'
  s.swift_version  = '6.1'

  s.source_files = 'Sources/ChuanqiCutEditor/**/*.swift'
  s.frameworks   = 'Metal', 'MetalKit', 'AVFoundation', 'CoreImage', 'CoreVideo'

  # SDK（内核 Session）+ 基座（Theme/注入点）
  s.dependency 'ChuanqiCutEngine'
  s.dependency 'SharedUI'

  # UIA-042 / ADR-0041：编辑器 UIKit 布局统一走 SnapKit（约束 DSL）。
  # * iOS 专属：SnapKit 只被 `#if os(iOS)` 的 UIKit 布局代码 import，macOS 端不引入
  #   （macOS App 无 UIKit 布局代码，不白背一个依赖）。
  # * MIT（ARCH-002 §5 ALLOW 级）；版本由两端 Podfile.lock 钉死（当前 5.7.1）。
  # * SPM Package.swift 不引：该包只是 macOS `swift test` 宿主，`#if os(iOS)`
  #   文件在 macOS 上整文件跳过；App 侧行为以本 podspec 为准（同 SharedUI 惯例）。
  s.ios.dependency 'SnapKit', '~> 5.7.0'

  # CChuanqiCut module 由 Engine 的正常 Pod 依赖传递，不再手工注入路径（ADR-0033）。
end
