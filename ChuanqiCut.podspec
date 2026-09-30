# ChuanqiCut.podspec — CocoaPods 集成（C++/OC SDK 层）
#
# 定位（与 SPM 的分工，见 docs/COCOAPODS.md）：
#   * 本 podspec 负责 **SDK 层**：C++20 内核 + ObjC++ PAL + Swift 绑定源码。
#     它需要 vendored 二进制、C++ 标准设置、一堆系统框架 —— 这些正是 CocoaPods
#     擅长而 SPM 别扭的地方。
#   * App 的 **UI 层**三方库走 SPM（Xcode 的 Swift Package Dependencies）。
#   * ⚠️ 二者不要重复引入 ChuanqiCut：同一份 Swift 源码被 pod 与 SPM 各编一次，
#     会出现重复符号。二选一，见 docs/COCOAPODS.md「SPM 与 CocoaPods 共存」。
#
# 两种集成模式（subspec 切换）：
#   * Binary（默认）：链接预构建的 XCFramework，不编译 C++ —— 日常开发用这个
#   * Source        ：现场编译 C++20 内核与 ObjC++ PAL —— 调试内核 / 无预构建产物时用
#
# 用法（App 的 Podfile）：
#   pod 'ChuanqiCut', :path => '../..'                  # 默认 Binary
#   pod 'ChuanqiCut/Source', :path => '../..'           # 源码模式
#
# ⚠️ Binary 模式前置：必须先生成 xcframework
#     tools/build/build_core_apple.sh --config=Release && bindings/swift/prepare.sh

Pod::Spec.new do |s|
  s.name          = 'ChuanqiCut'
  s.version       = '0.1.0'
  s.summary       = 'Cross-platform video editing SDK (C++20 kernel + PAL + Swift bindings)'
  s.description   = <<-DESC
    ChuanqiCut is a cross-platform video editing SDK: a shared C++20 kernel
    (media / render / session) with platform adaptation layers and native UI shells.
    This pod provides the SDK layer; UI-layer dependencies are managed separately
    via SwiftPM. See docs/COCOAPODS.md.
  DESC

  # ⚠️ 仓库当前**没有** git remote（2026-09-30 核实），故这里用显式占位而非编造 URL。
  #    发布到远端 spec repo 之前必须替换成真实地址；本地 `:path =>` 引用不受影响。
  s.homepage      = 'https://REPLACE_ME.invalid/ChuanqiCut'
  s.source        = { :git => 'https://REPLACE_ME.invalid/ChuanqiCut.git',
                      :tag => s.version.to_s }

  # ⚠️ License **尚未最终确定**：FFmpeg LGPL 静态链接的处置（目标文件归档 / 商业授权 /
  #    动态链接 / 不接入 FFmpeg）待 owner + 法务拍板，见 ADR-0010 与项目 MEMORY.md。
  #    发布前必须改这里，不要带着 Proprietary 占位对外分发。
  s.license       = { :type => 'Proprietary',
                      :text => 'License not finalized. FFmpeg LGPL linking strategy pending (see ADR-0010).' }
  s.author        = { 'zhuning' => 'REPLACE_ME.invalid' }

  # 平台基线：ADR-0010（iOS 16 / macOS 15.4）。不要为编译通过而抬高。
  s.ios.deployment_target = '16.0'
  s.osx.deployment_target = '15.4'
  s.swift_version  = '6.1'

  # 默认二进制：App 集成不应每次都编译整个 C++ 内核。
  s.default_subspecs = 'Binary'

  # =========================================================================
  # CBridge — C ABI 的 Clang module（Swift 侧 import CChuanqiCut 的来源）
  # =========================================================================
  # shim.c 不是业务逻辑：SwiftPM/CocoaPods 都需要一个真实源文件才会为 C target
  # 生成 module（BIND-002 实测：只有头文件会报 "no such module"）。
  s.subspec 'CBridge' do |ss|
    ss.source_files      = 'bindings/swift/Sources/CChuanqiCut/shim.c'
    ss.preserve_paths    = 'bindings/swift/Sources/CChuanqiCut/include/module.modulemap',
                           'bindings/swift/Sources/CChuanqiCut/include/cq_sdk.h'
    ss.module_map        = 'bindings/swift/Sources/CChuanqiCut/include/module.modulemap'
    # 内核是 C++20，消费方必须链 C++ 运行时。
    ss.libraries         = 'c++'
    ss.pod_target_xcconfig = {
      'HEADER_SEARCH_PATHS' => '$(inherited) "$(PODS_TARGET_SRCROOT)/bindings/swift/Sources/CChuanqiCut/include"'
    }
  end

  # =========================================================================
  # Swift — 绑定层源码（与 SPM 共用同一份文件，不复制）
  # =========================================================================
  s.subspec 'Swift' do |ss|
    ss.source_files = 'bindings/swift/Sources/ChuanqiCut/**/*.swift'
    ss.dependency 'ChuanqiCut/CBridge'
  end

  # =========================================================================
  # Binary — 链接预构建 XCFramework（默认）
  # =========================================================================
  s.subspec 'Binary' do |ss|
    ss.dependency 'ChuanqiCut/Swift'
    ss.dependency 'ChuanqiCut/CBridge'

    # XCFramework 内含三个切片（ios-arm64 / ios-simulator / macos），
    # 由 tools/build/build_core_apple.sh 产出，bindings/swift/prepare.sh 拷到此路径。
    # ⚠️ 该目录是**构建产物**（.gitignore 已忽略），远端分发时需要 CI 先生成再打包。
    ss.vendored_frameworks = 'bindings/swift/Frameworks/ChuanqiCut.xcframework'
  end

  # =========================================================================
  # Source — 现场编译 C++20 内核 + ObjC++ PAL
  # =========================================================================
  # 用途：调试内核、或没有预构建产物时（例如 clone 后只想跑 iOS 模拟器）。
  # 注意：这条路径**不经过**项目的 CMake，编译设置在这里重建 —— 两者若漂移，
  #       以 cmake/CompileOptions.cmake 为准，回来同步本段。
  s.subspec 'Source' do |ss|
    ss.dependency 'ChuanqiCut/Swift'
    ss.dependency 'ChuanqiCut/CBridge'

    ss.source_files        = 'core/src/**/*.{cpp}',
                             'core/include/**/*.{h,hpp}',
                             'pal/apple/**/*.{mm,h}'
    ss.public_header_files = 'core/include/**/*.h'
    ss.header_mappings_dir = 'core/include'

    ss.libraries    = 'c++'
    ss.frameworks   = 'Foundation', 'Metal', 'AVFoundation', 'CoreMedia',
                      'VideoToolbox', 'CoreVideo', 'CoreGraphics',
                      'AudioToolbox', 'QuartzCore'
    # IOSurface 是 macOS 专有框架，iOS SDK 里不存在（PALA-002 已踩过一次）。
    ss.osx.frameworks = 'IOSurface'

    ss.pod_target_xcconfig = {
      'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
      'CLANG_CXX_LIBRARY'           => 'libc++',
      'CLANG_ENABLE_OBJC_ARC'       => 'YES',
      'HEADER_SEARCH_PATHS'         => '$(inherited) "$(PODS_TARGET_SRCROOT)/core/include"',
      # 内核禁用异常；与 cmake 保持一致（ARCH-001）。
      'GCC_ENABLE_CPP_EXCEPTIONS'   => 'NO',
      'GCC_ENABLE_CPP_RTTI'         => 'NO'
    }
  end
end
