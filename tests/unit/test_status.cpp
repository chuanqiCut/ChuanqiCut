// ChuanqiCut — Status 错误码单测（CORE-002）
//
// 验证：错误码数值稳定（显式写死，跨端一致）、分类覆盖媒体管线、
// 取消与错误的语义分界、无异常路径。

#include <cstdint>
#include <cstdio>

#include "cq/base/status.h"

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
    static_assert(static_cast<int32_t>(cq::StatusCode::kOk) == 0, "kOk");
    static_assert(static_cast<int32_t>(cq::StatusCode::kIoError) == 1000, "kIoError");
    static_assert(static_cast<int32_t>(cq::StatusCode::kIoNotFound) == 1001, "kIoNotFound");
    static_assert(static_cast<int32_t>(cq::StatusCode::kIoPermission) == 1002, "kIoPermission");
    static_assert(static_cast<int32_t>(cq::StatusCode::kIoTimeout) == 1003, "kIoTimeout");
    static_assert(static_cast<int32_t>(cq::StatusCode::kDecodeError) == 2000, "kDecodeError");
    static_assert(static_cast<int32_t>(cq::StatusCode::kDecodeUnsupported) == 2001, "kDecodeUnsupported");
    static_assert(static_cast<int32_t>(cq::StatusCode::kDecodeNoKeyframe) == 2002, "kDecodeNoKeyframe");
    static_assert(static_cast<int32_t>(cq::StatusCode::kEncodeError) == 3000, "kEncodeError");
    static_assert(static_cast<int32_t>(cq::StatusCode::kEncodeUnsupported) == 3001, "kEncodeUnsupported");
    static_assert(static_cast<int32_t>(cq::StatusCode::kFormatUnsupported) == 4000, "kFormatUnsupported");
    static_assert(static_cast<int32_t>(cq::StatusCode::kResourceExhausted) == 5000, "kResourceExhausted");
    static_assert(static_cast<int32_t>(cq::StatusCode::kCancelled) == 6000, "kCancelled");
    static_assert(static_cast<int32_t>(cq::StatusCode::kInvalidArgument) == 7000, "kInvalidArgument");
    static_assert(static_cast<int32_t>(cq::StatusCode::kOverflow) == 8000, "kOverflow");
    static_assert(static_cast<int32_t>(cq::StatusCode::kInternal) == 9000, "kInternal");
    static_assert(static_cast<int32_t>(cq::StatusCode::kUnknown) == 9900, "kUnknown");
    Check(true, "所有码值显式写死（static_assert 已在编译期校验）");
}

void TestCategories() {
    std::printf("[test] 分类覆盖媒体管线\n");
    Check(cq::CategoryOf(cq::StatusCode::kIoNotFound) == cq::StatusCategory::kIo, "IO 分类");
    Check(cq::CategoryOf(cq::StatusCode::kDecodeUnsupported) == cq::StatusCategory::kDecode, "解码分类");
    Check(cq::CategoryOf(cq::StatusCode::kEncodeError) == cq::StatusCategory::kEncode, "编码分类");
    Check(cq::CategoryOf(cq::StatusCode::kFormatUnsupported) == cq::StatusCategory::kFormat, "格式分类");
    Check(cq::CategoryOf(cq::StatusCode::kResourceExhausted) == cq::StatusCategory::kResource, "资源分类");
    Check(cq::CategoryOf(cq::StatusCode::kInvalidArgument) == cq::StatusCategory::kInvalidArgument, "参数分类");
    Check(cq::CategoryOf(cq::StatusCode::kOverflow) == cq::StatusCategory::kNumeric, "数值分类");
    Check(cq::CategoryOf(cq::StatusCode::kInternal) == cq::StatusCategory::kInternal, "内部分类");
}

void TestCancelBoundary() {
    std::printf("[test] 取消与错误的语义分界\n");
    cq::Status cancelled(cq::StatusCode::kCancelled);
    cq::Status internal(cq::StatusCode::kInternal);

    // 取消不是错误：IsError 对 kCancelled 返回 false。
    Check(cancelled.IsOk() == false, "kCancelled 不是 Ok");
    Check(cancelled.IsError() == false, "kCancelled 不是 Error（独立信号）");
    Check(cancelled.IsCancelled() == true, "kCancelled 识别为取消");

    // 真正的错误是错误。
    Check(internal.IsError() == true, "kInternal 是 Error");
    Check(internal.IsCancelled() == false, "kInternal 不是取消");

    // operator bool：仅 Ok 为真。
    Check(static_cast<bool>(cq::Status::Ok()) == true, "Ok 可当 true");
    Check(static_cast<bool>(cancelled) == false, "Cancelled 当 false");
    Check(static_cast<bool>(internal) == false, "Internal 当 false");
}

void TestToString() {
    std::printf("[test] StatusToString 可读\n");
    Check(__builtin_strcmp(cq::StatusToString(cq::StatusCode::kOk), "OK") == 0, "Ok 字符串");
    Check(__builtin_strcmp(cq::StatusToString(cq::StatusCode::kCancelled), "Cancelled") == 0, "Cancelled 字符串");
    Check(__builtin_strcmp(cq::StatusToString(cq::StatusCode::kUnknown), "Unknown") == 0, "Unknown 兜底");
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
