# 实测基线

> **本文件是唯一被认可的数字来源。** 原调研文档中的性能数字均为估算（[E]），
> 在 `PERF-001` 完成前**不得**作为任何验收阈值或设计依据。
> 每次更新必须附：日期、设备、系统版本、测量方法、样本。

## 当前状态

**尚未建立。** `PERF-001`（性能基准套件）完成后填入。

## 待填充项（对应原调研中的估算数字，需逐一实测替换）

### 媒体
| 项 | 原估算值 | 实测 | 设备 | 日期 |
|---|---|---|---|---|
| 4K H.265 硬解单帧耗时 | < 0.5ms [E] | — | | |
| 1080p 硬编单帧耗时 | — | — | | |
| AVAssetReader 重建开销 | 20–200ms [E] | — | | |
| MediaCodec 关键帧 seek 开销 | — | — | | |
| FFmpeg demux 产物体积（apple-x86_64, 全 demuxer+parser） | 参考基准（无硬阈值） | 4.9MB（全 demuxer+parser 档位实测，非超标告警）[DEPS-010] | i7-9750H / macOS 14 | 2026-09-24 |
| FFmpeg demux 产物体积（apple-x86_64, 常用子集） | 参考基准（无硬阈值） | 2.22MB（常用子集档位实测，见下节）[DEPS-010] | i7-9750H / macOS 14 | 2026-09-25 |
| FFmpeg demux 产物体积（arm64） | 参考基准（无硬阈值） | —（待 DEPS-011/012 在对应平台实测） | | |

### 渲染
| 项 | 原估算值 | 实测 | 设备 | 日期 |
|---|---|---|---|---|
| 变换 shader | < 0.05ms [E] | — | | |
| 多轨 blend（2 轨） | < 0.1ms [E] | — | | |
| 3D LUT 采样 | ~0.05ms [E] | — | | |
| 4K 三轨完整效果链帧时间 | — | — | | |

### AI
| 项 | 原估算值 | 实测 | 设备 | 日期 |
|---|---|---|---|---|
| Vision 人脸检测 | ~0.5ms ANE [E] | — | | |
| landmark 468 推理 | 1–2ms ANE [E] / 5–7ms CPU [E] | — | | |
| **是否命中 ANE** | 假设命中 [H] | — | | |
| 磨皮 compute shader | ~0.5ms [E] | — | | |
| 完整美颜管线 | 2–9.5ms [E] | — | | |
| 相机检测桥单帧耗时（CAM-011：人脸+人体+动物全请求，含转换与平滑） | 未估算 | **未实测**（需真机；数据源 `VisionDetector.lastDetectionDurationMs` 埋点） | | |
| 相机检测降频默认值（CAM-011 `detectionHz`） | 15Hz [E] | **未实测**（真机以 `totalDroppedByRate`/帧率权衡定频） | | |

### 内存
| 项 | 目标 | 实测 | 设备 | 日期 |
|---|---|---|---|---|
| 1080p 三轨预览峰值 | ≤ 400MB | — | | |
| 4K 三轨预览峰值 | ≤ 1.2GB | — | | |
| 4K 导出峰值 | ≤ 1.5GB | — | | |

### 素材导入（UIA-009 子步骤 3，2026-10-03）
| 项 | 实测 | 备注 |
|---|---|---|
| probe_duration（打开容器→读时长→关闭，golden 1080p h264） | **未实测** | 主线程同步调用（毫秒级假设 [E]）；导入是用户低频动作，非逐帧路径。需埋点后回填 |
| importMedia 全流程（probe+注册+建轨+追加） | **未实测** | 测试墙钟 ~0.3s 含断言轮询，不能作基线 |

### 时间线布局（UIA-004，2026-10-03，本机 Intel Mac）
| 项 | 实测 | 备注 |
|---|---|---|
| 500 片段（5 轨×100）单帧布局 | **0.663 ms/帧** | TimelineLayout 纯函数（换算+可见裁剪+标尺），100 帧平均；预算 16ms 的 4%。拖拽交互实帧率归 UIA-005 真机 |

### 命令层（MODEL-002，2026-10-03）
| 项 | 实测 | 备注 |
|---|---|---|
| Execute / Undo / Redo 单次开销 | **未实测** | 功能验收阶段；量级为微秒级纯内存操作，接入 Session 后随埋点补测 |

### 预览单帧链路（UIA-003，2026-10-03）
| 项 | 实测 | 备注 |
|---|---|---|
| 预览单帧全链路（seek+解码+零拷贝导入+离屏绘制+blit） | **未实测** | 功能验收已过（SharedUI 像素级用例，golden 0.5s 真实解码渲染）；帧率 / 耗时待 PERF-001，**不得**引用测试墙钟时间当基线 |

### 竞品参考（**仅作参考，非本项目指标**）
| 项 | 原估算值 | 备注 |
|---|---|---|
| 剪映美颜管线 | ~2ms [E] | 上游自述为"传闻数据，基于行业共识估算" |

---

## 测量方法约定

- 每帧耗时：取 P50 / P95 / P99，不取平均值（P99 才对应卡顿体验）
- 每项测 3 次取中位，样本固定（用 `tests/golden/` 中的素材）
- 设备状态：冷启动后预热 5 秒，关闭后台应用，记录电量与温度
- 数据由 `tools/perf/*` 产出机器可读 JSON，本文件引用其结果

---

## FFmpeg demux 档位构建基线（DEPS-010, 2026-09-24）

> 设备：Intel i7-9750H（6C/12T），macOS，AppleClang 17.0.0，无 nasm/yasm，无 brew/port。
> 源码：`third_party/src/ffmpeg` @ `946fcce07b6dcd0331c8cc609192aeff5e1924f8`（tag n9.0.2，shallow clone）。
> 本机产物目录：`third_party/prebuilt/apple-x86_64`；manifest `artifact.platform` 填 `apple-x86_64`（parser 正则只接受 apple/android/ohos/host 前缀）。

### Configure 命令行（可复现照抄，最终版）
```bash
cd third_party/src/ffmpeg
./configure \
  --prefix=/tmp/ffbuild \
  --disable-everything \
  --enable-avformat --enable-avutil --enable-avcodec \
  --enable-parsers --enable-demuxers --enable-bsfs \
  --enable-protocol=file --enable-protocol=pipe \
  --disable-x86asm --disable-network --disable-doc \
  --disable-programs --disable-autodetect \
  --disable-swscale --disable-swresample --disable-avfilter --disable-avdevice \
  --enable-static --disable-shared \
  --enable-small --disable-debug
```
要点：`--disable-x86asm` 必加（本机无 nasm/yasm，否则 configure 报 nasm/yasm not found）；
`--disable-autodetect` 避免拉入系统 zlib/bzlib 等外部库；`--disable-network` 仅留 file/pipe 协议；
`--disable-everything` 后只显式开 avformat/avutil/avcodec + parsers/demuxers/bsfs；
额外显式 `--disable-swscale --disable-swresample --disable-avfilter --disable-avdevice` 关掉其余库。
⚠️ FFmpeg 9.0.2 中 **不存在** `--disable-postproc` 选项（postproc 已不是独立库，其能力在 avfilter 内，
而 avfilter 已被 disable），configure 遇 unknown option 会直接退出，故不要加该 flag。

### 组件启用矩阵（来自 `configure` 输出，License: LGPL version 2.1 or later）
- CONFIG_GPL=0 / CONFIG_NONFREE=0 / CONFIG_VERSION3=0；External libraries: 无
- decoders / encoders / muxers / filters / hwaccels / indevs / outdevs：**全空**
- swscale / swresample / avfilter / avdevice 库：**已 disable**（CONFIG_SWSCALE=0 / SWRESAMPLE=0 / AVFILTER=0 / AVDEVICE=0）；postproc 非独立库，其能力随 avfilter 一并关闭
- parsers：全开（约 75 个）；demuxers：全开（实测 367 个，9.0.2）；bsfs：全开；protocols：file、pipe

### 产物（third_party/prebuilt/apple-x86_64/）
| 文件 | 字节数 | sha256 |
|---|---|---|
| libavutil.a | 828056 | `2d78a371bfb863a345d62f66ca1d24fb2dc2dd21d28e85f68419e0c5d4501480` |
| libavformat.a | 2107296 | `bba242e317ebaad4e301208bcb3461cb0c84a378d9ba2e1659a21e1429f2c37e` |
| libavcodec.a | 2202920 | `9502eb4d631b6de9f7092ebca961c76f46a3d0df3edf1052ad00afac6954fa02` |
| libffmpeg.a（三库合并） | 5117328 | `870f6ae4b5762927e5ec35fddebce2641f3743dbe94f80f1188582665b49e14a` |

合并方法（关键坑，已验证）：`libutil/libavformat/libavcodec` 内含同名 `.o`（utils.o、cpu.o、version.o、codec.o 等），
**不能**用 `libtool -static` 或 BSD `ar` 直接合并（同名成员会丢符号）。正确做法：分别 `ar x` 到独立子目录 →
重命名为 `lib名_原名.o` → `ar rcs` 合并；最终 duplicate members = 0、711 个 .o 全部保留、符号数 17768 ≈ 三库之和 17909。

### nm GPL/外部库符号扫描
- 扫描文件：libavutil.a / libavformat.a / libavcodec.a（共 17,909 条符号）
- 扫描模式（大小写不敏感）：`x264|x265|libxvid|xvid|faac|libfaac|aacenc|libmp3lame|mp3lame|libvorbis|libtheora|libvpx|libopenjpeg|libgsm|libopencore|libtwolame|libvo_aac|libaacplus|libilbc|libsnappy|libzimg|libcdio|libopenh264|libwebp|rtmp|_gpl|gpl`
- 命中行数：**0**（三库均为 0）
- 结论：无任何 GPL / external-GPL 符号，符合 LGPL demux 档位要求。

### 教训：GPL 符号扫描模式必须用 `lib<name>` / 显式第三方 API 前缀（DEPS-010 收尾）
- **不要用裸格式名**（vorbis / theora / aac / mp3 / ilbc 等）作扫描模式。这些名字会命中 **FFmpeg 自身** 的 LGPL 代码，
  造成「误报 GPL 泄漏」的假阳性。复验时 team-lead 用裸 `vorbis|theora|ilbc` 扫出 47 处命中，全部是 FFmpeg 自己的符号，
  例如 `ff_vorbis_ch_layouts`、`av_vorbis_parse_frame`、`ff_ilbc_demuxer`、`ff_aac_*`。
- **正确模式**：只针对**真实第三方 GPL 库**的导出符号，用其库名前缀 `lib<name>` 或显式 API 前缀，例如
  `libx264|libx265|libxvid|libvorbis|libtheora|libvpx|libopenjpeg|libgsm|libopencore|libtwolame|libvo_aac|libaacplus|libilbc|libsnappy|libzimg|libcdio|libopenh264|libwebp|rtmp|_gpl|gpl`。
- 精确模式下（本档位 17,909 条符号）用 `lib<name>` 前缀命中恒为 0，证明 demux 档位无 GPL 符号；
  裸格式名会把 FFmpeg 内部 LGPL 实现算进去，导致 **DEPS-013（符号门禁）误杀**。
- 关键认知：FFmpeg 内部自带 vorbis/theora/aac 等的 LGPL 解码/解析逻辑，符号名带 `vorbis`/`theora`/`aac`
  **不**等于引入了 GPL 库。DEPS-013 的扫描正则务必沿用本文件 pattern，禁止退化成裸格式名。

### 耗时（time 实测）
- configure：~2m32s（real，12 逻辑核）；make -j12：~24s wall（178s user）。合计一次构建约 3 分钟，执行一次，无重试。

### 门禁状态（DEPS-010 复验 + 收尾后最终状态，2026-09-24）
- `python3 tools/deps/deps.py validate third_party/manifest.toml` → **exit 0**（7 条条目校验通过，0 错误 0 警告）
- `python3 tools/deps/deps.py lock third_party/manifest.toml --out /tmp/deps.lock.after`（不带 --allow-placeholder）→ **exit 0**
- `python3 tools/deps/deps.py check third_party/manifest.toml --lock /tmp/deps.lock.after` → **exit 0**
- `python3 tools/deps/deps.py summarize third_party/manifest.toml` → **exit 0**
- `python3 tools/deps/selfcheck.py` → **18/18 通过**（exit 0）
> 整仓已可 clean-lock 通过。原 tflite 占位（sha256=2222…）已在收尾中删除：tflite 改为 `integration=auto` + 锁定到 TF v2.16.1 真实 commit
> `5bc9d26649cca274750ad3625bd93422617eed4b`，android-arm64-v8a 预编译产物待 DEPS-011/012 在设备上实测后回填为 `[[dep.artifact]]`（见末节）。

### 体积记录（无硬阈值，仅作参考基准）
- 本档位**不设硬性体积上限**（2026-09-25 由 team-lead 修订：原 `< 3MB` 约束已废除，体积只是裁剪的结果、不是反推该裁哪些格式的依据）。
- 实测合并产物 5,117,328 B（≈4.88MB）/ 三库之和 5,138,272 B（≈4.90MB）。
  这是「全量 demuxer + 全量 parser」这一**选择**的实测结果，**不是超标告警**。
- 根因：本档位按字面要求启用「libavformat + libavutil + avcodec 的 parser 部分 + 全部 demuxers + 全部 bsfs」，
  全量 parser/bsf 与全量 demuxer 的真实体量即此量级（libavformat 2.107MB、libavcodec 2.203MB、libavutil 0.829MB）。
- `strip -S` 对 .a 几乎无效（5.12MB→5.44MB，macOS BSD strip 对归档行为异常），体积来自代码而非调试信息，故裁剪是根本手段。
- 后续路径（**产品决策，不在本任务权限内**）：
  1. 把 demuxer/parser 裁剪到常用子集（视频编辑 SDK 不需要全部 367 个 demuxer）；
  2. 或把度量改为「链接+strip 后 SDK 贡献体积」（链接期只引入被用到的 .o，远小于 .a 之和）。

### 剩余风险 / 后续
- **tflite 占位已清除（DEPS-010 收尾 Task 2）**：删除了 `android-arm64-v8a` 占位 artifact（sha256=2222…），tflite 改为 `integration=auto`
  并锁定到 TF v2.16.1 真实 commit `5bc9d26649cca274750ad3625bd93422617eed4b`（GitHub API 核对，tag 解引用后的 commit）。
  android-arm64-v8a 的预编译 `libtensorflowlite.a` 由 DEPS-011/012 在目标设备上实测体积/校验和后再回填为 `[[dep.artifact]]`；
  parser 约束：`binary` 集成必须带 artifact，故未回填前用 `auto`+commit 表达「已规划、尚未产出二进制」，避免声明不存在的产物（比占位更糟）。
- 磁盘目录已统一为 `third_party/prebuilt/apple-x86_64/`（原 `darwin-x86_64`，收尾 Task 1 重命名，sha256 重测一致）。
- 原 `apple-arm64` / `android-arm64-v8a` 两条占位 artifact 条目已于 DEPS-010 删除（其占位 sha256 会挡 clean-lock；arm64 产物本应由 DEPS-011/012 在对应平台实测回填）。
- 体积记录：full 档位 5.12MB（全量格式实测，非超标）、常用子集 2.22MB（见下节），均无硬阈值，仅作参考基准。

---

## FFmpeg demux 常用子集档位构建基线（DEPS-010 收尾 Task 3，slim / apple-x86_64-slim，2026-09-24）

> 实验目的：在 demux 档位基础上，把 demuxer/parser/bsf 裁到视频编辑 SDK 真正需要的「常用子集」，
> 看体积能否压到 <3MB。产物只落在 `third_party/prebuilt/apple-x86_64-slim/`，**不写入 manifest artifact**（保持 full 档位为清单真源）。
> 源码同 `third_party/src/ffmpeg` @ `946fcce…`（n9.0.2）；`git clean -xfd` 后重新 configure。

### Configure（关键：逐个 `--enable-demuxer/--enable-parser/--enable-bsf`，不是 `--disable-everything`+`--enable-demuxers` 全开）
```bash
./configure --prefix=/tmp/ffbuild-slim --disable-everything \
  --enable-avformat --enable-avutil --enable-avcodec \
  --enable-demuxer=mov --enable-demuxer=mp4 --enable-demuxer=m4v --enable-demuxer=3gp \
  --enable-demuxer=matroska --enable-demuxer=webm --enable-demuxer=avi --enable-demuxer=flv \
  --enable-demuxer=mpegts --enable-demuxer=mpegps --enable-demuxer=gif --enable-demuxer=image2 \
  --enable-demuxer=image2pipe --enable-demuxer=wav --enable-demuxer=pcm_s16le --enable-demuxer=mp3 \
  --enable-demuxer=aac --enable-demuxer=flac --enable-demuxer=ogg --enable-demuxer=oga --enable-demuxer=m4a \
  --enable-parser=h264 --enable-parser=hevc --enable-parser=aac --enable-parser=mp3 \
  --enable-parser=flac --enable-parser=vorbis --enable-parser=opus --enable-parser=mpegaudio \
  --enable-parser=vp8 --enable-parser=vp9 --enable-parser=av1 --enable-parser=mjpeg --enable-parser=png --enable-parser=gif \
  --enable-bsf=h264_mp4toannexb --enable-bsf=hevc_mp4toannexb --enable-bsf=aac_adtstoasc \
  --enable-bsf=extract_extradata --enable-bsf=null --enable-bsf=flush_packets \
  --enable-protocol=file --enable-protocol=pipe \
  --disable-x86asm --disable-network --disable-doc --disable-programs --disable-autodetect \
  --disable-swscale --disable-swresample --disable-avfilter --disable-avdevice \
  --enable-static --disable-shared --enable-small --disable-debug
```
- ⚠️ **configure 警告（非错误，已确认等价）**：`mp4 / 3gp / webm / oga / m4a` 作为 demuxer 名未匹配 —— 它们是别名，分别由 `mov`(覆盖 mp4/3gp/m4v/m4a)、`matroska`(webm)、`ogg`(oga) 承载；`--enable-demuxer=mov` 等已实际启用。
  `mp3` parser 未匹配 —— 它即 `mpegaudio`（已启用）。`flush_packets` 作为 bsf 未匹配：**FFmpeg 9.0.2 没有 `flush_packets` 这个 bsf**（列表里只有 5 个 bsf 生效：h264_mp4toannexb/hevc_mp4toannexb/aac_adtstoasc/extract_extradata/null）。
- 实际启用：**demuxers 16（规范名）**、**parsers 13**、**bsfs 5**；Libraries 仅 avcodec/avformat/avutil；External libraries 无；`CONFIG_GPL=0 / NONFREE=0 / VERSION3=0`。

### 体积对比（slim 子集 vs full 全量，同机同配置）
| 文件 | full (apple-x86_64) B | slim (apple-x86_64-slim) B | 变化 |
|---|---:|---:|---:|
| libavutil.a | 828,056 | 708,776 | −119,280 (−14.4%) |
| libavformat.a | 2,107,296 | 795,576 | −1,311,720 (−62.2%) |
| libavcodec.a | 2,202,920 | 834,064 | −1,368,856 (−62.1%) |
| **libffmpeg.a（合并）** | **5,117,328** | **2,324,920** | **−2,792,408 (−54.6%)** |

- **关键结论：slim 合并产物 2,324,920 B ≈ 2.22 MiB（常用子集档位实测，参考基准，无硬阈值）**；full 合并 5.12 MB（≈4.88 MiB）为全量格式实测。
  即「裁到常用子集」这条路显著缩小体积（full 档位因全 demuxer/全 parser 才偏大）。体积完全由 demuxer/parser 范围决定。
- 合并方法同 full：`ar x` 分库解包 → 重命名 `<lib>_<base>.o` → `ar rcs` 合并；slim 合并 members=274、duplicate=0（无符号丢失）。

### nm 符号数对比
| 库 | full 符号数 | slim 符号数 |
|---|---:|---:|
| libavutil.a | 2,322 | 2,328 |
| libavformat.a | 9,064 | 2,774 |
| libavcodec.a | 5,067 | 2,227 |
| libffmpeg.a（合并） | 16,325 | 7,269 |

### 被裁剪的 demuxer（full `--list-demuxers` 367 个 − 保留 16 个 = 351 个）
> 全量 367 个（DEPS-010 基线写的「约 250」是高估，9.0.2 实测 367）。保留：mov(matroska/ogg 同族已含 webm/oga；mp4/3gp/m4v/m4a 为 mov 别名)、avi、flv、mpegts、mpegps、gif、image2、image2pipe、wav、pcm_s16le、mp3、aac、flac。
> 裁剪 351 个：`aa aax ac3 ac4 ace acm act adf adp ads adx aea afc aiff aix alp amr amrnb amrwb anm apac apc ape apm apng aptx aptx_hd apv aqtitle argo_asf argo_brp argo_cvg asf asf_o ass ast au av1 avisynth avr avs avs2 avs3 bethsoftvid bfi bfstm bink binka bintext bit bitpacked bmv boa bonk brstm c93 caf cavsvideo cdg cdxl cine codec2 codec2raw concat dash data daud dcstr derf dfa dfpwm dhav dirac dnxhd dsf dsicin dss dts dtshd dv dvbsub dvbtxt dvdvideo dxa ea ea_cdata eac3 epaf evc ffmetadata filmstrip fits flic fourxm frm fsb fwse g722 g723_1 g726 g726le g728 g729 gdv genh gsm gxf h261 h263 h264 hca hcom hevc hls hnm hxvs iamf ico idcin idf iff ifv ilbc image2_alias_pix image2_brender_pix image_bmp_pipe image_cri_pipe image_dds_pipe image_dpx_pipe image_exr_pipe image_gem_pipe image_gif_pipe image_hdr_pipe image_j2k_pipe image_jpeg_pipe image_jpegls_pipe image_jpegxl_pipe image_jpegxs_pipe image_pam_pipe image_pbm_pipe image_pcx_pipe image_pfm_pipe image_pgm_pipe image_pgmyuv_pipe image_pgx_pipe image_phm_pipe image_photocd_pipe image_pictor_pipe image_png_pipe image_ppm_pipe image_psd_pipe image_qdraw_pipe image_qoi_pipe image_sgi_pipe image_sunrast_pipe image_svg_pipe image_tiff_pipe image_vbn_pipe image_webp_pipe image_xbm_pipe image_xpm_pipe image_xwd_pipe imf ingenient ipmovie ipu ircam iss iv8 ivf ivr jacosub jpegxl_anim jv kux kvag laf lc3 libgme libmodplug libopenmpt live_flv lmlm4 loas lrc luodat lvf lxf mca mcc mgsts microdvd mjpeg mjpeg_2000 mlp mlv mm mmf mods moflex mpc mpc8 mpegtsraw mpegvideo mpjpeg mpl2 mpsub msf msnwc_tcp msp mtaf mtv musx mv mvi mxf mxg nc nistsphere nsp nsv nut nuv obu oma osq paf pcm_alaw pcm_f32be pcm_f32le pcm_f64be pcm_f64le pcm_mulaw pcm_s16be pcm_s24be pcm_s24le pcm_s32be pcm_s32le pcm_s8 pcm_u16be pcm_u16le pcm_u24be pcm_u24le pcm_u32be pcm_u32le pcm_u8 pcm_vidc pdv pjs pmp pp_bnk pva pvf qcp qoa r3d rawvideo rcwt realtext redspark rka rl2 rm roq rpl rsd rso rtp rtsp s337m sami sap sbc sbg scc scd sdns sdp sdr2 sds sdx segafilm ser sga shorten siff simbiosis_imx sln smacker smjpeg smush sol sox spdif srt stl str subviewer subviewer1 sup svag svs swf tak tedcaptions thp threedostr tiertexseq tmv truehd tta tty txd ty usm v210 v210x vag vapoursynth vc1 vc1t vividas vivo vmd vobsub voc vpk vplayer vqf vvc w64 wady wavarc wc3 webm_dash_manifest webp_anim webvtt wsaud wsd wsvqa wtv wv wve xa xbin xmd xmv xvag xwma yop yuv4mpegpipe`

### GPL/外部库符号扫描（slim，用 `lib<name>` 前缀模式，大小写不敏感）
- 模式：`libx264|libx265|libxvid|libvorbis|libtheora|libvpx|libopenjpeg|libgsm|libopencore|libtwolame|libvo_aac|libaacplus|libilbc|libsnappy|libzimg|libcdio|libopenh264|libwebp|rtmp|_gpl|gpl`
- 三库命中：**0**（libavutil 0 / libavformat 0 / libavcodec 0）。
- 反例验证：slim `libavcodec.a` 中能 `grep -i vorbis` 到 `_channel_reorder_vorbis`、`_ff_vorbis_ch_layouts`（FFmpeg 自身 LGPL 代码）；
  裸名模式 `vorbis` 会误命中这些，而 `libvorbis` 前缀模式**不会** —— 正是 Task 0 教训的体现，证明 slim 档位无 GPL 符号、且扫描写法正确。

### 结论
- slim 子集档位（实验，2026-09-24）：2.22 MiB（常用子集档位实测，参考基准，无硬阈值）、GPL 扫描 0、仅 avcodec/avformat/avutil 三库、demuxer 16/parser 13/bsf 5。
  （注：此为裁掉 image_webp_pipe 的实验档；最终定稿档位 `apple-x86_64-demux` 在此基础上补回 `image_webp_pipe`，为 **17 demuxer**，见下节。）
- 这是「产品决策层面」的可行裁剪方案；若要锁定为正式档位，需把这套 `--enable-demuxer/parser/bsf` 清单固化为 manifest `features` 或一个显式 `profile`（如 demux-slim），属治理决策，不在本实验写集内。

---

## FFmpeg demux 常用档位（profile=demux 的最终实现，apple-x86_64-demux，2026-09-25）

> 状态：本档位即 manifest `ffmpeg` 的 `profile="demux"` 实现（传哲 2026-09-25 拍板：只保留常用的即可，按需增减）。
> schema 的 `profile` 字段与档位目录未变；`demux` 的 note 已去掉 `< 3MB` 硬阈值（见 team-lead 修订）。
> **体积不再是约束**：先按「视频编辑 SDK 用户会不会用到」定组件范围，体积只是该选择的结果、如实记入本文件作参考基准，无硬上限。
> 产物目录 `third_party/prebuilt/apple-x86_64-demux/`（与 full `apple-x86_64`、实验 `apple-x86_64-slim` 三者并存对比，互不覆盖）。
> 源码同 `third_party/src/ffmpeg` @ `946fcce…`（n9.0.2）；`git clean -xfd` 后重新 configure + make。

### Configure（最终实现；在 slim 的 16 基础上补回 `image_webp_pipe`，并去掉 9.0.2 不存在的 `flush_packets` bsf）
```bash
cd third_party/src/ffmpeg
./configure --prefix=/tmp/ffbuild-demux --disable-everything \
  --enable-avformat --enable-avutil --enable-avcodec \
  --enable-demuxer=mov --enable-demuxer=mp4 --enable-demuxer=m4v --enable-demuxer=3gp \
  --enable-demuxer=matroska --enable-demuxer=webm --enable-demuxer=avi --enable-demuxer=flv \
  --enable-demuxer=mpegts --enable-demuxer=mpegps --enable-demuxer=gif --enable-demuxer=image2 \
  --enable-demuxer=image2pipe --enable-demuxer=image_webp_pipe --enable-demuxer=wav --enable-demuxer=pcm_s16le --enable-demuxer=mp3 \
  --enable-demuxer=aac --enable-demuxer=flac --enable-demuxer=ogg --enable-demuxer=oga --enable-demuxer=m4a \
  --enable-parser=h264 --enable-parser=hevc --enable-parser=aac --enable-parser=mp3 \
  --enable-parser=flac --enable-parser=vorbis --enable-parser=opus --enable-parser=mpegaudio \
  --enable-parser=vp8 --enable-parser=vp9 --enable-parser=av1 --enable-parser=mjpeg --enable-parser=png --enable-parser=gif \
  --enable-bsf=h264_mp4toannexb --enable-bsf=hevc_mp4toannexb --enable-bsf=aac_adtstoasc \
  --enable-bsf=extract_extradata --enable-bsf=null \
  --enable-protocol=file --enable-protocol=pipe \
  --disable-x86asm --disable-network --disable-doc --disable-programs --disable-autodetect \
  --disable-swscale --disable-swresample --disable-avfilter --disable-avdevice \
  --enable-static --disable-shared --enable-small --disable-debug
```

### 组件清单（来自生成源 `libavformat/demuxer_list.c` / `libavcodec/parser_list.c` / `bsf_list.c`）
- **demuxers 17（规范名，mp4/3gp/m4a 为 mov 别名、webm 为 matroska 别名、oga 为 ogg 别名；m4v 在 9.0.2 是独立 demuxer；`image_webp_pipe` 即运行时看到的 `webp_pipe`）**：
  `aac avi flac flv gif image2 image2pipe image_webp_pipe m4v matroska mov mp3 mpegps mpegts ogg pcm_s16le wav`
  - 高频单图输入：`image2` 负责**文件型**单张 PNG/JPEG（实测走 `image2`，非 `image_png_pipe`/`image_jpeg_pipe` —— 后者仅用于 stdin 管道）；
    `image2pipe` 保留供管道/内存输入；`gif` 覆盖动图；`image_webp_pipe`（`webp_pipe`）负责 WebP，**按文件内容（RIFF/WEBP 魔数）识别，不依赖扩展名**。
- **parsers 13**：`aac av1 flac gif h264 hevc mjpeg mpegaudio opus png vorbis vp8 vp9`
- **bsfs 5**：`aac_adtstoasc extract_extradata h264_mp4toannexb hevc_mp4toannexb null`
- Libraries 仅 `avcodec/avformat/avutil`；External libraries 无；`CONFIG_GPL=0 / NONFREE=0 / VERSION3=0`。

### 单图 / 单图格式实测（本档位最关键的一项，先于定稿；含 WebP 硬证据）
> 用最小 C 程序 `avformat_open_input` 链本档位静态库，对真实样本报告能否打开 + 探测到的 demuxer，并用 `av_read_frame` 读一帧确认真能解封装（非仅头探测）。
> WebP 样本为从 gstatic 拉取的**真实 WebP**（RIFF/WEBP/VP8，550x368），非手工伪造。

| 样本 | 本档位(demux) 打开 | 探测 demuxer | read_frame |
|---|---|---|---|
| cover.png（单张 PNG，带 .png） | ✅ | `image2` | ✅ pkt_size=2313 |
| cover.jpg（单张 JPEG，带 .jpg） | ✅ | `image2` | ✅ pkt_size=938 |
| cover.gif（GIF） | ✅ | `gif` | ✅ pkt_size=1733 |
| cover.webp（**WebP，带 .webp 扩展名**） | ✅ | `webp_pipe` | ✅ pkt_size=30320 |
| cover.webp（**同一文件，去掉扩展名**） | ✅ | `webp_pipe` | ✅ pkt_size=30320 |
| tone.wav | ✅ | `wav` | ✅ pkt_size=8192 |
| tone.mp3 | ✅ | `mp3` | ✅ pkt_size=417 |
| gf_1080p_h264.mp4 | ✅ | `mov,mp4,m4a,3gp,3g2,mj2` | （容器探测通过） |

- **WebP 结论（推翻「webp 需要 webp_pipe 否则打不开」的推断，并补实测）：**
  - 本档位**确实能打开 WebP**，且是**按内容识别**（`image_webp_pipe` 的 `webp_probe` 只查 RIFF/WEBP 魔数，返回 `AVPROBE_SCORE_MAX-1`），**不依赖扩展名**——去掉 .webp 扩展名仍能 `webp_pipe` 打开并 `read_frame` 成功。
  - 复盘「为什么之前会误以为打不开」：最初定稿清单只有 `image2`/`image2pipe`，没有 `image_webp_pipe`。`image2` 对 WebP 的探测是**扩展名驱动**的（无扩展名时 `image2` 连真实 PNG 都拒开，证实其非内容探测）；而 `image_webp_pipe`（`webp_pipe`）才是**内容驱动**。两者都存在于全量档位，全量下 WebP 走 `webp_pipe`、扩展名无关。
  - 因此定稿清单在 slim 的 16 个基础上**补回 `image_webp_pipe`**，使 WebP 导入与全量档位行为一致（内容识别、扩展名无关）。WebP 是 Android 截图 / 微信 / 网页图片的常见格式，属真实导入场景，应当稳健支持。
  - **注意**：本档位是 demux 档（decoders 全禁），`webp_pipe` 只负责识别+抽取 VP8/VP8L 包；真正的 WebP 像素解码由后续解码档/`avcodec` 解码层（或原生 ImageIO）完成，不在本档位职责内——这与 PNG/JPEG 同构。

### 三向体积对比（full / slim 实验 / 本档位 demux，同机同配置）
| 文件 | full (apple-x86_64) B | slim (apple-x86_64-slim) B | demux (apple-x86_64-demux) B |
|---|---:|---:|---:|
| libavutil.a | 828,056 | 708,776 | 708,776 |
| libavformat.a | 2,107,296 | 795,576 | 796,072 |
| libavcodec.a | 2,202,920 | 834,064 | 834,072 |
| **libffmpeg.a（合并）** | **5,117,328** | **2,324,920** | **2,325,424** |

- demux 相对 slim 仅多 `image_webp_pipe` 一个 demuxer，合并产物 +584 B（2,324,920 → 2,325,424）；其余三库增量来自 `ar` 归档头 mtime/uid 元数据（非代码差异）。
- **本档位合并产物 2,325,424 B ≈ 2.22 MiB，仅作参考基准，无硬阈值**（原 `< 3MB` 约束已废除）。
- 合并方法同前：`ar x` 分库解包 → 重命名 `<lib>_<base>.o` → `ar rcs` 合并；members=274、duplicate_members=0（无符号丢失）。

### 产物 sha256（third_party/prebuilt/apple-x86_64-demux/，manifest artifact 已回填）
| 文件 | 字节数 | sha256 |
|---|---|---|
| libavutil.a | 708,776 | `485576db817440ea75fe42ca5fc70acba55ad00186361c040e74d8095abf4ac4` |
| libavformat.a | 796,072 | `f8c9ecba1aa790e6b4a3ddf5bb2c5b8643bc28a21cb466c45d782044a2ac390d` |
| libavcodec.a | 834,072 | `b63dd61f4aa0939749e2ea3bcdbddce2067683a5f80e33e8b773066b4374a469` |
| libffmpeg.a（三库合并） | 2,325,424 | `e1850cd2726005e80c31bf721d8392fcb7813ff5f259bb5bd9c49c536bcf110b` |

### GPL/外部库符号扫描（本档位，用 `lib<name>` 前缀模式，大小写不敏感）
- 模式：`libx264|libx265|libxvid|libvorbis|libtheora|libvpx|libopenjpeg|libgsm|libopencore|libtwolame|libvo_aac|libaacplus|libilbc|libsnappy|libzimg|libcdio|libopenh264|libwebp|rtmp|_gpl|gpl`
- 三库命中：**0**。
- 反例验证：`libavcodec.a` 中 `grep -i vorbis` 命中 `_channel_reorder_vorbis`、`_ff_vorbis_ch_layouts`（FFmpeg 自身 LGPL 代码），裸名 `vorbis` 会误命中，而 `libvorbis` 前缀模式不会 —— 扫描写法正确，本档位无 GPL 符号。

### 结论
- 本档位 = `profile="demux"` 的最终实现：2.22 MiB（参考基准、无硬阈值）、GPL 扫描 0、仅 avcodec/avformat/avutil 三库、demuxer 17 / parser 13 / bsf 5（17 = slim 16 + `image_webp_pipe`）。
- 单图 PNG/JPEG 经 `image2` 正常解封装（硬证据）；**WebP 经 `webp_pipe` 按内容识别、扩展名无关**（硬证据：去扩展名仍可开）；常用格式（mov/mp4/m4v/m4a/3gp、matroska/webm、avi、flv、mpegts、wav、mp3、aac、flac、ogg、gif、image2/image2pipe、`webp_pipe`）全覆盖。
- 已写入 manifest `[[dep.artifact]]`（platform=apple-x86_64，path=prebuilt/apple-x86_64-demux，sha256/size 见上表）；原虚构 url `https://artifacts.internal/...` 已移除，url 改为 `local-build://` 本地构建标记（schema 要求 artifact 必带 url 字段，真实来源见 `path` 与本文件构建命令）。
- 体积可随业务需要按需增减：若后续发现某「不必」项其实常用，加回对应 `--enable-demuxer` 即可，体积略增无妨，仅在报告说明原因。

### 已知能力边界（架构结论，影响后续 MEDIA 任务）：HEIC/HEIF 不在 FFmpeg 支持范围内
> 结论：**HEIC/HEIF（iPhone 默认照片格式）FFmpeg 9.0.2 完全不支持**，本仓库 `libavformat/` 下无 `heic`/`heif` 源文件（仅有 `webp_anim_dec.c`、`isom.c`、`isom_tags.c` 等）。
> 即 **full 档位同样打不开 HEIC** —— 这是 FFmpeg 自身的能力边界，**不是我们裁剪导致的**；加 `heic` demuxer 也解决不了（该 demuxer 在 9.0.2 不存在）。
> **正确路径**：Apple 平台的图片导入应走**原生 API**（`ImageIO` / `Photos.framework` / `CoreGraphics`），FFmpeg demux 档位只负责**视频容器**与**受支持的位图格式**（PNG/JPEG/WebP/GIF 等）。
> **不要**试图加 `heic` demuxer —— 它不存在；HEIC 解码应作为独立能力（原生框架或后续引入的专用解码库）处理，不在本 demux 档位职责内。
> 此结论对后续视频编辑 SDK 的图片导入设计有指导意义：HEIC 导入链路与 FFmpeg demux 解耦。

---

## RationalTime 溢出边界（CORE-001, 2026-09-25）
> 设备：Intel i7-9750H，macOS，AppleClang 17.0.0，构建 `tools/build/build_core.sh --platform=apple --config=Debug`。
> 源码：`core/include/cq/base/time.h`、`core/src/base/time.cpp`。单测 `tests/unit/test_time.cpp::TestOverflowBoundary`。

### 数值基础
- `RationalTime.value` 为 `int64_t`，`INT64_MAX = 9223372036854775807`（≈9.22×10¹⁸）。
- `timescale` 为 `int32_t`，项目统一 `kProjectTimeScale = 60000`。

### 边界核算（`static_assert` 已固化于单测）
| 场景 | 计算 | value | 结论 |
|---|---|---|---|
| 24h 项目 @60000 | 86400 × 60000 | 5,184,000,000 | ≪ INT64_MAX，安全 |
| 1 年项目 @60000 | 31536000 × 60000 | 1,892,160,000,000 | ≪ INT64_MAX，安全 |
| 理论上限 @60000 | INT64_MAX / 60000 | — | ≈1.537×10¹⁴ s ≈ **4.87×10⁶ 年** |

### 溢出行为（必须显式上报，不静默环绕）
- 运算全程整数，`AddRational`/`SubRational`/`ScaleRational`/`Rescale` 检测 int64/int32 溢出，经 `Status::kOverflow`（CORE-002 码值 8000）返回。
- 已验证：`INT64_MAX + 1` 相加 → `kOverflow`；`INT64_MAX × 2` 重定标 → `kOverflow`。
- 内核无异常（ARCH-001），`Status` 为唯一错误传播通道。

### ⚠️ 待 ADR 决策：项目 timescale 60000 对 23.976fps 不精确
- 23.976fps 帧周期 = 1001/24000 s；在 timescale=60000 需 2502.5 tick（非整数），逐帧须舍入、累积误差。
- 其余七种（含 29.97=30000/1001、59.94=60000/1001）在 60000 下均精确。
- **建议 ADR-0006 将项目 timescale 改为 `120000`（= lcm(60000,24000)）**：23.976 @120000 = 5005 tick 精确，八种帧率全部整数化。本任务按 ADR 维持 60000，未就地改值。
- 八帧率 × 10000 步进零漂移实测见 CORE-001 单测输出（drift 全为 0，因步进在各自原生 timescale 下进行）。

## base 层实测（CORE-001~004，2026-09-25，apple-x86_64 / AppleClang 17.0.0）

### RationalTime 八帧率零漂移（步进 10000 次）
| 帧率 | timescale | 累计 value | 期望 | drift |
|---|---:|---:|---:|---:|
| 24 | 60000 | 25000000 | 25000000 | 0 |
| 25 | 60000 | 24000000 | 24000000 | 0 |
| 30 | 60000 | 20000000 | 20000000 | 0 |
| 50 | 60000 | 12000000 | 12000000 | 0 |
| 60 | 60000 | 10000000 | 10000000 | 0 |
| 23.976 | 24000 | 10010000 | 10010000 | 0 |
| 29.97 | 30000 | 10010000 | 10010000 | 0 |
| 59.94 | 60000 | 10010000 | 10010000 | 0 |

⚠️ 上表在**各自原生 timescale** 下成立。ADR-0009 已将项目 timescale 由 60000 修订为 **120000**：
60000 下 23.976 单帧 = 2502.5 tick（非整数）必须舍入；120000 下全部帧率整数，不精确 0 种。
int64 上限 @120000 ≈ 243 万年。素材仍可保留原生 timescale，两者互补。

### 溢出边界
- 24h @60000 → value = 5,184,000,000；1y @60000 → 1,892,160,000,000
- INT64_MAX = 9,223,372,036,854,775,807 → 理论上限约 4.87e6 年
- `INT64_MAX+1` 相加、`INT64_MAX×2` 重定标均返回 `Status::kOverflow`，不静默环绕

### 单测规模（ctest，5/5 通过）
| 用例 | 检查项 | 失败 |
|---|---:|---:|
| cq_cxx20_smoke | — | 0 |
| core_time | 64 | 0 |
| core_status | 20 | 0 |
| core_log | 25 | 0 |
| core_alloc | 158 | 0 |

### 纹理预算并发（TextureBudget，8 线程 × 10 张 1MiB）
- 并发登记后 UsedCount = 80，UsedBytes = 83,886,080（80.00 MiB）
- 超预算 Register 返回 code = 5000（kResourceExhausted），且 UsedBytes 不增长
- 注销 id=5 后 UsedBytes = 94,371,840，UsedCount = 9，Remaining = 10,485,760

### 构建
`-Werror` 下零警告（警告集含 -Wconversion / -Wshadow / -Wold-style-cast），
全量 `build_core.sh --test` EXIT=0，总测试耗时 < 0.05s。

### 并发原语 / 取消 / 有界队列实测（CORE-005，2026-09-25，apple-x86_64 / AppleClang 17.0.0）
> 源码：`core/include/cq/base/concurrency.h`、`core/src/base/concurrency.cpp`。单测 `tests/unit/test_concurrency.cpp`（ctest `core_concurrency`）。

| 项 | 实测 | 说明 |
|---|---:|---|
| 取消及时性（阻塞 Pop 被取消 → 返回） | **0.061 ms** | `cv.wait_for(1ms)` 轮询 token；远小于 16ms 主线程预算 |
| 取消返回码 | 6000（kCancelled） | `IsError()==false`，非错误停止信号 |
| 有界队列满（容量 3） | 第 4 次 `TryPush` 返回 false | 满队列不阻塞、不丢内部状态，调用方据 false 丢弃/报错 |
| 满队列取消中断（Push 被取消） | 返回 kCancelled，IsError()==false | 阻塞 Push 在满且被取消时干净退出 |
| 并发一致性（4 生产者×1000 / 4 消费者） | produced=consumed=4000，sum=7998000（=期望） | 多生产者/消费者计数与元素总和一致，无丢失/重复/卡死 |

- 单测规模（ctest，6/6 通过，CORE-005 新增 `core_concurrency`）：
  | 用例 | 检查项 | 失败 |
  |---|---:|---:|
  | cq_cxx20_smoke | — | 0 |
  | core_time | 64 | 0 |
  | core_status | 20 | 0 |
  | core_log | 25 | 0 |
  | core_alloc | 158 | 0 |
  | core_concurrency | 32 | 0 |
- 全量 `build_core.sh --test` EXIT=0（注：本机 shell 调用 `build_core.sh` 偶发被信号中断，改用
  `cmake --build build` + `ctest --test-dir build` 直接跑同样零警告、全绿；非代码问题）。

### ⚠️ 教训：`wait_for(lk, dur, pred)` 超时返回 `pred()` 而非循环到 pred 为真
- 早版 `Pop` 写 `cv.wait_for(lk, 1ms, pred)` 后无条件 `front()`，正常阻塞（空队列、未取消）在 1ms
  超时后 `pred()==false` 仍返回，对**空 deque 调 `front()`** → UBSan 抓到 `load of null pointer in
  deque::front`（SIGSEGV）。修复：显式 `while (cond && !cancelled) wait_for(lk,1ms);` 守护。
- 配套：单测 stdout 改无缓冲 + 每用例 `WithTimeout` 护栏 + 全局 30s 看门狗，杜绝 CI 挂死。

---

## CORE-007：能力查询实测（2026-09-29）

### ⚠️ 设备：Intel Mac（macOS 15.4，x86_64）—— **不代表 iPhone**

本机**无 ANE、无 ProRes 硬件编解码、无 AV1 硬解**（见 ADR-0010 / pitfalls E5）。
下表仅供「查询机制真的在工作」的对照，**任何 iPhone 结论必须由传哲在 iPhone 17 Pro 实测回填**。

| 能力项 | 本机实测 | 判定依据 |
|---|---|---|
| hw_decode_h264 | **yes** | `VTIsHardwareDecodeSupported` |
| hw_decode_hevc | **yes** | 同上 |
| hw_decode_av1 | **no** | 同上（Intel Mac 无 AV1 硬解，符合预期） |
| hw_decode_prores | **no** | 同上（本机无 ProRes 硬解，与既有记录交叉吻合 ✅） |
| hw_encode_h264 | **yes** | VT 会话探针（macOS 10.9+ 常量可用） |
| hw_encode_hevc | **yes** | 同上 |
| hw_encode_prores | **no** | 同上（本机无 ProRes 硬编，交叉吻合 ✅） |
| 10bit_pipeline | **degraded** | 无可靠公开 API，不猜（见 TASK-CORE-007 D2） |
| hdr_display | **no** | SDK 未接入 HDR 色彩管理，如实上报 |
| compute_shader | **yes** | Metal 设备存在 |
| float_texture | **yes** | Metal 设备存在 |
| external_memory_import | **yes** | PALA-002 已实测打通零拷贝 |
| npu_inference | **yes** | CoreML 可用；**不代表实际跑在 ANE** |
| gpu_metal | **yes** | `MTLCreateSystemDefaultDevice()` 非 nil |
| gpu_gles | **no** | Apple 平台 GLES 已废弃 |
| gpu_vulkan | **no** | Apple 无原生 Vulkan |

**交叉验证价值**：`hw_decode_prores=no` 与 `hw_encode_prores=no` 与项目既有事实
（Intel Mac 无 ProRes 硬编）一致 —— 证明查询是真的在问设备，而不是返回写死的常量。

### iOS 上待真机回填的项

- `hw_encode_*`：iOS 16 / 17.0~17.3 因常量要求 iOS 17.4+ 而**无法探测**，返回
  `degraded`（未知，非"没有"）。iPhone 17 Pro 上应为 iOS 18+ → 走真实探针。
- `hw_decode_av1`：iPhone 17 Pro（A19 Pro）预期支持，本机不支持，需真机确认。
- `10bit_pipeline`：待确定可靠查询方式后回填。

---

## CORE-008：线程模型实测（2026-09-29）

设备：Intel Mac，macOS 15.4（x86_64）。**不代表 iPhone 17 Pro**，需真机回填。

| 项 | 实测 | 说明 |
|---|---:|---|
| `TaskRunner::Post()` 返回耗时 | **0.030 ms** | 投递内含 100ms sleep 的任务；16ms 主线程预算的 **1/533** |
| 满队列时 `Post()` 返回耗时 | **< 16 ms**（立即） | 返回 `kResourceExhausted`，不阻塞、不无限增长 |
| FIFO 保序 | 10 个任务顺序与投递序一致 | Session Thread 串行语义成立 |
| 任务执行线程 | `IsMainThread()==false`，角色 = 配置值 | worker 入口自动打角色标记 |
| 角色未标记时 | `kUnknown` | 不猜成 main（误判会让守卫失效） |

注：`Post()` 的 0.030ms 只证明"投递不阻塞"。真正的端到端延迟
（投递 → worker 实际开始执行）取决于系统调度，尚未测量。

## CORE-009：EditorSession 实测（2026-09-29）

设备：Intel Mac，macOS 15.4（x86_64）。不代表 iPhone 17 Pro。

| 项 | 实测 | 说明 |
|---|---:|---|
| `Submit()` 返回耗时 | **0.005 ~ 0.010 ms** | 投递内含 100ms sleep 的变更；16ms 预算的 ~1/2000 |
| 满队列时 `Submit()` | **< 16 ms**（立即） | 返回 `kResourceExhausted` |
| 版本号语义 | 成功 +1；失败/取消**不推进** | 否则 UI 会以为状态变了而错刷 |
| 变更执行线程 | session 线程，串行 FIFO | 8 个变更顺序与提交顺序一致 |
| 观察者回调线程 | session 线程（非主线程） | Swift 侧须自行 dispatch |

注：状态摘要（digest）的语义由模型层定义，本期只用计数器验证机制，
**不代表真实 TimelineModel 的 diff 能力**。

## UIA-005：时间线交互（2026-10-03）

设备：Intel Mac，macOS 15.4（x86_64）。**不代表 iPhone 17 Pro**。

| 项 | 实测 | 说明 |
|---|---:|---|
| 500 片段单帧布局（回归） | **0.611 ms/帧** | UIA-004 曾测 0.663ms；布局未变，属正常波动，仍远低于 16ms 预算 |
| 拖拽/裁剪的实际帧率 | **未实测** | SwiftUI 手势无法在 XCTest 驱动，且本机无 iOS 运行时；真机验证待 iPhone 17 Pro |
| 一次拖拽产生的命令数 | **1 条**（设计值，非实测） | ADR-0012 D1：拖拽期间不提交，松手提交一条 |

⚠️ 上表里「1 条」是**设计约束**（代码路径保证：commit 只在 onEnded 调一次），
不是性能测量值 —— 别把它当实测数字引用。

## UIA-010：播放（2026-10-03）

| 项 | 实测 | 说明 |
|---|---:|---|
| 播放推进精度 | sleep 120ms → 推进 ≈120ms（断言区间 80~500ms） | 墙钟驱动，不累积误差；**粗粒度断言**，未做长时间漂移实测 |
| 播放实际帧率 / 单帧解码耗时 | **未实测** | MVP 取帧+渲染都在主线程，帧率取决于解码速度；真机（iPhone 17 Pro）待验 |
| 时钟推进开销 | **未实测** | 只有几个整数运算 + 一次 steady_clock；未单独测量 |

⚠️ 播放链路的**性能**数字目前一个都没有 —— 只有"时刻推进正确"的正确性验证。
引用前先看 PERF-001 是否已做（当前未做）。

## UIA-010 子步骤 5：预览取帧实测（2026-10-04）

设备：**Intel Mac + AMD GPU，macOS 15.4（x86_64）**。**不代表 iPhone 17 Pro**
（无 ANE、无 ProRes 硬编）。素材 `tests/golden/frames/gf_1080p_h264.mp4`。

### 单帧各阶段耗时（`cq_preview_last_timings`，ns）

| 场景 | acquire | import | draw | total | 上限帧率 |
|---|---:|---:|---:|---:|---:|
| 连续递进请求（每帧 +40ms），128x128，**Release** | 93,346,824 | 24,670 | 5,889,670 | 99,277,196 | **10.1 fps** |
| 同上，**Debug** | 90,465,549 | 25,321 | 5,808,443 | 96,325,369 | **10.4 fps** |
| 孤立请求单帧，128x128，Release | 4,954,937 | 16,012 | 3,251,354 | 8,236,492 | — |

单帧 total 的 min/max（Release，30 帧）：**11.6 ms / 174.2 ms** —— 方差极大，
正是"每帧重解一个 GOP、离关键帧越远越慢"的指纹。

### App 侧端到端（SharedUI `testPlaybackFeedsPumpAndFramesAdvance`）

| 项 | 实测 | 说明 |
|---|---:|---|
| 1 秒播放：请求 / 实际渲染 / 合并丢弃（**Release** XCFramework） | **59 / 14 / 43** | 1280x720 → **≈14 fps** |
| 同上（**Debug** XCFramework） | 59 / 3 / 54 | → ≈3 fps。Debug/Release 差 ~4.7×，但两者都远低于 30fps |
| 主线程是否被取帧堵住 | **否**（取帧在泵线程） | `Request` 实测：单帧成本 50ms 时 10 次 Request 耗时 0ms |

### 结论（可直接引用）

1. **取帧占单帧 94%**，导入（~25µs）与绘制（~5.9ms）都不是瓶颈。
2. 单帧**取帧**段 Debug 与 Release 几乎一样慢（90.5 vs 93.3 ms）→ 不是编译器优化
   问题，是**算法/策略**问题；端到端帧率 Debug/Release 差 4.7×（3 vs 14 fps），
   来自绘制与周边开销，不是取帧。
3. 挪线程换来的收益是**主线程不再被每帧堵住**；帧率没有因此提高。
4. 要提帧率必须改取帧策略（P38 / TASK-MEDIA-021），不是 GPU 侧优化。

## MEDIA-021：顺序取帧快路径实测（2026-10-04）

设备：**Intel Mac + AMD GPU，macOS 15.4（x86_64）**。**不代表 iPhone 17 Pro**。
素材 `tests/golden/frames/gf_1080p_h264_long_gop_bframes.mp4`（1080p / 30fps /
GOP60 / B帧3 / 300 帧）。方法：`media_sequential_real` 内置对照（快路径 vs
每帧显式 seek，120 帧整数 tick 网格顺序请求）。

### 顺序取帧 acquire 耗时（120 帧，n=120）

| 项 | 修复前（P38） | 修复后 Debug | 修复后 Release |
|---|---:|---:|---:|
| 快路径 acquire 均值 | **93.3 ms**（128x128 渲染口径） | **2.95 ms** | **4.45 ms** |
| 快路径 acquire max | 174.2 ms | 93.5 ms | 137.6 ms |
| 每帧显式 seek 对照均值 | — | 67.33 ms | 65.87 ms |
| 加速比（对照/快路径） | 1x | **22.8x** | **14.8x** |
| 逐帧 pts 严格递增 / 区间归属 / 快慢一致 | 错帧（P39/P40/P41） | 120/120 全过 | 120/120 全过 |

注：修复前数字（93.3ms）来自 UIA-010 子步骤 5 的 `cq_preview_last_timings`
（渲染目标 128x128）；修复后来自 `media_sequential_real`（不渲染，纯 acquire），
**口径不同，只做数量级对照，不能直接相除**。同口径对照 = 14.8~22.8x。

### 学习期开销（多 GOP mock，`media_sequential_acquire`）

顺序 16 帧（4 GOP × I P B B）seek/flush 均只发生 **2 次**（t=0 无锚点、t=1
跨度学习），t=2 起全快路径；快路径跨 GOP 时实证 KF 间隔进一步放大阈值。

### 结论（可直接引用）

1. 顺序播放的取帧瓶颈（P38）已消除：GOP60 素材上取帧均值降到 **单帧毫秒级**。
2. 快路径与「每帧 seek」的旧语义**逐帧 pts 一致**（kExact 未放宽）。
3. 修 P38 的过程中暴露并修复了三个**慢路径同样中招**的正确性 bug（P39/P40/P41）；
   修复前 kExact 在 B 帧素材上系统性差帧（且 duration 报负值）。
4. 端到端帧率上限预期从 ~10fps 提升到远超 30fps（取帧段）；App 实际帧率
   受渲染/合并环节约束，待真机验证（iPhone 17 Pro）。

### UIA-011 FitMode（2026-10-04）：性能条目**不适用**

fit 为每帧一次整数几何计算（4 次乘除）+ 一次视口状态设置，无可测量的
性能影响面；stretch 默认路径完全不触碰视口状态（编码序列与引入前逐字节
一致）。故本任务不新增性能基线条目 —— 预览帧率的实测数字仍以
「MEDIA-021 / UIA-010」段为准（真机端到端帧率待 iPhone 17 Pro）。
## CAM-001：相机契约（2026-10-04；**契约当日回退，条目改记环境事实**）

> ⚠️ ADR-0014：相机转 iOS 原生（App 层），CAM-001 的 PAL 契约/ABI/枚举已回退，
> 本条目保留环境事实与"未实测清单"（这些验收项转给 iOS 原生实现的任务）。

**环境注意（pitfalls P42）**：本轮构建机 = Intel Mac / **macOS 13.7 / Xcode 15.2（AppleClang 15）**，
与此前 baselines 里的 "macOS 15.4 / AppleClang 17" **不是同一台机器**。
数字引用先看环境。相机真机数字全部**未实测**（iPhone 17 Pro 待 CAM-002/003 落地后由传哲测）。

| 项 | 值 | 说明 |
|---|---|---|
| 全量 ctest（Debug） | **40/40 通过** | 含新增 `camera_contract`（9 项语义检查）；-Werror 全绿 |
| 双摄分辨率/帧率上限 | **未实测** | 1080p/流 为调研估算 [E]；待真机 activeFormat 实测（SPEC-CAM-001 A5） |
| 预览帧率（相机） | **未实测** | 待 CAM-003 渲染链路落地 |
| 录制时长偏差 | **未实测** | 验收阈值 ≤2 帧（SPEC-CAM-001 A4），CAM-005 落地后测 |

### 相机磨皮（CAM-012，2026-10-04）
| 项 | 实测 | 设备 | 日期 | 备注 |
|---|---|---|---|---|
| 1080p 单帧磨皮（Metal 双边引擎，s=0.5，render→GPU 完成，best-of-3） | 9.85ms | Intel Iris Plus 640 / macOS 13.7（**宿主，非真机**） | 2026-10-04 | 真机 ≤8ms 验收阈值仍为 [E] 未实测 |
| 1080p 单帧磨皮（Metal 双边引擎，s=1.0） | 18.01ms | 同上 | 2026-10-04 | 同上 |
| 1080p 单帧磨皮（A 期默认 CI 高斯对照，s=0.5） | 19.12ms | 同上 | 2026-10-04 | kernel 引擎在本机口径下快 ~2× |
| 平坦区方差压降（s=1.0 / 基线） | 0.000082 / 0.006115（75×） | 同上（GPU 实证） | 2026-10-04 | tools/qa/beauty_harness |
| 边缘过渡宽度（10-90%，s=0.5 / s=1.0） | 2.0px / 4.0px | 同上 | 2026-10-04 | 平台对比度保持 101.6%/103.3% |

## 启动基线（LaunchBench，2026-10-05）：「点图标 → 首页」冷启动

> 来源：用户报「App 启动感觉慢」的诊断会话。测的是**正式启动路径**
> （`ChuanqiCutApp.init()` 只调 `markMainThread()`；HomeView 纯导航壳；
> Session/Previewer/相机全部惰性，进编辑器/拍摄页才创建）。
> 工具：`tools/perf/launch_bench/`（独立 XcodeGen 工程，零主工程改动，
> `XCTApplicationLaunchMetric` ×7，预热 1 轮，每轮 terminate 后 launch）。

**环境**：宿主 Intel i7-9750H / macOS 26.7.1 / Xcode 26.6；模拟器 iPhone 16 Pro（iOS 18.4）。
电量/温度未记录。⚠️ 模拟器绝对值受 Intel 宿主拖累，**只看相对差值，不要引用绝对秒数当体验**。

| 项 | P50 | P95 | min–max | RSD | 备注 |
|---|---|---|---|---|---|
| ChuanqiCut Debug（sim） | 2.08s | 2.15s | 1.83–2.15 | 4.9% | 第一会话 |
| ChuanqiCut Debug（sim，复测） | 1.84s | 1.93s | 1.70–1.93 | 4.3% | 同会话跟在参照 App 后跑，会话间方差 ~10% |
| ChuanqiCut Release（sim） | 2.16s | 2.41s | 1.98–2.41 | 6.1% | build/release_sim 产物 |
| 空壳 SwiftUI 参照 App（sim） | 2.21s | 2.63s | 1.99–2.63 | 8.4% | com.chuanqi.perf.reference |

**结论**：
1. **App 净启动成本 ≈ 0**：与空壳参照无统计差异（Debug、Release 都是），代码路径上没有可优化点。
2. **Debug 构建不是慢因**（sim 上 Debug≈Release）。
3. 模拟器 ~2s 是 launch 机制/渲染栈开销（Intel 宿主放大），**不代表真机体感**。
4. **真机（iPhone 17 Pro / iOS 26.6.1）未实测**：UI test runner 在真机两次 exit 74
   （见 pitfalls P64），待解锁后由传哲跑：
   `xcodebuild test -project tools/perf/launch_bench/LaunchBench.xcodeproj -scheme LaunchBench -destination 'id=00008150-00016C381ED8401C'`
5. 静态证据（主二进制无 `__mod_init_func`、无 ObjC `+load`、无内嵌 dylib、App 包仅系统框架依赖）
   见当日工作日志。

## 预览播放吞吐（阶段 0 真机剖面，2026-10-06）

> 工具：DEBUG 播放诊断（AppEntry 每 2s 汇总，`CQ_AUTO_PLAY=1` 自动开播，
> `devicectl device process launch --console` 采集）。
> 素材：用户真机相册导入的 iPhone 实拍 422MB .MOV（tmp/cq_album_2CEBC5E4…，疑 4K60 HDR HEVC [hypothesis]）。
> 构建：Debug（arm64 真机）。

| 项 | 数值 | 备注 |
|---|---|---|
| pump_req/s | 178–180 | 60Hz Timer × 合并语义正常 |
| **pump_rendered/s** | **32 → 17**（第 2、4 秒窗口） | **播放卡顿主因：解码管线吞吐不足** |
| mtk_draw/s | 228（起步）/ 120（稳态） | ProMotion 满帧，UI 呈现层健康 |
| tick_p95 | <1ms（打印 0ms） | **SwiftUI 30Hz 重算在 A19 上非主因**（修正 RESEARCH-008 §1 假设） |

**结论**：卡顿 = 解码管线（VT→BGRA 转换写带宽 hypothesis 主嫌，4K 帧 33MB/帧），
UI 重建（ADR-0024）解决不了它 → 立即立 MEDIA-023（VT 输出降采样 ≤1080p）。

## 泵内分段耗时（MEDIA-023 仪器，真机 iPhone 17 Pro，2026-10-06）

> 素材同上节（422MB 4K60 实拍 HEVC，输出已降采样 1080x1920，hw=YES）。
> 仪器：PreviewPump 分段直方图（每 20 帧）。

| 段 | p50 | p95 | max | 结论 |
|---|---|---|---|---|
| acquire（取帧+解码） | 17.6→32.5ms | **237–253ms** | 253.7 | **大头1**：远超 VT 裸解码（8-10ms）→ kExact 编排/GOP 重解码爆发，顺序快路径（ADR-0017）对该真实素材未生效 |
| import（Metal 导入） | 0.0ms | 0.2ms | 0.2 | 零拷贝健康 |
| draw（离屏渲染） | 1.5ms | 2.0ms | 2.2 | 健康 |
| **total** | 19.4–33.7ms | **1068ms** | 1068 | **大头2**：秒级尖刺不在 acquire/import/draw 三段内（RenderFrame 其余路径：快照加载/provider 查找/EnsureTarget 等），待定点位 |

同期 [perf]：pump_rendered/s = 19~37（请求 180/s）。**卡顿归因定案：acquire 段 GOP
重解码 + 渲染帧外秒级尖刺**；VT 解码、Metal 导入、离屏渲染、SwiftUI 全部健康。

### 修复后复测（MEDIA-024 修复①②，同素材同机，2026-10-06）

| 项 | 修复前 | 修复后 |
|---|---|---|
| pump_rendered/s | 19~37 | **74（追帧）→ 120（ProMotion 满帧）** |
| acquire p50 | 17.6→32.5ms | **0.0ms（区间内复用命中，跳过 acquire+import）** |
| acquire p95 | 237–253ms | **53.1ms 且逐窗口收敛**（233.6 为首个含 seek 的样本） |
| total p50 | 19.4–33.7ms | **1.2–1.8ms** |
| 遗留 | — | 偶发多秒渲染停顿（rendered/s=0 窗口，stuck render 不进样本）→ watchdog 定位 |

修复内容：①渲染器区间内复用导入纹理（跳过 acquire+import）；②解码器输出尺寸
元数据改实际 CVPixelBuffer 尺寸。另 MEDIA-025 色彩转换已应用（2020/HLG→709）。

### 播放冻结 / 内存（MEDIA-027，真机 iPhone 17 Pro，2026-10-06）

> 环境：iPhone 17 Pro（iPhone18,1）/ iOS 26.x / DEBUG 包（core 走 Source pod）。
> 素材：相册导入 4K60 HDR MOV（2160x3840，BT.2020 + HLG），解码输出 1080x1920 BGRA。
> 仪器：DEBUG 剖面行（每 2s：`pump_rendered/s` / `pump_nonok/s` / `footprint`）+
> 渲染阶段 watchdog + 解码器队列日志。

| 指标 | 修复前（MEDIA-026 之后） | 修复后（MEDIA-027） |
|---|---|---|
| 播放可持续时间 | ~5s 后 `rendered/s` 归零且**永不恢复**；t=11.98s 被 signal 9 | **跑满 t=121.99s**（素材播完） |
| pump_rendered/s | 131 → 116 → **0** | **151~168 全程稳定** |
| `footprint`（phys_footprint） | **3375.0MB**（单调增长到死） | **134~184MB** 平稳波动 |
| pump_nonok/s | — | **0** |
| 结局 | `App terminated due to signal 9`（jetsam） | 正常播完 |

**素材是 VFR**（缺口日志实证）：期望 pts=420000 与实际 420200 差 200/120000 ≈ 1.67ms
—— 帧长不恒定，「上一帧 duration 外推」的显示序期望永远对不上 → 队列只进不出。
两分钟内共 5 次「显示序缺口」+ 2 次「队列超上界」，全部自恢复。

**桌面参照（macOS 26.7.1 / Intel + AMD，720p30 CFR 自造素材，60Hz 请求，3600 次）**：

| 项 | 修复前 | 修复后 |
|---|---|---|
| rss 增量（60s 内容） | +13.8MB（单调增长） | **+7.4MB，其中 60s 内仅 +0.5MB（持平）** |
| footprint | 5.4 → 11.5MB | 4.6 → 4.9MB |
| acquire p50 / p95 | 10 / 158ms | 14 / 401ms ⚠️ |
| wall（3600 请求） | 178s | 306s ⚠️ |

⚠️ 桌面吞吐退化未定位（可能是 autorelease pool 开销 / 机器负载差异 / 修复引入的
额外解码），**不得当作"没变"**，需单独量一次。真机侧吞吐是**提升**的（0 → 155/s）。
## 播放器（UIA-015，2026-10-05）：**全部未实测**

> 独立文件播放器 MVP（AVPlayer 过渡，ADR-0022）。本节逐项登记"未实测"，
> 构建机编译 + 真机验收后**替换为实测数字**（数字纪律：估算不得作验收阈值）。

| 项 | 值 | 待测条件 |
|---|---|---|
| 起播延迟（本地 1080p mp4，`automaticallyWaitsToMinimizeStalling=false`） | **未实测** [E 估算百毫秒级] | 构建机 + 真机 |
| 零容差 seek 落点延迟（长 GOP 源 vs 短 GOP） | **未实测** | 真机，对比 golden 片段 |
| 双击 ±10s（关键帧容差 seek）感知延迟 | **未实测** | 真机 |
| 变速 2x（audioTimePitchAlgorithm=.timeDomain）CPU 占用 | **未实测** | 真机 Instruments |
| 缩略图 LRU 120 张内存占用（maximumSize 480） | **未实测** [E ≈32MB] | 真机 Memory gauge |
| 单张缩略图生成耗时（tolerance ±1s） | **未实测** | 真机 |
| 逐帧步进（，/.）单步延迟 | **未实测** | 真机 |
| A-B 循环回跳延迟（tick 0.25s 粒度） | **未实测** | 真机 |
| 长按倍速 2x→恢复 1x 的引擎切换顺滑度 | **未实测** | 真机 |
| 缩略图批量预热（≤24 桶 × 50ms 错峰）CPU 峰值 | **未实测** | 真机 Instruments |
| 音轨/字幕切换生效延迟（selectMediaOption） | **未实测** | 真机，多轨样本 |
| 播放队列连播换片间隙（swapMedia 现载路径） | **未实测** [E <1s] | 真机 |
| iOS security-scoped bookmark 跨会话重开 | **未实测** | 真机（Files 选入的文件） |
| ASS 2MB 解析耗时 | **未实测** [E <200ms] | 构建机 |
| 关窗续播（PlayerController App 级 VM） | **未实测** | 构建机 + 真机 |
| 章节/轨道/时长元数据装载耗时（三异步任务） | **未实测** | 真机 |
| SharedUI swift test（含 PlayerTests 8 用例） | **未跑**（本机 Swift 5.5，P45/P46） | 构建机 |
| iOS/macOS xcodebuild（0 error 0 warning） | **未跑** | 构建机 |
### 音频地基（AUDIO-001，2026-10-05）
| 项 | 实测 | 环境 | 日期 | 备注 |
|---|---|---|---|---|
| 音频线程零分配（pool/ring/graph.Process 全路径） | operator new 增量 = 0 | Intel Iris Plus 640 / macOS 13.7（宿主） | 2026-10-05 | core_audio_graph 单测实测，kAudio 标记线程，热身后测 256 块 |
| SPSC 环往返 20 万序号 | 通过（序号连续无丢失） | 同上 | 2026-10-05 | core_audio_pcm 压测；吞吐/延迟未做 microbench，**未实测** |
| AudioBlockPool 并发 4 线程 × 2 万次 | 无污染、InUse 记账闭合 | 同上 | 2026-10-05 | 末态整池可取空再全还 |

### 美颜色彩空间与人脸区域化（CAM-018/019，2026-10-06；曾号 CAM-015/016 撞号让位）
| 项 | 实测 | 环境 | 日期 | 备注 |
|---|---|---|---|---|
| 蒙版 DAG 宿主渲染采样（中心白/角落黑/退化全黑） | 14/14 PASS（逻辑级） | Intel Iris Plus 640 / macOS 12 宿主脚本 | 2026-10-06 | 区域化端到端：脸内亮度 76→115、背景 76→76（0.3 灰源 + EV0.45） |
| Vision 人脸检测耗时（1080p BGRA，landmarks+body+animals 全请求） | **未实测** | 真机 | — | `CQ_DEBUG_PROFILE=1` 打印 `lastDetectionDurationMs`，15Hz 降频 [E] 待定频 |
| 磨皮闪烁消除 + 保边恢复（workingColorSpace=sRGB） | **未实测** | 真机 | — | 归传哲人工验收（TASK-CAM-018 验收项） |
| 蒙版区域化真机观感（美白只在脸/背景不糊/跳帧不抖） | **未实测** | 真机 | — | 归传哲；检测降频 N 与框平滑参数 [E] 随之定案 |
| 录制产物与预览颜色一致性（池缓冲色彩空间标记） | **未实测** | 真机 | — | 池对 kCVPixelBufferColorSpaceKey 接受度未验证（hypothesis） |
| SharedUITests 全量（含 FaceMaskTests 13 用例） | **未跑**（本机 Swift 5.5，P45/P46） | 构建机 | — | — |
