// ChuanqiCut — XCFramework 消费者侧最小链接冒烟样例（仅用于构建门禁）
//
// 目的：证明「打得出来」≠「能被消费」。
// xcodebuild -create-xcframework 只要 .a 是合法 Mach-O 就会成功，但库里缺 UnusedKeyname
// 段、链接需要的 framework 没声明、架构/部署目标不匹配等问题，都要到真正 link 时才暴露。
//
// 约束：
//   - 只用唯一 public C ABI 头 cq_sdk.h（禁止依赖 Engine 内部 C++ 头）。
//     2026-09-29 曾凭印象 grep cq_get_version / cq_query_capability，实际这两个符号并不
//     存在（C ABI 边界尚未实现），差点写成永远不会通过的测试。
//   - 只依赖 C++20 + 标准库，不依赖任何平台类型，保持 Platform 头文件门禁语义。
//   - 输出必须可被脚本精确断言（这里打印一行 "ChuanqiCut version = 0.1.0"）。

#include <cstdio>

#include <cq_sdk.h>

int main() {
    std::printf("ChuanqiCut version = %d.%d.%d\n",
                cq_version_major(), cq_version_minor(), cq_version_patch());
    return 0;
}
