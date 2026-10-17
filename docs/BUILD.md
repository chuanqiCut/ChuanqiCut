# ChuanqiCut 构建与门禁说明

面向第一次 clone 本仓库的人。读完这份文档，你应该能在一台新机器上把项目跑起来并跑通全部门禁。

## 1. 前置工具

| 工具 | 版本要求 | 说明 |
|---|---|---|
| CMake | ≥ 3.20（本项目实测 4.4.3） | **PATH 里可能没有 `cmake`**，脚本里统一用 `CMAKE_BIN` |
| C++ 编译器 | C++20（AppleClang 17 / GCC / MSVC 均可） | 内核硬锁 C++20，禁 GNU 扩展 |
| Python | ≥ 3.11（需 tomllib） | 仅依赖治理工具链与门禁脚本用，**运行时不依赖** |
| Xcode（仅 Apple 平台） | 完整 Xcode，非仅命令行工具 | 需要 Metal / AVFoundation / VideoToolbox / CoreVideo 等框架 |

构建脚本的 cmake 解析顺序（INFRA-028 起）：**先试 PATH，再回退 `$HOME` 下的托管安装位置**，
两者都可被 `CMAKE_BIN` 覆盖（CI 里 `CMAKE_BIN=cmake` 即用系统 cmake）。
本机托管安装的实际位置形如：

```
cmake   $HOME/.workbuddy/binaries/cmake/CMake.app/Contents/bin/cmake
ctest   与 cmake 同目录（build_core.sh 自动从 CMAKE_BIN 推导，可用 CTEST_BIN 覆盖）
python  $HOME/.workbuddy/binaries/python/versions/<ver>/bin/python3
```

> 这些是隔离安装路径，不污染系统环境。文档与脚本里**不写机器用户名**
> （历史上写死过 `/Users/<name>/...`，换机即静默失效，见 INFRA-028）。
> 本机工具链的**具体版本号**登记在 `.ai/memory/env.md`（那是环境清单，允许绝对路径）。

## 2. ⚠️ 第一段必读：产物不入库

**仓库里没有任何第三方预编译产物。** `third_party/manifest.toml` 只登记
「依赖的哪个 commit、构建档位、产物期望的 sha256 / size」，`third_party/prebuilt/` 与
`third_party/src/` 都在 `.gitignore` 里。

所以 clone 下来**直接链接会失败**（缺 `libffmpeg.a` 之类）。必须先按下面的步骤自行构建一次。

这样做的理由：产物可由 `pin_ref` + 构建档位**可复现地**重新生成，没必要把二进制塞进 git；
同时避免把 LGPL 二进制随仓库分发（ADR-0008 / ADR-0010）。

### `build/` 唯一临时产物根与分区（INFRA-028 / ADR-0044）

| 目录 | 用途 | 谁写 |
|---|---|---|
| `build/`（根） | **cmake 缓存与内核产物**（`CMakeCache.txt`、`bin/`、`lib/`、`tests/`、`generated/shaders/`） | `tools/build/build_core.sh` |
| `build/spm/<包名>/` | Swift 包 `swift test/build` 的 scratch | `run_gate.sh`（`--scratch-path`） |
| `build/xcode/` | 壳工程 DerivedData（**新增**一律用这个名字） | 手工 xcodebuild `-derivedDataPath` |
| `build/gate-logs/` | 门禁分步日志 | `tools/ci/run_gate.sh` |
| `third_party/prebuilt/` | 第三方预置产物归口（不在 `build/` 下，因 `manifest.toml` 按相对路径锚定） | `tools/build/build_ffmpeg_demux.sh` |

三条纪律：

1. **cmake 保持在 `build/` 根**，不迁 `build/cmake/`：缓存约 5.3G，迁移即全废 + 一次全量重编，
   且全仓 43 处 `ctest --test-dir build` 要连带改写（含 9 个 skill）。洁癖不值这个价。
   > **订正（2026-10-17，INFRA-045/046 收尾批，活文档就地更新）**：那个 **43** 已失效 ——
   > 实测 `git ls-files` 里含 `--test-dir build` 的是 **96 处 / 64 个文件**（本批自测时已漂到 97，
   > 因为**引用这条命令的叙述行本身也算一处**，所以这天生是个会漂的数，带日期读）。
   > 顺带把「为什么不拆 `build/dbg` + `build/rel`」写实（池 [25] 判定、INFRA-040 不立项）：
   > 分档后 `core-rel` 整步 199s 里构建段只有 **≈57s**，拆树能省的就这么多 / 每个版本批一次；
   > 而上面这条 64 文件里绝大多数是模块册历史行、任务卡、归档 HANDOFF、问卷，**按红线 5 不得改写**，
   > 改完会永久留下"历史命令指向不存在的路径"的裂口。⇒ **本条决定继续有效，反转要走 ADR**。
2. **禁止往 `build/` 根扔新的具名散目录**。存量在役的四个（`shell-ios` 被 `tools/qa/probe` 的真机 SOP 引用、
   `shell-mac`、`DerivedData-iOS-device` 真机联调缓存、`audio-check` 被 `.ai/modules/media.md` 门禁记录引用）
   **本轮不改名**——改名会打断写死该路径的 SOP 与历史记录；新跑的一律落 `build/xcode/`。
3. 双 scratch 不许并存：SPM 的 `.build` 必须靠 `--scratch-path` 重定向到 `build/spm/`。
   案底：`ChuanqiCutEditor/.build`（当时在 `apps/apple/packages/` 下，INFRA-031 已迁顶层 `ui/ChuanqiCutEditor/`）因为手工 `swift test` 没带该参数，攒到 223M。

### 构建 FFmpeg（DEPS-010/012 档位，ADR-0036）

```bash
# 源码 checkout（首次）
git clone https://github.com/FFmpeg/FFmpeg.git third_party/src/ffmpeg
cd third_party/src/ffmpeg && git checkout 946fcce07b6dcd0331c8cc609192aeff5e1924f8   # tag n9.0.2
```

**入口只有一个脚本，不要手写 configure**（flag 单一真源；完整命令与实测体积另见
`.ai/memory/baselines.md` 的「FFmpeg demux 档位构建基线」一节）：

```bash
# 5 个 slice（首次全跑；单个 slice 约 3-8 分钟）
tools/build/build_ffmpeg_demux.sh --sdk macosx --arch x86_64
tools/build/build_ffmpeg_demux.sh --sdk macosx --arch arm64
tools/build/build_ffmpeg_demux.sh --sdk iphoneos --arch arm64
tools/build/build_ffmpeg_demux.sh --sdk iphonesimulator --arch x86_64
tools/build/build_ffmpeg_demux.sh --sdk iphonesimulator --arch arm64
# 最后一个 slice 跑完会自动汇总 xcframework；也可单独重组：
tools/build/make_ffmpeg_xcframework.sh
```

- 产物：`third_party/prebuilt/ffmpeg/9.0.2/demux/<sdk>-<arch>/{libffmpeg.a,include/}`
  与 `libffmpeg.xcframework`（**不入 git**，P84）；最后一个 slice 跑完会把 xcframework
  自动同步到 `engine/vendor/`（CocoaPods vendored 沙箱只认 pod root 内路径，P104 补记）。
- CMake 侧默认 binary 集成直接用上面产物；`-DCQ_FFMPEG_INTEGRATION=source`
  会调同一个脚本现场重建（DEPS-012 双集成，同一 target `cq_ffmpeg`）。
- 源码级调试 FFmpeg 内部：`build_ffmpeg_demux.sh --debug`（-O0 不 strip），
  产物替换正常档后重建下游即可断点。

关键约束（别改）：
- 从 `--disable-everything` 起步，**只**显式开启 demux / parser / bsf
- 禁 decoder / encoder / filter / swscale / swresample / postproc / 网络 / 外部库
- **绝不开 `--enable-gpl`**（保持 LGPL-2.1-or-later；这是法律边界不是性能选项，
  处置结论 ADR-0036）
- 三库合并只能 `ar x` 分库解包 → 重命名 → `ar rcs`（baselines 已验证同名 .o 坑），
  脚本内置 duplicate members=0 校验与 GPL 符号扫描，别绕过

### 构建 shader 工具链（SHADER-001 的构建期依赖，P160）

`engine/shaders/portable/*.glsl` 是在**编译期**转成 MSL 头的（CMake 目标 SHADER-001），
需要 `glslang` 与 `spirv-cross` 两个二进制。它们和 FFmpeg 一样**不入库**：
源码在 `third_party/src/`、产物在 `build/tools/`，两者都在 `.gitignore` 里。

```bash
# 幂等：缺什么补什么；两个二进制都构建后，最后一步用 SHADER-001 真转一遍 blit 自检
tools/build/build_shader_toolchain.sh
tools/build/build_shader_toolchain.sh --check-only   # 只验产物在不在、能不能跑（只读，不删文件）
tools/build/build_shader_toolchain.sh --rebuild      # 强制重配重编
```

- 源码按 `third_party/manifest.toml` 的 `pin_ref` 浅 fetch 并校验 `HEAD == pin`（脚本自己不写死 commit）。
  本机是历史 checkout 的**非 git 树**，脚本会明打"commit 级 pin 不可校验"，只做版本级核对。
- 实测产物：`build/tools/glslang/StandAlone/glslang` 3 133 560 B、
  `build/tools/spirv-cross/spirv-cross` 4 155 984 B（⚠️ **全小写**，与 `tools/shaders/build_shaders.py`
  的默认查找路径逐字一致；跟随源码树的大写名在 macOS 上"碰巧能用"，大小写敏感的卷直接找不到）；
  端到端 `build/generated/shaders/blit_msl.h` = **1689 B**。
- 干净复现（`rm -rf build` 逐遍重装）四遍全绿，单遍 **6m48s~11min**；判据与口径见 **ADR-0045**
  与 `.ai/memory/baselines.md` 的「P160 干净复现」表。
- **顺序约束**：本步必须在 `build_core.sh` **之前**跑 —— `build_core.sh --clean` 连 `build/tools/` 一起清，
  CI 里把装配步放到内核构建之后就编不出来（同 P160）。
- 不做这一步的症状：构建停在 27% `error: shader 工具链不可用`，随后 ctest 报 50/51
  "Could not find executable"，看着像测试崩，其实全是这一个 error 的下游。

## 3. 构建内核
```bash
CMAKE_BIN=/path/to/cmake
$CMAKE_BIN -S . -B build -DCMAKE_BUILD_TYPE=Debug     # 或 Release
$CMAKE_BIN --build build -j4
```

> `tools/build/build_core.sh` 是封装入口，但在某些环境会被信号中断；
> 出错时直接用上面的两条命令即可（等价）。

**Debug 与 Release 都要能构建。** 本项目出现过 Release-only 的缺陷
（日志宏在 NDEBUG 下不引用参数 → `-Wunused-variable` 打断构建；测试越界访问 → SEGFAULT），
日常开发在 Debug 下看不出来。因此**两个配置都要跑测试**。

## 4. 门禁（全部必须绿）

```bash
CTEST_BIN=$(dirname $CMAKE_BIN)/ctest
PY=/path/to/python3

$CTEST_BIN --test-dir build                                  # C++ 单测 + 编译验证 + 静态门禁
$PY tools/platform/check_platform_headers.py                             # Platform/GFX/MEDIA 头零平台类型、零 FFmpeg 类型
$PY tests/golden/verify.py                                     # golden 样本库 21 段（ffprobe 实测）
$PY tools/deps/deps.py validate third_party/manifest.toml      # 依赖清单 schema
$PY tools/deps/deps.py lock   third_party/manifest.toml --out /tmp/lock   # 不带 --allow-placeholder
$PY tools/deps/deps.py check  third_party/manifest.toml --lock third_party/deps.lock
$PY tools/deps/selfcheck.py                                    # 解析器自测 18 项
tools/ci/check_repo_hygiene.sh                                 # 仓库卫生：忽略锚定/旧路径/产物入库/editorconfig
```

> 上面这些是**单条**门禁，便于定位。本机总入口是 `tools/ci/run_gate.sh`（INFRA-034 起 17 步，
> 先窄后全，分步日志落 `build/gate-logs/`，结尾 PASS/FAIL/SKIP 摘要行数恒等于步数）。
> `.github/workflows/ci.yml` 只承担"不需要真机、不需要 Xcode 壳"的那一段，
> **远端绿不是验收口径**（AGENTS「验证」+ ADR-0030）。

### 几条门禁的设计意图（别把它们当形式）

- **`check_platform_headers.py`**：零平台类型**编译证明不了**
  （AppleClang 下头文件里出现 `CVPixelBufferRef` 照样能编译过）。该脚本会先**剥离注释与字符串**
  再匹配，因为朴素 grep 会把注释里的说明误报成违规。
  覆盖 `engine/core/cq/{platform,gfx,media}/`，新增头文件会自动纳入。
- **`deps.py lock` 默认拒绝占位 sha256**：全 0 / 全 1 / 全 2 这类明显占位会被拦下。
  这条的意义是防止「声明一个我们明知不存在的产物」——那比不声明更糟。
- **`-Werror`**：警告集合含 `-Wconversion -Wshadow -Wold-style-cast`。
  告警必须**改代码**修掉，**禁止 `-Wno-*` 逃逸**（INFRA-002 已用故意触发实验证明它会让构建失败）。

## 5. 平台后端现状

| 平台 | 状态 |
|---|---|
| Apple（macOS） | 渲染 / 解封装 / 硬解 / 零拷贝导入 / 导出 均已实现并验证 |
| Android | 未开始（Platform 接口已冻结，可直接实现） |
| 鸿蒙 | 本期仅 `platform/ohos/` 接口编译检查 |

Apple 端的能力链路：

```
读 MP4(PALA-010) → 硬解(PALA-011) → 零拷贝导入(PALA-002) → Metal 渲染(PALA-001)
                                                        ↘ 导出 H.264 MP4(PALA-012)
```

## 6. 性能埋点（真机实测前务必看）

埋点**默认关闭**，需显式 `SetPerfEnabled(true)` 打开；**Release 下同样可用**（真机实测就是 Release）。
可 `SetPerfSampleRate(N)` 采样以降低高频路径开销。

打开后 `AcquireFrame` 等关键点会输出结构化记录（含 `pts`），可据此定位慢帧。
详见 `engine/core/cq/base/chq_perf.h` 头部说明。

## 7. 常见坑

1. **新增 `.mm`（Objective-C++）必须同时登记三处**：`add_library` 源文件列表、
   `set_source_files_properties`(ARC)、`find_library`+`target_link_libraries`(系统框架)。
   漏了只会在链接期报「符号未定义」，且**报错只显示引用位置、不指明缺哪个框架**，排查成本高。
2. 修改 golden 后必须重跑 `tests/golden/verify.py`——校验是 ffprobe 实测，不迁就产物。
3. 改 `docs/specs/PLATFORM-接口契约.md` 或 `engine/core/cq/**` 前先确认是否被冻结。
   Platform 接口已冻结（CORE-006），**新增**接口可以，**修改既有签名**需先提 ADR。
