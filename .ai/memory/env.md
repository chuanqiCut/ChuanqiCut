# 本机工具链环境（ChuanqiCut 开发机）

> 这里的路径绕过 BM：这些工具**不在 PATH 里**，脚本与文档引用时必须写绝对路径。

## 机器

| 项 | 值 |
|---|---|
| CPU | Intel(R) Core(TM) i7-9750H @ 2.60GHz |
| arch | **x86_64（Intel Mac，非 Apple Silicon）** |
| 编译器 | AppleClang 17.0.0.17000013 |

⚠️ **重要含义**：这是 Intel Mac，所以
- **ANE（Apple Neural Engine）不存在** —— 所有 AI-002「CoreML 是否落在 ANE」的实测**必须换到 Apple Silicon 机器做**
- ProRes 硬编 / UMA 零拷贝等 Apple Silicon 特性**在本机无法验证**
- 本机测得的性能数字**不代表目标设备**，PERF-001 基线必须标注采集机型，否则会污染 baselines
- **arch 是 x86_64，Rosetta 不是问题**（本来就是 Intel）

## 工具绝对路径

| 工具 | 路径 | 状态 |
|---|---|---|
| cmake 4.4.3 | `/Users/zhuning/.workbuddy/binaries/cmake/CMake.app/Contents/bin/cmake` | 已安装验证（Kitware 官方 universal 包） |
| ffmpeg 6.1.1 | `/Users/zhuning/.workbuddy/binaries/ffmpeg/bin/ffmpeg` | 已安装验证（tessus / evermeet.cx 构建） |
| ffprobe 6.1.1 | `/Users/zhuning/.workbuddy/binaries/ffmpeg/bin/ffprobe` | 同上 |
| python 3.13.12 | `/Users/zhuning/.workbuddy/binaries/python/versions/3.13.12/bin/python3` | 托管版本 |
| node 22.22.2 | `/Users/zhuning/.workbuddy/binaries/node/versions/22.22.2-3/bin/node` | 托管版本 |

**不要用裸 `cmake` / `ffmpeg` / `ffprobe`** —— PATH 里都没有。CI 或脚本统一先定义 `CMAKE_BIN` / `FFMPEG_BIN` / `FFPROBE_BIN`。

### ffmpeg 的 provenance 与使用边界（重要）

这台 ffmpeg 是 evermeet.cx 的 tessus 静态构建（evermeet.cx 正是 ffmpeg.org 官方下载页推荐的 macOS 构建源）。
但它 `--enable-gpl --enable-libx264 --enable-libx265` 等 **GPL 组件**。

> **只准用作构建期的主机工具**（生成 golden 测试夹具）。
> **绝不链接进任何发布产物**，也不要把它当作 FFmpeg 位数/符号基线的数据源（那是 DEPS-013 的事，
> 必须用我们自己按 demux 档位编出来的产物测）。
> 混淆这两者会让 LGPL/GPL 合规判断失真。

## 网络

- github.com **可达**（含 raw/releases/api）
- PyPI **可连通但很慢**，pip install 动辄超过 120s 默认超时 → **必须后台跑或放宽 timeout**
- 早期 DEPS-001 worker 报「无网络」只对一半：那是 pip 超时，不是断网

## 缺失 / 待定

- **ffmpeg / ffprobe**：尚未装上。尝试过的路径：无 brew/port/conda；evermeet.cx 已迁移到 deolaha.ca 且 404。
  未装上则 golden 样本的编码类维度（H.264/HEVC/B帧/VFR/旋转/音轨）无法合成。
- 无 Homebrew —— 是否安装待传哲决定（会影响后续所有工具获取）
