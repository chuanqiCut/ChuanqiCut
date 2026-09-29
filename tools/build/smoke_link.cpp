// ChuanqiCut — XCFramework 消费者侧最小链接冒烟样例（仅用于构建门禁）
//
// 目的：证明「打得出来」≠「能被消费」。
// xcodebuild -create-xcframework 只要 .a 是合法 Mach-O 就会成功，但库里缺 UnusedKeyname
// 段、链接需要的 framework 没声明、架构/部署目标不匹配等问题，都要到真正 link 时才暴露。
//
// 约束：
//   - 只用 core/include 下**真实存在**的 API（写之前先读头文件，禁止凭印象编函数名）。
//     2026-09-29 曾凭印象 grep cq_get_version / cq_query_capability，实际这两个符号并不
//     存在（C ABI 边界尚未实现），差点写成永远不会通过的测试。
//   - 只依赖 C++20 + 标准库，不依赖任何平台类型，保持 PAL 头文件门禁语义。
//   - 输出必须可被脚本精确断言（这里打印一行 "StatusToString(kOk) = OK"）。

#include <cstdio>

#include <cq/base/status.h>

int main() {
    std::printf("StatusToString(kOk) = %s\n", cq::StatusToString(cq::StatusCode::kOk));
    return 0;
}
