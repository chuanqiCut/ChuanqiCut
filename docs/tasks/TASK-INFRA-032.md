# TASK-INFRA-032：Swift 门面外提 `engine/bindings/swift` → `api/swift`（engine 回归纯 C++）

```yaml
id:          TASK-INFRA-032
layer:       SDK
goal:        Swift 对外门面从 engine/ 提出为顶层 api/swift/，ChuanqiCutEngine.podspec 的 pod 根随之迁移
input:       [ADR-0044 决策 2, 传哲 2026-10-16 决策 7（选 b）, RESEARCH-018 §6]
output:      [api/swift/**(22 个原入库文件 + ChuanqiCutEngine.podspec), api/{kotlin,arkts}/.gitkeep,
              双 Podfile 的 ChuanqiCutEngine 路径,
              run_gate.sh apple-prepare/swift test 两段, tools/docs/gen_api_reference.py]
write_set:   engine/bindings/**（迁出即删）→ api/swift/**, engine/ChuanqiCutEngine.podspec → api/swift/ChuanqiCutEngine.podspec,
             apps/apple/ios/Podfile, apps/apple/mac/Podfile, tools/ci/run_gate.sh,
             tools/docs/gen_api_reference.py, api/**
read_set:    engine/ChuanqiCutCore.podspec, engine/ChuanqiCutFFmpeg.podspec, .gitignore（只读，027 已预声明 api/swift/.build）
deps:        [TASK-INFRA-031]   # 同写双 Podfile 与 run_gate.sh；且传哲纪律：UI 与路径改名不同批
acceptance:
  - `git ls-files api | wc -l` = 25（= engine/bindings/swift 的 22 个 + `kotlin/.gitkeep` + `arkts/.gitkeep`
    + 随迁的 `ChuanqiCutEngine.podspec`），且 `git ls-files engine/bindings | wc -l` = 0、
    `git ls-files engine | wc -l` 前后差值恰为 **25**（⚠️ 卡面原写 23 是估错：`engine/bindings` 实测
    **24** 个入库文件而非 22 个 —— 24 + 1 podspec = 25；实测 149 → 124）
  - `find engine -maxdepth 1 -type d` 输出不含 `bindings`；剩余为
    `core/ platform/ vendor/(ignored) ffmpeg/(仅 License.md，随 ChuanqiCutFFmpeg.podspec 留在 engine/ 根内，不动)`
    + 3 个 podspec 中的 Core/FFmpeg 两个 + `NOTICE.md`（engine/ 根没有 CMakeLists.txt，顶层构建脚本在仓库根）
  - `engine/bindings/{kotlin,arkts}/.gitkeep` 两个预留占位迁到 `api/{kotlin,arkts}/.gitkeep`
  - `ChuanqiCutEngine.podspec` 的 `source_files` = `'Sources/ChuanqiCut/**/*.swift'`（pod 根 = api/swift/），
    `grep -n "bindings" api/swift/ChuanqiCutEngine.podspec` 零命中
  - 双壳 `pod install` 后 `Pods/Local Podspecs/ChuanqiCutEngine.podspec.json` 的 `source_files` 与新 spec 一致；
    两壳 xcodebuild Debug 成功
  - `swift test`（api/swift）用例数与迁移前一致；run_gate.sh apple-swift-bindings 段仍非零
  - `grep -rnI "engine/bindings" tools/ apps/ api/ engine/ README.md ui/` 零命中（活文件；docs/ 与 append-only 留给 034）。
    ⚠️ **`-I` 不是可省的**：实测唯一命中是 `apps/apple/ios/ChuanqiCut.xcworkspace/xcuserdata/…/UserInterfaceState.xcuserstate`
    二进制（被 `.gitignore:84` 忽略、未入库，Xcode 自己的历史状态，改不了也不该改）。
    去掉 `-I` 该条判据恒假；`git grep` 同范围亦 0，二者互为佐证。
verification:
  - git ls-files api | wc -l && git ls-files engine/bindings | wc -l
  - (cd api/swift && swift test --disable-sandbox --scratch-path "$PWD/../../build/spm/bindings")
  - tools/build/build_core_apple.sh --config=Release && api/swift/prepare.sh
  - 双壳 pod install + xcodebuild
risk:        pod 根变更会重算整个 ChuanqiCutEngine Pod 的文件清单与头文件映射；
             若 prepare.sh 生成的 xcframework 路径仍是旧相对路径，Pod 会"装得上但符号找不到"，
             表现为链接期错误而非 pod install 失败 —— 验收必须跑到 xcodebuild 链接完成，不能只看 pod install。
parallel:    false（同写双 Podfile / run_gate.sh）
```

## 背景

`bindings` 描述的是机制（FFI 绑定），不是角色（对外 API 表面）；而且它让 `engine/` 同时装 C++ 内核、
Apple 平台实现、Swift 门面、3 个 podspec 和二进制副本 —— 与 AGENTS.md「`core/` = C++ 共享内核，对外纯 C ABI」
的分层叙述对不上。传哲 2026-10-16 选 b：**门面外提为顶层 `api/`**，将来 `api/kotlin/`、`api/arkts/` 同层并列。

## 实现要点

- `ChuanqiCutCore.podspec` 与 `ChuanqiCutFFmpeg.podspec` 的 pod 根**不动**（仍 = `engine/`）：
  CocoaPods 要求 `vendored_frameworks` 落在 podspec 同目录树下，而 FFmpeg xcframework 必须在 `engine/vendor/`。
  这条耦合在 ADR-0044 已明文登记，后续要拆须另开 ADR（决策 8）。
- `api/kotlin/`、`api/arkts/` 继续用 `.gitkeep` 表达预留（决策 9）。
- `Tests/SwiftSmoke/main.swift`、`prepare.sh`、`run_smoke.sh` 里的相对路径与 `Package.swift` 的
  `unsafeFlags`/`linkerSettings` 路径要随迁移重算，逐条核对而不是全局替换。
- ⚠️ **`source_files` 是 pod 根相对，不是仓库根相对**（本批最危险的静默失效点）：机械把
  `bindings/swift/…` 替换成 `api/swift/…` 会得到 `api/swift/Sources/ChuanqiCut/**/*.swift`，
  而 pod 根已经是 `api/swift/` → 该 glob 落在 pod 根**之外**，CocoaPods **静默丢弃全部源文件**
  （`pod install` 仍 exit 0，Pods 工程里 8 个 `.swift` 引用变 0，`libChuanqiCutEngine.a` 成空壳）。
  正确写法是去掉前缀 = `'Sources/ChuanqiCut/**/*.swift'`；取证不能只看 `pod install`，
  要 `grep -c "path = Sources/ChuanqiCut/" Pods/Pods.xcodeproj/project.pbxproj` = **8**
  加 App 二进制 `nm | grep -c ChuanqiCutEngine` 非零（P149 同族：搬家批的兜底假设一律不成立）。
- ⚠️ **相对符号链接会随 `git mv` 一起搬走并失效**（卡面初版漏项）：
  `Sources/ChuanqiCutCore/include/cq_sdk.h -> ../../../../../core/cq/cq_sdk.h`
  旧路径上溯 5 层落在 `engine/`，搬家后同样 5 层落在**仓库根** → 目标不存在，
  `swift test` 会报 `no such module`/头文件找不到。新目标 =
  `../../../../../engine/core/cq/cq_sdk.h`。`git` 里表现为 `D`+`A` 成对（不是 `R`），
  改完必须 `test -f` 实证解析成功，而不是看 `git status` 有改名。
- `.package(path: "../../api/swift")` 的本地包**身份取目录末段**（旧 `bindings/swift` → `"swift"`，
  新 `api/swift` → 仍是 `"swift"`），故 `.product(name: "ChuanqiCutEngine", package: "swift")`
  **不需要改** —— 属巧合而非设计，别把它当规律用（P137）。
- `docs/api/engine-api.md` 是生成物：`gen_api_reference.py` 的 `HEADER` 随迁移改路径后必须**重跑生成器**
  （`--check` 只比对，不改写）。本批重跑顺带暴露该文档**长期过期**（见「实测」里的漂移数字），
  因为它不在门禁里 —— 归 INFRA-034 补。

## 验收

见 yaml；重点是 xcodebuild **链接**通过（不是 pod install 通过）。

## 实测（2026-10-16，本机 = 集成机）

搬家纯度与覆盖面：

| 项 | 结果 |
|---|---|
| `git ls-files api` / `engine/bindings` / `engine` | **25 / 0 / 124**（迁移前 engine=**149** → 差 **25**，卡面原估 23 已纠正） |
| 移动集拆分（`git diff --cached -M --name-status -- api engine`） | **15 条 `R100`**（逐字搬迁）+ **9 条 `R0xx`**（搬迁且改路径字面）+ **1 条符号链接**（`D`+`A` 成对，目标重写，P151）= 25 |
| 入库总数守恒 | `git ls-files \| wc -l` = **857**（与 031 收口基线逐字相等，搬家不改总数） |
| `find engine -maxdepth 1` | 无 `bindings`；剩 `core/ platform/ vendor/(ignored) ffmpeg/(仅 License.md)` + `ChuanqiCutCore/FFmpeg.podspec` + `NOTICE.md`（**engine/ 根确无 CMakeLists.txt**，顶层构建脚本在仓库根） |
| 门面产物忽略状态 | `git check-ignore -v api/swift/Frameworks/…/Info.plist` → 命中 `.gitignore:68 api/swift/Frameworks/`（027 预声明生效）；`git status --porcelain -uall api` 无未忽略产物 |
| `grep -rnI "engine/bindings" tools/ apps/ api/ engine/ README.md ui/` | **0 命中**（`-I` 必需：唯一命中是 `xcworkspace/xcuserdata/…/UserInterfaceState.xcuserstate` 二进制，该路径被 `.gitignore:84` 忽略且未入库）；`git grep` 同范围亦 0 |
| `grep -n bindings api/swift/ChuanqiCutEngine.podspec` | **0 命中**，`source_files = 'Sources/ChuanqiCut/**/*.swift'` |
| 构建清单零污染 | `git grep bindings -- CMakeLists.txt tests third_party shaders tools/shaders` = 0（CMake/SPM/podspec 三套清单没有交叉引用） |

链接级证据（卡面 risk 指向的"装得上但符号找不到"）：

| 层 | 证据 |
|---|---|
| 双壳 `pod install` | ios **14/14**、mac **7/7**，exit 0；`Podfile.lock` 的 `ChuanqiCutEngine :path` = `../../../api/swift` |
| Local Podspecs JSON | ios 与 mac 两份的 `source_files` 均为 `Sources/ChuanqiCut/**/*.swift` |
| Pods 工程源码引用 | 两端各 **8** 条 `path = Sources/ChuanqiCut/*.swift`（8 个门面文件一字不差，**没有 pod 根外静默丢弃**） |
| Pod 产物 | `libChuanqiCutEngine.a` **507616B**（Debug-iphoneos）/ **511248B**（mac Debug），时间戳为本次构建 |
| App 二进制符号 | `nm -a ChuanqiCutApp \| grep -c ChuanqiCutEngine` = **1838**；mac 壳 = **1842**（链接期真有门面，不是空壳） |
| 双壳 xcodebuild | ios `ChuanqiCutApp` + mac `ChuanqiCutMacApp` 均 **BUILD SUCCEEDED**，`error:` **0** 行，warning ios **24** / mac **6**（与 031 基线逐字相同，全为既有 deployment-target 9.0 与 SHADER-001 run-script 无输出项） |

窄检：

- `api/swift` `swift test`（scratch 先清空 `build/spm/bindings` 187M 后从零重建）：
  **Executed 26 tests, 0 failures** —— 与迁移前基线 **26** 逐字相等（卡面验收「用例数与迁移前一致」满足）。
- `api/swift/prepare.sh`：新根 `ROOT_DIR=../..` 解析到仓库根，xcframework 副本 **4.5M** 重建成功。
- `api/swift/run_smoke.sh`：直连 `build/apple/ChuanqiCut.xcframework/macos-arm64_x86_64/libChuanqiCut.a`
  编译并运行 → `version: 0.1.0` + **PASSED**（链接级 + 空隙语义）。
- `ui/SharedUI` `swift build` → Build complete；`ui/ChuanqiCutEditor` `swift test` → **81/81** 0 失败。
  两包的 `.package(path: "../../api/swift")` 实测解析通过（**字面 grep 抓不到，必须实跑**）。
- `python3 tools/docs/gen_api_reference.py` + `--check` → 一致，`docs/api/engine-api.md` 重生成
  **9 节 / 95 条声明**（生成器自己的计数口径）/ **516 行**；与 `cq_sdk.h` 的**符号名**对比是
  **76 → 103**（含 struct，两个数不同名，别混用）。
- `swift package dump-package` + 改注释后复跑 `swift test` → manifest 解析正常
  （targets = `ChuanqiCutCoreBinary` / `ChuanqiCutCore` / `ChuanqiCutEngine` / `ChuanqiCutTests`，
  products = `ChuanqiCutEngine`），**Executed 26 tests, 0 failures**（`error:` 0 行）。

### 全量门禁（2026-10-16 21:43:41 → 22:02:39，**18m58s**，本机 = 集成机）

**run1 FAIL → run2 全绿**，中间只做了一件事：清 `build/spm/*`（1.2G 增量缓存）——
`apple-import` 段报 `missing inputs: …/engine/bindings/swift/Frameworks/ChuanqiCut.xcframework/…`，
而 import 包只引 `../SharedUI`，属**传递依赖被缓存钉死旧绝对路径**（P152）。
**没有改任何代码**。判"搬家造成回归"之前必须先清 scratch。

| 步 | 结果 |
|---|---|
| deps / headers / artifacts / layer-hygiene | 全 PASS；headers scanned **43**、**0** violation；两趟合计 **119** 文件 R1 **0**；无构建产物入库 |
| core-dbg / core-rel | 各 **100% tests passed out of 52**，real **149.75s** / **144.73s** |
| apple-xcframework / apple-prepare | PASS（`prepare.sh` 从新根 `../..` 复制 xcframework 入 package） |
| apple-swift-bindings / sharedui / player / camera / import / editor | **26 / build 27.68s / 52 / 77 / 16 / 81**，合计 **252** 用例 **0 失败** —— 与 031 基线逐字相等 |
| golden | `verify.py --json` built_ok **21** / fail **0** / unbuilt **0** / **901784** bytes |
| 摘要 | **PASS=15 / FAIL=0 / SKIP=0**，exit 0 |

## 顺带发现（不由本批改）

- **接口文档长期过期**：`gen_api_reference.py --check` **不在 `run_gate.sh` 的 15 步里**，
  `docs/api/engine-api.md` 落后实际 ABI —— 本次重跑实测符号 **76 → 103**（新增 **24 个函数 + 3 个 struct**：
  `cq_session_split_clip`/`remove_clip`/`remove_track`/`set_canvas`/`move_clip_to_track`/效果参数系列/
  `cq_audio_preview_*` 等），行数 **406 → 516**，**无符号消失**（纯遗漏，非删除）。→ 已登记为
  INFRA-034 验收项「接口文档入门禁」（P151 附带发现）。
- **027 的过渡忽略规则已失效**：`.gitignore:66-67` 与 `.zcodeignore:70-71` 四条
  `engine/bindings/swift/{Frameworks,.build}/` 现在指向不存在的目录 → INFRA-034「死忽略规则清理」。
- **`ChuanqiCutEngine.podspec` 的 license 文本仍写** `FFmpeg LGPL linking strategy pending (see ADR-0010)`，
  而 `docs/COCOAPODS.md:106` 记录该策略**已定**（ADR-0036）。License 声明会随 podspec JSON 分发给集成方，
  **不由布局批顺手改**，需 owner 确认文本后再动（登记于此，避免当成搬家遗漏）。
- **`docs/COCOAPODS.md` 整棵 pod 树过期**（:4/:5/:16/:64/:137）：门面外提后"engine/ = 两个本地 spec 同目录"
  的叙述不再成立 → 已并入 INFRA-034 的活文档收口口径（实测残留数字见该卡）。
- `ui-apple.md` 的「工程生成」段仍写 `xcodegen generate`，与 ADR-0037（XcodeGen 已退役）冲突 → 同归 034 活文档债。
- **`linkcheck_docs.py` 是自反的**（收口自查抓到，→ **P153**，已归 034 验收项 + write_set）：
  本次实测断链 **9** 条，而 INFRA-035 收口记的是 **6** —— 多的 3 条是
  `TASK-BACKLOG.md:567` / `TASK-INFRA-034.md:90` / `TASK-INFRA-035.md:70`
  指向已改名的 `PAL-接口契约.md`，**正是那几张卡"登记待清理死链"的清单本身**
  （`:22` 的 `BACKTICK_PATH` 对所有反引号内 `*.md` 做存在性检查）。
  → 035 行的历史数字按 append-only **不回改**，只向前登记。

## 回写（本批实际落盘，逐项核过）

- [x] `.ai/modules/ui-apple.md`：**pod 根表**（Core/FFmpeg = `engine/`，Engine = `api/swift/`）+
      依赖链改写成四层 Pod + `api/swift/` 进工程结构树 + `TestPaths`（api/swift，上溯 5 层）标注；
      **模块册**加 2026-10-16 INFRA-032 行（全量门禁 + 双壳 + 链接级数字）
- [x] `.ai/modules/core.md`：日志装配形状的 Swift 投影路径 → `api/swift/Sources/ChuanqiCut/ChuanqiCut.swift`
- [x] `.ai/modules/platform-apple.md` / `platform-android.md`：**边界**行 `bindings/{swift,kotlin}` → `api/{swift,kotlin}`
- [x] `.ai/modules/preview.md`：三处可执行命令 `cd bindings/swift …` / `./bindings/swift/run_smoke.sh` → `api/swift`
- [x] `.ai/modules/media.md`：PreviewAudio 行路径
- [x] `.agents/skills/cq-build-test/SKILL.md:80`：`bindings/swift/prepare.sh` → `api/swift/prepare.sh`
      （**会被下一个 agent 当命令执行**，属"活文件"，不等 034）
- [x] `README.md` 附二「主要目录」：门面行改 `api/swift/`，顺带补 031 漏项（`ui/` 与 `apps/apple/` 两行）
- [x] ADR-0044 §2：落地状态 + 两个隐性连带项（符号链接、`.package` 身份取目录名）；
      遗留段：把「Core/FFmpeg pod 根仍 = `engine/`」标为**已登记事实**（非待办）
- [x] `api/swift/Package.swift` 顶部注释三处纠过期（门禁跑完后才动，避免与读取竞争）：
      「Swift 绑定」→「Swift 对外门面 + pod/package 根 = 本目录」、结构表补 `ChuanqiCutCore` 并把
      `ChuanqiCut` 改成真实 target 名 `ChuanqiCutEngine`、`Frameworks/…` 的「符号链接到 build/apple」
      改成 **`cp -R` 复制**（`prepare.sh:37` 实测是复制；binaryTarget 必须在 package 树内）。
      改后 `dump-package` + `swift test` **26/26** 复验
- [x] `.ai/memory/pitfalls.md`：**P150**（`source_files` 相对 pod 根，全局替换会静默丢源码 + 三层取证口径）、
      **P151**（相对符号链接不随 `git mv` 改写目标，git 显示 `D`+`A` 非 `R`）、
      **P152**（SPM 增量缓存钉死旧绝对路径 → 未受影响的包照样把门禁跑红；先清 scratch 再判回归）、
      **P153**（`linkcheck_docs.py` 把叙述里的死路径也当链接 → 判据自反，归 034 修工具）
- [x] `.ai/memory/baselines.md`：032 收口数字段（供 033/034 逐条复对）
- [x] `docs/tasks/TASK-INFRA-034.md`：新增两条验收（`gen_api_reference --check` 入门禁、死忽略规则清理）+
      活文档零残留 pattern 扩成含 `bindings/swift` 并写入实测基线 +
      **hygiene 脚本必须走 `git ls-files`（裸 `grep -r` 会命中已忽略的 `xcuserdata` 二进制 → 判据恒假）** +
      追加 `docs/README.md:136` 双重过期残留（`engine/bindings/` + 早已改名的 `CChuanqiCut`）
- [x] `docs/tasks/TASK-BACKLOG.md` §15：032 行置 ✅ 并贴数字
- [x] `.workbuddy/memory/2026-10-16.md`：当日日志（append-only）
