// ChuanqiCut — cq_core 构建锚点（INFRA-002）
//
// 本文件是 CORE 系列任务落地前的占位翻译单元，刻意保持最小、零业务逻辑：
//   - 不实现任何内核 API（那些由 base/model/gfx/... 任务负责）；
//   - 仅提供一个带外部链接的锚点符号，使 cq_core 静态库非空、可参与链接；
//   - 它必须能在 -Wall -Wextra -Wconversion -Wshadow -Wold-style-cast -Werror
//     下零警告编译，否则本文件本身就是回归信号。
//
// 后续 CORE 任务会向 core/src/<module>/ 添加真实源，并可直接复用本文件的
// 编译/警告配置（已在 core/CMakeLists.txt 中统一施加）。

#include <cstddef>

// 锚点符号：返回“编译本 TU 所用的 C++ 标准宏”，供 smoke 测试间接验证工具链。
// 使用外部链接（非 static / 非匿名命名空间），避免 -Wunused-function 误伤；
// 不声明在头文件里也安全，因为 -Wmissing-declarations 不在本项目启用的警告集合内。
int cq_core_build_anchor() {
    // __cplusplus 在 C++20 下为 202002L。返回其值（int 容量足够表达该年份常量）。
    return static_cast<int>(__cplusplus);
}
