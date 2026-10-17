# TASK-INFRA-045：Draft 包进门禁（收池 [21]）

> 模板口径见 `.ai/templates/task.md`。背景 = 池 [21]：顶层六包里唯一一个**从未被门禁编译过**的包。

```yaml
id:          TASK-INFRA-045
layer:       基建
goal:        给 ui/ChuanqiCutDraft 在总门禁里一个真实执行位，结束"六包之一从没编过"的状态
input:       [池 [21], 实测：该包 swift build 冷编 1.54s 通过 / swift test rc=1]
output:      [tools/ci/run_gate.sh（新增 apple-draft 步）, tools/ci/gate_scope.sh（R4 build-only 名单）,
              .ai/source/AGENTS.root.md（L3 步数改口）+ 5 份生成物]
write_set:   tools/ci/run_gate.sh、tools/ci/gate_scope.sh、.ai/source/AGENTS.root.md、AGENTS.md 等生成物、
             本卡、TASK-BACKLOG.md、TODO-POOL、.ai/modules/core.md、.ai/memory/*.md、docs/reports/VERSIONS.md
read_set:    [ui/ChuanqiCutDraft/**]
deps:        [INFRA-043]
acceptance:
  - `run_gate.sh` 的包段含 `apple-draft` 步，命令是 **`swift build`** 不是 `swift test`
  - `gate_scope.sh` 对 `ui/ChuanqiCutDraft/*` 的改动路由到 `swift build`（不能吐一条恒红的命令）
  - 该步在 `--fast` / `--skip-apple` 下与包段其余步一并跳过（不新增例外分支）
  - `bash -n` rc=0；`sync_context.py --check` 一致
verification:
  - `(cd ui/ChuanqiCutDraft && swift build --disable-sandbox --scratch-path "$ROOT/build/spm/ChuanqiCutDraft")`
  - `printf '%s\n' ui/ChuanqiCutDraft/Sources/x.swift | tools/ci/gate_scope.sh --stdin`
risk:        ① 门禁只证明"能编"，不证明"有行为正确性" —— 该包**零 XCTest 用例**，判据射程就这么大，
              要功能证据得另开测试卡（不拿 build 冒充 test）；② 步数 18→19，历史文档里"18 步"是当时事实，
              不回改（append-only），真源改成"步数以脚本为准"以免继续腐。
```

## 实测

| 项 | 结果 |
|---|---|
| 该包结构 | `Sources/ChuanqiCutDraft/DraftDomain.swift` 单文件 + `Package.swift` + podspec，**无 `Tests/` 目录** |
| `swift build` | **Build complete! (1.54s)**（首编，1 个源文件），rc=0；暖跑重入 = 0.31s |
| `swift test`（反证） | **rc=1**：`error: no tests found; create a target in the 'Tests' directory` |
| 结论 | 无 Tests 目标的包只能 `swift build`。"没有用例所以通过"这个直觉**是错的**（见 P176） |

## 回写

- 池 [21] 关闭；步数口径 → 真源 §验证分四层 L3 行 + `sync_context.py` 重刷
- 两个实测数字 → `.ai/memory/baselines.md`；坑 → `.ai/memory/pitfalls.md` P176
