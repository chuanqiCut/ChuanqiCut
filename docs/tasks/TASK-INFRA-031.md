# TASK-INFRA-031：UI 组件上提为扁平顶层 `ui/`（apps/apple/packages → ui/）

```yaml
id:          TASK-INFRA-031
layer:       UI
goal:        五个 Swift UI Pod 从 apps/apple/packages/ 上提为顶层 ui/<Module>/，
             apps/ 只留 ios/ 与 mac/ 两个壳工程
input:       [ADR-0044 决策 3, RESEARCH-018 §3 决策 5/6, INFRA-026 契约]
output:      [ui/{SharedUI,ChuanqiCutPlayer,ChuanqiCutImport,ChuanqiCutEditor,ChuanqiCutCamera,ChuanqiCutDraft}/**,
              双 Podfile 路径, 双壳 pbxproj 文件引用, run_gate.sh 五段包路径, beauty_harness 脚本路径]
write_set:   apps/apple/packages/**（迁出即删）→ ui/**（含 6 个 `Package.swift`：Editor/SharedUI 的
             `.package(path:)` 深度 4→2 必改，其余 4 个只随迁移改注释）,
             apps/apple/ios/Podfile（含 TimelineKit 路径守卫，池 [20] 过渡防护项）, apps/apple/mac/Podfile,
             apps/apple/ios/ChuanqiCut.xcodeproj/project.pbxproj,
             apps/apple/ios/ChuanqiCut.xcworkspace/contents.xcworkspacedata（实测无 packages 字面，预期不改）,
             apps/apple/mac/ChuanqiCut.xcodeproj/project.pbxproj,
             apps/apple/mac/ChuanqiCut.xcworkspace/contents.xcworkspacedata（同上）,
             tools/ci/run_gate.sh, tools/qa/beauty_harness/build_and_run.sh,
             apps/apple/*/RepoPath.swift（若存在仓库根推导）→ 实为 ui/ChuanqiCutEditor/Tests/…/RepoPath.swift,
             活文档：README.md、.ai/modules/{ui-apple,preview}.md、.agents/skills/cq-build-test/SKILL.md、
             .ai/memory/pitfalls.md（P149 新增 + 4 处前瞻型路径回填，历史"现象"行不动）、
             docs/tasks/TODO-POOL-门禁真机待办池.md（池 [20] 勾防护 + 新增池 [21]）、
             docs/tasks/TASK-INFRA-034.md（登记 docs/COCOAPODS.md 与 docs/specs 的残留债）
read_set:    .gitignore（027 已冻结，只读）, engine/*.podspec
deps:        [TASK-INFRA-026]
acceptance:
  - `git ls-files ui | wc -l` = 124 且 `git ls-files apps/apple/packages | wc -l` = 0
  - `grep -rn "packages" apps/apple/*/Podfile tools/ci/run_gate.sh` 零命中
  - **门禁没有静默变空**：run_gate.sh 的 apple-* 五段（sharedui/player/camera/import/editor）
    每段仍各报告非零用例数（贴出五段 `Test Suite ... passed` 行）
  - 五包用例总数与迁移前一致（迁移前先用 `tools/ci/run_gate.sh` 跑一趟取基线数字）
  - 双壳 `bundle exec pod install` + `xcodebuild`（Debug）成功，Podfile.lock 的本地 Pod 路径全部指向 `../../../ui/...`
    （相对 `apps/apple/{ios,mac}/` 是三层上溯到仓库根，不是四层 —— 卡面原写 `../../../../` 有误，2026-10-16 实测纠正）
  - **`swift test` 依赖解析没断**：`ui/ChuanqiCutEditor/Package.swift` 与 `ui/SharedUI/Package.swift` 的
    `.package(path:)` 深度已由 4 层改到 2 层，两包 `swift build` 成功即为证（字面 grep 抓不到，必须实跑）
  - **图层卫生覆盖不掉数**：`check_uiview_layer_hygiene.py apps/apple` 与 `... ui` 两趟报告的文件数之和
    = 迁移前单趟的 **119**（迁移前基线见 `build/gate-logs/layer-hygiene.log` 首行）
  - `python3 tools/compliance/check_uiview_layer_hygiene.py ui` 退出码 0（P131 图层铁律扫描根随迁移）
verification:
  - git ls-files ui | wc -l && git ls-files apps/apple/packages | wc -l
  - tools/ci/run_gate.sh 2>&1 | tail -40        # 只有 --fast / --skip-apple 两个开关，无 --stage
  - (cd apps/apple/ios && bundle exec pod install && xcodebuild -workspace ChuanqiCut.xcworkspace \
      -scheme ChuanqiCut -configuration Debug -destination 'generic/platform=iOS Simulator' build)
  - mac 壳同法一趟
risk:        **pbxproj 里的 `../packages` 字面 pod install 不会重写，必须手改**（2026-10-16 实测纠正卡面初稿）：
             ADR-0037 已退役 XcodeGen、把 `ChuanqiCut.xcodeproj` 冻结为**手工真源**，所以"靠 pod install 重生成"
             这条路不存在。iOS pbxproj 的 `[CAM] metallib CIKernel` run-script 内嵌 3 处
             `$PROJECT_DIR/../packages/ChuanqiCutCamera/…`（beauty_bilateral / face_warp / beauty_guided），
             随搬家改成 `$PROJECT_DIR/../../../ui/…`。好在失败模式是**响的**（脚本 `set -euo pipefail` +
             metal 找不到源文件即报错），不会假绿；取证口径 = 三个 `.metallib` 产物时间戳为新且体积非 96B。
             改动必须最小：本批实测 `git diff --stat` = **1 行**（1 insertion / 1 deletion），mac 工程 0 改动。
             迁移后若忘记重跑 pod install，Pods 里残留旧路径 → 构建仍"绿"但用的是过期清单（假绿，P85 同类）。
             ⚠️ 顺带发现（不属本批，登记）：`ui/ChuanqiCutDraft/` 既不在两份 Podfile 也无门禁 step，
             本批只做到 `swift package resolve` 通过，**从未被真正编译过** —— 覆盖面缺口进待办池。
parallel:    true（与 029/035 写集不相交；**禁止与 032 同批** —— 传哲纪律：UI 与路径改名不同批）
```

## 背景

`apps/apple/packages/` 这个名字两头不讨好：里面是**源码**（不是打包产物），却又藏在 `apps/apple/` 下
（不是壳工程本体）。传哲 2026-10-16：「packages 感觉都是打包好的，其实是源码；源码还是在最外层按模块放，
看的时候也比较清晰，尤其是 VSCode 打开的时候」。扁平顶层 `ui/` 后，顶层一眼就是
`engine / api / ui / apps / tests / tools / docs` 七个角色。

## 实现要点

- 模块名保留 `ChuanqiCut` 前缀（决策 6）：pod 名 = Swift module 名 = `import` 语句，
  去前缀要动 57 个文件的 import，收益只有目录排序。
- `Sources/<Target>` 一层保留：SPM 强制，去掉就跑不了 `swift test` 窄检。
- 一次 `git mv` 整目录，**不**在同批做任何 UI 内容改动。
- ⚠️ **`RepoPath.swift` 是本批唯一会静默炸的功能点**：
  `apps/apple/packages/ChuanqiCutEditor/Tests/ChuanqiCutEditorTests/RepoPath.swift`
  用 `#filePath` 上溯 **7 层**求仓库根（`packages→apple→apps→根`，注释里写明曾错过 4 层/6 层）。
  搬到 `ui/<包>/Tests/<测试>/` 后只剩 **5 层**，少删两层就得到错误的 root，
  `goldenVideo` / `goldenVideoHevc` 指向不存在的文件 —— 这类测试若只做 `XCTAssertNotNil` 会假绿。
  改完必须确认这两个路径真实存在（`ls` 取证），而不是只看用例通过。
- 引用面实测（2026-10-16，`git grep -o packages`）：全仓 **349 处 / 343 行 / 142 个文件**，
  其中 `docs/` **253 处 / 101 个文件**属历史/append-only，按红线 5 **不改**。
  包外真正要改的活文件 **15 个** = 配置/脚本 9（双 `Podfile`、双 `Podfile.lock`（由 pod install 重生成）、
  iOS `project.pbxproj`、`tools/ci/run_gate.sh`、`tools/qa/beauty_harness/build_and_run.sh`、
  `.gitignore`、`.zcodeignore` —— 后两条 027 已预声明 `ui/*`，本批实际不动）
  + 活文档 6（`README.md`、`.ai/modules/{ui-apple,preview}.md`、`.ai/memory/{pitfalls,baselines}.md`、
  `.agents/skills/cq-build-test/SKILL.md`）；包内另有 **22 个文件**含 `packages` 字面
  （多为测试头部的 `// 运行：cd apps/apple/packages/... && swift test` 注释，随 `git mv` 一并改）。
- ⚠️ **两个 `Package.swift` 靠相对层数找 engine**，字面不含 `packages` 所以 grep 抓不到，必须人算：
  `ChuanqiCutEditor/Package.swift:17` 与 `SharedUI/Package.swift:21` 写的是
  `../../../../engine/bindings/swift`（自 `apps/apple/packages/<包>/` 上溯 4 层 = 仓库根）。
  搬到 `ui/<包>/` 后只剩 **2 层** → 必须改成 `../../engine/bindings/swift`；
  INFRA-032 再把尾巴换成 `api/swift`。`../SharedUI`（Editor/Import 依赖）是同目录相对引用，整树搬迁后不变。
- ⚠️ **图层卫生门禁会静默变窄**：`tools/compliance/check_uiview_layer_hygiene.py` 只接**一个**根参数
  （`check_uiview_layer_hygiene.py:120` 默认 `apps/apple`），`run_gate.sh:154` 实测扫 **119 个文件**。
  包上提后若还按 `apps/apple` 扫，自绘视图全部落到 `ui/` 而扫描根没跟上 → 违规写法不再被拦（ADR-0044 红线 1 的复发病）。
  本批把该 step 改成跑两趟（`apps/apple` + `ui`），验收口径 = **两趟文件数之和 = 119**（允许两边重新分配，总数不得掉）。
- **TimelineKit 路径守卫（ADR-0044 决策 ① 的落地项）**：iOS Podfile 里
  `pod 'TimelineKit', :path => '../../../../ChatGPT/zui'` 指向**仓库外**的本机 checkout（不收编）。
  搬家批最容易把它误判成"本仓坏了"，故加显式守卫：`File.exist?(<dir>/TimelineKit.podspec)` 不成立即
  `raise` 并打印该目录须含 `TimelineKit.podspec`、收编另开卡、换机可改 `:path`。
  实测：守卫生效后 ios `pod install` 仍 **exit 0（14 dependencies / 14 pods）**。

## 实测（2026-10-16，集成机）

- 一次 `git mv apps/apple/packages ui`：`git diff --cached -M --stat` = **124 files, 0 insertions / 0 deletions**（纯搬家，
  本批未做任何 UI 内容改动）；`git ls-files ui` = **124**、`git ls-files apps/apple/packages` = **0**。
- 包内字面改写：`apps/apple/packages/` → `ui/` 共 **17 个文件**；podspec 注释里的 `:path => '../packages/X'`
  → `'../../../ui/X'` 共 **5 个 podspec**（注释级，不影响解析）。
- `Package.swift` 深度 4→2：仅 **Editor 与 SharedUI** 两份引用 engine（`../../engine/bindings/swift`）；
  六包 `swift package resolve` **全部 OK**（相对依赖由文件系统取证，不靠 grep）。
- `RepoPath.swift` 上溯 **7 层 → 5 层**，并用 `os.path.dirname`×5 复核：算出的 root 与仓库根**完全相等**，
  且 `tests/golden/frames/gf_1080p_h264.mp4`(46003B) / `gf_1080p_hevc.mp4`(27972B) **真实存在**。
  顺带纠正该文件头注释：它写的是 `SharedUI/Tests/SharedUITests/`，实际在 `ChuanqiCutEditor/Tests/ChuanqiCutEditorTests/`。
- 双壳：`pod install` ios **14/14**、mac **7/7** 均 exit 0，`Podfile.lock` 本地 Pod 路径全部 `../../../ui/...`；
  ios `ChuanqiCutApp` + mac `ChuanqiCutMacApp` 均 **BUILD SUCCEEDED**（exit 0）。
  metallib 三件全部重生成（20:42）：`beauty_bilateral 9215B` / `face_warp 5792B` / `beauty_guided 8118B` —— 非 96B 空壳，
  证明 pbxproj run-script 的新路径真的编到了源文件。
- 图层卫生两趟：`apps/apple` **4** + `ui` **115** = **119**（与迁移前单趟逐字相等，覆盖面没掉）。
- `[!] [Xcodeproj] Generated duplicate UUIDs:` 在迁移**前**的两份 pod install 日志里同样存在（各 1 次），
  **不是本批引入**；本批不改该项，留作后续（登记，不当作已修）。

## 验收

**逐条对 yaml**（2026-10-16，本机 = 集成机实测）：

| 验收项 | 结果 |
|---|---|
| `git ls-files ui` = 124 / 旧路径 = 0 | ✅ 124 / 0 |
| Podfile + `run_gate.sh` 零 `packages` 命中 | ✅ `grep -rn packages apps/apple/*/Podfile tools/ci/run_gate.sh` = 0 行 |
| 门禁没静默变空（五段各有非零用例） | ✅ bindings **26** / player **52** / camera **77** / import **16** / editor **81** = **252**，`Executed N tests` 逐段取自各 step 日志本体 |
| 五包用例总数与迁移前一致 | ✅ 与 P148 基线（同日 19:xx 立的）**一字不差** |
| 双壳 pod install + xcodebuild | ✅ ios **14/14**、mac **7/7** exit 0；两端 **BUILD SUCCEEDED**；lock 本地 Pod 全指 `../../../ui/…` |
| `swift test` 依赖解析没断（深度 4→2） | ✅ 六包 `swift package resolve` 全 OK + `swift build`/`swift test` 实跑通过（字面 grep 抓不到，故以实跑为证） |
| 图层卫生不掉数（两趟之和 = 119） | ✅ `apps/apple` **4** + `ui` **115** = **119**，且新 step 内置"任一根扫到 0 个文件即 FAIL"的断言 |
| 全量门禁 | ✅ **PASS=15 / FAIL=0 / SKIP=0**，exit 0；Debug 52/52 165.11s、Release 52/52 145.14s、headers 43 头 0 违规、golden 21/0/0 901784B |

**本批未做/明确不做**：不做任何 UI 内容改动（纪律：UI 与路径改名不同批）；
`.gitignore`/`.zcodeignore` 的新旧路径同覆盖是 027 的设计，旧行保留；
`docs/` 里的 253 处 `packages` 字面按红线 5 不回填，其中**活文档债**（`docs/COCOAPODS.md` 1 处、
`docs/specs/**` 12 处 / 9 份）已登记给 INFRA-034。

## 回写

- `.ai/modules/ui-apple.md`：目录树、Pod 落点、门禁跑法
- `.ai/memory/pitfalls.md`：若 pod install 未重跑导致假绿
- 日志 → `.workbuddy/memory/2026-10-16.md`
