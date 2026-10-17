# RESEARCH-018：仓库布局复勘与整改执行方案

> 日期：2026-10-16
> 上游命题：传哲「看下项目整体的目录结构，分析如何优化；可读性太差，文件夹中还夹杂着测试 case 留下的垃圾；
> 按模块一个文件夹、各平台壳工程各自文件夹、不要搞太深的层级」
> 前作：`RESEARCH-011-仓库布局与分层整改方案.md`（2026-10-10）。**本文是对它的复勘 delta + 新决策**，不是重写。
> 方法：磁盘实勘（`find`/`du`/`git ls-files`/`git grep` 现场执行）+ 引用面计数
> 数字纪律：所有规模与引用数为本次实测；未取证处标 `hypothesis`。本文不含性能数字。

---

## 0. 三句话结论

1. **RESEARCH-011 的 P0/P1/P2 确实已落地**（ADR-0035 改名、INFRA-022/024 源共置、FFmpeg in-source 产物已清零、
   `CMakePresets.json` 与根 README 已存在），**P3 一件没做**；本文 §2 给出逐项复勘。
2. **你要的三条里，"每模块一个文件夹"与"浅层级"在 C++ 侧已经成立**（`engine/core/cq/{11 个模块}`）。
   真正造成"可读性差"的是另外四件事：轨道组件根本不在仓库里、产物散落 6 处、夹具埋在模块源码内、测试平铺无归属。
3. **版本库本身是干净的**（`git status` clean，入库产物 0 个）。脏的是工作目录视野与一处仓库外依赖。

---

## 1. 现状实勘（2026-10-16）

### 1.1 规模

| 指标 | 实测 |
|---|---|
| 入库文件 | 857 |
| 其中 markdown / 源码 | **325 / 311**（文档略多于源码） |
| 工作树体积 | 5.9G，其中 `build/` = **5.3G** |
| 顶层条目 | 11 普通目录 + 7 dot 目录 + 9 根文件 = **27** |
| 路径深度 | 最深 8 层；≥7 层的文件 **195** 个 |
| 入库的构建产物 | **0**（`git ls-files -i -c` 为空） |

### 1.2 问题清单（按严重度）

| # | 问题 | 证据（全部实测） | 分级 |
|---|---|---|---|
| 1 | **轨道区真源组件不在仓库内，且无版本控制** | `apps/apple/ios/Podfile:34` → `pod 'TimelineKit', :path => '../../../../ChatGPT/zui'` = `/Users/zhuning/Documents/ChatGPT/zui`。该目录 15 个 Swift 文件 / 252K 源码，`git rev-parse` 返回非工作树；目录内另有自己的 `SPEC.md`/`PLAN.md`/`AGENT_HANDOFF.md`/`REPLICATION_MATRIX.md` 与一份 3.1MB 的 `DVETrackKit-arm64.md`。**TASK-UIA-045 已就地改过组件源码 3 处**（`TimelineStyle.showsTrackHeader` 等），改动同样不在任何版本控制下 | **P0** |
| 2 | 产物散落 6 处，`build/` 成了垃圾场 | `build/` 下 **25 个平级条目**，含自造名 `appicon-work`/`audio-check`/`gate-logs`/`shell-mac2`/`DerivedData-iOS-device` 与散落的 `core-check-configure.log`；`build/spm` 1.2G **与** `apps/apple/packages/ChuanqiCutEditor/.build` 223M 并存（P84 规则漏了这个包） | P1 |
| 3 | FFmpeg 二进制 4 个落点，2 个是孤儿 | 规范位 `third_party/prebuilt/ffmpeg/9.0.2/demux/`（`build_ffmpeg_demux.sh:73` 输出根，57M）；**孤儿** = 根 `prebuilt/`（35M，2026-09-24 迁入 third_party 前的遗留）+ `third_party/prebuilt/{apple-x86_64,apple-x86_64-slim}`（`manifest.toml` 已不引用）；⚠️ 同级的 `apple-x86_64-demux` **不是孤儿、删不得**：`manifest.toml:85-88` + `deps.lock:44` 以 `local-build://prebuilt/apple-x86_64-demux` 与 sha256 显式锚定它；Pod 消费位 `engine/vendor/libffmpeg.xcframework`（18M） | P1 |
| 4 | 夹具埋在模块源码里，把模块撑变形 | `engine/core/cq/ai/` 共 64 个入库文件，**59 个是 golden 夹具**（58 个 JSON + `manifest.txt`），真源码 5 个。`tests/CMakeLists.txt:661` 用 `CQ_EDIT_PLAN_GOLDEN_DIR` 指向源码树内 | P1 |
| 5 | 测试七处分散、两套管法 | `tests/unit/` **51 个文件平铺**（11 个靠 `_apple` 后缀区分平台）；Swift 侧就近放包内 `Tests/`；`tools/deps/tests/`、`tools/perf/launch_bench/Tests/` 另算 | P2 |
| 6 | 机器私有绝对路径写进脚本 | `tools/build/build_core.sh:22`、`build_core_apple.sh:42`（cmake 路径）、`tests/golden/generate.py:226,228`、`verify.py:65`（ffmpeg/ffprobe）。均可被环境变量覆盖，但换机即挂 | P2 |
| 7 | 治理文件仍缺 | `.github/workflows/` 只有 `.gitkeep`（**无 CI**）；`.clang-format`/`.editorconfig`/`CODEOWNERS` 均不存在 | P2 |
| 8 | 测试泄漏物留在 golden 目录 | `tests/golden/frames/tmptws05f4p/` 93 个 PNG / 5.7M，2026-09-24 worker 被 429 打断泄漏，靠 `.gitignore` 的 `tmp*/` 兜住才没入库 | P2 |
| 9 | `packages` 命名误导 + UI 层级过深 | `apps/apple/packages/` 装的**全是 Swift 源码**（"packages" 在 Swift 语境 = SPM 包，非"打包产物"）；最深源码路径 `apps/apple/packages/ChuanqiCutEditor/Sources/ChuanqiCutEditor/UIKit/*.swift` = 9 层 | P2 |
| 10 | `engine/` 名实不符 + `bindings` 说的是机制不是角色 | `engine/` 同时装 C++ 内核、Apple 平台实现、**Swift 门面**、3 个 podspec、`vendor/` 二进制副本；`engine/bindings/{kotlin,arkts}` 各只有一个 `.gitkeep` | P2 |
| 11 | 顶层 `shaders/` 与消费者割裂 | `shaders/src/` 只有 `blit.{vert,frag}`，消费者是 `engine/platform/apple/CMakeLists.txt:59` 与 `gfx/blit_pass.mm:18`；红线 #6 的另一半（Platform-Native）在 `platform/<p>/shaders/`，两半分居两处；`shaders/generated/` 是空残壳（真实产物落 `build/generated/shaders/`） | P2 |
| 12 | 文档归档未做 | `docs/handoff/` 27 份含重号（HANDOFF-004×2、006×3）、`docs/tasks/` 126 份 | P3 |

### 1.3 辟谣（看着像垃圾但不是的三处）

1. `apps/apple/ios/iOSApp/Assets.xcassets/AppIcon.appiconset/icon_1024 1.png` / `2.png`：Xcode 的
   light/dark/tinted 三槽位，`Contents.json` 三处均在引用，三张同图（md5 一致）。**删了图标缺槽**。
2. `engine/bindings/swift/Sources/ChuanqiCutCore/include/cq_sdk.h`：**符号链接**（`git ls-files -s` mode `120000`），
   指向 `core/cq/cq_sdk.h`。红线 #7「唯一公共头」没有被破坏。
3. `apps/android`、`apps/ohos`、`engine/bindings/{kotlin,arkts}`：P1/P2 平台的显式预留（AGENTS.md 明写
   「HarmonyOS 本期仅预留」）。**保留，但要在 README 目录速查标注"预留空壳"，免得被当垃圾清掉**。

---

## 2. 对 RESEARCH-011 的逐项复勘

| RESEARCH-011 项 | 10-10 判定 | 10-16 复勘 |
|---|---|---|
| A 半迁移未提交 | P0 阻塞 | **已解决**（INFRA-022/024，`git status` clean） |
| B FFmpeg in-source `.o/.d` 554 个 | P1 | **已解决**（`third_party/src` 下 `.o`/`.d` 计数均为 0） |
| C SPM scratch 双路径 | P1 | **复发**：`build/spm` 1.2G 与 `ChuanqiCutEditor/.build` 223M 并存 |
| D `pal` 命名不自明 | P1 | **已解决**（ADR-0035 全量改名，含类型名与门禁白名单） |
| E 空壳目录残留 | P1 | **已解决**（`engine/core/{include,src,tests}`、`cq/cq` 均不存在） |
| F 测试七处分散 | P2 | **未动**（本轮做，见 INFRA-029/030） |
| G 根 README/clang-format/editorconfig/CODEOWNERS/CI 全缺 | P2 | **部分**：根 README 有（= 周报形态）、`CMakePresets.json` 有；clang-format/editorconfig/CODEOWNERS/CI **仍全缺** |
| H `.zcodeignore` 与 `.gitignore` 不同步 | P2 | **仍在**（60 条 vs 31 条） |
| I 三套 manifest 无一致性校验 | P2 | **未动**（本轮不做，见 §4） |
| J 文档数 ≈ 源码数 | P3 观察 | 加剧：325 md vs 311 源码 |

**新增（10-10 未发现）**：问题 1（TimelineKit 在仓库外）、问题 3（FFmpeg 4 落点与 2 个孤儿）、
问题 11（shaders 两半分居）。这三条是本轮才暴露的，其中第 1 条为 P0。

---

## 3. 决策（传哲 2026-10-16 拍板，共 14 项）

| # | 决策 | 取值 |
|---|---|---|
| 1 | TimelineKit 处理 | **本轮不收编**，只登记风险 + 加 Podfile 路径守卫；将来落 `ui/TimelineKit` |
| 2 | C++ 单测归位 | 根 `tests/unit/<模块>/` 建 **12 个子目录** = `engine/core/cq/` 的 11 个模块名 ∪ `{abi}`（**不**就近共置进模块目录；2026-10-16 逐文件定案见 TASK-INFRA-030 分组表） |
| 3 | 整改范围 | **全量一次做完**（含 CI 与治理） |
| 4 | edit_plan 夹具落点 | `tests/golden/edit_plan/` |
| 5 | UI 模块上提 | `apps/apple/packages/` → **扁平顶层 `ui/`**（Android 来了再拆 `ui/android`） |
| 6 | Pod 模块名 | **保留 `ChuanqiCut` 前缀**（改要动 57 个文件的 import，收益仅目录排序） |
| 7 | Swift 门面 | `engine/bindings/swift` → **顶层 `api/swift/`**，`engine/` 回归纯 C++ |
| 8 | Core pod 根耦合 | 本轮不动（`ChuanqiCutCore.podspec` 根仍 = `engine/`，因它同时覆盖 `core/cq/**` + `platform/apple/**` + `vendor/`），仅在 ADR-0044 写明 |
| 9 | 平台预留空壳 | 保留，README 标注 |
| 10 | agent 上下文目录 | **不合并**（`.ai`/`.workbuddy`/`.agents`/`.zcode` 维持现状） |
| 11 | AI 规则生成物 | 保持入库（clone 即用），README 标注"生成物禁止手改" |
| 12 | handoff 归档 | 建 `docs/archive/handoff/`，在位只留最近 5 份；重号补注不删 |
| 13 | `shaders/` | 并入 `engine/shaders/{portable,native}/` |
| 14 | `tools/probe/` | 并入 `tools/qa/`；`tools/perf/` 保留独立 |

**分批纪律**：`ui/` 上提与 `api/` 外提**不得同批**（ADR-0034 分批；ADR-0035 红线「一次全仓路径改名已踩过
门禁脚本目录白名单静默失效」，同批叠两个全仓改名会让 bisect 与门禁失败定位都变难）。

---

## 4. 明确不做

- **不把 C++ 与 Swift 扁平混进单一顶层 `modules/`。** 这条仓库的目录名是机器校验的判定依据：
  `tools/platform/check_platform_headers.py:241` 的 `CONTRACT_DIR_NAMES` 按目录名白名单决定扫不扫、扫描根写死
  `engine/core/cq`；podspec 的 public/private header 边界按路径 glob；`.gitignore` 按路径。
  扁平混排会同时拆掉这三道校验（ADR-0035 红线 1 的同类事故）。
- **不改 pod 模块名**（决策 6）。
- **不做三套 manifest（CMake / SPM / CocoaPods）的一致性校验工具**（RESEARCH-011 I 项）：与本轮布局整改正交，
  单独排期。登记为待办。
- **不动 `Sources/<Target>` 这一层**：SPM 强制，去掉就跑不了 `swift test` 窄检。这类"看着深但不是本仓的债"
  的位置在 README 里说明即可。
- **不清理文档数量**（J 项）：文档多是本阶段协作方式决定的（每批留台账与问卷），强行精简会丢决策记录。

---

## 5. 目标布局

```
ChuanqiCut/
├── engine/                      纯 C++ + CocoaPods 强制的两处副本
│   ├── core/cq/<module>/        11 个模块目录（已达标，不动）
│   ├── platform/<os>/<域>/      平台实现（不动）
│   └── shaders/{portable,native}/  ★并入（决策 13）
├── api/swift/                   ★ Swift 对外门面（原 engine/bindings/swift，决策 7）
├── ui/<Module>/                 ★ 6 个功能 Pod 上提（原 apps/apple/packages，决策 5）
├── apps/apple/{ios,mac}/        只剩壳工程
├── apps/{android,ohos}/         预留空壳（标注）
├── tests/{unit/<module>,golden}/  ★ 单测分模块 + 夹具入 golden 库
├── third_party/prebuilt/        唯一构建产物归口
├── tools/{qa,build,ci,...}/     ★ probe 并入 qa（决策 14）
├── docs/{…,archive/handoff/}    ★ 归档（决策 12）
└── build/                       临时产物，内部分区 cmake/ spm/ xcode/ third_party/ logs/
```

顶层从 11 个普通目录变为 12（`shaders` 消失、`api` 与 `ui` 新增），但**语义变成"一层一名"**：
`engine`(C++) / `api`(跨语言门面) / `ui`(Swift 组件) / `apps`(壳)。

---

## 6. 引用面与成本（实测计数）

| 迁移 | 配置/脚本文件 | 文档引用 |
|---|---|---|
| `apps/apple/packages` → `ui` | 需改的**非包内文件 15 个**：配置/脚本 9（2 Podfile、2 Podfile.lock、iOS `project.pbxproj`、`run_gate.sh`、`beauty_harness/build_and_run.sh`、`.gitignore`、`.zcodeignore`，后两条 027 已预声明故 031 实际不动）+ 活文档 6（`README.md`、`.ai/modules/{ui-apple,preview}.md`、`.ai/memory/{pitfalls,baselines}.md`、`.agents/skills/cq-build-test/SKILL.md`）；另包内 22 个文件随迁 | `git grep -o packages` 全仓 **349 处 / 343 行 / 142 个文件**；其中 `docs/` **253 处 / 101 个文件**属 append-only 历史，按 P103 不改写 |
| `engine/bindings/swift` → `api/swift` | 13 个：`ChuanqiCutEngine.podspec`、2 `Package.swift`、`build_core_apple.sh`、`run_gate.sh`、`gen_api_reference.py`、`bindings/swift` 内 6 个测试与脚本、2 Podfile | 同上，历史卡（TASK-BIND-002/003 等）不改写 |
| `shaders` → `engine/shaders` | 3 个：`tools/shaders/build_shaders.py:104`（`src_dir = repo_root/"shaders"/"src"`，代码级）、`engine/platform/apple/CMakeLists.txt:69-70`（DEPENDS 两条）、`shaders/src/*` 本体；`run_gate.sh` **不含** shader 路径（实测零命中，前记有误）；podspec `:66` 只调脚本不带路径，故不改 | 红线 #6 措辞需 ADR 修订；README `:16,184,388` 与 `docs/BUILD.md:43` 的树描述归 034 回填 |
| 夹具与测试搬家 | `tests/CMakeLists.txt`（含 `:661` 常量） | RESEARCH/SPEC 引用 2 处 |

---

## 7. 来源

- 现状实勘：`git ls-files`/`git status --porcelain --ignored`/`du`/`find`/`git grep -c`/`git ls-files -s` 本次现场执行
- 关键行号：`apps/apple/ios/Podfile:34`、`engine/ChuanqiCutCore.podspec:35,47,101`、`engine/ChuanqiCutEngine.podspec:30`、
  `tools/platform/check_platform_headers.py:241`、`tests/CMakeLists.txt:661`、`tools/ci/run_gate.sh:121,158-194`、
  `engine/platform/apple/CMakeLists.txt:59`、`tools/build/build_ffmpeg_demux.sh:73`、`third_party/manifest.toml:86-123`
- 上游：RESEARCH-011、ADR-0033（源码共置与双 Pod 边界）、ADR-0035（PAL→Platform）、ADR-0031（壳化与功能 Pod 分治）、
  ADR-0038（引擎 Pod 重命名与 FFmpeg 独立 Podspec）、ADR-0019（文档分层）、ADR-0034（分批推进）
- 坑：P84（SPM scratch 与产物不入库）、P95/P103（改名与门禁白名单、append-only 文件排除）
