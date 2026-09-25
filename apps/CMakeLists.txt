# apps/ — 各端原生 UI 壳（INFRA-001 占位骨架）
#
# Apple 端由 Xcode workspace 构建、Android 由 Gradle(AGP) 构建、OHOS 由 Hvigor 构建；
# 这些宿主构建走各自工具链，不走本 CMake 编译产物。
# 此处仅注册占位 target，使 CMake 工程能识别各端入口（ARCH-001 §8/§9）。
add_subdirectory(apple)
add_subdirectory(android)
add_subdirectory(ohos)
