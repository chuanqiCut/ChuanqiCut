# CChuanqiCut.podspec — Engine C/C++20 内核与 Apple Platform
#
# 目录与发布边界（ADR-0033）：
# - core/cq/<功能>：内部 C++ 头与实现共置；
# - platform/apple/{base,gfx,media}：Apple 私有头与实现共置；
# - 唯一 public header：core/cq/cq_sdk.h（纯 C ABI）。
#
# Swift 不在本 Pod 编译；Swift 适配由 ChuanqiCutEngine.podspec 单独负责。

Pod::Spec.new do |s|
  s.name        = 'CChuanqiCut'
  s.version     = '0.1.0'
  s.summary     = 'ChuanqiCut C ABI, C++20 engine core and Apple Platform'
  s.description = <<-DESC
    Cross-platform C++20 video editing engine core and Apple platform adapter.
    The only public header is cq_sdk.h; all C++ and platform headers are private.
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

  # 头文件与实现文件保持在同一功能目录；CocoaPods 会在 Pods 工程中自然按物理目录展示，
  # 不再由 post_install 往主工程或 Pods 工程补 PBX 引用。
  s.source_files = 'core/cq/**/*.{h,cpp}',
                   'platform/apple/**/*.{h,mm}'

  # 对外只暴露纯 C ABI（唯一 public 头）。
  # 不显式列 private_header_files：CocoaPods 默认已把「非 public 的 .h」当 private 处理，
  # 再列一遍只是与 source_files 重复同一批文件（2026-10-09 实测：删与不删，
  # Pods/Headers/Private 布局一致）。
  #
  # 已知无害噪音（P96）：core/cq 下存在 basename 同名头（gfx/gfx.h 与 platform/gfx.h），
  # Pods 工程会报 `Skipping duplicate build file in Copy Headers build phase`。
  # 两者在 Private 下分别落到 gfx/gfx.h 与 platform/gfx.h，不互相覆盖，不影响编译；
  # 不要为了消这条警告去改 podspec 或乱改头文件名。
  s.public_header_files = 'core/cq/cq_sdk.h'
  s.header_mappings_dir = 'core/cq'

  s.frameworks = 'Foundation', 'Metal', 'AVFoundation', 'CoreMedia',
                 'VideoToolbox', 'CoreVideo', 'CoreGraphics',
                 'AudioToolbox', 'QuartzCore'
  s.osx.frameworks = 'IOSurface'
  s.libraries = 'c++'

  cq_major, cq_minor, cq_patch = s.version.to_s.split('.')
  s.pod_target_xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'CLANG_ENABLE_OBJC_ARC' => 'YES',
    'GCC_ENABLE_CPP_EXCEPTIONS' => 'NO',
    'GCC_ENABLE_CPP_RTTI' => 'NO',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) CQ_VERSION_MAJOR=%s CQ_VERSION_MINOR=%s CQ_VERSION_PATCH=%s' %
                                      [cq_major, cq_minor, cq_patch],
    'HEADER_SEARCH_PATHS' => '$(inherited) "$(PODS_TARGET_SRCROOT)/core" ' \
                             '"$(PODS_TARGET_SRCROOT)/platform/apple/base" ' \
                             '"$(PODS_TARGET_SRCROOT)/platform/apple/gfx" ' \
                             '"$(PODS_TARGET_SRCROOT)/platform/apple/media"'
  }
end
