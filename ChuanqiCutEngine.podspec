# ChuanqiCut.podspec — CocoaPods 集成（C++/OC SDK 层）
#
# 定位（INFRA-009 起，见 docs/COCOAPODS.md）：
#   * 本 podspec 负责 **SDK 层**：C++20 内核 + ObjC++ PAL + Swift 绑定源码。
#   * App（apps/apple/ios 与 apps/apple/mac 两个独立工程）经各自的 Podfile
#     引用本 pod 与 SharedUI pod；App **不使用 SPM**。
#   * ⚠️ 不要在 SPM 与 pod 两边同时引入 ChuanqiCut：同一份 Swift 源码被各编
#     一次会出现重复符号。SPM（bindings/swift/Package.swift）只保留作
#     `swift test` 测试宿主，不在 App 依赖链上。
#
# 两种集成模式（subspec 切换）：
#   * Source（默认）：现场编译 C++20 内核与 ObjC++ PAL —— 调试内核、分析
#     问题、无预构建产物时用（owner 决策 2026-10-02）
#   * Binary        ：链接预构建的 XCFramework，不编译 C++ —— 发布期/提速用
#
# 用法（App 的 Podfile）：
#   pod 'ChuanqiCut/Source', :path => '../..'           # 源码模式（默认）
#   pod 'ChuanqiCut/Binary', :path => '../..'           # 二进制模式
#
# ⚠️ Binary 模式前置：必须先生成 xcframework
#     tools/build/build_core_apple.sh --config=Release && bindings/swift/prepare.sh
#
# ⚠️ Swift 绑定源码 `import CChuanqiCut`：C module 与 pod module（ChuanqiCut）
#    必须是两个名字。**不要**在本 podspec 上设 s.module_map —— CocoaPods 会把
#    自定义 modulemap 当作 pod 自身的 module（实证：2026-09-30 pod install 残留
#    产物 ChuanqiCut-iOS.modulemap 即 `module CChuanqiCut`），App 侧
#    `import ChuanqiCut` 随即断裂。正确做法是 pod_target_xcconfig 的
#    SWIFT_INCLUDE_PATHS 指向 bindings/swift/Sources/CChuanqiCut/include/，
#    让 Swift 编译期看见独立的 CChuanqiCut clang module——该 modulemap 与
#    cq_sdk.h 符号链接与 SPM 共用同一份文件，不复制。

Pod::Spec.new do |s|
  # 2026-10-07（传哲拍板）：SDK 层整体改名 Engine——pod/module/SPM target 统一
  #   'ChuanqiCutEngine'（Xcode 26 显式模块构建要求 module 名 == 目标名，module_name
  #   别名不可用）；import 全仓同步更新；C 模块 CChuanqiCut 与静态库 libChuanqiCut 不变。
  s.name          = 'ChuanqiCutEngine'
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
  #
  # CQ_POD_SOURCE_GIT 是给 `pod lib lint` 用的逃生口：lint 会真的去 clone s.source，
  #    占位地址必然失败。要跑完整 lint 时用本地仓库覆盖：
  #      git tag v0.1.0
  #      CQ_POD_SOURCE_GIT="$PWD" pod lib lint ChuanqiCut.podspec --allow-warnings
  s.homepage      = 'https://REPLACE_ME.invalid/ChuanqiCut'
  s.source        = { :git => ENV.fetch('CQ_POD_SOURCE_GIT',
                                        'https://REPLACE_ME.invalid/ChuanqiCut.git'),
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

  # 默认源码模式：现场编译整个 C++ 内核（owner 决策 2026-10-02）。
  # 便于调试与分析问题，且 clone 后无「先构建 xcframework」的前置。
  s.default_subspecs = 'Source'

  # =========================================================================
  # 公共部分：C ABI 的 Clang module + Swift 绑定源码
  # =========================================================================
  # ⚠️ 不要在这里设 s.module_map（见文件头「Swift 绑定源码 import CChuanqiCut」）。
  #    CChuanqiCut clang module 经 SWIFT_INCLUDE_PATHS 暴露给 Swift 编译期；
  #    pod 自身的 module（ChuanqiCut）由 CocoaPods 生成。
  #
  # shim.c 不是业务逻辑：SwiftPM/CocoaPods 都需要一个真实源文件才会为 C target
  # 生成 module（BIND-002 实测：只有头文件会报 "no such module"）。
  # Swift 绑定源码与 SPM 共用同一份文件，不复制。
  s.source_files = 'bindings/swift/Sources/CChuanqiCut/shim.c',
                   'bindings/swift/Sources/ChuanqiCut/**/*.swift'

  # 模块文件与头文件本体不属于 source_files，声明保留防止打包路径剥离。
  s.preserve_paths = 'bindings/swift/Sources/CChuanqiCut/include/module.modulemap',
                     'bindings/swift/Sources/CChuanqiCut/include/cq_sdk.h',
                     # 让 core 头文件在 Pods 导航器可见（答疑 2026-10-07：源码模式
                     # 下"看不到头文件"）。⚠️ 只 preserve、不进 source_files——
                     # headermap 基名劫持 <time.h> 案底见 Source subspec 注释。
                     'core/include/**/*.h'

  # Swift 编译期：让 `import CChuanqiCut` 解析到与 SPM 共用的 module.modulemap；
  # shim.c 的 `#include "cq_sdk.h"` 也走这条搜索路径。
  s.pod_target_xcconfig = {
    'SWIFT_INCLUDE_PATHS' => '$(inherited) $(PODS_TARGET_SRCROOT)/bindings/swift/Sources/CChuanqiCut/include',
    'HEADER_SEARCH_PATHS' => '$(inherited) "$(PODS_TARGET_SRCROOT)/bindings/swift/Sources/CChuanqiCut/include"'
  }

  # ⚠️ 消费方也必须能看到 CChuanqiCut module：本 pod 的 Swift 公开 API 引用了
  #    CChuanqiCut 里的 C 类型，消费方 `import ChuanqiCut` 时 Swift 要求该
  #    module 可见（否则报 "missing required module 'CChuanqiCut'"）。
  #    user_target_xcconfig 覆盖 App target；pod 形态的消费方（SharedUI）
  #    不受它影响，须在自家 podspec 声明同一路径（2026-10-02 实测）。
  #    路径锚定 SRCROOT（=apps/apple/ios|mac），向上三级到仓库根。
  s.user_target_xcconfig = {
    'SWIFT_INCLUDE_PATHS' => '$(inherited) "$(SRCROOT)/../../../bindings/swift/Sources/CChuanqiCut/include"'
  }

  # 内核是 C++20，消费方必须链 C++ 运行时。
  s.libraries = 'c++'

  # =========================================================================
  # Binary — 链接预构建 XCFramework（默认）
  # =========================================================================
  s.subspec 'Binary' do |ss|
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
    # ⚠️ **不要把 .h 声明进 source_files / *_header_files**：
    #    CocoaPods 会为 target 生成 headermap（hmap），按**文件基名**映射所有
    #    声明过的头。core/include/cq/base/time.h 一旦声明，pod 内所有编译的
    #    `#include <time.h>`（系统头！CoreFoundation/Darwin 都会引）就先命中
    #    我们的 C++ 头 → ObjC module 上下文里 <cstdint> 不可见 →
    #    "'cstdint' file not found" → 系统模块全体级联崩（2026-10-02 实测）。
    #    头文件不必进任何 build phase：C++/ObjC++ 编译靠下面的
    #    HEADER_SEARCH_PATHS（-I 只按路径前缀匹配，不按基名劫持；
    #    time.h 在 cq/base/ 子目录，#include <time.h> 不会命中它）。
    ss.source_files        = 'core/src/**/*.cpp',
                             'pal/apple/**/*.mm'

    ss.libraries    = 'c++'
    ss.frameworks   = 'Foundation', 'Metal', 'AVFoundation', 'CoreMedia',
                      'VideoToolbox', 'CoreVideo', 'CoreGraphics',
                      'AudioToolbox', 'QuartzCore'
    # IOSurface 是 macOS 专有框架，iOS SDK 里不存在（PALA-002 已踩过一次）。
    ss.osx.frameworks = 'IOSurface'

    # 版本宏：cq_sdk.cpp 裸用 CQ_VERSION_MAJOR/MINOR/PATCH，正常由 CMake 注入
    # （core/CMakeLists.txt target_compile_definitions）。pod 编译不经 CMake，
    # 在此从 s.version 派生注入，避免两处漂移。
    cq_major, cq_minor, cq_patch = s.version.to_s.split('.')

    # ⚠️ subspec 的 xcconfig 同 key 会**覆盖**根 spec 的值（不是链式 $(inherited)），
    #    故 HEADER_SEARCH_PATHS 必须把根 spec 的 CChuanqiCut include 路径一并写全。
    ss.pod_target_xcconfig = {
      'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
      'CLANG_CXX_LIBRARY'           => 'libc++',
      'CLANG_ENABLE_OBJC_ARC'       => 'YES',
      'HEADER_SEARCH_PATHS'         => '$(inherited) "$(PODS_TARGET_SRCROOT)/core/include" ' \
                                       '"$(PODS_TARGET_SRCROOT)/bindings/swift/Sources/CChuanqiCut/include"',
      'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) CQ_VERSION_MAJOR=%s CQ_VERSION_MINOR=%s CQ_VERSION_PATCH=%s' %
                                       [cq_major, cq_minor, cq_patch],
      # 内核禁用异常；与 cmake 保持一致（ARCH-001）。
      'GCC_ENABLE_CPP_EXCEPTIONS'   => 'NO',
      'GCC_ENABLE_CPP_RTTI'         => 'NO'
    }
  end
end
