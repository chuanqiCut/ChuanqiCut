# TASK-DEPS-012 — FFmpeg 源码/二进制双集成 + 本地 Pod 接入（冒烟切片）

## 元数据

```yaml
id:          DEPS-012
goal:        FFmpeg 9.0.2 demux 档双集成（CMake cq_ffmpeg 同 target）+ xcframework
             本地 Pod vendored 进 CChuanqiCut + core 冒烟探针，终结「规划完整但零消费」状态
owner:       集成机（2026-10-11 执行）
write_set:   tools/build/build_ffmpeg_demux.sh, tools/build/make_ffmpeg_xcframework.sh(新),
             third_party/CMakeLists.txt, engine/CChuanqiCut.podspec, engine/NOTICE.md(新),
             engine/core/cq/media/ffmpeg_probe.{h,cpp}(新),
             tests/unit/test_ffmpeg_probe.cpp(新), tests/CMakeLists.txt,
             third_party/manifest.toml(artifact), docs/{decisions/ADR-0036,BUILD.md,COCOAPODS.md},
             .ai/memory/baselines.md, .ai/modules/media.md
deps:        [DEPS-010]
adr:         ADR-0036（LGPL 处置 + 集成形态，负责人 2026-10-11 确认）
```

## 子步骤

| # | 内容 | 状态 |
|---|---|---|
| 1 | 修 build_ffmpeg_demux.sh 实雷（libtool→ar 合并、头文件保留、--sdk/--arch 多平台、--debug） | ✅ |
| 2 | 5 slice 构建（macosx x86_64/arm64、iphoneos arm64、sim x86_64/arm64）+ xcframework 汇总 | ✅（体积/sha 见 baselines 与 manifest artifact） |
| 3 | third_party/CMakeLists.txt：cq_ffmpeg 双集成 target（binary 默认 / source=ExternalProject 同脚本） | ✅ |
| 4 | CChuanqiCut.podspec：vendored xcframework + 头路径 + NOTICE + 缺产物防御报错 | ✅ |
| 5 | core/cq/media/ffmpeg_probe（唯一 FFmpeg 头 TU，ADR-0011 隔离）+ test_ffmpeg_probe（golden h264） | ✅ |
| 6 | 验证：probe 冒烟 11/11（手动链接，见模块册）；deps.py check ✓；pod install + vendored 接线 ✓（-lffmpeg 传导）；全量 ctest/xcodebuild 被并行 audio 线未完成文件阻断，顺延阶段批 | 见模块册门禁记录 |
| 7 | 治理落账：manifest artifact 回填 + deps.py lock 重生成 + baselines arm64 实测 + ADR-0036 | ✅ |

## 验证命令

```bash
ctest --test-dir build -R media_ffmpeg_probe
python3 tools/deps/deps.py check third_party/manifest.toml --lock third_party/deps.lock
bundle exec pod install  # apps/apple/mac（产物缺失时 podspec 明确报错）
```

## 风险 / 待验

- iOS 真机运行验证：Intel 本机无法跑 → 已登记 TODO-POOL [11]（构建机门禁清单）。
- ~~vendored 相对路径~~ **已定案**（2026-10-12 三次实测）：绝对路径报错 / pod root 外
  `../` 相对路径静默忽略 / vendored_libraries 不认 xcframework 目录 → 终版 =
  `vendored_frameworks` + 构建脚本同步 `engine/vendor/`（pitfalls P104 补记）。
- 全量 build_core 被 audio 线未完成文件（track_reader.cpp，untracked 并行写集）阻断，
  probe 链路已用独立 clang++ 链接验证（11/11）；全量 ctest 顺延阶段批。
- ARCH-002 §5.2 的 SBOM/头扫描工具（gen_sbom.py/scan_headers.py）不存在，本切片以
  deps.py check + 手工 grep 代替，工具缺口已在 COCOAPODS.md §6 登记。

## 备注

- MEDIA-021（FFmpegFrameProvider 后端）为下一张卡，消费 ffmpeg_probe 建立的接缝。
- 产物不入 git（P84）；换机后先跑 5 个 slice（~15 分钟）再 pod install。
