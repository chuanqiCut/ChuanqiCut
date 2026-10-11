# ADR-0036：FFmpeg 本地 Pod 二进制接入与 LGPL 处置

- **状态**：已接受（2026-10-11，DEPS-010/012 冒烟切片执行）
- **日期**：2026-10-11
- **决策者**：传哲（LGPL 处置路径 + 范围拍板）+ 集成机执行
- **依据**：ADR-0003（仅 Demux 与能力裁剪）、ADR-0008（本地 git 管理 + commit 锁定）、
  ARCH-002 §5.1（LGPL 附加义务三路径）、ADR-0033（Engine 源码共置与双 Pod 边界）
- **相关**：`third_party/manifest.toml`（ffmpeg 条目）、`tools/build/build_ffmpeg_demux.sh`、
  `tools/build/make_ffmpeg_xcframework.sh`、`third_party/CMakeLists.txt`（cq_ffmpeg）、
  `engine/CChuanqiCut.podspec`、`engine/NOTICE.md`

## 背景

FFmpeg 的规划、manifest 登记（9.0.2，demux 档，LGPL-2.1-or-later，integration=auto）、
源码 checkout、x86_64 预编译产物（DEPS-010）自 2026-09 起全部就位，但**从未被任何
代码消费**：core 零调用、Pod 零接线、CMake 双集成（DEPS-012）未做，arm64/iOS 产物
一片没有。同时发现构建脚本两处实雷：

1. 脚本用 `libtool -static` 合并三库 —— baselines.md 已验证同名 .o 会丢符号，
   正确方法是 `ar x` 分库解包 → 重命名 → `ar rcs`；
2. 脚本 staging 目录被 trap 清理，**FFmpeg 头文件从未随产物保存**，Pod vendored 无头可引。

## 决策

### 1. 集成形态：xcframework vendored 进 CChuanqiCut Pod

- FFmpeg 属 C/C++ 层依赖，按 ADR-0033 边界进 **CChuanqiCut**（C Pod），
  不进 ChuanqiCutEngine（Swift adapter）。
- 产物为单合并库 `libffmpeg.a`（demux 档）+ `include/`，按
  `<sdk>-<arch>` 组织后经 `xcodebuild -create-xcframework` 汇总三个 slice：
  macosx（x86_64+arm64）/ iphoneos（arm64）/ iphonesimulator（x86_64+arm64）。
- `s.vendored_libraries` 指向 xcframework；产物**不入 git**（P84：`*.a` 全局
  ignore，与既有 prebuilt 档一致），podspec 内做存在性检查并给出构建指引。
- 头文件只被 core 私有实现 TU 引用；public 头（cq_sdk.h）零第三方类型（DEPS-004）。

### 2. 双集成（DEPS-012）：同一 CMake target，构建脚本单一真源

- `third_party/CMakeLists.txt` 暴露 `cq_ffmpeg`（IMPORTED STATIC）：
  `-DCQ_FFMPEG_INTEGRATION=binary`（默认）指 prebuilt 产物；
  `=source` 时 ExternalProject 调**同一个** `build_ffmpeg_demux.sh` 再指同一产物路径
  —— configure flag 永不漂移，对应 manifest `integration=auto` 语义（本地 binary / CI source）。
- 源码级调试路径：`build_ffmpeg_demux.sh --debug`（-O0 不 strip）产物替换正常档。

### 3. LGPL 处置（ARCH-002 §5.1 路径 1，负责人 2026-10-11 确认）

采纳业界通行（该厂商系等）静态链接合规路径，义务三件套：

1. **App 内许可声明**：`engine/NOTICE.md` 随 Pod 分发（FFmpeg 版本 / commit /
   源码地址 / 许可文本指引），发布时在 App「关于/设置」页可达；
2. **源码可获得**：GitHub 仓库 + pin commit（ADR-0008 机制保证）；
3. **可重链接对象归档**：vendored `libffmpeg.a` 本身即目标文件归档；发布流程
   须保留其可提供性。

前提约束（门禁保证）：**永不 `--enable-gpl`**，不链 libx264/libx265/libvpx 等
GPL/外部编解码组件；`build_ffmpeg_demux.sh` 内置 GPL 符号扫描
（`lib<name>` 前缀模式，见 baselines「裸格式名误报」教训），0 命中才过。
不采用商业授权（FFmpeg 社区代码无「买断式」授权，不可行）。

### 4. 消费入口（本切片）：core 探针 + 单测

- `core/cq/media/ffmpeg_probe.{h,cpp}`：全仓库唯一 include FFmpeg 头的 TU，
  单独成 TU（ADR-0011 规则 1，ADR-0035 后原文路径不变），头文件零 AV* 类型；
- `tests/unit/test_ffmpeg_probe.cpp`：golden H.264 样本（1920x1080/5.0s/无音轨）
  探测断言 + 错误路径，ctest 名 `media_ffmpeg_probe`，链 `cq_core + cq_ffmpeg`；
- MEDIA-021（FFmpegFrameProvider demux 后端）在此接缝上另开卡，不在本切片。

## 被否决的备选

| 备选 | 否决原因 |
|---|---|
| 产物入 git（vendored 即 clone 即用） | 违反 P84（构建产物零入库），且 10MB+ 体积 |
| Pod 内现场源码编译（script_phase） | 单次构建 15 分钟进 App 构建不可接受；调试体验差 |
| 动态 framework（libffmpeg.dylib） | iOS 侧 framework 嵌入的 LGPL 合规性存疑（ARCH-002 §5.1）；静态 + 归档义务更稳 |
| 商业授权 | FFmpeg 社区代码无统一商业授权渠道，不可行 |

## 影响

- 体积（demux 档合并库，strip 后实测见 baselines「FFmpeg demux 档位构建基线」节）；
- cq_core 新增一个 archive member（ffmpeg_probe.o），不消费 FFmpeg 的目标不受影响；
- 首次 clone 后 pod install 前需本地构建 FFmpeg（5 slice 一次性 ~15 分钟）；
- SBOM 生成与公共头第三方符号扫描工具（`tools/compliance/gen_sbom.py` /
  `scan_headers.py`，ARCH-002 §5.2 规划）**尚不存在**，本切片以 `deps.py check`
  + 手工 grep 扫描代替，工具缺口登记 TODO-POOL。

## 验证锚点

- `tools/build/build_ffmpeg_demux.sh` 五 slice 全绿 + GPL 扫描 0 命中；
- `ctest -R media_ffmpeg_probe`；
- `bundle exec pod install`（macOS App）+ 编译链接冒烟；
- `python3 tools/deps/deps.py check`（manifest↔lock 一致）。
