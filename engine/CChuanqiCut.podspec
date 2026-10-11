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
  # SDK 本体协议仍为 Proprietary（待定）；第三方 vendored 组件的许可见
  # engine/NOTICE.md。FFmpeg 9.0.2 以 LGPL-2.1-or-later vendored（demux 档，
  # 无 GPL 组件），处置结论见 ADR-0036（ARCH-002 §5.1 路径 1，负责人 2026-10-11 确认）。
  s.license  = { :type => 'Proprietary',
                  :text => 'License not finalized. See NOTICE.md for vendored third-party licenses (FFmpeg LGPL-2.1-or-later).' }
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

  # ---- FFmpeg（DEPS-010/012，ADR-0036）----
  # demux 档位静态库（libavformat+libavutil+libavcodec parser/bsf），LGPL-2.1-or-later，
  # 无 GPL 组件。产物由 tools/build/build_ffmpeg_demux.sh 构建、manifest.toml 登记
  # sha256。xcframework 三个 slice：macosx(x86_64+arm64) / iphoneos(arm64) /
  # iphonesimulator(x86_64+arm64)。源码集成（调试/CI 审计）走
  # third_party/CMakeLists.txt 的 cq_ffmpeg target（integration=auto 的 source 侧）。
  #
  # ⚠️ 产物不入 git（P84：*.a 全局 ignore，与旧 prebuilt 档一致）。首次 pod install
  # 前必须本地构建一次（或从集成机拷贝 third_party/prebuilt/ffmpeg/）：
  #   tools/build/build_ffmpeg_demux.sh --sdk macosx --arch x86_64
  #   tools/build/build_ffmpeg_demux.sh --sdk macosx --arch arm64
  #   tools/build/build_ffmpeg_demux.sh --sdk iphoneos --arch arm64
  #   tools/build/build_ffmpeg_demux.sh --sdk iphonesimulator --arch x86_64
  #   tools/build/build_ffmpeg_demux.sh --sdk iphonesimulator --arch arm64
  # ⚠️ vendored_libraries 必须相对 podspec 且在 pod root 内（2026-10-12 双实测）：
  #   绝对路径 → 直接报错（File patterns must be relative）；pod root 外的
  #   ../third_party 相对路径 → **静默忽略**（Pods 工程无任何引用，比报错更坑）。
  #   故 make_ffmpeg_xcframework.sh 构建后把 xcframework 同步到 engine/vendor/，
  #   这里引用仓内副本（vendor 由 .gitignore 盖住，产物不入 git，P84）。
  ffmpeg_xcframework = 'vendor/libffmpeg.xcframework'
  unless File.exist?(File.expand_path(ffmpeg_xcframework, __dir__))
    raise "FFmpeg demux 产物缺失（engine/vendor/libffmpeg.xcframework）。\n" \
          "先构建：tools/build/build_ffmpeg_demux.sh 5 个 slice（自动同步 vendor，见 docs/BUILD.md）。"
  end
  # vendored_libraries 必须是相对路径（CocoaPods 校验：File patterns must be relative），
  # 相对 podspec 目录解析；存在性检查用绝对路径（Pod 2026-10-12 实测：绝对路径直接报错）。
  # xcframework 走 vendored_frameworks（CocoaPods 1.10+ 对 .xcframework 后缀自动
  # 按 SDK 选 slice；vendored_libraries 只认裸 .a/.dylib 文件路径，对 xcframework
  # 目录静默忽略——2026-10-12 三次实测：绝对路径报错 / ../ 外部路径不接 / 目录不展开）
  s.vendored_frameworks = ffmpeg_xcframework
  # FFmpeg 头只被 engine 私有 .cpp 引用（public 头零第三方类型，DEPS-004 扫描）。
  # 三 slice 头文件同源（同一 commit），取 macosx-arm64 一份即可，xcframework
  # 的 vendored headers 亦由 CocoaPods 自动接入，此路径是显式兜底。
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
                             '"$(PODS_TARGET_SRCROOT)/platform/apple/media" ' \
                             '"$(PODS_TARGET_SRCROOT)/../third_party/prebuilt/ffmpeg/9.0.2/demux/macosx-arm64/include"'
  }
end
