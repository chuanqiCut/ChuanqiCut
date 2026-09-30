# TASK-BIND-002：Swift 绑定层（SPM package）

- **层**：SDK 绑定
- **依赖**：**BIND-001（已完成）**
- **阻塞**：UIA-001~008（全部 iOS/macOS UI 任务）
- **日期**：2026-09-30

## 背景

BIND-001 冻结了 `cq_sdk.h` 纯 C ABI，但 Swift 侧仍无法调用——
`bindings/swift/` 只有一个 `.gitkeep`。本任务把 C ABI 包成 Swift package。

## 写集（write_set）

| 文件 | 动作 | 说明 |
|---|---|---|
| `bindings/swift/Package.swift` | 新增 | SPM manifest（3 层 target） |
| `bindings/swift/Sources/CChuanqiCut/{include,shim.c}` | 新增 | C module 桥接 |
| `bindings/swift/Sources/ChuanqiCut/ChuanqiCut.swift` | 新增 | 值类型 + 全局入口 |
| `bindings/swift/Sources/ChuanqiCut/Session.swift` | 新增 | EditorSession 的 Swift 门面 |
| `bindings/swift/Tests/ChuanqiCutTests/*.swift` | 新增 | XCTest 验收（7 例） |
| `bindings/swift/Tests/SwiftSmoke/main.swift` + `run_smoke.sh` | 新增 | 独立于 SPM 的调用链验收 |
| `bindings/swift/prepare.sh` | 新增 | 把 xcframework 放进 package |
| `tools/build/build_core_apple.sh` | 修改 | 库名 `ChuanqiCut.a` → **`libChuanqiCut.a`** |
| `.gitignore` | 修改 | 忽略 `Frameworks/` 与 `.build/` |

## 设计决策（评审点）

### D1 · 三层 target，头文件**不复制**

```
ChuanqiCutCore (binaryTarget: xcframework)
   └─ CChuanqiCut (C target: shim.c + modulemap)
        └─ ChuanqiCut (Swift target: 对外封装)
```

`Sources/CChuanqiCut/include/cq_sdk.h` 是**符号链接**指向
`core/include/cq/cq_sdk.h`。复制一份必然漂移（违反单一真源）。

### D2 · 回调一律「函数指针 + `void*` 上下文」

`@convention(c)` 闭包不能捕获变量，故用 `Unmanaged` 把 Swift 盒子作为 ctx 传入
再取回。变更体用 `passRetained`（一次性），观察者用 `passUnretained`（Session 持有）。

### D3 · 观察者默认转发到主线程

内核在 **session 线程**回调。绑定层默认 `DispatchQueue.main`，并允许指定队列
（测试里就用 `.global()`，否则主线程阻塞在 semaphore 上会自锁）。

### D4 · `changeName` 用 `StaticString` 而非 `String`

内核只保存指针、不拷贝。`StaticString` 的 `utf8Start` 指向静态存储且 NUL 结尾，
字符串字面量安全；`String` 会悬垂。这是**刻意的 API 限制**，不是笔误。

### D5 · 库名必须是 `libChuanqiCut.a`（本任务最大的坑，见下）

## 排障记录（本任务真正卡住的地方）

| 现象 | 真因 | 修复 |
|---|---|---|
| `no such module 'CChuanqiCut'` | SPM 的 C target **只有头文件、无源文件**时不生成 module | 加 `shim.c` |
| 同上（第二轮） | 符号链接相对路径层数算错（4 层写成 5 层的反例） | 改对层数 |
| `ld: library 'ChuanqiCut' not found` | **`-lNAME` 只匹配 `libNAME.a`**，而库叫 `ChuanqiCut.a` | 库改名 `libChuanqiCut.a` |
| `symbol(s) not found`（swift test） | SPM **不会**自动把 binaryTarget 的静态库链进产物 | `linkerSettings: [.linkedLibrary("ChuanqiCut")]` |
| SwiftPM 沙箱 | 本机 SPM 要写 `~/.swiftpm/security`，被沙箱拦 | 加 `--disable-sandbox` |
| ld 告警 "newer macOS 15.4 than being linked 15.0" | swiftc 默认 target 15.0 | `-target <arch>-apple-macosx15.4` |

⚠️ 教训：`swift build` **绿不等于能链接** —— library target 只编译不链接，
要等 `swift test` 链接可执行宿主时才暴露。又一次"绿灯 ≠ 可用"。

## 验证命令

```bash
# 1. 构建内核 xcframework（库名 libChuanqiCut.a）
tools/build/build_core_apple.sh --config=Release

# 2. 放进 package 并跑 Swift 验收
bindings/swift/prepare.sh
cd bindings/swift && swift test --disable-sandbox     # 期望 7/7

# 3. 独立于 SPM 的调用链验收（不依赖 binaryTarget）
bindings/swift/run_smoke.sh                            # 期望 PASSED
```

## 验收结果（2026-09-30 实测）

- `swift build`：**零告警**（Sendable 告警已按项目纪律改代码消除）
- `swift test`：**7 tests, 0 failures**
- `run_smoke.sh`：**PASSED**（version 0.1.0 从内核取到；submit → 版本 1；
  失败不推进；观察者收到版本 2；变更名不悬垂）
- 内核 CTest 未受影响（库改名只影响 Apple 打包脚本）

## 剩余风险 / 已知限制

- **`--disable-sandbox` 是本机环境所需**：SPM 要写 `~/.swiftpm/security`。
  CI 上可能不需要，届时去掉该参数。
- **任务未执行即销毁会话会泄漏闭包盒子**：内核不会回调，`passRetained` 的盒子
  无人释放。量级受队列容量限制（默认 64）。严格零泄漏需改为
  「Session 持有未完成任务注册表」（当前未做，避免过早复杂化）。
- **digest 恒为 0**：模型层（MODEL-001）未接入，与 C ABI 同一限制。
- iOS 真机未验证：本机只有 macOS 切片可跑；iPhone 17 Pro 需传哲实测。
