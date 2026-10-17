# ChuanqiCut — Vendored 第三方组件许可声明

本目录（ChuanqiCutCore Pod，原 CChuanqiCut）包含以下第三方代码的预编译产物。本文件随 Pod 分发，
发布时**不得删除**（LGPL 义务，见 ADR-0036 / ARCH-002 §5.1）。

## FFmpeg 9.0.2（demux 档）

- 版本：n9.0.2（commit `946fcce07b6dcd0331c8cc609192aeff5e1924f8`）
- 来源：<https://github.com/FFmpeg/FFmpeg>（ffmpeg.org 登记镜像）
- 许可：**LGPL-2.1-or-later**（本构建未启用任何 GPL 组件——无 libx264/libx265/
  libvpx/libpostproc，configure flag 见 `tools/build/build_ffmpeg_demux.sh`，
  GPL 符号扫描 0 命中记录于 `.ai/memory/baselines.md`）
- 用途：媒体容器 demux（libavformat + libavutil + libavcodec 的 parser/
  bitstream-filter 部分），以静态库 `libffmpeg.a` vendored（xcframework 三 slice）
- 义务履行（负责人 2026-10-11 确认，业界通行式合规路径）：
  1. 本文件即为 App 内许可声明载体，发布时须在 App「关于/设置」页可达；
  2. 对应版本源码可通过上述 GitHub 地址 + commit 获取；
  3. 保留「接收者可重链接」义务通道：发布流程须提供本产物 .a（目标文件归档）
     或等价重链接材料（ARCH-002 §5.1 路径 1）。

FFmpeg 源码本体不入库（`third_party/src/ffmpeg` 为本地 shallow clone，
版本锁定见 `third_party/manifest.toml` + ADR-0008）。
