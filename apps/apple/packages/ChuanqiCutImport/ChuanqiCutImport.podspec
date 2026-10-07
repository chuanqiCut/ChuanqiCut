# ChuanqiCutImport.podspec — 素材导入域 Pod（ADR-0031 阶段 2，INFRA-016）
#
# 定位：相册权限/浏览器（UIA-013 自研相册浏览器，ADR-0015）/批量选片。
#   消费方 = ChuanqiCutEditor 的 MediaSheet，经 SharedUI/Common 的
#   MediaLibraryInjector 注入（功能 Pod 横向零依赖）；壳层 Podfile 直引本 Pod 装配。
# 测试宿主：同目录 Package.swift（AlbumPickerTests）。
#
# 用法：pod 'ChuanqiCutImport', :path => '../packages/ChuanqiCutImport'

Pod::Spec.new do |s|
  s.name          = 'ChuanqiCutImport'
  s.version       = '0.1.0'
  s.summary       = 'ChuanqiCut 素材导入域（相册浏览器/批量选片；UIA-011~013）'
  s.homepage      = 'https://REPLACE_ME.invalid/ChuanqiCut'
  s.source        = { :git => ENV.fetch('CQ_POD_SOURCE_GIT',
                                        'https://REPLACE_ME.invalid/ChuanqiCutImport.git'),
                      :tag => s.version.to_s }
  s.license       = { :type => 'Proprietary', :text => 'License not finalized. See ADR-0010.' }
  s.author        = { 'zhuning' => 'REPLACE_ME.invalid' }

  s.ios.deployment_target = '16.0'
  s.osx.deployment_target = '15.4'
  s.swift_version  = '6.1'

  s.source_files = 'Sources/ChuanqiCutImport/**/*.swift'
  s.frameworks   = 'Photos', 'PhotosUI'

  s.dependency 'SharedUI'
end
