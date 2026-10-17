# ChuanqiCutCore.podspec — Engine C/C++20 内核与 Apple Platform（原 CChuanqiCut，ADR-0038 更名）
#
# 目录与发布边界（ADR-0033）：
# - core/cq/<功能>：内部 C++ 头与实现共置；
# - platform/apple/{base,gfx,media}：Apple 私有头与实现共置；
# - 唯一 public header：core/cq/cq_sdk.h（纯 C ABI）。
#
# Swift 不在本 Pod 编译；Swift 适配由 ChuanqiCutEngine.podspec 单独负责。

Pod::Spec.new do |s|
  s.name        = 'ChuanqiCutCore'
  s.version     = '0.1.0'
  s.summary     = 'ChuanqiCut engine core: C ABI, C++20 kernel and Apple Platform'
  s.description = <<-DESC
    Cross-platform C++20 video editing engine core and Apple platform adapter.
    The only public header is cq_sdk.h; all C++ and platform headers are private.
    Third-party backends live in their own pods (ChuanqiCutFFmpeg, ADR-0038).
  DESC

  s.homepage = 'https://REPLACE_ME.invalid/ChuanqiCut'
  s.source   = { :git => ENV.fetch('CQ_POD_SOURCE_GIT',
                                    'https://REPLACE_ME.invalid/ChuanqiCut.git'),
                 :tag => s.version.to_s }
  # SDK 本体协议仍为 Proprietary（待定）。第三方后端在各自独立 Pod 声明许可：
  # FFmpeg（LGPL-2.1-or-later）见 ChuanqiCutFFmpeg.podspec / NOTICE.md / ADR-0036。
  s.license  = { :type => 'Proprietary',
                  :text => 'License not finalized. Third-party backends are separate pods (see ChuanqiCutFFmpeg / NOTICE.md).' }
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

  # SHADER-001：Portable shader → MSL 的**构建期生成**（Xcode/Pods 侧接线）。
  # CMake 侧由 engine/platform/apple/CMakeLists.txt 的 custom command 完成
  # （产物落 ${CMAKE_BINARY_DIR}/generated/shaders）；Pods/Xcode 构建不经过
  # CMake，若不在这里补接线，blit_pass.mm 的 `#include "blit_msl.h"` 在壳工程
  # 里直接编不过（生成物只在 CMake 构建里存在）——那就是"CMake 绿、壳工程红"
  # 的又一处分裂，本项目已在两套渲染路径上付过代价（ADR-0014），不许再犯。
  # 产物落仓库根 build/generated/shaders/（.gitignore 忽略；与 CMake 侧同一
  # 路径，两套构建系统写同一份幂等产物，不互相覆盖）。
  s.script_phases = [
    {
      :name => 'SHADER-001: Portable shader -> MSL (blit_msl.h)',
      :script => <<-SH,
set -e
REPO_ROOT="${PODS_TARGET_SRCROOT}/.."
OUT_DIR="${REPO_ROOT}/build/generated/shaders"
mkdir -p "${OUT_DIR}"
python3 "${REPO_ROOT}/tools/shaders/build_shaders.py" --repo-root "${REPO_ROOT}" --out-dir "${OUT_DIR}"
SH
      :execution_position => :before_compile,
    }
  ]

  s.frameworks = 'Foundation', 'Metal', 'AVFoundation', 'CoreMedia',
                 'VideoToolbox', 'CoreVideo', 'CoreGraphics',
                 'AudioToolbox', 'QuartzCore'
  s.osx.frameworks = 'IOSurface'
  s.libraries = 'c++'

  cq_major, cq_minor, cq_patch = s.version.to_s.split('.')

  # ---- 第三方后端（ADR-0038）：FFmpeg 独立 Pod（许可与义务）+ 本 Pod 携带二进制 ----
  # 许可与义务（LGPL 声明、App 内声明资源包）归 ChuanqiCutFFmpeg Pod（dependency 下方）。
  # FFmpeg 二进制的 vendored 接线在本 Pod：CocoaPods 对无源 Pod 不产生链接产物
  #（2026-10-11 实测），必须由有源 Pod 携带 vendored；将来可迁移（ADR-0038 附录）。
  s.dependency 'ChuanqiCutFFmpeg', '9.0.2'

  ffmpeg_xcframework = File.expand_path('vendor/libffmpeg.xcframework', __dir__)
  unless File.exist?(ffmpeg_xcframework)
    raise "FFmpeg demux 产物缺失（#{ffmpeg_xcframework}）。\n" \
          "先构建并同步：tools/build/build_ffmpeg_demux.sh（5 个 slice，见 docs/BUILD.md）" \
          " && tools/build/make_ffmpeg_xcframework.sh"
  end
  # ⚠️ 必须是 vendored_frameworks，不能是 vendored_libraries。
  #    CocoaPods 只按 `File.extname == '.xcframework'` 识别 xcframework
  #    （sandbox/file_accessor.rb 的 vendored_xcframeworks）；vendored_libraries
  #    期待的是 *.a 文件/通配，给它一个 .xcframework 目录会 glob 到目录本身、
  #    静默不产生任何接线 —— 2026-10-15 实测：App 聚合 xcconfig 的 OTHER_LDFLAGS
  #    里没有 -l"ffmpeg"，LIBRARY_SEARCH_PATHS 无 vendor 路径，Pods.xcodeproj
  #    里 grep vendor 0 命中。链接闭合却没人发现，因为当时无人调用 FFmpeg 符号，
  #    archive 成员不拉取 → 构建照样 SUCCEEDED（ADR-0038 §验证记载有误，见勘误）。
  # ⚠️ 路径必须相对 podspec（绝对路径被 CocoaPods 拒绝）。
  s.vendored_frameworks = 'vendor/libffmpeg.xcframework'

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
                             '"$(PODS_TARGET_SRCROOT)/../build/generated/shaders" ' \
                             '"$(PODS_TARGET_SRCROOT)/vendor/libffmpeg.xcframework/macos-arm64_x86_64/Headers"'
  }
end
