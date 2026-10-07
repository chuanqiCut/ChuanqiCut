# TASK-INFRA-021：ChuanqiCutEngine pod 正常化（头文件可见 + Binary 移除 + 重名头改名）

```yaml
id:          TASK-INFRA-021
layer:       基建
goal:        传哲三项：①头文件在工程可见；②docs 不再混入 Pods 工程；③移除从未使用的 Binary 子规格
input:       [docs/COCOAPODS.md 附注, pitfalls P83/P85, CocoaPods 1.17.0 源码实证]
output:      [ChuanqiCutEngine.podspec 正常化, 7 个重名头改名, apps/apple/pods_post_install.rb]
write_set:   ChuanqiCutEngine.podspec、core/include（7 头改名）、137 文件 include 同步、apps/apple/pods_post_install.rb、双 Podfile、docs/COCOAPODS.md 附注
read_set:    CocoaPods 1.17.0 file_accessor/file_references_installer 源码
deps:        []
acceptance:
  - Pods 工程：docs 引用 0 条；引擎组下 core/include 头文件树 42 条 + CChuanqiCut 组补录 cq_sdk.h/module.modulemap
  - headermap 零劫持（重名碰撞扫描 = 0）；core Debug 45/45 零回归
  - 双壳 BUILD SUCCEEDED
verification:
  - grep -c '"docs/' apps/apple/ios/Pods/Pods.xcodeproj/project.pbxproj   # 0
  - tools/build/build_core.sh --platform=apple --config=Debug --test
risk:    新增头文件与系统头同名会复发级联崩 → podspec 注释立禁令
parallel:    false
```

## 关键结论（源码实证，CocoaPods 1.17.0）
1. docs 混入 = 本地 pod 开发辅助（add_developer_files），无开关；pod 根=仓库根所以吞全树。
2. private_header_files 不生成导航条目；公开声明则 C++ 头进 umbrella 模块级联崩。
3. 唯一可行解 = post_install 钩子（删 docs + 补头文件树），已落 `pods_post_install.rb`。
4. 曾否决：podspec 挪子目录（pod 根外源文件静默丢弃）、符号链接（glob 不穿）、exclude_files（不作用）。
