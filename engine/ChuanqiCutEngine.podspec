# ChuanqiCutEngine.podspec — Swift 适配层
#
# ADR-0033：C/C++20 内核与 Apple Platform 已拆到 CChuanqiCut Pod；本 Pod 只编译 Swift
# binding，并保持 App/UI 侧 `import ChuanqiCutEngine` 不变。
#
# App 的 Podfile 必须同时以本地 path 声明 CChuanqiCut 与 ChuanqiCutEngine，避免
# CocoaPods 为传递依赖去远端 spec repo 查找 CChuanqiCut。

Pod::Spec.new do |s|
  s.name        = 'ChuanqiCutEngine'
  s.version     = '0.1.0'
  s.summary     = 'Swift adapter for the ChuanqiCut C engine'
  s.description = <<-DESC
    Native Swift API adapter over the CChuanqiCut public C ABI.
    The C++ engine and Apple Platform are compiled by the separate CChuanqiCut Pod.
  DESC

  s.homepage = 'https://REPLACE_ME.invalid/ChuanqiCut'
  s.source   = { :git => ENV.fetch('CQ_POD_SOURCE_GIT',
                                    'https://REPLACE_ME.invalid/ChuanqiCut.git'),
                 :tag => s.version.to_s }
  s.license  = { :type => 'Proprietary',
                  :text => 'License not finalized. FFmpeg LGPL linking strategy pending (see ADR-0010).' }
  s.author   = { 'zhuning' => 'REPLACE_ME.invalid' }

  s.ios.deployment_target = '16.0'
  s.osx.deployment_target = '15.4'
  s.swift_version = '6.1'

  s.source_files = 'bindings/swift/Sources/ChuanqiCut/**/*.swift'
  s.frameworks = 'Foundation'
  s.dependency 'CChuanqiCut', s.version.to_s
end
