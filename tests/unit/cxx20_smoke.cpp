// ChuanqiCut — 内核单测 smoke 用例（INFRA-002）
//
// 唯一目的：证明整个构建链确实按 C++20 编译，且单测能在 -Werror 下干净通过。
// 不发明任何业务逻辑，不引入测试框架依赖（选型见任务报告：doctest，待 DEPS-001
// 登记后接入）。后续每个 CORE 模块的真实单测沿用本文件的编译/警告配置即可。

#include <cstdio>

int main() {
    // 编译期断言：C++20 宏必须 >= 202002L。
    // 若工具链降级到 C++17/14，这里直接编译失败，作为最早的回归信号。
    static_assert(__cplusplus >= 202002L,
                  "ChuanqiCut requires C++20 (__cplusplus >= 202002L)");

    // 运行期再确认一次（同一常量，双重保险，且让可执行文件有可观测输出）。
    if (__cplusplus < 202002L) {
        std::printf("FAIL: __cplusplus=%ld, expected >= 202002L\n",
                    static_cast<long>(__cplusplus));
        return 1;
    }

    std::printf("OK: core compiles as C++20 (__cplusplus=%ld)\n",
                static_cast<long>(__cplusplus));
    return 0;
}
