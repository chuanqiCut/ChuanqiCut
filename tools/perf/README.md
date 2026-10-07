# tools/perf — 性能基准工程

性能基线的**测量工具族**落点。产出的数字一律回填 `.ai/memory/baselines.md`（带机器环境）；
引用性能数字前先查 baselines（数字纪律见 AGENTS.md）。编排与取号口径见
`docs/tasks/PLAN-三线并行.md`（本目录归集成机）。

## 现有工程

### launch_bench/（2026-10-05 立）

App 冷启动基准：独立 XcodeGen 工程（`project.yml` → LaunchBench.xcodeproj），
XCUITest 驱动 Runner 测主 App 启动耗时，产出机器可读 JSON。

- 运行：`xcodebuild test -project tools/perf/launch_bench/LaunchBench.xcodeproj -scheme LaunchBench -destination 'id=<device-id>'`（真机；sim 结论见 baselines「启动基线」节）
- 已入册数据：baselines.md「启动基线（launch_bench）」节（sim 实测：App 净启动成本≈0；真机数字待回填）
- 自带 `.gitignore`（xcuserdata / DerivedData / 产物不入库）

## 规划中的兄弟工具（module 文档已引用，未立项）

- `render_bench`（render.md 验证口径：`--resolution=4K --tracks=3`）—— RenderGraph 落地（RENDER-001）后建
- `frame_provider_bench`（media.md / MEDIA-021 验收）—— FFmpeg 后端阶段建
- 新工具一律沿用本目录 `<name>_bench/` 命名，一个工具一个子目录 + 独立 README 说明
