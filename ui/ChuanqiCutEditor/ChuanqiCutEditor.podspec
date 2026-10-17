# ChuanqiCutEditor.podspec — 编辑器域 Pod（ADR-0031 阶段 5，INFRA-019）
#
# 定位：编辑器三件套（EditorView/EditorScreen/Timeline）+ EditorViewModel（内核
#   Session 门面，AppEntry.swift）+ 素材面板 MediaSheet（UIA-026 播放器联动经
#   PlayerPreviewInjector、相册浏览器经 MediaLibraryInjector 注入，横向零依赖）。
#   **UIA-032 编辑页对标 App 式重构在新 Pod 内进行。**
#   注：素材表/导入逻辑（importMedia）当前与 EditorViewModel 不可分，随本 Pod；
#   LIB-001~005 落地后素材库真域另立 ChuanqiCutAssets（INFRA-017 改挂 LIB 依赖）。
#
# 用法（两端不同）：
#   iOS  ：pod 'ChuanqiCutEditor/TimelineKitTrack', :path => '../../../ui/ChuanqiCutEditor'
#   macOS：pod 'ChuanqiCutEditor',                  :path => '../../../ui/ChuanqiCutEditor'
#
# ## 为什么拆子 spec（2026-10-15）
#
# TimelineKit 是 **UIKit-only** 的本地 Pod（`platforms: ios 15.0`），macOS 端
# 根本不可能解析/编译它。而实测：CocoaPods **不会**因为写了 `s.ios.dependency`
# 就在 macOS 解析时把它摘掉 —— 同一个 spec 里的 `s.ios.dependency 'SnapKit'`
# 就出现在 macOS 的 Podfile.lock 里，且 `pod 'TimelineKit'` 一旦被 macOS 解析，
# 直接报「not compatible with macOS」，`pod install` 整体失败（mac 端连 Pods
# 工程都生成不出来）。故只能靠**子 spec** 把「只有 iOS 才存在的依赖」隔离出去：
# macOS 引默认子 spec `Core`（不含 TimelineKit 依赖），iOS 引 `TimelineKitTrack`。
# 这不是绕路：依赖的物理边界本来就该由「谁真的用它」决定。

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
  s.frameworks   = 'Metal', 'MetalKit', 'AVFoundation', 'CoreImage', 'CoreVideo'

  # 默认子 spec：两端共用。**不含**任何 TimelineKit 相关文件与依赖。
  s.default_subspec = 'Core'

  s.subspec 'Core' do |ss|
    ss.source_files = 'Sources/ChuanqiCutEditor/**/*.swift'
    # 只 iOS 成立的三件套（适配层 / 轨道容器 / 组件调试预览）由 TimelineKitTrack 提供。
    ss.exclude_files = [
      'Sources/ChuanqiCutEditor/UIKit/TimelineKitAdapter.swift',
      'Sources/ChuanqiCutEditor/UIKit/EditorTimelineKitView.swift',
      'Sources/ChuanqiCutEditor/UIKit/TimelineKitIntegrationPreview.swift',
    ]

    # SDK（内核 Session）+ 基座（Theme/注入点）
    ss.dependency 'ChuanqiCutEngine'
    ss.dependency 'SharedUI'

    # UIA-042 / ADR-0041：编辑器 UIKit 布局统一走 SnapKit（约束 DSL）。
    # * iOS 专属：SnapKit 只被 `#if os(iOS)` 的 UIKit 布局代码 import，macOS 端不引入
    #   （macOS App 无 UIKit 布局代码，不白背一个依赖）。
    # * MIT（ARCH-002 §5 ALLOW 级）；版本由两端 Podfile.lock 钉死（当前 5.7.1）。
    # * SPM Package.swift 不引：该包只是 macOS `swift test` 宿主，`#if os(iOS)`
    #   文件在 macOS 上整文件跳过；App 侧行为以本 podspec 为准（同 SharedUI 惯例）。
    ss.ios.dependency 'SnapKit', '~> 5.7.0'
  end

  # 轨道区（TimelineKit 版）+ 适配层。**iOS 专属子 spec**：macOS 端 Podfile 不引它，
  # 于是 TimelineKit 这个 UIKit-only 依赖不会被 macOS 解析。
  s.subspec 'TimelineKitTrack' do |ss|
    ss.source_files = [
      'Sources/ChuanqiCutEditor/UIKit/TimelineKitAdapter.swift',
      'Sources/ChuanqiCutEditor/UIKit/EditorTimelineKitView.swift',
      'Sources/ChuanqiCutEditor/UIKit/TimelineKitIntegrationPreview.swift',
    ]
    ss.dependency 'ChuanqiCutEditor/Core'
    # 本地 CocoaPods 组件（独立 Swift/UIKit 时间线组件）：由宿主 iOS Podfile 给 :path。
    ss.ios.dependency 'TimelineKit'
    ss.ios.dependency 'SnapKit', '~> 5.7.0'
  end

  # ChuanqiCutCore module（原 CChuanqiCut）由 Engine 的正常 Pod 依赖传递，不再手工注入路径（ADR-0033）。
end
