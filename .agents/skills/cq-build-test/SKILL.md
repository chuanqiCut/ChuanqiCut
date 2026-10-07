---
name: cq-build-test
description: 代码改动后跑模块级构建与测试（先窄后宽）。全量门禁按阶段批由集成机跑（ADR-0030），开发会话不跑全量。产出精确命令、日志摘要与自查结论。
---

# 构建与测试

## 触发
任何 Swift / ObjC / C++ / Kotlin / GLSL 改动之后（模块级）；全量门禁 = 阶段批
（PLAN 阶段收尾 / 一批任务卡闭环，集成机执行）。

## 原则
**先跑最窄的相关测试。** 开发会话到此为止——**不跑全量 `run_gate.sh`（阶段批归集成机，
ADR-0030），不碰真机**；全量验证项登记进 `docs/tasks/TODO-POOL-门禁真机待办池.md`。

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
# ⚠️ tools/shaders/ 目前是占位（构建/lint 脚本尚未实现）。改 shader 时人工确认
#    Portable 层（shaders/src/）无平台扩展；脚本落地后（BACKLOG INFRA）补命令。
```

### Golden（渲染/导出相关改动必跑）
```bash
python3 tests/golden/verify.py --json   # 样本齐备性/参数一致性（需 Python ≥ 3.11）
# ⚠️ 视觉比对（PSNR/SSIM）归 QA-002，尚未实现 —— 当前 golden 门禁只查齐备性。
```

### 门禁（阶段批，集成机执行）
```bash
tools/ci/run_gate.sh          # 本机总门禁（INFRA-010）：deps 校验 + 头纯净性 +
                              # Debug/Release 全量单测 + XCFramework/Swift/SharedUI
                              # + golden 齐备性；日志落 build/gate-logs/
tools/ci/run_gate.sh --fast   # 快速档：跳过 Release 与 Apple/Swift
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
- 构建产物缓存污染 → 手动删 `build/`（无 clean.sh 脚本）后重跑
- 改了 `core/` 之后 Swift 侧报 `symbol(s) not found` → SPM 用的是 XCFramework 复制件，
  先 `tools/build/build_core_apple.sh --config=Release && bindings/swift/prepare.sh`
- 多个 worktree 共用 DerivedData → 每个 worktree 必须独立 DerivedData 路径
- golden 失败 → 先确认是"预期变更"还是"回归"，预期变更需更新 golden 并在 PR 说明
