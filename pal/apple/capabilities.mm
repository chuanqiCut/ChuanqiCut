// ChuanqiCut — Apple 能力后端（CORE-007）
//
// 设计原则（详见 docs/tasks/TASK-CORE-007.md）：
//   D1 未注入后端 → kNo（安全默认，宁可降级不可用，不可谎报可用）
//   D2 查不到就诚实返回 kNo / kDegraded，**不做乐观猜测**
//   D3 kNpuInference 语义收窄为「CoreML 可用」，不代表实际跑在 ANE
//   D4 部署目标不抬高（iOS 16 / macOS 15.4），高版本 API 用 @available 守卫
//   D5 后端为进程生命周期内的静态实例，内核侧不接管所有权
//
// 每一项的判定依据都写在对应分支的注释里，便于评审逐项核对。
// 凡"无法用公开 API 可靠判定"的，一律 kDegraded 并写明原因 —— 不猜机型、不猜芯片。

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <VideoToolbox/VideoToolbox.h>

#include "capabilities_apple.h"

#include "cq/pal/capabilities.h"

namespace cq {
namespace apple {
namespace {

// ---------------------------------------------------------------------------
// Metal 设备（懒加载 + 缓存）
// ---------------------------------------------------------------------------
// MTLCreateSystemDefaultDevice() 有创建开销，且能力查询可能被较频繁调用
// （RenderGraph 后端选择、导出前检查、UI 能力标签），故缓存一次。
// 函数内 static 的初始化由编译器保证线程安全。
id<MTLDevice> GetMetalDevice() {
    static id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    return device;
}

// ---------------------------------------------------------------------------
// 硬件解码能力
// ---------------------------------------------------------------------------
// 依据：VTIsHardwareDecodeSupported()
//   官方可用性 —— iOS 11.0+ / iPadOS 11.0+ / macOS 10.13+ / tvOS 11.0+ / visionOS 1.0+
//   （Apple Developer Documentation，2026-09-29 核对）
//   部署目标 iOS 16 / macOS 15.4（ADR-0010）均满足 → **无需 @available 守卫**。
//
// 这比 PALA-011 用的会话探针覆盖面更广：PALA-011 依赖
// kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder，该常量要求
// **iOS 17.0+**，iOS 16 上只能"不知为不知"（见 media_decode.mm 注释）。
// 本函数在 iOS 16 上就能如实上报硬解能力。
CapabilityValue QueryHwDecode(CMVideoCodecType codec) {
    return VTIsHardwareDecodeSupported(codec) ? CapabilityValue::kYes
                                              : CapabilityValue::kNo;
}

// ---------------------------------------------------------------------------
// 硬件编码能力（一次性会话探针）
// ---------------------------------------------------------------------------
// ⚠️ Apple **没有** VTIsHardwareEncodeSupported 这类直接查询 API。
//    唯一可靠手段：建立一次性 VTCompressionSession，再查询
//    kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder。
//
// ⚠️ 平台事实（2026-10-05 本机 iPhoneOS17.2 SDK 头文件实证）：这两个常量在
//    VTCompressionProperties.h 中被 `#if !TARGET_OS_IPHONE` **整体包裹** ——
//    iOS 上任何版本都不声明（macOS-only API，头部标注的 ios(8.0) 不生效）。
//    旧注释「常量要求 iOS 17.4+」是误判（把 Decoder 侧 ios(17.0) 的规则错套
//    到了 Encoder 侧），`@available` 守卫救不了「use of undeclared identifier」。
//
//    iOS：**无法探测**。此处**不能**返回 kNo —— 那等于断言"设备没有硬件编码"，
//    而真实情况是"未知"（iOS 设备实际普遍具备 H.264 硬编）。
//    返回 **kDegraded**：语义为「未确认，上层须按软编路径处理，并在真正创建
//    会话时按实际结果处理」。
CapabilityValue DoProbeHwEncode(CMVideoCodecType codec) {
#if !TARGET_OS_IPHONE
    // macOS：常量自 10.9 起在 SDK 中声明，部署目标 15.4，直接探针。
    // 探针用 1080p：分辨率会影响硬件编码器可用性，取项目最常用的档位。
    constexpr int32_t kProbeWidth = 1920;
    constexpr int32_t kProbeHeight = 1080;

    NSDictionary* spec = @{
        (__bridge id)kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: @YES,
    };
    VTCompressionSessionRef session = nullptr;
    OSStatus st = VTCompressionSessionCreate(
        kCFAllocatorDefault, kProbeWidth, kProbeHeight, codec,
        (__bridge CFDictionaryRef)spec, nullptr, nullptr, nullptr, nullptr, &session);
    if (st != noErr || session == nullptr) {
        // 连会话都建不起来 → 该编码格式在此设备上不可用（硬软皆无）。
        return CapabilityValue::kNo;
    }
    CapabilityValue result = CapabilityValue::kNo;
    CFBooleanRef hw = nullptr;
    if (VTSessionCopyProperty(
            session, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
            kCFAllocatorDefault, &hw) == noErr &&
        hw != nullptr) {
        result = (hw == kCFBooleanTrue) ? CapabilityValue::kYes : CapabilityValue::kNo;
        CFRelease(hw);
    }
    VTCompressionSessionInvalidate(session);
    CFRelease(session);
    return result;
#else
    (void)codec;  // iOS：无法探测，如实返回"未知"
    return CapabilityValue::kDegraded;
#endif
}

// 探针会创建并销毁一个 VTCompressionSession，有开销，故每个 codec 缓存一次结果。
CapabilityValue ProbeHwEncodeH264() {
    static const CapabilityValue v = DoProbeHwEncode(kCMVideoCodecType_H264);
    return v;
}
CapabilityValue ProbeHwEncodeHevc() {
    static const CapabilityValue v = DoProbeHwEncode(kCMVideoCodecType_HEVC);
    return v;
}
CapabilityValue ProbeHwEncodeProRes() {
    static const CapabilityValue v = DoProbeHwEncode(kCMVideoCodecType_AppleProRes422);
    return v;
}

// ---------------------------------------------------------------------------
// 后端实现
// ---------------------------------------------------------------------------
class AppleCapabilities final : public ICapabilities {
public:
    CapabilityValue Query(Capability cap) const override {
        switch (cap) {
            // ---- 硬解：VTIsHardwareDecodeSupported（iOS 11+ / macOS 10.13+）----
            case Capability::kHwDecodeH264:
                return QueryHwDecode(kCMVideoCodecType_H264);
            case Capability::kHwDecodeHevc:
                return QueryHwDecode(kCMVideoCodecType_HEVC);
            case Capability::kHwDecodeAv1:
                return QueryHwDecode(kCMVideoCodecType_AV1);
            case Capability::kHwDecodeProres:
                // ProRes 有多个变体（422 / 422HQ / 4444 / RAW），这里以最常用的
                // Apple ProRes 422 作为该能力项的判定代表。
                return QueryHwDecode(kCMVideoCodecType_AppleProRes422);

            // ---- 硬编：会话探针（iOS 17.4+ / macOS 10.9+）----
            case Capability::kHwEncodeH264:
                return ProbeHwEncodeH264();
            case Capability::kHwEncodeHevc:
                return ProbeHwEncodeHevc();
            case Capability::kHwEncodeProres:
                return ProbeHwEncodeProRes();

            // ---- 10-bit 管线：无可靠的单一查询 API ----
            case Capability::k10BitPipeline:
                // 10-bit 管线需同时满足：Metal 能处理 10-bit 像素格式（BGR10A2Unorm /
                // RGBA16Float）+ 10-bit HEVC 硬解。前者没有直接的公开查询 API
                // （-supportsFeatureSet: 已在 iOS 16 弃用，supportsFamily 的家族语义
                //  跨平台不对齐），后者又无法区分 8-bit / 10-bit profile。
                // 按 D2：不猜，返回 kDegraded —— 上层按 8-bit 处理，不报错、不谎报。
                return CapabilityValue::kDegraded;

            // ---- HDR 显示 ----
            case Capability::kHdrDisplay:
                // 从 **SDK 能力** 角度如实返回 kNo：RenderGraph 目前未接入 EDR /
                // HDR 色彩管理，即便设备支持 HDR 显示，SDK 侧也无法正确呈现。
                // 另：真实查询需 AppKit(NSScreen) / UIKit(UIScreen) 依赖，为一项能力
                // 查询给内核引入 UI 框架并不划算。待渲染侧支持 HDR 后再回来接。
                return CapabilityValue::kNo;

            // ---- GPU 特性 ----
            case Capability::kComputeShader:
                // Metal 自 1.0 起支持 kernel function，所有 Metal 设备均具备。
                return GetMetalDevice() != nil ? CapabilityValue::kYes : CapabilityValue::kNo;
            case Capability::kFloatTexture:
                // float 纹理**采样**在所有 Metal 设备上可用。
                // 注意：作为 render target 时仍须按具体 MTLPixelFormat 校验，
                // 本项只表达「float 纹理可用」，不表达「任意格式可作 RT」。
                return GetMetalDevice() != nil ? CapabilityValue::kYes : CapabilityValue::kNo;
            case Capability::kExternalMemoryImport:
                // PALA-002 已实测打通 CVPixelBuffer → CVMetalTexture 零拷贝导入
                // （IOSurface 一致性验证通过），故有 Metal 设备即视为可用。
                return GetMetalDevice() != nil ? CapabilityValue::kYes : CapabilityValue::kNo;

            // ---- NPU ----
            case Capability::kNpuInference:
                // 语义收窄为「CoreML 推理可用」（iOS 11+ / macOS 10.13+），
                // 部署目标已远超 → kYes。
                // ⚠️ **不代表实际跑在 ANE**：是否用 ANE 由 CoreML 运行时决定，
                //    没有任何 API 可预先查询（见 .ai/memory/pitfalls.md R1）。
                return CapabilityValue::kYes;

            // ---- GPU 后端标识 ----
            case Capability::kGpuMetal:
                return GetMetalDevice() != nil ? CapabilityValue::kYes : CapabilityValue::kNo;
            case Capability::kGpuGles:
                // Apple 平台 GLES 已废弃（iOS 12 / macOS 10.14 起），本项目不提供
                // GLES 后端。如实 kNo，不是"没查"。
                return CapabilityValue::kNo;
            case Capability::kGpuVulkan:
                // Apple 无原生 Vulkan（第三方 MoltenVK 属外部依赖，本项目未接入）。
                return CapabilityValue::kNo;
        }
        // 枚举被扩展但此处未覆盖时，落到安全值。刻意不写 default:，
        // 这样新增枚举项会触发 -Wswitch 让编译先失败，而不是静默走兜底。
        return CapabilityValue::kNo;
    }
};

}  // namespace

Status InstallCapabilities() {
    // 静态实例：进程生命周期内有效，满足契约「生命周期须长于查询调用」。
    // 重复调用只是重复注入同一实例，幂等。
    static AppleCapabilities backend;
    return SetCapabilitiesBackend(&backend);
}

}  // namespace apple
}  // namespace cq
