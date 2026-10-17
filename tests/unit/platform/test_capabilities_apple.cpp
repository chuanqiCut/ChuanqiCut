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
#include "cq/platform/chq_capabilities.h"

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

const char* ValueName(cq::ChqCapabilityValue v) {
    switch (v) {
        case cq::ChqCapabilityValue::kNo:
            return "no";
        case cq::ChqCapabilityValue::kYes:
            return "yes";
        case cq::ChqCapabilityValue::kDegraded:
            return "degraded";
    }
    return "?";
}

const char* CapName(cq::ChqCapability c) {
    switch (c) {
        case cq::ChqCapability::kHwDecodeH264:
            return "hw_decode_h264";
        case cq::ChqCapability::kHwDecodeHevc:
            return "hw_decode_hevc";
        case cq::ChqCapability::kHwDecodeAv1:
            return "hw_decode_av1";
        case cq::ChqCapability::kHwDecodeProres:
            return "hw_decode_prores";
        case cq::ChqCapability::kHwEncodeH264:
            return "hw_encode_h264";
        case cq::ChqCapability::kHwEncodeHevc:
            return "hw_encode_hevc";
        case cq::ChqCapability::kHwEncodeProres:
            return "hw_encode_prores";
        case cq::ChqCapability::k10BitPipeline:
            return "10bit_pipeline";
        case cq::ChqCapability::kHdrDisplay:
            return "hdr_display";
        case cq::ChqCapability::kComputeShader:
            return "compute_shader";
        case cq::ChqCapability::kFloatTexture:
            return "float_texture";
        case cq::ChqCapability::kExternalMemoryImport:
            return "external_memory_import";
        case cq::ChqCapability::kNpuInference:
            return "npu_inference";
        case cq::ChqCapability::kGpuMetal:
            return "gpu_metal";
        case cq::ChqCapability::kGpuGles:
            return "gpu_gles";
        case cq::ChqCapability::kGpuVulkan:
            return "gpu_vulkan";
    }
    return "?";
}

const cq::ChqCapability kAllCapabilities[] = {
    cq::ChqCapability::kHwDecodeH264,
    cq::ChqCapability::kHwDecodeHevc,
    cq::ChqCapability::kHwDecodeAv1,
    cq::ChqCapability::kHwDecodeProres,
    cq::ChqCapability::kHwEncodeH264,
    cq::ChqCapability::kHwEncodeHevc,
    cq::ChqCapability::kHwEncodeProres,
    cq::ChqCapability::k10BitPipeline,
    cq::ChqCapability::kHdrDisplay,
    cq::ChqCapability::kComputeShader,
    cq::ChqCapability::kFloatTexture,
    cq::ChqCapability::kExternalMemoryImport,
    cq::ChqCapability::kNpuInference,
    cq::ChqCapability::kGpuMetal,
    cq::ChqCapability::kGpuGles,
    cq::ChqCapability::kGpuVulkan,
};

void TestInstall() {
    std::printf("[test] Apple 后端安装与查询\n");
    cq::ChqStatus st = cq::apple::InstallCapabilities();
    Check(st.IsOk(), "InstallCapabilities() 返回 Ok");

    // 安装后必须能查到非 kNo 的某些项 —— 否则说明后端没真正生效。
    // 取 kNpuInference（CoreML 可用）作为探针：它在 Apple 上恒为 kYes。
    Check(cq::QueryCapability(cq::ChqCapability::kNpuInference) == cq::ChqCapabilityValue::kYes,
          "安装后 kNpuInference = kYes（证明后端真的生效）");
}

// 有**确定依据**的项，按依据断言（不依赖本机具体硬件）。
void TestDeterministicValues() {
    std::printf("[test] 有确定依据的能力项\n");
    Check(cq::QueryCapability(cq::ChqCapability::kGpuMetal) == cq::ChqCapabilityValue::kYes,
          "gpu_metal = yes（本机有 Metal 设备）");
    Check(cq::QueryCapability(cq::ChqCapability::kGpuGles) == cq::ChqCapabilityValue::kNo,
          "gpu_gles = no（Apple 平台 GLES 已废弃，本项目不提供）");
    Check(cq::QueryCapability(cq::ChqCapability::kGpuVulkan) == cq::ChqCapabilityValue::kNo,
          "gpu_vulkan = no（Apple 无原生 Vulkan）");
    Check(cq::QueryCapability(cq::ChqCapability::kHdrDisplay) == cq::ChqCapabilityValue::kNo,
          "hdr_display = no（SDK 未接入 HDR 色彩管理，如实上报）");
    Check(cq::QueryCapability(cq::ChqCapability::k10BitPipeline) == cq::ChqCapabilityValue::kDegraded,
          "10bit_pipeline = degraded（无可靠公开 API，不猜）");
    Check(cq::QueryCapability(cq::ChqCapability::kNpuInference) == cq::ChqCapabilityValue::kYes,
          "npu_inference = yes（CoreML 可用；不代表实际跑在 ANE）");
}

// 其余项：值必须合法，但不断言具体是什么（依赖设备）。
void TestAllLegalAndPrint() {
    std::printf("[test] 全部能力项（值供真机核对，见 baselines.md）\n");
    for (cq::ChqCapability cap : kAllCapabilities) {
        cq::ChqCapabilityValue v = cq::QueryCapability(cap);
        bool legal = (v == cq::ChqCapabilityValue::kNo || v == cq::ChqCapabilityValue::kYes ||
                      v == cq::ChqCapabilityValue::kDegraded);
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
