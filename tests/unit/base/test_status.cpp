// ChuanqiCut — ChqStatus 错误码单测（CORE-002）
//
// 验证：错误码数值稳定（显式写死，跨端一致）、分类覆盖媒体管线、
// 取消与错误的语义分界、无异常路径。

#include <cstdint>
#include <cstdio>

#include "cq/base/chq_status.h"

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

// 编译期守卫：每个码值必须稳定（显式写死，不得依赖自动编号）。
void TestStableValues() {
    std::printf("[test] 错误码数值稳定（跨端一致）\n");
    static_assert(static_cast<int32_t>(cq::ChqStatusCode::kOk) == 0, "kOk");
    static_assert(static_cast<int32_t>(cq::ChqStatusCode::kIoError) == 1000, "kIoError");
    static_assert(static_cast<int32_t>(cq::ChqStatusCode::kIoNotFound) == 1001, "kIoNotFound");
    static_assert(static_cast<int32_t>(cq::ChqStatusCode::kIoPermission) == 1002, "kIoPermission");
    static_assert(static_cast<int32_t>(cq::ChqStatusCode::kIoTimeout) == 1003, "kIoTimeout");
    static_assert(static_cast<int32_t>(cq::ChqStatusCode::kDecodeError) == 2000, "kDecodeError");
    static_assert(static_cast<int32_t>(cq::ChqStatusCode::kDecodeUnsupported) == 2001, "kDecodeUnsupported");
    static_assert(static_cast<int32_t>(cq::ChqStatusCode::kDecodeNoKeyframe) == 2002, "kDecodeNoKeyframe");
    static_assert(static_cast<int32_t>(cq::ChqStatusCode::kEncodeError) == 3000, "kEncodeError");
    static_assert(static_cast<int32_t>(cq::ChqStatusCode::kEncodeUnsupported) == 3001, "kEncodeUnsupported");
    static_assert(static_cast<int32_t>(cq::ChqStatusCode::kFormatUnsupported) == 4000, "kFormatUnsupported");
    static_assert(static_cast<int32_t>(cq::ChqStatusCode::kResourceExhausted) == 5000, "kResourceExhausted");
    static_assert(static_cast<int32_t>(cq::ChqStatusCode::kCancelled) == 6000, "kCancelled");
    static_assert(static_cast<int32_t>(cq::ChqStatusCode::kInvalidArgument) == 7000, "kInvalidArgument");
    static_assert(static_cast<int32_t>(cq::ChqStatusCode::kOverflow) == 8000, "kOverflow");
    static_assert(static_cast<int32_t>(cq::ChqStatusCode::kInternal) == 9000, "kInternal");
    static_assert(static_cast<int32_t>(cq::ChqStatusCode::kUnknown) == 9900, "kUnknown");
    Check(true, "所有码值显式写死（static_assert 已在编译期校验）");
}

void TestCategories() {
    std::printf("[test] 分类覆盖媒体管线\n");
    Check(cq::CategoryOf(cq::ChqStatusCode::kIoNotFound) == cq::ChqStatusCategory::kIo, "IO 分类");
    Check(cq::CategoryOf(cq::ChqStatusCode::kDecodeUnsupported) == cq::ChqStatusCategory::kDecode, "解码分类");
    Check(cq::CategoryOf(cq::ChqStatusCode::kEncodeError) == cq::ChqStatusCategory::kEncode, "编码分类");
    Check(cq::CategoryOf(cq::ChqStatusCode::kFormatUnsupported) == cq::ChqStatusCategory::kFormat, "格式分类");
    Check(cq::CategoryOf(cq::ChqStatusCode::kResourceExhausted) == cq::ChqStatusCategory::kResource, "资源分类");
    Check(cq::CategoryOf(cq::ChqStatusCode::kInvalidArgument) == cq::ChqStatusCategory::kInvalidArgument, "参数分类");
    Check(cq::CategoryOf(cq::ChqStatusCode::kOverflow) == cq::ChqStatusCategory::kNumeric, "数值分类");
    Check(cq::CategoryOf(cq::ChqStatusCode::kInternal) == cq::ChqStatusCategory::kInternal, "内部分类");
}

void TestCancelBoundary() {
    std::printf("[test] 取消与错误的语义分界\n");
    cq::ChqStatus cancelled(cq::ChqStatusCode::kCancelled);
    cq::ChqStatus internal(cq::ChqStatusCode::kInternal);

    // 取消不是错误：IsError 对 kCancelled 返回 false。
    Check(cancelled.IsOk() == false, "kCancelled 不是 Ok");
    Check(cancelled.IsError() == false, "kCancelled 不是 Error（独立信号）");
    Check(cancelled.IsCancelled() == true, "kCancelled 识别为取消");

    // 真正的错误是错误。
    Check(internal.IsError() == true, "kInternal 是 Error");
    Check(internal.IsCancelled() == false, "kInternal 不是取消");

    // operator bool：仅 Ok 为真。
    Check(static_cast<bool>(cq::ChqStatus::Ok()) == true, "Ok 可当 true");
    Check(static_cast<bool>(cancelled) == false, "Cancelled 当 false");
    Check(static_cast<bool>(internal) == false, "Internal 当 false");
}

void TestToString() {
    std::printf("[test] StatusToString 可读\n");
    Check(__builtin_strcmp(cq::StatusToString(cq::ChqStatusCode::kOk), "OK") == 0, "Ok 字符串");
    Check(__builtin_strcmp(cq::StatusToString(cq::ChqStatusCode::kCancelled), "Cancelled") == 0, "Cancelled 字符串");
    Check(__builtin_strcmp(cq::StatusToString(cq::ChqStatusCode::kUnknown), "Unknown") == 0, "Unknown 兜底");
}

}  // namespace

int main() {
    std::printf("== ChuanqiCut core_status 单测 ==\n");
    TestStableValues();
    TestCategories();
    TestCancelBoundary();
    TestToString();

    std::printf("\n== 结果：%d 项检查，%d 项失败 ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
