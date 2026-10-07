# ChuanqiCutPlayer.podspec — 独立播放器域 Pod（ADR-0031 阶段 1，INFRA-015）
#
# 定位：
#   * 播放器全域（AVPlayerEngine / PlayerViewModel / PlayerScreen / Launcher /
#     MiniBar / 字幕 / 缩略图 / 最近播放），2026-10-07 自 SharedUI 迁出
#     （UIA-015~027；ADR-0022 AVPlayer 过渡）。
#   * 消费方：双壳（iOS HomeView 播放入口、macOS 窗口 + MiniBar）直接 import；
#     MediaSheet 播放器联动经 SharedUI/Common 的 PlayerPreviewInjector 注入
#     —— 功能 Pod 横向零依赖（ADR-0031 决定 3）。
#   * 不依赖 ChuanqiCut SDK：AVPlayer 过渡期纯系统框架；内核播放 session
#     （ADR-0022 演进触发）落地时再加 SDK 依赖。
#   * 零基座符号（实测，ADR-0031 拓扑微调）：MediaSheet 联动走反向注入，
#     触感反馈内联（原引 MediaPicker 域 PickerFeedback 已内联）——待 Player
#     真正消费 Theme/公共组件时再加 `s.dependency 'SharedUI'` 并同步 Package.swift。
#
# 测试宿主：同目录 Package.swift（`swift test`）；App 不使用 SPM（INFRA-009）。
#
# 用法（App 的 Podfile）：
#   pod 'ChuanqiCutPlayer', :path => '../packages/ChuanqiCutPlayer'

Pod::Spec.new do |s|
  s.name          = 'ChuanqiCutPlayer'
  s.version       = '0.1.0'
  s.summary       = 'ChuanqiCut 独立播放器域（AVPlayer 过渡；UIA-015~027）'
  s.description   = <<-DESC
    Standalone player domain for ChuanqiCut: AVPlayerEngine, view model,
    screen / launcher / mini-bar UI, subtitles, thumbnails, recents.
    Editor linkage is decoupled via PlayerPreviewInjector (ADR-0031).
  DESC

  # 占位 source（仓库内 :path 引用不用）；lint 用 CQ_POD_SOURCE_GIT 覆盖，
  # 惯例同 ChuanqiCut.podspec / SharedUI.podspec。
  s.homepage      = 'https://REPLACE_ME.invalid/ChuanqiCut'
  s.source        = { :git => ENV.fetch('CQ_POD_SOURCE_GIT',
                                        'https://REPLACE_ME.invalid/ChuanqiCutPlayer.git'),
                      :tag => s.version.to_s }
  s.license       = { :type => 'Proprietary',
                      :text => 'License not finalized. See ADR-0010.' }
  s.author        = { 'zhuning' => 'REPLACE_ME.invalid' }

  # 平台基线：ADR-0010（iOS 16 / macOS 15.4）
  s.ios.deployment_target = '16.0'
  s.osx.deployment_target = '15.4'
  s.swift_version  = '6.1'

  s.source_files = 'Sources/ChuanqiCutPlayer/**/*.swift'

  # 显式 import 的系统框架（AVPlayerLayer 宿主 / PiP / 播放链路）。
  # Metal/MetalKit 是 Editor 域 MTKView 的声明，不随迁（仍在 SharedUI.podspec）。
  s.frameworks = 'AVFoundation', 'AVKit', 'QuartzCore'
end
