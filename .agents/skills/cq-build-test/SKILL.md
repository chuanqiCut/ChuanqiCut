---
name: cq-build-test
description: 任何代码改动后跑构建与测试。产出精确命令、日志摘要与门禁结论。
---

# 构建与测试

## 触发
任何 Swift / ObjC / C++ / Kotlin / GLSL 改动之后。

## 原则
**先跑最窄的相关测试，再跑项目门禁。** 不要一上来跑全量（慢），也不要只跑全量（定位慢）。

## 命令

### 内核（最快反馈）
```bash
tools/build/build_core.sh --platform=apple      # 或 android
ctest --test-dir build -R <相关模块>            # 先窄后宽
ctest --test-dir build                          # 全量
```

### Apple App
```bash
xcodebuild -workspace apps/apple/ChuanqiCut.xcworkspace -scheme iOSApp build
xcodebuild -workspace apps/apple/ChuanqiCut.xcworkspace -scheme MacApp build
xcodebuild test -scheme SharedUI
```

### Android
```bash
./gradlew :cqbind:test
./gradlew :app:assembleDebug
./gradlew :app:connectedAndroidTest              # 需设备
```

### Shader
```bash
tools/shaders/build.sh --all && tools/shaders/lint.sh
```

### Golden（渲染/导出相关改动必跑）
```bash
tools/qa/golden_compare.sh --case=<case>
```

### 门禁（提交前）
```bash
tools/ci/run_gate.sh          # 编译 + 单测 + 静态检查 + 协议门禁 + SBOM
```

## 报告格式（必须）
```
执行了什么命令：
通过 / 失败：
跳过了什么（及原因）：
剩余风险：
```

**禁止**只说"已通过"而不给命令与输出摘要。

## 检查清单
- [ ] 编译零警告（项目开启 -Werror）
- [ ] 相关模块单测通过
- [ ] 渲染/导出改动已跑 golden
- [ ] 涉及依赖已跑协议门禁
- [ ] 报告含命令、结果、跳过项、风险

## 常见失败处理
- 构建产物缓存污染 → `tools/build/clean.sh` 后重试
- 多个 worktree 共用 DerivedData → 每个 worktree 必须独立 DerivedData 路径
- golden 失败 → 先确认是"预期变更"还是"回归"，预期变更需更新 golden 并在 PR 说明
