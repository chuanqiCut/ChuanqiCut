# TASK-INFRA-022：引擎源码收拢 engine/（pod 根脱离仓库根）

```yaml
id:          TASK-INFRA-022
layer:       基建
goal:        core/pal/bindings 收拢到顶层 engine/，ChuanqiCutEngine pod 根随之落位，docs/ 不再被 CocoaPods 文档探测吞入
input:       [传哲拍板「目录结构不合理就调」, INFRA-021, CocoaPods developer_files 机制]
output:      [engine/{core,pal,bindings,ChuanqiCutEngine.podspec}, 根 CMakeLists/tests/build 脚本/SPM/project.yml/Podfile 路径重定基]
write_set:   engine/**（迁入）、根 CMakeLists.txt、tests/CMakeLists.txt、tools/build/{build_core_apple.sh}、engine/bindings/swift/{prepare.sh,run_smoke.sh}、tools/ci/run_gate.sh、双 SPM Package.swift、双 project.yml、双 Podfile、.gitignore
deps:        [TASK-INFRA-021]
acceptance:
  - core CMake Debug 构建 + 45/45 单测（根 CMake 入口不变，cmake -S .）
  - XCFramework Release 构建产出 + prepare.sh 就位 + bindings swift test 26/26
  - Pods 工程 docs 引用 0（pod 根=engine，docs 在外，天然脱离文档探测）
  - 双壳构建 SUCCEEDED；四包测试全绿
verification:
  - tools/build/build_core.sh --platform=apple --config=Debug --test
  - (cd engine/bindings/swift && swift test --disable-sandbox --scratch-path <root>/build/spm/bindings)
  - 双 xcodebuild + 四包 swift test
risk:    Android/OHOS 侧路径未在本机验证（apps/android CMake 为占位骨架无引用；pal/android 随迁）→ 池登记待验
parallel:    false
```

## 验证中发现并修复的三处连带（实证）

1. **podspec 本体须随迁**（engine/ChuanqiCutEngine.podspec）：`:path` 按目录找同名 podspec。
2. **CChuanqiCut include 路径四处重定基**：SharedUI/Editor/Camera 三个消费方 podspec 的
   pod_target_xcconfig + Engine 自己的 user_target_xcconfig（SRCROOT 3 级到根再进 engine/）。
3. **bindings 测试 TestPaths 上溯 5→6 层**（engine/bindings/swift/Tests/…），否则 12 个
   真实媒体用例因 golden 路径错位挂掉。

## 结构（终态）

```
engine/                    ← 跨平台引擎源（pod 根；docs/apps/tools 在外）
├── ChuanqiCutEngine.podspec
├── core/    （C++ 内核：include + src + tests 注册）
├── pal/     （apple/android/ohos 适配）
└── bindings/（Swift 绑定 SPM 包：Package.swift/Sources/Tests/Frameworks/prepare.sh/run_smoke.sh）
根 CMakeLists.txt 仍在仓库根（cmake -S .），add_subdirectory(engine/core|engine/pal)。
tests/（C++ 单测 + golden）留根，include 路径重定基 engine/core/include。
```
