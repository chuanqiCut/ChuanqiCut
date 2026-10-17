# TASK-INFRA-037：双 App 壳构建进总门禁（收池 [18]）

> 传哲 2026-10-17 裁定「可以进，但是是不是可以用 APP 中的去跑」——**是**，用 App 自己的 workspace，
> 不另立判据工程。

```yaml
id:          TASK-INFRA-037
layer:       基建
goal:        让总门禁真的把 iOS/macOS 两个 App 壳编一遍，堵住"壳内 Swift / podspec / *.metal /
             Pbxproj 坏了而门禁全绿"这一整类伪绿
input:       [池 [18], pitfalls P129（双壳配方）, P96（mac 端 -arch 冲突）, P150（pod 根 glob 静默丢源码）]
output:      [tools/ci/check_apple_shells.sh（新增）, tools/ci/run_gate.sh 第 6 步 apple-shells]
write_set:   tools/ci/check_apple_shells.sh · tools/ci/run_gate.sh
read_set:    apps/apple/{ios,mac}/ChuanqiCut.xcworkspace · 各 podspec/Podfile（只读，不改）
deps:        [TASK-INFRA-036]
acceptance:
  - 两端 `BUILD SUCCEEDED=1`、`error:` 行 = 0、脚本退出码 0
  - 用的是 App 自己的 workspace，仓库里没有第二个"看起来像 App"的构建工程
  - derivedData 与日志一律落仓库根 `build/gate-logs/`，源码树内不产生任何产物目录
  - `--fast` / `--skip-apple` 时该步与 apple 组一起跳过（不新增独立开关）
verification:
  - tools/ci/check_apple_shells.sh                 # 两端
  - tools/ci/check_apple_shells.sh --shell=ios     # 单端
  - tools/ci/run_gate.sh
risk:         单步 +39s（暖）/+280s（冷，含 pod install）；`pod install` 会重生成 `Pods/`（已忽略）；
              Podfile.lock 若变化本步**只报不修**，锁文件改动归人确认
parallel:     false   # 构建脚本 = 高冲突文件
```

## 背景

池 [18] 的实证事故：`face_warp.metal` 改签名后**门禁 15 步全绿，但那一行 shader 从没被编译过**——
`*.metal` 由壳工程 postBuildScript 编成 metallib，SPM 包测试不碰。`run_gate.sh` 里那句
「Camera 实现层 iOS 专属不进 SPM，随双壳构建验证」长期是**空头承诺**，因为双壳一直在门禁外。

## 实现要点

1. **判据工程 = App 工程**。`apps/apple/{ios,mac}/ChuanqiCut.xcworkspace`，scheme 分别
   `ChuanqiCutApp`（`-destination generic/platform=iOS`）与 `ChuanqiCutMacApp`
   （`-arch $(uname -m) ONLY_ACTIVE_ARCH=YES`，P96：Intel 机带 `-destination` 会与 `-arch` 冲突，
   universal 编 arm64 会挂在系统库而不是我们代码上）。
2. **判据三条同时成立才算过**：`rc==0` **且** `BUILD SUCCEEDED` **且** `error:` 行数 0。
   单看 rc 会被 xcodebuild 的"依赖缺失但退出 0"骗；单看 SUCCEEDED 会被 `** BUILD SUCCEEDED **`
   出现在历史日志里骗。warning 行数**只留痕不判**（跨趟不可比）。
3. **产物落点必须绝对**（P164，本卡踩出来的）：脚本在 `cd apps/apple/<壳>` 的子 shell 里调
   xcodebuild，`-derivedDataPath ../../build/...` 那一刻的语义已经变成 `apps/build/` ——
   一趟就在源码树里留下 **1.5G**。改成 `${ROOT_DIR}/build/gate-logs/dd-<壳>`，并加路径前缀断言
   + 跑完自查一次（卫生门禁的同类判据排在本步**之前**，抓不到本步刚生成的目录）。
4. **pod install 的留痕不能用 `grep -c Installing`**：Podfile 未变时 CocoaPods 根本不打印这类行，
   计数恒 0 = 恒不命中的判据（P162 同款）。改取 `Pod installation complete!` 完成行。

## 验收（本机 Intel x86_64 集成机实测）

| 口径 | 数字 |
|---|---|
| 冷（空 derivedData，两端合计） | **280s**，rc=0，error=0，iOS 993MB + macOS 514MB derivedData |
| 冷（单 iOS 端，历史独立测量） | **199s**，rc=0，error=0 |
| 暖（两端合计，本脚本目录内） | **39s**，rc=0，error=0（iOS warning 13 / mac warning 5） |
| pod install | rc=0，14 个 pod；两端各一次 |
| 源码树自查 | `git status` 下 `apps/` 无任何未跟踪产物；hygiene 判据 5 PASS |

## 回写

- `run_gate.sh` 头部步骤清单（新增第 6 步，golden 顺延为第 7）与 `--fast/--skip-apple` 语义描述；
- `.ai/modules/core.md` 模块册行、`.ai/memory/baselines.md`「双壳进门禁」数字、
  `.ai/memory/pitfalls.md` P164、池 [18] 关闭回填。
