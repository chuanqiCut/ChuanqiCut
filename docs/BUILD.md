# ChuanqiCut 构建与门禁说明

面向第一次 clone 本仓库的人。读完这份文档，你应该能在一台新机器上把项目跑起来并跑通全部门禁。

## 1. 前置工具

| 工具 | 版本要求 | 说明 |
|---|---|---|
| CMake | ≥ 3.20（本项目实测 4.4.3） | **PATH 里可能没有 `cmake`**，脚本里统一用 `CMAKE_BIN` |
| C++ 编译器 | C++20（AppleClang 17 / GCC / MSVC 均可） | 内核硬锁 C++20，禁 GNU 扩展 |
| Python | ≥ 3.11（需 tomllib） | 仅依赖治理工具链与门禁脚本用，**运行时不依赖** |
| Xcode（仅 Apple 平台） | 完整 Xcode，非仅命令行工具 | 需要 Metal / AVFoundation / VideoToolbox / CoreVideo 等框架 |

本机（开发机）的绝对路径参考：

```
cmake   /Users/zhuning/.workbuddy/binaries/cmake/CMake.app/Contents/bin/cmake
ctest   与 cmake 同目录
python  /Users/zhuning/.workbuddy/binaries/python/versions/3.13.12/bin/python3
```

> 这些是隔离安装路径，不污染系统环境。脚本里不要写裸 `cmake`，用 `CMAKE_BIN` 变量。

## 2. ⚠️ 第一段必读：产物不入库

**仓库里没有任何第三方预编译产物。** `third_party/manifest.toml` 只登记
「依赖的哪个 commit、构建档位、产物期望的 sha256 / size」，`third_party/prebuilt/` 与
`third_party/src/` 都在 `.gitignore` 里。

所以 clone 下来**直接链接会失败**（缺 `libffmpeg.a` 之类）。必须先按下面的步骤自行构建一次。

这样做的理由：产物可由 `pin_ref` + 构建档位**可复现地**重新生成，没必要把二进制塞进 git；
同时避免把 LGPL 二进制随仓库分发（ADR-0008 / ADR-0010）。

### 构建 FFmpeg（DEPS-010 档位）

```bash
# 源码 checkout（首次）
git clone https://github.com/FFmpeg/FFmpeg.git third_party/src/ffmpeg
cd third_party/src/ffmpeg && git checkout 946fcce07b6dcd0331c8cc609192aeff5e1924f8   # tag n9.0.2
```

完整 configure 命令与实测体积见 `.ai/memory/baselines.md`（「FFmpeg demux 常用子集档位」一节），
**照抄那一节，不要凭记忆写**。

关键约束（别改）：
- 从 `--disable-everything` 起步，**只**显式开启 demux / parser / bsf
- 禁 decoder / encoder / filter / swscale / swresample / postproc / 网络 / 外部库
- **绝不开 `--enable-gpl`**（保持 LGPL-2.1-or-later，见 ADR-0010；这是法律边界不是性能选项）

产物落到 `third_party/prebuilt/apple-x86_64-demux/`（平台目录名按实际平台）。

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
$PY tools/pal/check_pal_headers.py                             # PAL/GFX/MEDIA 头零平台类型、零 FFmpeg 类型
$PY tests/golden/verify.py                                     # golden 样本库 21 段（ffprobe 实测）
$PY tools/deps/deps.py validate third_party/manifest.toml      # 依赖清单 schema
$PY tools/deps/deps.py lock   third_party/manifest.toml --out /tmp/lock   # 不带 --allow-placeholder
$PY tools/deps/deps.py check  third_party/manifest.toml --lock third_party/deps.lock
$PY tools/deps/selfcheck.py                                    # 解析器自测 18 项
```

### 几条门禁的设计意图（别把它们当形式）

- **`check_pal_headers.py`**：零平台类型**编译证明不了**
  （AppleClang 下头文件里出现 `CVPixelBufferRef` 照样能编译过）。该脚本会先**剥离注释与字符串**
  再匹配，因为朴素 grep 会把注释里的说明误报成违规。
  覆盖 `core/include/cq/{pal,gfx,media}/`，新增头文件会自动纳入。
- **`deps.py lock` 默认拒绝占位 sha256**：全 0 / 全 1 / 全 2 这类明显占位会被拦下。
  这条的意义是防止「声明一个我们明知不存在的产物」——那比不声明更糟。
- **`-Werror`**：警告集合含 `-Wconversion -Wshadow -Wold-style-cast`。
  告警必须**改代码**修掉，**禁止 `-Wno-*` 逃逸**（INFRA-002 已用故意触发实验证明它会让构建失败）。

## 5. 平台后端现状

| 平台 | 状态 |
|---|---|
| Apple（macOS） | 渲染 / 解封装 / 硬解 / 零拷贝导入 / 导出 均已实现并验证 |
| Android | 未开始（PAL 接口已冻结，可直接实现） |
| 鸿蒙 | 本期仅 `pal/ohos/` 接口编译检查 |

Apple 端的能力链路：

```
读 MP4(PALA-010) → 硬解(PALA-011) → 零拷贝导入(PALA-002) → Metal 渲染(PALA-001)
                                                        ↘ 导出 H.264 MP4(PALA-012)
```

## 6. 性能埋点（真机实测前务必看）

埋点**默认关闭**，需显式 `SetPerfEnabled(true)` 打开；**Release 下同样可用**（真机实测就是 Release）。
可 `SetPerfSampleRate(N)` 采样以降低高频路径开销。

打开后 `AcquireFrame` 等关键点会输出结构化记录（含 `pts`），可据此定位慢帧。
详见 `core/include/cq/base/perf.h` 头部说明。

## 7. 常见坑

1. **新增 `.mm`（Objective-C++）必须同时登记三处**：`add_library` 源文件列表、
   `set_source_files_properties`(ARC)、`find_library`+`target_link_libraries`(系统框架)。
   漏了只会在链接期报「符号未定义」，且**报错只显示引用位置、不指明缺哪个框架**，排查成本高。
2. 修改 golden 后必须重跑 `tests/golden/verify.py`——校验是 ffprobe 实测，不迁就产物。
3. 改 `docs/specs/PAL-接口契约.md` 或 `core/include/cq/**` 前先确认是否被冻结。
   PAL 接口已冻结（CORE-006），**新增**接口可以，**修改既有签名**需先提 ADR。
