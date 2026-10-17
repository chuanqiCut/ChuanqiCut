# TASK-INFRA-027：忽略规则一次性收口（迁移前后路径同时覆盖）

```yaml
id:          TASK-INFRA-027
layer:       基建
goal:        把 .gitignore / .zcodeignore 改成"锚定 + 显式"，且一次写全能同时覆盖搬家前与搬家后的路径，
             使 028~035 各批都不必再动这两个文件
input:       [ADR-0044 红线 5（机械替换须排除 append-only）, .gitignore:3-7 历史误忽略注释]
output:      [.gitignore, .zcodeignore]
write_set:   .gitignore, .zcodeignore
read_set:    git ls-files 全量清单, apps/apple/packages/**, engine/bindings/swift/**, tools/build/*.sh
deps:        [TASK-INFRA-026]
acceptance:
  - 裸 `prebuilt/` 改为 `/prebuilt/` + `third_party/prebuilt/` 两条；`engine/vendor/` 与
    `apps/apple/*/vendor/`（bundle 缓存）各自显式，不再靠裸 `vendor/` 通配
  - `tools/build/` 仍**不被忽略**：`git check-ignore -v tools/build/build_core.sh` 返回非 0
  - 新路径预声明生效：`git check-ignore -v ui/SharedUI/.build/x api/swift/.build/x engine/shaders/generated/x`
    三条都命中规则
  - 改规则后**没有任何原本入库的源码变成未跟踪**：`git ls-files | wc -l` 改前后差值 = 0，
    且 `git status --porcelain | grep '^??'` 行数 = 0
  - 027 之后各批的 write_set 均不含 .gitignore / .zcodeignore
verification:
  - git ls-files | wc -l                      # 记录改前数字，改后必须相同
  - git check-ignore -v tools/build/build_core.sh prebuilt/x third_party/prebuilt/x \
      engine/vendor/x apps/apple/ios/vendor/bundle/x ui/SharedUI/.build/x \
      api/swift/.build/x engine/shaders/generated/x shaders/generated/x tests/golden/frames/tmptws05f4p/x
  - git status --porcelain | grep -c '^??'    # 期望 0
risk:        裸模式静默误忽略是本仓已发生过的事故（三个构建脚本 + smoke_link.cpp 从未入库，
             clone 者拿不到构建入口而交接文档还在教人跑）。本卡的验收口径就是针对该事故设计的，
             不能只看"规则变少了"。
parallel:    true（与 028 不并行：028 依赖本卡规则才能安全删盘）
```

## 背景

`.gitignore` 现有 76 行、含 3 处裸模式（`prebuilt/`、`vendor/`、`shaders/generated/`），
历史上裸 `build/` 已造成过一次静默漏入库。本轮要把 `packages`→`ui`、`engine/bindings/swift`→`api/swift`、
`shaders`→`engine/shaders`，若逐批改 ignore 就会让高冲突的忽略文件与每批写集相交；
故一次性预声明新旧两套路径，后续批次零改动。

## 实现要点

- 迁移期**保留**旧路径规则（`apps/apple/packages/*/.build/` 等），新路径规则**追加**，
  全部批次完成后的收尾（INFRA-034）再删旧条目 —— 这样任何时刻产物都不会漏入库。
- `engine/shaders/generated/`：真实产物从来在 `build/generated/shaders/`
  （`engine/platform/apple/CMakeLists.txt:59`），顶层 `shaders/generated/` 是空残壳；
  规则里保留 `shaders/generated/` 通配以兼容迁移前后。

## 验收

逐条对应 yaml，全部用 `git check-ignore` 的返回值取证，不接受"看起来对了"。

## 回写

- 坑与防复发规则 → `.ai/memory/pitfalls.md`（若本批发现新的误忽略）
- 日志 → `.workbuddy/memory/2026-10-16.md`
