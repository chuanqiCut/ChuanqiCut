# ChuanqiCutFFmpeg.podspec — FFmpeg 许可与义务 Pod（ADR-0038）
#
# 边界（重要，写明为什么这么拆）：
#   * 本 Pod 承载 FFmpeg 的**许可声明与合规义务**：LGPL-2.1-or-later 许可、
#     App 内声明资源包（License.md 随 App 分发——ADR-0036 §5.1 路径 1 的义务载体）、
#     构建与裁剪档位文档。
#   * FFmpeg **二进制**（vendor/libffmpeg.xcframework）的 vendored 接线在
#     ChuanqiCutCore.podspec —— CocoaPods 对「无源 Pod」不产生链接产物
#     （2026-10-11 实测：xcconfig-only target，无 Copy XCFrameworks、无 ldflags
#     聚合），必须由有源 Pod 携带 vendored 才能进 App 链接行。二进制位置是
#     CocoaPods 机制限制下的落地处，**所有权与许可归本 Pod**；将来 CocoaPods
#     支持无源 vendored（或改 framework 封装）后把 vendored 行迁过来即可。
#   * 上游：FFmpeg 9.0.2 demux 档（libavformat + libavutil + libavcodec
#     parser/bsf，无 GPL 组件）；产物由 tools/build/build_ffmpeg_demux.sh 构建
#     （flag 单一真源）、make_ffmpeg_xcframework.sh 打包同步（P84 不入库）。

Pod::Spec.new do |s|
  s.name        = 'ChuanqiCutFFmpeg'
  s.version     = '9.0.2'
  s.summary     = 'FFmpeg 9.0.2 demux-profile license & compliance pod (LGPL-2.1-or-later)'
  s.description = <<-DESC
    Ownership and compliance pod for the vendored FFmpeg 9.0.2 demux-profile
    static libraries (binary wiring lives in ChuanqiCutCore, see ADR-0038).
    Ships the LGPL notice as an in-app resource bundle (ADR-0036 path 1:
    in-app attribution + source availability + relinkable archive).
  DESC

  s.homepage = 'https://REPLACE_ME.invalid/ChuanqiCut'
  s.source   = { :git => ENV.fetch('CQ_POD_SOURCE_GIT',
                                    'https://REPLACE_ME.invalid/ChuanqiCut.git'),
                 :tag => s.version.to_s }
  # FFmpeg 以 LGPL-2.1-or-later vendored（上游 FFmpeg 许可，无 GPL 组件启用）。
  s.license  = { :type => 'LGPL-2.1-or-later',
                  :text => 'FFmpeg 9.0.2 demux profile, LGPL-2.1-or-later. Obligations and source-availability statement: ffmpeg/License.md (bundled in-app) and engine/NOTICE.md (ADR-0036).' }
  s.author   = { 'zhuning' => 'REPLACE_ME.invalid' }

  s.ios.deployment_target = '16.0'
  s.osx.deployment_target = '15.4'

  # App 内声明（ADR-0036 路径 1 义务）：LGPL 声明随 App 分发，用户可见。
  s.resource_bundles = {
    'ChuanqiCutFFmpegLicense' => 'ffmpeg/License.md',
  }
end
