# TASK-INFRA-001：monorepo 目录骨架与 CMake 顶层

```yaml
id:          INFRA-001
layer:       基建
goal:        建立三平台共享的目录骨架与 CMake 顶层入口，使后续每个模块有唯一归属位置
input:       [ARCH-001 §9 工程结构, AGENTS.root.md 写集规则]
output:      [目录骨架, 根 CMakeLists.txt, 各层 CMake 桩, docs/README 更新]
write_set:   仓库根目录结构, CMakeLists.txt(根), core/CMakeLists.txt(桩), pal/CMakeLists.txt(桩),
             apps/CMakeLists.txt(桩), third_party/CMakeLists.txt(桩), tools/CMakeLists.txt(桩)
read_set:    docs/specs/ARCH-001-技术方案总纲.md, .ai/source/AGENTS.root.md
deps:        []
acceptance:
  - 目录结构与 ARCH-001 §9 列出的树完全一致，无多余顶层目录
  - 三个平台入口（core/、pal/apple|android|ohos/、apps/apple|android|）均存在且可被 CMake 识别
  - `cmake -S . -B build` 能配置成功（可以是空产物）
  - 新增任何顶层目录都必须同步修改本任务定义的目录清单
verification:
  - cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
  - cmake --build build --target help    # 三个入口 target 可见
risk:        目录结构一旦定下，后续 117 个任务的 write_set 都以它为准，改动成本极高。
             缓解：本任务只建骨架不填内容，结构由 ARCH-001 §9 唯一确定，不自由发挥。
parallel:    false          # 高冲突：几乎所有任务依赖它
```

## 背景

ARCH-001 §9 已给出目录树。本任务把它落成磁盘上的真实结构。**这是整个工程的地基**，后续所有任务的 write_set 都引用这里的路径，所以目录命名不允许自由发挥。

## 实现要点

- 顶层只放：`core/`、`pal/`、`apps/`、`third_party/`、`tools/`、`tests/`、`docs/`、`.ai/`。
- `core/` 内部按模块分：`base/`、`model/`、`gfx/`、`render/`、`media/`、`audio/`、`ai/`、`project/`、`export/`、`session/`。
- `core/include/cq/` 是公共头根，`cq_sdk.h` 是唯一对外伞形头（本任务只建占位文件，内容由 CORE 系列填）。
- 每个 layer 一个 CMake target，target 名统一前缀 `cq_`。
- **不要在骨架阶段引入任何第三方依赖**，third_party 只放占位 CMake。

## 验收

逐条对应 acceptance。目录树用 `find . -maxdepth 2 -type d` 输出比对 ARCH-001 §9。

## 回写

- 目录结构若有任何偏离 ARCH-001 §9 的调整 → 更新 ARCH-001 §9 并说明原因
- `.ai/modules/core.md` 补实际路径
