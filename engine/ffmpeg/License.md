# FFmpeg — LGPL-2.1-or-later 声明（App 内声明，ADR-0036 §5.1 路径 1）

本应用包含 FFmpeg（https://ffmpeg.org）9.0.2 的 demux 档位静态库
（libavformat / libavutil / libavcodec 的 parser 与 bitstream filter 子集，
未启用任何 GPL 组件），以 **LGPL-2.1-or-later** 许可使用。

## 义务与获取源码

- FFmpeg 采用 LGPL-2.1-or-later 授权，完整许可文本见
  https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html 。
- 使用的 configure 参数与裁剪清单由 `tools/build/build_ffmpeg_demux.sh`
  单一真源维护；对应源码版本 9.0.2 可自 https://ffmpeg.org/download.html 获得，
  或向我们索取。
- 本应用以静态链接方式使用 FFmpeg；依照 LGPL-2.1 §6，你拥有对本应用中
  FFmpeg 部分进行重链接替换的权利——所需的构建脚本随本仓库分发
  （`tools/build/build_ffmpeg_demux.sh` + `tools/build/make_ffmpeg_xcframework.sh`）。

## 归属

FFmpeg 项目：https://ffmpeg.org —— FFmpeg developers，LGPL-2.1-or-later。
本声明由 ChuanqiCut 依据 ADR-0036（2026-10-11 负责人确认）随 App 分发。
