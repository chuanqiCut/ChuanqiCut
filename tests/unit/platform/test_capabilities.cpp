// ChuanqiCut — 能力查询单测（CORE-007，平台无关部分）
//
// 验证内核侧注入与分发的行为契约：
//   1. 未注入后端 → 一律 kNo（安全默认，绝不谎报 kYes）
//   2. 注入后端后按后端如实返回
//   3. nullptr 清除 → 回到 kNo
//   4. 枚举全部 16 项都可查询（无遗漏、无越界）
//
// ⚠️ 这些用例的本质是**防"断接口"复发**：CORE-006 冻结头文件后，
//    SetCapabilitiesBackend / QueryCapability 长期只有声明无定义，而
//    platform_headers_compile.cpp 的 static_assert 是编译期检查、不链接，
//    所以 CTest 全绿也看不出来。本用例**链接并运行**这两个函数。

#include <cstdio>

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

// 新增 ChqCapability 枚举项时必须同步此数组。
// （capabilities.mm 的 switch 刻意不写 default，新增项会先触发 -Wswitch 编译失败。）
const cq::ChqCapability kAllCapabilities[] = {
    cq::ChqCapability::kHwDecodeH264,   cq::ChqCapability::kHwDecodeHevc,
    cq::ChqCapability::kHwDecodeAv1,    cq::ChqCapability::kHwDecodeProres,
    cq::ChqCapability::kHwEncodeH264,   cq::ChqCapability::kHwEncodeHevc,
    cq::ChqCapability::kHwEncodeProres, cq::ChqCapability::k10BitPipeline,
    cq::ChqCapability::kHdrDisplay,     cq::ChqCapability::kComputeShader,
    cq::ChqCapability::kFloatTexture,   cq::ChqCapability::kExternalMemoryImport,
    cq::ChqCapability::kNpuInference,   cq::ChqCapability::kGpuMetal,
    cq::ChqCapability::kGpuGles,        cq::ChqCapability::kGpuVulkan,
};

// 固定返回同一值的测试后端。
class FixedBackend final : public cq::ChqICapabilities {
public:
    explicit FixedBackend(cq::ChqCapabilityValue v) : value_(v) {}
    cq::ChqCapabilityValue Query(cq::ChqCapability) const override { return value_; }

private:
    cq::ChqCapabilityValue value_;
};

// ---- 1. 未注入后端：一律 kNo ----
void TestNoBackend() {
    std::printf("[test] 未注入后端 -> 一律 kNo（安全默认）\n");
    // 显式清除，使本用例与执行顺序无关。
    Check(cq::SetCapabilitiesBackend(nullptr).IsOk(), "SetCapabilitiesBackend(nullptr) 返回 Ok");
    for (cq::ChqCapability cap : kAllCapabilities) {
        cq::ChqCapabilityValue v = cq::QueryCapability(cap);
        Check(v == cq::ChqCapabilityValue::kNo, CapName(cap));
    }
}

// ---- 2. 注入后端后如实返回 ----
void TestInjected() {
    std::printf("[test] 注入后端 -> 按后端如实返回\n");
    FixedBackend yes_backend{cq::ChqCapabilityValue::kYes};
    Check(cq::SetCapabilitiesBackend(&yes_backend).IsOk(), "注入后端返回 Ok");
    for (cq::ChqCapability cap : kAllCapabilities) {
        Check(cq::QueryCapability(cap) == cq::ChqCapabilityValue::kYes, CapName(cap));
    }

    FixedBackend degraded_backend{cq::ChqCapabilityValue::kDegraded};
    cq::SetCapabilitiesBackend(&degraded_backend);
    for (cq::ChqCapability cap : kAllCapabilities) {
        Check(cq::QueryCapability(cap) == cq::ChqCapabilityValue::kDegraded, CapName(cap));
    }
}

// ---- 3. 清除后端 -> 回到 kNo ----
void TestClear() {
    std::printf("[test] 清除后端 -> 回到 kNo\n");
    FixedBackend yes_backend{cq::ChqCapabilityValue::kYes};
    cq::SetCapabilitiesBackend(&yes_backend);
    Check(cq::QueryCapability(cq::ChqCapability::kHwDecodeH264) == cq::ChqCapabilityValue::kYes,
          "注入后可查询到 kYes");
    cq::SetCapabilitiesBackend(nullptr);
    Check(cq::QueryCapability(cq::ChqCapability::kHwDecodeH264) == cq::ChqCapabilityValue::kNo,
          "清除后回到 kNo");
}

// ---- 4. 枚举项数量守卫 ----
void TestEnumCoverage() {
    std::printf("[test] 枚举覆盖：%zu 项\n",
                sizeof(kAllCapabilities) / sizeof(kAllCapabilities[0]));
    // 契约枚举（capabilities.h）为 16 项。若将来扩展，须同步本数组与该注释。
    Check(sizeof(kAllCapabilities) / sizeof(kAllCapabilities[0]) == 16, "枚举共 16 项");
}

}  // namespace

int main() {
    TestNoBackend();
    TestInjected();
    TestClear();
    TestEnumCoverage();

    // 收尾：清掉后端，避免影响同进程内其他用例（CTest 各用例是独立进程，
    // 但保持"不留下全局副作用"的习惯）。
    cq::SetCapabilitiesBackend(nullptr);

    std::printf("\n%s: %d checks, %d failures\n", g_failures == 0 ? "PASSED" : "FAILED",
                g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
