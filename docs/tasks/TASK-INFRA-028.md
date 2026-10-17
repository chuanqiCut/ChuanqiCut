# TASK-INFRA-028：孤儿产物清理与 build/ 分区收口

```yaml
id:          TASK-INFRA-028
layer:       基建
goal:        删掉磁盘上的孤儿/重复产物，把 build/ 根的一次性散目录并入既有分区，
             并把散落在 tools/ 与包目录里的 scratch 出口重定向到 build/
input:       [RESEARCH-018 §1.2, INFRA-027 忽略规则]
output:      [tools/build/*.sh 的 scratch 路径与 CMAKE_BIN 默认值, build/ 目录形态, 磁盘清理记录]
write_set:   tools/build/*.sh（含把 `CMAKE_BIN` 默认值里的 `/Users/zhuning` 改为 `$HOME`），
             docs/BUILD.md（本机路径示例同步改 `$HOME`）,
             AGENTS 真源 .ai/source/AGENTS.root.md 的「验证」段（仅当 ctest 路径变化），
             及其 5 个生成物（必须用 tools/ai/sync_context.py 生成，禁止手改）
read_set:    .gitignore（027 已冻结，只读）, build/ 磁盘形态
deps:        [TASK-INFRA-027]
acceptance:
  - 四处**真孤儿**已出树（一律 mv 到仓库外隔离目录，不 rm，保留可回滚）：
    根 `prebuilt/`（35M，仅 1 个 2026-09-24 的 `libffmpeg.a`，已被
    `third_party/prebuilt/ffmpeg/9.0.2/demux/` 的 5 切片 + xcframework 取代）、
    `third_party/prebuilt/apple-x86_64`（9.8M）与 `apple-x86_64-slim`（4.5M）、
    `tests/golden/frames/tmptws05f4p/`（2.8M）、`build/shell-mac2`（481M，10-11 重跑留下的副本）
  - ⚠️ **`third_party/prebuilt/apple-x86_64-demux` 不许动**：`third_party/manifest.toml:85-88`
    与 `deps.lock:44` 用 `local-build://prebuilt/apple-x86_64-demux` + sha256 显式锚定它
    （复勘正文 RESEARCH-018 问题 3 判定正确；错在本卡首版验收项把三套 `apple-x86_64*` 一并列为待删，
     执行前核 `manifest.toml` 才捞出 demux 那套是锚定项 —— 已在本条写死防复发）
  - 可再生产物直接删除：`apps/apple/packages/ChuanqiCutEditor/.build`（223M）、`tools/deps/__pycache__/`
  - **cmake 仍在 `build/` 根**（ADR-0044 决策 1 附注）；存量四个在役散目录（`shell-ios` 被
    `tools/qa/probe` 真机 SOP 引用、`shell-mac`、`DerivedData-iOS-device` 真机缓存、`audio-check` 被
    `.ai/modules/media.md` 门禁记录引用）**本轮不改名**，改名会打断写死路径的 SOP 与历史记录；
    分区规则与"新目录一律落 `build/xcode/`"写进 `docs/BUILD.md` §2
  - `grep -rn "/Users/" tools/build/*.sh` 零命中：`CMAKE_BIN` 改为"先 PATH、再 `$HOME` 托管位置"
    （`.ai/memory/env.md` 的本机工具链登记表**按设计保留绝对路径**，它是环境清单不是代码路径）
  - 重建通过且**用例数不掉**：`tools/build/build_core.sh --platform=apple --test`
    → `100% tests passed out of 52`（155.74s）
  - 双壳 `pod install` 通过：ios 14/14 pods、mac 7/7 pods，`Podfile.lock` 零 diff
verification:
  - git ls-files | wc -l                       # 857，改规则前后相同
  - git status --porcelain | grep -c '^??'     # 除本次新增 docs 卡外为 0
  - tools/build/build_core.sh --platform=apple --test 2>&1 | tail -6
  - (cd apps/apple/ios && LANG=en_US.UTF-8 bundle exec pod install)
  - (cd apps/apple/mac  && LANG=en_US.UTF-8 bundle exec pod install)
risk:        隔离目录在仓库外（`~/Documents/.chuanqiCut-quarantine-2026-10-16/`，533M），
             本批之后若双壳 xcodebuild 与真机均无异常即可由传哲决定删除；
             直接 rm 的风险是"误删不可再生产物"（FFmpeg 重编一次约 10 分钟量级，demux 锚定项更是删不得）。
parallel:    false（独占磁盘与构建脚本；且必须在 027 之后，否则清理会误删仍需入库的东西）
```

## 背景

RESEARCH-018 实测：仓库 `git status` 干净、入库产物 0，"垃圾感"完全来自磁盘 ——
`build/` 约 5.3G、根 `prebuilt/` 35M、`third_party/prebuilt/` 里三套旧 apple-x86_64* 目录、
`apps/apple/packages/ChuanqiCutEditor/.build` 223M（手工 `swift test` 没带 `--scratch-path` 攒出来的）。

## 实现要点

- **cmake 产物留在 `build/` 根**（ADR-0044 决策 1 附注）：迁 `build/cmake/` 会作废 5.3G 缓存
  并连带改全仓 43 处 `ctest --test-dir build`（含 9 个 skill），成本远大于收益。
- 包内 `swift test` 一律带 `--scratch-path "$ROOT/build/spm/<包名>"`（`run_gate.sh` 早已这么做），
  这是 223M 散 `.build` 的真正成因；只删目录不改约定必然复发 —— 复发拦截归 `check_repo_hygiene.sh`（INFRA-034）。
- 清理只碰**未入库**的东西：每条先 `git check-ignore` / `git ls-files` 确认非跟踪，
  跟踪中的一律不动（那是 029/030 的搬家范围）。
- 不可再生或再生成本高的一律 **mv 到仓库外隔离目录**而不是 rm。

## 执行记录（2026-10-16，本机 = 集成机）

- 隔离出树 533M：`~/Documents/.chuanqiCut-quarantine-2026-10-16/`
  （`repo-root-prebuilt/ffmpeg` 35M、`third-party-prebuilt/apple-x86_64{,-slim}` 14.3M、
  `build/shell-mac2` 481M、`tests-golden-frames/tmptws05f4p` 2.8M）
- 删除可再生：`apps/apple/packages/ChuanqiCutEditor/.build` 223M、`tools/deps/__pycache__/`
- 脚本：`build_core.sh` / `build_core_apple.sh` 的 `CMAKE_BIN` 改「PATH 优先 → `$HOME` 托管位置回退」，
  `bash -n` 通过；`docs/BUILD.md` §1 与 §2 同步（新增 `build/` 分区表与三条纪律）
- 窄检：`tools/build/build_core.sh --platform=apple` → 100% built；`--test` →
  **`100% tests passed out of 52`**，155.74s（此数字即 029/030 的对比基线）
- 双壳 pod install：ios **14/14**、mac **7/7**，`Podfile.lock` 零 diff
- **跳过项（明确登记）**：双壳 `xcodebuild` 本批未跑 —— 027/028 没有改任何壳内文件路径
  （只改 `.gitignore`/`.zcodeignore`/构建脚本变量解析），pod install 已验证 Pod 图完整。
  xcodebuild 双壳在真正动壳路径的 INFRA-031 批次跑。
- 顺带发现（非本批引入）：两壳 `pod install` 都打印 `[Xcodeproj] Generated duplicate UUIDs:` 长警告，
  CocoaPods 1.17 既有噪声，安装结果正常 → 记入待办池观察，不阻塞。

## 验收

见 yaml；必须报告清理前后 `du -sh build` 与 ctest 具体数字。

## 回写

- 实测体积数字 → `.ai/memory/baselines.md`（替换"约 5.9G"这类估算）
- 若发现新的 scratch 出口漏管 → `.ai/memory/pitfalls.md`
