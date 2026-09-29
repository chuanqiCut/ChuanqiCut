// ChuanqiCut — Apple 能力后端单测（CORE-007，仅 Apple 平台）
//
// 目的不是"断言本机硬件长什么样"（那没有可移植意义），而是：
//   1. 后端真的被安装上，且查询路径能跑通（防「断接口」复发）
//   2. 每项返回值都在合法枚举内，且**有确定依据**的项按依据断言
//   3. 打印全部结果，供真机（iPhone 17 Pro）实测时逐项核对回填 baselines.md
//
// ⚠️ 本机为 Intel Mac：无 ANE、无 ProRes 硬编。**本机结果不能代表 iPhone**。
//    任何性能/能力结论都不得取自本机（见 .ai/memory/baselines.md 与 ADR-0010）。

#include <cstdio>

#include "capabilities_apple.h"
#include "cq/pal/capabilities.h"

namespace {

int g_failures = 0;
int g_checks = 0;

void Check(bool cond, const char* msg) {
    ++g_checks;
    if (!cond) {
        ++g_failures;
        std::printf("  FAIL: %s\n", msg);
    }
}

const char* ValueName(cq::CapabilityValue v) {
    switch (v) {
        case cq::CapabilityValue::kNo:
            return "no";
        case cq::CapabilityValue::kYes:
            return "yes";
        case cq::CapabilityValue::kDegraded:
            return "degraded";
    }
    return "?";
}

const char* CapName(cq::Capability c) {
    switch (c) {
        case cq::Capability::kHwDecodeH264:
            return "hw_decode_h264";
        case cq::Capability::kHwDecodeHevc:
            return "hw_decode_hevc";
        case cq::Capability::kHwDecodeAv1:
            return "hw_decode_av1";
        case cq::Capability::kHwDecodeProres:
            return "hw_decode_prores";
        case cq::Capability::kHwEncodeH264:
            return "hw_encode_h264";
        case cq::Capability::kHwEncodeHevc:
            return "hw_encode_hevc";
        case cq::Capability::kHwEncodeProres:
            return "hw_encode_prores";
        case cq::Capability::k10BitPipeline:
            return "10bit_pipeline";
        case cq::Capability::kHdrDisplay:
            return "hdr_display";
        case cq::Capability::kComputeShader:
            return "compute_shader";
        case cq::Capability::kFloatTexture:
            return "float_texture";
        case cq::Capability::kExternalMemoryImport:
            return "external_memory_import";
        case cq::Capability::kNpuInference:
            return "npu_inference";
        case cq::Capability::kGpuMetal:
            return "gpu_metal";
        case cq::Capability::kGpuGles:
            return "gpu_gles";
        case cq::Capability::kGpuVulkan:
            return "gpu_vulkan";
    }
    return "?";
}

const cq::Capability kAllCapabilities[] = {
    cq::Capability::kHwDecodeH264,   cq::Capability::kHwDecodeHevc,
    cq::Capability::kHwDecodeAv1,    cq::Capability::kHwDecodeProres,
    cq::Capability::kHwEncodeH264,   cq::Capability::kHwEncodeHevc,
    cq::Capability::kHwEncodeProres, cq::Capability::k10BitPipeline,
    cq::Capability::kHdrDisplay,     cq::Capability::kComputeShader,
    cq::Capability::kFloatTexture,   cq::Capability::kExternalMemoryImport,
    cq::Capability::kNpuInference,   cq::Capability::kGpuMetal,
    cq::Capability::kGpuGles,        cq::Capability::kGpuVulkan,
};

void TestInstall() {
    std::printf("[test] Apple 后端安装与查询\n");
    cq::Status st = cq::apple::InstallCapabilities();
    Check(st.IsOk(), "InstallCapabilities() 返回 Ok");

    // 安装后必须能查到非 kNo 的某些项 —— 否则说明后端没真正生效。
    // 取 kNpuInference（CoreML 可用）作为探针：它在 Apple 上恒为 kYes。
    Check(cq::QueryCapability(cq::Capability::kNpuInference) == cq::CapabilityValue::kYes,
          "安装后 kNpuInference = kYes（证明后端真的生效）");
}

// 有**确定依据**的项，按依据断言（不依赖本机具体硬件）。
void TestDeterministicValues() {
    std::printf("[test] 有确定依据的能力项\n");
    Check(cq::QueryCapability(cq::Capability::kGpuMetal) == cq::CapabilityValue::kYes,
          "gpu_metal = yes（本机有 Metal 设备）");
    Check(cq::QueryCapability(cq::Capability::kGpuGles) == cq::CapabilityValue::kNo,
          "gpu_gles = no（Apple 平台 GLES 已废弃，本项目不提供）");
    Check(cq::QueryCapability(cq::Capability::kGpuVulkan) == cq::CapabilityValue::kNo,
          "gpu_vulkan = no（Apple 无原生 Vulkan）");
    Check(cq::QueryCapability(cq::Capability::kHdrDisplay) == cq::CapabilityValue::kNo,
          "hdr_display = no（SDK 未接入 HDR 色彩管理，如实上报）");
    Check(cq::QueryCapability(cq::Capability::k10BitPipeline) == cq::CapabilityValue::kDegraded,
          "10bit_pipeline = degraded（无可靠公开 API，不猜）");
    Check(cq::QueryCapability(cq::Capability::kNpuInference) == cq::CapabilityValue::kYes,
          "npu_inference = yes（CoreML 可用；不代表实际跑在 ANE）");
}

// 其余项：值必须合法，但不断言具体是什么（依赖设备）。
void TestAllLegalAndPrint() {
    std::printf("[test] 全部能力项（值供真机核对，见 baselines.md）\n");
    for (cq::Capability cap : kAllCapabilities) {
        cq::CapabilityValue v = cq::QueryCapability(cap);
        bool legal = (v == cq::CapabilityValue::kNo || v == cq::CapabilityValue::kYes ||
                      v == cq::CapabilityValue::kDegraded);
        Check(legal, CapName(cap));
        std::printf("    %-24s = %s\n", CapName(cap), ValueName(v));
    }
}

}  // namespace

int main() {
    TestInstall();
    TestDeterministicValues();
    TestAllLegalAndPrint();

    std::printf("\n%s: %d checks, %d failures\n", g_failures == 0 ? "PASSED" : "FAILED",
                g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
