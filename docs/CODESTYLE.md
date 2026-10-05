# CODESTYLE — ChuanqiCut 代码风格规范

> 生效：2026-10-05（CODE-001 首次成文）。
> 地位：风格判定的**唯一标准**，`cq-code-review` skill 按本文件执行。
> 约定来源 = 仓库既有主导实践（全库审计归纳），不是新发明；少数条目是对既有
> 偏离的收敛决定，随条目标注。架构红线（PAL 头零平台类型、RationalTime、
> Command、依赖治理等）在 AGENTS.md，不在此重复。

## 1. 命名与前缀（防库间冲突的硬规则）

| 对象 | 规则 | 例 |
|---|---|---|
| C ABI 公开函数 | `cq_<模块>_<动作>`，模块段 ∈ {session, preview, player, status, version, …} | `cq_session_add_clip` |
| C ABI 公开类型/句柄 | `CQ` 前缀 PascalCase，opaque 用 `typedef struct CQXxx CQXxx;` | `CQSession`、`CQSnapshot` |
| C ABI 回调 typedef | `CQXxxFn` / `CQXxxObserver` | `CQSnapshotObserver` |
| C 宏 / include guard | `CQ_` 前缀；guard 统一 `CQ_<路径>_<文件>_H_`（尾下划线） | `CQ_BASE_TIME_H_` |
| C++ 命名空间 | 内核一律 `namespace cq`；pal 平台层嵌套 `cq::apple` | |
| C++ 类型 | PascalCase；接口 `I` 前缀；叶子实现类标 `final` | `IPalResource`、`GfxDeviceImpl final` |
| C++ 函数 | PascalCase（与既有库一致，不改 snake_case） | `CreateGfxDevice` |
| 成员变量 | 尾下划线 `x_` | `mtx_`、`state_` |
| 枚举 | `enum class` + `k` 前缀值 | `StatusCode::kOk` |
| 常量 | `k` 前缀 PascalCase | `kProjectTimeScale` |
| 文件名 | snake_case，与主类型对应 | `timeline.h` → `Timeline` |
| Swift 绑定层类型 | **不带前缀**，靠 module `ChuanqiCut` 隔离（成文决策，勿加前缀） | `Session`、`Status` |
| Swift 状态码 | 语义码一律命名 static（`extension Status` 落在绑定层），**禁止绑定层之外出现裸 `Status(rawValue: n)`** | `.decodeError` |
| App 层（iOSApp/MacApp/SharedUI） | App target 内一律 internal（禁 `public`）；SharedUI 的 `public` 唯一判据 = 被 App target 消费 | |

第三方冲突红线：公共头（`core/include/cq/`）零平台类型、零第三方类型
（ffmpeg 的 `AV*`、`av_*` 宏等不得出现，机器门禁 `tools/pal/check_pal_headers.py`
+ 未来 DEPS-004 符号扫描强制）。

## 2. C++ 内核

- **无异常**：构建 `-fno-exceptions`，禁止 try/throw。ABI 边界分配一律
  `new (std::nothrow)` + 判空返回 `kResource`；内部优先容器/智能指针
  （`unique_ptr` > `shared_ptr`）。
- **错误处理**：统一 `Status` 值类型；新 ABI 返回值语义单一——错误码 XOR 数据，
  条数走 out 参数。
- **日志**：`CQ_LOG_*` 宏 + `ILogSink` 注入，禁止直写 stdout/cerr。
- **时间**：一律 `RationalTime`，唯一浮点出口 `ToSeconds()`（日志/UI 展示）。
- **include 顺序**：自带头 → 本 TU 平台头（`#import`，仅 .mm）→ `<std>` →
  `cq/` 项目头 → 同目录本地头。（pal 侧 media_decode.mm 等旧文件按此收敛。）
- **注释**：中文为主；注释中引用的 `cq_*` 函数名与 `k*` 常量必须真实存在
  （出现过幽灵引用案底，审查时按此检查）。

## 3. Swift 层

- **分层**：UI/App 只 `import ChuanqiCut`（门面），禁止直接 `import CChuanqiCut`
  或裸调 `cq_*`；相机栈豁免见 ADR-0014。
- **日志**：统一 `os.Logger`（subsystem=`com.chuanqi.cut`，category=类型名），
  禁 `print()`。
- **文案**：用户可见字符串一律中文。
- **错误**：不滥用 throws；小错误枚举按域收敛（EditorError 等），不散造
  `NSError(domain:)`。
- **禁止**：force unwrap（含 `!` 与 `try!`）；`try? XCTUnwrap` 削弱断言。
- **等待内核落地**：不拿版本号差值当判据（P33），等目标效果本身；等待原语
  收敛后统一用共享实现（STYLE-004），此前各处手写 deadline+轮询的注释必须
  说明判据。

## 4. 测试

- C++：自研框架（`Check()` + `main()` + printf 汇总），文件名 `test_<模块>.cpp`；
  平台相关用 `*_apple.cpp`；ABI 纯净用真 C TU（`test_c_abi*.c`）。
  **`Check()` 等辅助收敛到共享头（STYLE-001），禁止新测试再复制私有版本。**
- Swift：XCTest，`testXxxDoesYyy` 驼峰 + 中文断言消息。
  **`#filePath` 上溯链只允许存在于 TestPaths / RepoPath（P30）**，新测试一律用
  `TestPaths.goldenVideo` / `RepoPath.goldenVideo`；异步等待用「哨兵基准版本 +
  目标效果」判据（P31/P33）。

## 5. 工具链（逐步机器化）

- 已有机器门禁：`-Werror` 编译、`ctest`、`tools/pal/check_pal_headers.py`、
  `tools/deps/deps.py validate`、`tests/golden/verify.py`、smoke_link。
- `tools/ci/run_gate.sh` = 本机总门禁入口（合并守门/提交前跑）。
- `.clang-format`/`.clang-tidy` 待引入（INFRA-012）；引入前以本文件 +
  既有代码风格为准。
