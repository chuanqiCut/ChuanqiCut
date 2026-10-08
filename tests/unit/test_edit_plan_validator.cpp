// ChuanqiCut — EditPlan 校验器单测（AIEDIT-001）
//
// 遍历 golden 样例集（manifest 驱动），逐例断言校验器结果与预期一致；
// 补充静态检查：错误码值稳定、op 名往返、红线 4 timescale 机器检查。

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

#include "cq/ai/edit_plan.h"
#include "ai/plan/edit_plan_validator.h"  // core/src 私有头（tests CMake 注入 src 目录）
#include "cq/base/rational_time.h"
#include "cq/base/status.h"

#ifndef CQ_EDIT_PLAN_GOLDEN_DIR
#define CQ_EDIT_PLAN_GOLDEN_DIR "."
#endif

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

cq::EditPlanAssetTable DefaultAssets() {
    cq::EditPlanAssetTable assets;
    assets.push_back({"a1", cq::RationalTime{1200000, cq::kProjectTimeScale}, 3});
    assets.push_back({"a2", cq::RationalTime{2400000, cq::kProjectTimeScale}, 4});
    assets.push_back({"a3", cq::RationalTime{600000, cq::kProjectTimeScale}, 2});
    return assets;
}

std::string ReadFile(const char* path) {
    std::ifstream ifs(path, std::ios::in | std::ios::binary);
    if (!ifs) return {};
    std::string content;
    ifs.seekg(0, std::ios::end);
    const auto sz = ifs.tellg();
    ifs.seekg(0, std::ios::beg);
    content.resize(static_cast<size_t>(sz));
    ifs.read(content.data(), static_cast<std::streamsize>(sz));
    return content;
}

struct Case {
    std::string filename;
    bool expect_valid;
    std::string expect_code_name;
};

std::vector<Case> ParseManifest(const char* dir) {
    std::string path = std::string(dir) + "/manifest.txt";
    std::ifstream ifs(path);
    std::vector<Case> cases;
    if (!ifs) return cases;
    std::string line;
    while (std::getline(ifs, line)) {
        if (line.empty() || line[0] == '#') continue;
        Case c;
        const auto semi1 = line.find(';');
        if (semi1 == std::string::npos) continue;
        c.filename = line.substr(0, semi1);
        const auto semi2 = line.find(';', semi1 + 1);
        if (semi2 == std::string::npos) {
            c.expect_valid = (line.substr(semi1 + 1) == "valid");
        } else {
            c.expect_valid = (line.substr(semi1 + 1, semi2 - semi1 - 1) == "valid");
            c.expect_code_name = line.substr(semi2 + 1);
        }
        cases.push_back(std::move(c));
    }
    return cases;
}

void TestGoldenCases() {
    std::printf("[test] golden 样例集（manifest 驱动）\n");
    const char* dir = CQ_EDIT_PLAN_GOLDEN_DIR;
    auto cases = ParseManifest(dir);
    Check(!cases.empty(), "manifest 非空");
    const auto assets = DefaultAssets();
    int valid_pass = 0, invalid_pass = 0;
    for (const auto& c : cases) {
        std::string filepath = std::string(dir) + "/" + c.filename;
        std::string json = ReadFile(filepath.c_str());
        // 非空检查只对合法用例做：invalid_json_empty.json 的测试内容就是空串
        // （校验器对空输入拒绝 = 预期行为，读取层面文件存在即可）。
        if (c.expect_valid) {
            Check(!json.empty(), ("读取 " + c.filename + " 非空").c_str());
        }
        cq::EditPlan plan;
        cq::ai::EditPlanError err;
        const cq::Status s = cq::ai::ValidateEditPlanJson(json, assets, plan, err);
        if (c.expect_valid) {
            const bool ok = s.IsOk();
            if (ok) ++valid_pass;
            Check(ok, (c.filename + ": 预期合法，实际 code=" +
                       std::to_string(static_cast<int32_t>(err.code)) +
                       " path=" + std::string(err.path)).c_str());
        } else {
            const bool rejected = s.IsError();
            if (rejected) {
                const char* actual_name = cq::StatusToString(err.code);
                const bool name_match =
                    std::strcmp(actual_name, c.expect_code_name.c_str()) == 0;
                if (name_match) ++invalid_pass;
                Check(name_match,
                      (c.filename + ": 预期 " + c.expect_code_name +
                       "，实际 " + std::string(actual_name)).c_str());
            } else {
                Check(false, (c.filename + ": 预期非法，实际通过").c_str());
            }
        }
    }
    std::printf("  合法通过: %d  非法精确匹配: %d / 总 %zu\n",
                valid_pass, invalid_pass, cases.size());
}

void TestStableErrorCodes() {
    std::printf("[test] AI 决策错误码值稳定\n");
    static_assert(static_cast<int32_t>(cq::StatusCode::kAiPlanJsonMalformed) == 9500);
    static_assert(static_cast<int32_t>(cq::StatusCode::kAiPlanSchemaUnknown) == 9501);
    static_assert(static_cast<int32_t>(cq::StatusCode::kAiPlanFieldMissing) == 9502);
    static_assert(static_cast<int32_t>(cq::StatusCode::kAiPlanFieldType) == 9503);
    static_assert(static_cast<int32_t>(cq::StatusCode::kAiPlanFloatTime) == 9504);
    static_assert(static_cast<int32_t>(cq::StatusCode::kAiPlanTimescaleMismatch) == 9505);
    static_assert(static_cast<int32_t>(cq::StatusCode::kAiPlanTimeNonPositive) == 9506);
    static_assert(static_cast<int32_t>(cq::StatusCode::kAiPlanUnknownOp) == 9507);
    static_assert(static_cast<int32_t>(cq::StatusCode::kAiPlanAssetUnknown) == 9508);
    static_assert(static_cast<int32_t>(cq::StatusCode::kAiPlanShotOutOfRange) == 9509);
    static_assert(static_cast<int32_t>(cq::StatusCode::kAiPlanSourceRange) == 9510);
    static_assert(static_cast<int32_t>(cq::StatusCode::kAiPlanTimelineOverlap) == 9511);
    static_assert(static_cast<int32_t>(cq::StatusCode::kAiPlanReorderNotPermutation) == 9512);
    static_assert(static_cast<int32_t>(cq::StatusCode::kAiPlanTransitionKindUnknown) == 9513);
    Check(true, "AI 决策段 static_assert 全过");
}

void TestOpNameRoundTrip() {
    std::printf("[test] op 名往返\n");
    for (int32_t i = 0; i <= static_cast<int32_t>(cq::EditPlanOp::kSetBgmPlaceholder); ++i) {
        const auto op = static_cast<cq::EditPlanOp>(i);
        const char* name = cq::EditPlanOpName(op);
        Check(name != nullptr, "op 名非空");
        cq::EditPlanOp roundtrip = cq::EditPlanOp::kUnknown;
        Check(cq::EditPlanOpFromName(name, roundtrip), "op 往返查找成功");
        Check(roundtrip == op, "op 往返一致");
    }
    cq::EditPlanOp dummy = cq::EditPlanOp::kUnknown;
    Check(!cq::EditPlanOpFromName("no_such_op", dummy), "未知 op 名拒绝");
}

void TestTransitionKindRoundTrip() {
    std::printf("[test] 转场类型名往返\n");
    for (int32_t i = 0;
         i <= static_cast<int32_t>(cq::EditPlanTransitionKind::kDipToBlack); ++i) {
        const auto kind = static_cast<cq::EditPlanTransitionKind>(i);
        const char* name = cq::EditPlanTransitionKindName(kind);
        Check(name != nullptr, "kind 名非空");
        cq::EditPlanTransitionKind roundtrip = cq::EditPlanTransitionKind::kUnknown;
        Check(cq::EditPlanTransitionKindFromName(name, roundtrip), "kind 往返成功");
        Check(roundtrip == kind, "kind 往返一致");
    }
}

void TestTimescaleMachineCheck() {
    std::printf("[test] 红线 4：timescale != 120000 被机器检查拦截\n");
    const char* json =
        "{\"schema\":\"cq.editplan/1\","
        "\"based_on\":{\"assets\":[\"a1\"],\"timeline_rev\":0},"
        "\"actions\":[{\"op\":\"place_clip\",\"asset\":\"a1\",\"shot\":0,"
        "\"timeline_start\":{\"value\":0,\"timescale\":60000},"
        "\"source_in\":{\"value\":0,\"timescale\":120000},"
        "\"duration\":{\"value\":1000,\"timescale\":120000}}]}";
    cq::EditPlan plan;
    cq::ai::EditPlanError err;
    const auto assets = DefaultAssets();
    cq::Status s = cq::ai::ValidateEditPlanJson(json, assets, plan, err);
    Check(s.IsError(), "timescale 60000 被拒绝");
    Check(err.code == cq::StatusCode::kAiPlanTimescaleMismatch,
          "错误码为 kAiPlanTimescaleMismatch");
}

}  // namespace

int main() {
    std::printf("== ChuanqiCut ai_edit_plan_validator 单测 ==\n");
    TestStableErrorCodes();
    TestOpNameRoundTrip();
    TestTransitionKindRoundTrip();
    TestTimescaleMachineCheck();
    TestGoldenCases();
    std::printf("\n== 结果：%d 项检查，%d 项失败 ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
