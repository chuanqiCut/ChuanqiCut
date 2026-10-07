// ChuanqiCut — CChuanqiCut target 的源文件（BIND-002）
//
// SwiftPM 的 C target 在「只有头文件、没有源文件」时**不会生成 module**，
// 消费方会报 `no such module 'CChuanqiCut'`（2026-09-29 实测）。
// 故本文件存在的唯一目的：让 SPM 认为这个 target 有东西可编译，
// 从而把 include/module.modulemap 编译成 Swift 可 import 的 Clang module。
//
// 这里**不**重新实现任何内核逻辑，也不复制头文件（include/cq_sdk.h 是符号链接，
// 指向 core/include/cq/cq_sdk.h，避免两份副本漂移）。

#include "cq_sdk.h"

// 占位符号：可被测试用来证明本 target 确实被编译并链接进产物。
int32_t cq_shim_marker(void) { return cq_version_major(); }
