# ChuanqiCutEngine.podspec — Swift 对外门面（ADR-0044 §2：门面外提为顶层 api/swift/）
#
# ADR-0033：C/C++20 内核与 Apple Platform 已拆到 ChuanqiCutCore Pod；本 Pod 只编译 Swift
# 门面，并保持 App/UI 侧 `import ChuanqiCutEngine` 不变。
#
# App 的 Podfile 必须同时以本地 path 声明 ChuanqiCutCore（pod 根 = engine/）与
# ChuanqiCutEngine（pod 根 = api/swift/），避免 CocoaPods 为传递依赖去远端 spec repo
# 查找 ChuanqiCutCore。

Pod::Spec.new do |s|
  s.name        = 'ChuanqiCutEngine'
  s.version     = '0.1.0'
  s.summary     = 'Swift adapter for the ChuanqiCut C engine'
  s.description = <<-DESC
    Native Swift API adapter over the ChuanqiCutCore public C ABI.
    The C++ engine and Apple Platform are compiled by the separate ChuanqiCutCore Pod.
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

  # pod 根 = api/swift/（INFRA-032）：路径必须相对 pod 根，不得写成仓库根相对。
  s.source_files = 'Sources/ChuanqiCut/**/*.swift'
  s.frameworks = 'Foundation'
  s.dependency 'ChuanqiCutCore', s.version.to_s
end
