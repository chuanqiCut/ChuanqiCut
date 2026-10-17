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
| FFmpeg demux 产物体积（5 slice，2026-10-11 档位） | 参考基准（无硬阈值） | macosx-x86_64 2.94MiB / macosx-arm64 3.13MiB / iphoneos-arm64 3.13MiB / sim-x86_64 2.76MiB / sim-arm64 3.13MiB（见「demux 档 2026-10-11 构建」节）[DEPS-012] | i7-9750H / macOS | 2026-10-11 |

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
| 对标 App 美颜管线 | ~2ms [E] | 上游自述为"传闻数据，基于行业共识估算" |

---

## 测量方法约定

- 每帧耗时：取 P50 / P95 / P99，不取平均值（P99 才对应卡顿体验）
- 每项测 3 次取中位，样本固定（用 `tests/golden/` 中的素材）
- 设备状态：冷启动后预热 5 秒，关闭后台应用，记录电量与温度
- 数据由 `tools/perf/*` 产出机器可读 JSON，本文件引用其结果

---

## FFmpeg demux 档位构建基线（DEPS-010, 2026-09-24）

### demux 档 2026-10-11 构建（DEPS-012，5 slice + xcframework，ADR-0036）

> 设备：i7-9750H（Intel），源码同 pin n9.0.2（946fcce）。入口 `tools/build/build_ffmpeg_demux.sh`
> （--sdk/--arch 参数化；合并 = ar x 解包重命名 ar rcs，duplicate members=0 校验过）。

| slice | size_bytes | sha256 | 备注 |
|---|---:|---|---|
| macosx-x86_64 | 2,787,960（2.66MiB） | `e7de9128…3b7bb74a5` | --disable-x86asm（无 nasm）；301 成员全保留 |
| macosx-arm64 | 2,963,056（2.83MiB） | `03cf9d77…5b949932` | --arch=arm64（缺该 flag configure 误判 x86_64 找 nasm）；+NEON 对象 |
| iphoneos-arm64 | 2,963,088（2.83MiB） | `40208c9e…5213c79255bf2` | -miphoneos-version-min=16.0 |
| iphonesimulator-x86_64 | 2,611,312（2.49MiB） | `b372e453…67ea981abb` | --disable-x86asm |
| iphonesimulator-arm64 | 2,962,088（2.82MiB） | `dcca3e52…f10fd8af3430f7134` | -mios-simulator-version-min=16.0 |

> ⚠️ 本表为 **2026-10-12 终版数字**（manifest artifact 已回填同值）。此前（10-11 深夜）一轮
> 3.0~3.3MiB 的数字**作废**：那批产物被 ar rcs 追加语义污染（旧成员叠加）+ ar x 平铺覆盖
> 同名 .o（cpu.o 双份丢一份），体积虚大且符号不全，见 pitfalls P104（三层坑完整记录）。

- arm64/iOS 体积参考：arm64 slice 均在 3.1MiB 上下，与 x86_64（2.94MiB）同量级；**无硬阈值**。
- GPL 扫描（lib<name> 前缀模式）：**5 slice 全部 0 命中**；产物含 `include/`（Pod vendored 可用）。
- xcframework：`prebuilt/ffmpeg/9.0.2/demux/libffmpeg.xcframework`（macos fat x86_64+arm64 /
  ios-arm64 / ios-arm64_x86_64-simulator fat），Pod vendored 消费。
- 相比 DEPS-010 常用子集（2.22MiB）偏大 ~0.7MiB：本档位 demuxer/parser/bsf 清单更全
  （22 demuxers / 17 parsers / 8 bsfs vs 17/13/5），属裁剪口径差异，非回归。


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
| 文件 | 该厂商数 | sha256 |
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
| 文件 | 该厂商数 | sha256 |
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
> 源码：`core/include/cq/base/time.h`、`core/src/base/time.cpp`。单测 `tests/unit/base/test_time.cpp::TestOverflowBoundary`。

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
> 源码：`core/include/cq/base/concurrency.h`、`core/src/base/concurrency.cpp`。单测 `tests/unit/base/test_concurrency.cpp`（ctest `core_concurrency`）。

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

> ⚠️ ADR-0014：相机转 iOS 原生（App 层），CAM-001 的 Platform 契约/ABI/枚举已回退，
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
| **预览处理耗时（美颜全关，CAM-033 P1 后真机稳态）** | **0.5-2ms**（窗口最大 40.8ms = 启动冷毛刺） | iPhone 17 Pro / 1080p | 2026-10-11 | DEBUG 浮层同源 cam-stats 2Hz；采集 30fps / 渲染 60fps / 内存 ~177MB 稳态；美颜全关 Vision 检测归零 |
| **预览处理耗时（磨皮0.5+美白0.5 开，CAM-033 修复后真机）** | **1.6-3.0ms 稳态**（窗口最大 8.2） | iPhone 17 Pro / 1080p | 2026-10-11 | cam-stats 2Hz；60fps 渲染满帧；noface 停止增长（dropout 保持生效=不闪） |
| **Vision faceRectangles 单次检测耗时（同轮实证）** | **11.6-20.3ms/次** | iPhone 17 Pro | 2026-10-11 | 30Hz 跑 = 近半核——**检测降频是下一个最大优化点**（美颜脸框 10-15Hz 足够 [E]）；ANE 告警（池 [15]）疑似部分层回退 CPU 的佐证 |
| **磨皮输出帧间稳定性（录像抽帧量化，禁用 σ_local 后）** | 脸区域高频能量 CV **9.3%** / 帧间变化率 **5.7%**（91 帧） | iPhone 17 Pro / 录像 1080×1920 | 2026-10-11 | σ_local 在则 AE 摆动调制 ±40% 摆幅；实测残余 = 运动/AE/编码噪声量级。工具 tools/probe/analyze_frames.swift |
| 1080p 单帧磨皮（真机，磨皮开） | **未实测** | iPhone 17 Pro | — | P2（CAM-034 引导滤波）落地后同口径测 |

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

## UIA-037/038：时间线缩略图 + 居中播放头/捏合缩放（2026-10-07 编码轮）

| 项 | 实测 | 说明 |
|---|---:|---|
| Editor 包 swift test（含 22 新用例） | **未执行** | 用户指示跳过验证；池 [6] 第一优先，跑通前不引用任何"通过" |
| iOS 模拟器构建 | **未执行** | UIKit 路径（居中播放头/scrub/pinch/胶片槽）macOS 侧编译不可见（P49） |
| 捏合缩放中时间线全量重建耗时 | **未实测** | 仅可参考 UIA-005 旧测 500 片段布局 0.611ms/帧（几何同源）；缩放含全量 reload + 重居中，待真机 |
| scrub 跟手性 / 帧栅格精度 | **未实测** | 帧时长 30fps 为常数 [E]（TimelineZoomMath.defaultFrameDuration），MEDIA 线透传真实帧率后替换 |
| 缩略图解码吞吐（AVAssetImageGenerator） | **未实测** | 1s 桶 / LRU 240 张 / 单张 72×88px / 并发上限 3；待真机回填 |
| 真机走查六项（池 [6]） | **未做** | 红条居中、scrub、捏合界限（全时长↔一帧一槽）、帧级刻度、缩略图 ≥3 帧、缩放不卡 |

⚠️ 本节零实测数字 —— 引用本批任何性能说法前先确认池 [6] 已消化。

## AIEDIT-001：智能成片契约冻结（2026-10-08 编码轮）

| 项 | 实测 | 说明 |
|---|---:|---|
| 校验器单测 | **本机 clang13 直编：117 检查 0 失败** | golden 58 例：合法 18/18、非法 40/40（错误码按码名精确匹配）；非 ctest 通道，构建机复跑 = 池[8] |
| **ctest 通道（2026-10-08 晚，构建机实测）** | **`ai_edit_plan` PASS；全量 Debug 46/46 · Release 46/46** | 机器：macOS 26.7.1 / Xcode 26.6 / Swift 6.3.3 / cmake 4.4.3（`~/.workbuddy/binaries/cmake/CMake.app`）。CMake 注册三件事（私有头 include / `CQ_EDIT_PLAN_GOLDEN_DIR` / 链 `cq_core`）全部成立 → **池 [8] 可关** |
| build_core.sh -Werror | ✅ 2026-10-08 晚通过 | Debug/Release 双向；新增 TU 零警告（仅 1 条链接期 `ignoring duplicate libraries` 环境级提示） |
| 校验器性能（单 plan 解析耗时） | **未实测** | 契约任务无性能验收项；AIEDIT-005 管线接入后随 token/延迟一并回填 |

⚠️ 本节无性能基线可引用（契约层任务）；唯一实测是正确性单测计数，非性能数字。

## 门禁计数基线（阶段批，构建机实测口径；机器：macOS 26.7.1 / Xcode 26.6 / Swift 6.3.3 / cmake 4.4.3）

> 用途：下次跑门禁前先看这里，数字对不上就是回归或口径漂移。**机器变了必须重记。**

| 2026-10-08 晚 | 数字 |
|---|---|
| core 全量单测（Debug / Release） | **46/46 · 46/46**（ctest；`tests/CMakeLists.txt` 行首 `add_test` = 30 个目标，46 是展开后用例数；旧「40/40」口径作废） |
| Swift 绑定 `swift test` | **26/26** |
| SharedUI | **只 `swift build`**（包内无 Tests/、Package.swift 无 testTarget；podspec 注释已写明「无独立测试，由门禁 build + 双壳构建兜底」）。「140」是全仓合计旧口径，**不是单包数** |
| ChuanqiCutPlayer | **52/52** |
| ChuanqiCutCamera | **57/57**（存量 36 = CameraBeauty 7 + CameraFilter 4 + DetectionSmoothing 13 + FaceMask 12；新增 MakeupMask **13** + PortraitSkinMask 7；本轮再 +1 直通防线用例）。**池 [10] 写的 53 是错数（曾把 MakeupMask 记成 10）**。⚠️ **2026-10-09 更新为 62/62**（新增 `CameraFormatSelectorTests` 5 例） |
| ChuanqiCutImport | **16/16** |
| ChuanqiCutEditor | **57/57**（文档「守恒 36」已失效：UIA-037/038 后涨到 57） |
| golden 齐备性 | built 21 / fail 0（880.6KB） |
| 双壳构建 | macOS `-scheme ChuanqiCutMacApp` **BUILD SUCCEEDED**；iOS `-scheme ChuanqiCutApp` 见当日日志（Pods 工程陈旧是第一个坑） |
| **metallib（2026-10-08 深夜实测）** | `beauty_bilateral.metallib` **9391B**（旧值 8431B 是 CAM-029 改 metal 之前）；`cq_beauty_down_h` / `cq_beauty_up_v_mix` **两个 kernel 名均在内**。取自 `/tmp/cq-dd-ios-device/.../ChuanqiCutApp.app/`（Debug-iphoneos，Xcode 26.6）。⚠️ 只验了大小与符号名，**算法剖面（保边保持率/高频恢复/耗时）仍零实测** |

## 目录共置后首跑（2026-10-09，机器 macOS 26.7.1 / AppleClang 21.0.0 / Swift 6.3.3 / cmake 4.4.3）

> ADR-0033 / INFRA-024：内核头与实现共置到 `engine/core/cq/**`、Apple Platform 分 `base/gfx/media`，
> Engine 拆 `CChuanqiCut` + `ChuanqiCutEngine` 两个 Pod。**门禁口径未变，数字必须与上表对齐。**

| 项 | 实测 | 说明 |
|---|---:|---|
| core CMake Debug 全量 ctest | **46/46** | 与上表 2026-10-08 基线一致，零回归 |
| `platform_header_gate` | **0 违规 / 38 头** | 扫描根改 `engine/core/cq` 后加契约目录白名单（P95） |
| `cq_core` + `cq_platform_apple` 构建 | **零错误零警告** | `-Werror` 下通过 |
| ChuanqiCutCamera `swift test` | **62/62** | 新增 5 例 format 选择（P94） |
| iOS 壳 `ChuanqiCutApp`（iphoneos / generic device） | **BUILD SUCCEEDED** | Podfile 双 `:path`（CChuanqiCut + ChuanqiCutEngine）后 `pod install` → `xcodebuild`；唯一警告是 P97 的无害 duplicate header |
| macOS 壳 `ChuanqiCutMacApp` | **BUILD SUCCEEDED（`-arch x86_64`）** | 不加 `-arch` 会挂：Intel 机 universal 编 arm64 时 SDK 26.5 无该 slice 预编译模块（P96），**不是代码回归** |
| `Pods/Headers/Public/CChuanqiCut` | **仅 cq_sdk.h**（+ umbrella/modulemap） | 双壳一致；其余头全在 Private 下按功能分子目录 |

⚠️ 本节只有"结构重构不回归"的计数，**不是性能基线**；性能基线（PERF-001）仍未建立。

## 2026-10-11 · INFRA-022 P2（`pal` → `platform` 全量改名）后实测

> 机器：Intel Mac / macOS 26.7.1 / Xcode 26.6 / cmake 4.4.3（**Intel，无 ANE/ProRes 硬编，不作产品阈值**）

| 项 | 实测 | 说明 |
|---|---:|---|
| `build_core.sh --platform=apple --config=Debug` | **EXIT 0，0 error / 0 warning** | 改名后首轮**全量重编 2m55s**（174 文件改动，逐个 TU 重建） |
| 同上加 `--test` | **46/46 通过**（113.32s） | 含 7 个改名后的 `platform_apple_*` 用例；与上表 2026-10-08 基线一致，零回归 |
| `tools/platform/check_platform_headers.py` | **38 头 / 0 违规** | 扫描根 `engine/core/cq`，契约目录白名单已含 `platform`（P95 复发已修） |
| `apps/` 目录体积（P1 清理后） | **5.5G → 4.3M** | 删 5 处包内 `.build`(1.27G) + 2 处 xcodebuild derivedData(4.6G) |

**单个用例耗时（本次实测，供回归对照）**：
`platform_apple_native_image` 3.76s / `platform_apple_encode` 8.25s / `platform_apple_muxer` 7.55s /
`platform_apple_muxer_audio` 1.72s / `platform_apple_capabilities` 0.54s /
`platform_apple_decode` 6.92s / `media_sequential_real` 65.97s（最慢）

⚠️ 本节是「改名不回归」的计数，**不是性能基线**；性能基线（PERF-001）仍未建立。

## 2026-10-15 · 编辑页播放（UIA-044 轨道区换 TimelineKit 后）

> 机器（**真机**）：iPhone 17 Pro / iPhone18,1 / **iOS 26.6.1**；**Debug** 构建
> （Intel Mac / Xcode 26.6 编译 arm64）；素材 = 单轨单片段 8s 1080p H.264（含音频），
> 循环播放，采样窗口 6s（`[wf:perf]` 2s 一行）。

| 项 | 实测 | 说明 |
|---|---:|---|
| 主线程 tick 耗时 p95 | **0ms**（日志 1ms 分辨率，三行全 0） | 播放中每帧 `setCurrentTime` 推 TimelineKit 未拖垮主线程 |
| 取帧泵 req/s | 120–122 | 与既有播放基线同量级（未因轨道区换实现而变化） |
| 取帧泵 rendered/s | 65–120（有丢帧） | 8s 短素材循环 seek 频繁；`nonok/s = 0`（无解码失败） |
| MTK draw/s | 119–120 | 与未换轨道区前的呈现频率同档 |
| 音频 drop / underrun / resync | **0 / 0 / 0** | 无音频异常 |
| 物理内存足迹 | 97.2–98.3MB（6s 内无增长趋势） | 无泄漏迹象（短窗口，非长时结论） |
| 崩溃 | **无**（DebugCrashDumper 未打栈） | 装载/播放/重建三路径均无 crash |

**轨道区灌入证据**（新增 DEBUG stderr 通道 `[tk:track]`，`devicectl --console` 可见）：
空态→装载后 `rebuild tracks=1 clips=0 assets=1` → `rebuild tracks=1 clips=1 assets=1`，
全程**零 `resync`**（未发生「组件自我变更但内核不支持」的回滚）。

⚠️ 样本极小（1 轨 1 片段 8s），**不得**作为产品阈值；长片段/多轨/长时间播放待补。

## 2026-10-16 · INFRA-027/028 布局整改前两批（本机 = 集成机，实测）

磁盘形态（清理前后，`du -sh` 实测，非估算）：

| 项 | 清理前 | 清理后 | 处置 |
|---|---|---|---|
| `build/` | 5.3G | **4.9G** | `shell-mac2` 481M 隔离出树 |
| 根 `prebuilt/` | 35M | 0 | 隔离（1 个 2026-09-24 的 `libffmpeg.a`，已被 `third_party/prebuilt/ffmpeg/9.0.2/demux/` 取代） |
| `third_party/prebuilt/apple-x86_64` + `-slim` | 14.3M | 0 | 隔离；**`-demux` 4.5M 保留**（`manifest.toml:85-88` + `deps.lock:44` sha256 锚定） |
| `apps/apple/packages/ChuanqiCutEditor/.build` | 223M | 0 | 删除（SPM scratch，可再生；根因是手工 `swift test` 未带 `--scratch-path`） |
| `tests/golden/frames/tmptws05f4p/` | 2.8M | 0 | 隔离（`tmp*/` 泄漏的中间帧） |
| 隔离目录合计 | — | 533M | `~/Documents/.chuanqiCut-quarantine-2026-10-16/`，待双壳与真机无异常后由传哲决定删除 |
| `apps/apple/ios/Pods/` | — | 5.8M | pod install 重生成 |

门禁数字（清理后当批实跑）：

- `tools/build/build_core.sh --platform=apple` → 100% built（增量）
- `tools/build/build_core.sh --platform=apple --test` → **`100% tests passed out of 52`**，real 155.74s
  （此 52 为 INFRA-029/030 搬家时的**对比基线**；`tests/unit` 有 51 个源文件（45 `.cpp` + 6 `.c`），
  `tests/CMakeLists.txt` 有 **52** 个 `add_test(NAME ...)`（51 个可执行 + 1 个无源文件的
  `platform_header_gate`，它直接 `COMMAND python3 tools/platform/check_platform_headers.py`），
  `ctest -N` 实跑 52 例 —— 三个数不同名，别混用）
- `git ls-files | wc -l` = **857**（改 `.gitignore` 前后相同，即无误伤）
- 双壳 `pod install`：ios **14/14 pods**、mac **7/7 pods**，`Podfile.lock` 零 diff
- ⚠️ 未实测：双壳 `xcodebuild`（027/028 未改壳内路径，推迟到 INFRA-031 批）

## 2026-10-16 · INFRA-029/030/035 布局整改批 4/5 收口（本机 = 集成机，全量门禁实跑）

**门禁计数基线**（下一批 INFRA-031 搬家后必须逐项对上，掉了就是搬家引起的）：

| 项 | 命令 | 数字 |
|---|---|---|
| 全量门禁 | `tools/ci/run_gate.sh` | **PASS=15 / FAIL=0 / SKIP=0**，exit 0 |
| 内核单测 Debug | `build_core.sh --platform=apple --config=Debug --test` | **52/52**，real **133.05s** |
| 内核单测 Release | 同上 `--config=Release` | **52/52**，real **226.96s** |
| 头纯净性 | `tools/platform/check_platform_headers.py` | scanned **43** header(s)，**0** violation(s) |
| 图层卫生 | `check_uiview_layer_hygiene.py apps/apple` | 扫描 **119** 个文件，R1 违规 **0** |
| golden 齐备 | `"${PY}" tests/golden/verify.py --json` | built_ok **21** / built_fail **0** / unbuilt **0** / **901784** bytes |
| mac 宿主包用例 | `run_gate.sh` 五个 `swift test` 段 | bindings **26** / player **52** / camera **77** / import **16** / editor **81** = **252**，0 失败；SharedUI 段为 `swift build`（包内无测试目标，见 P148） |
| 入库文件总数 | `git ls-files \| wc -l` | **857**（029 夹具搬家前后相同） |
| 单测源文件 | `git ls-files tests/unit \| wc -l` | **51**（45 `.cpp` + 6 `.c`），分布在 **12** 个模块子目录，根目录平铺残留 **0** |
| `add_test` 声明 | `grep -c "add_test(NAME" tests/CMakeLists.txt` | **52**（51 可执行 + `platform_header_gate` 无源文件） |
| 交接文档 | `ls docs/handoff/*.md` / `git ls-files docs/archive/handoff` | 在位 **5** / 归档 **22** / 合计 **27** |
| 文档死链 | `python3 tools/ai/linkcheck_docs.py` | **6** 条（全部存量；归档前基线 9） |
| 双壳 pod install | `apps/apple/{ios,mac}` `LANG=en_US.UTF-8 bundle exec pod install` | ios **14 dependencies / 14 pods**、mac **7 / 7**，两份 `Podfile.lock` **零 diff** |
| 双壳 xcodebuild | P129 配方（ios `-scheme ChuanqiCutApp -destination generic/platform=iOS`；mac `-scheme ChuanqiCutMacApp -arch x86_64 ONLY_ACTIVE_ARCH=YES`） | 均 **BUILD SUCCEEDED**，exit 0；`error:` **0** 行，warning ios **24** / mac **6** 行（全为既有 deployment-target 9.0 与 SHADER-001 run-script 无输出项告警） |

**耗时基线**（用于判断"搬家有没有把构建拖慢"，非性能结论）：
`platform_apple_decode` 空载单跑 **9.24~9.82s**、全量段内 **8.72s(Debug) / 10.74s(Release)**；
`media_sequential_real` **63.97~65.97s**（全量里最慢的一例）。
⚠️ decode 在机器忙时会以 **147/150 帧**假失败（P147，`media_decode.mm:681-698` 固定 1s 丢帧判据），
**不得**把它当回归，也不得写进 CI 无脑重试。

## 2026-10-16 · INFRA-031 包上提 `ui/` 收口（本机 = 集成机，实测）

搬家类数字（下一批 INFRA-032/033 照此对，掉了就是搬家引起的）：

| 项 | 命令 | 迁移前 → 迁移后 |
|---|---|---|
| UI 组件包 tracked 文件 | `git ls-files ui`（前为 `git ls-files apps/apple/packages`） | **124 → 124**（旧路径归 0） |
| 搬家纯度 | `git diff --cached -M --stat` | **124 files, 0 insertions / 0 deletions** |
| 图层卫生覆盖面 | `check_uiview_layer_hygiene.py apps/apple` + `... ui` | 单趟 **119** → 两趟 **4 + 115 = 119**（逐字相等） |
| mac 宿主包用例 | `run_gate.sh` 五段 | **bindings 26 / player 52 / camera 77 / import 16 / editor 81 = 252**，迁移前后一字不差 |
| 双壳 pod install | ios / mac | **14/14** 与 **7/7**，`Podfile.lock` 本地 Pod 路径 `../packages/…` → `../../../ui/…` |
| 双壳 xcodebuild | P129 配方 | 两端 **BUILD SUCCEEDED**，`error:` 0 行 |
| metallib 产物 | iOS App bundle（run-script 路径手改后） | `beauty_bilateral **9215B**` / `face_warp **5792B**` / `beauty_guided **8118B**`，时间戳为本次构建（**非 96B 空壳**） |
| 全量门禁 | `tools/ci/run_gate.sh` | **PASS=15 / FAIL=0 / SKIP=0**，exit 0；Debug 52/52 **165.11s**、Release 52/52 **145.14s**；headers 43/0；golden 21/0/0 901784B |
| 入库文件总数 | `git ls-files \| wc -l` | **857**（搬家不改总数） |

- `RepoPath`（`ui/ChuanqiCutEditor/Tests/ChuanqiCutEditorTests/RepoPath.swift`）上溯层数 **7 → 5**；
  实证不是"用例过了"而是运行日志里的 `probe 4ms path=…/tests/golden/frames/gf_1080p_h264.mp4`
  与 `gf_1080p_hevc.mp4`（两个夹具 46003B / 27972B 真实存在）。
- 本批**没有**新的性能结论；以上都是布局与覆盖面数字。

## 2026-10-16 · INFRA-032 Swift 门面外提 `api/swift/` 收口（本机 = 集成机，全量门禁实跑）

搬家类数字（下一批 INFRA-033/034 照此对，掉了就是搬家引起的）：

| 项 | 命令 | 迁移前 → 迁移后 |
|---|---|---|
| 门面 tracked 文件 | `git ls-files api` | **0 → 25**（= 原 `engine/bindings/swift` 的 24 + 随迁 `ChuanqiCutEngine.podspec`；`engine/bindings` → **0**） |
| `engine/` tracked | `git ls-files engine \| wc -l` | **149 → 124**（差恰为 25） |
| 入库总数守恒 | `git ls-files \| wc -l` | **857**（与 031 收口基线逐字相等） |
| 全量门禁 | `tools/ci/run_gate.sh` | **PASS=15 / FAIL=0 / SKIP=0**，exit 0（21:43:41 → 22:02:39，**18m58s**） |
| 内核单测 | `build_core.sh --platform=apple --{Debug,Release} --test` | Debug **52/52** real **149.75s**；Release **52/52** real **144.73s** |
| 头纯净性 / 图层卫生 / golden | `check_platform_headers.py`、`check_uiview_layer_hygiene.py`、`verify.py --json` | 43 头 **0** 违规；两趟合计 **119** 文件 R1 **0**；built_ok **21** / fail **0** / unbuilt **0** / **901784B** |
| mac 宿主包用例 | `run_gate.sh` 五段 `swift test` | **bindings 26 / player 52 / camera 77 / import 16 / editor 81 = 252**，0 失败（与 031 基线逐字相等） |
| 双壳 pod install | ios / mac | **14/14** 与 **7/7**，exit 0；`Podfile.lock` 的 `ChuanqiCutEngine :path` = `../../../api/swift` |
| 双壳 xcodebuild | P129 配方 | 均 **BUILD SUCCEEDED**，`error:` **0** 行，warning ios **24** / mac **6**（同 031） |
| Pod 链接级证据 | `nm -a <App 二进制> \| grep -c ChuanqiCutEngine`；`libChuanqiCutEngine.a` | ios **1838** / mac **1842** 个符号；静态库 **507616B**(iphoneos) / **511248B**(mac)；Pods 工程各 **8** 条 `path = Sources/ChuanqiCut/*.swift` |

- **搬家批的耗时对照**（非性能结论）：core-dbg 149.75s / core-rel 144.73s，落在 031 的 165.11s / 145.14s 同区间，
  门面外提没有拖慢内核。
- ⚠️ **本轮新踩的缓存坑（P152）**：门禁 run1 在 `apple-import` 段红，`missing inputs: …/engine/bindings/swift/Frameworks/…`
  —— `build/spm/*` 的 SPM 增量缓存（`workspace-state.json`、`build.db`、index store）把**旧绝对路径钉死**，
  与被迁移文件毫无关系的下游包也会因传递依赖而中招。清 `build/spm/*`（1.2G）后 run2 全绿。
  **搬家批若出现"路径不存在的输入"类失败，先清 scratch 再判回归**，不要改代码。
- 本批**没有**新的性能结论；以上都是布局、覆盖面与链接证据数字。

## 2026-10-16 · INFRA-033 shader 两半并入 `engine/shaders/`（本机 = 集成机，模块级窄检）

搬家类数字（034 末批全量门禁照此对）：

| 项 | 命令 | 迁移前 → 迁移后 |
|---|---|---|
| shader tracked 文件 | `git ls-files engine/shaders` / `git ls-files shaders` | **0 → 3**（`portable/blit.{vert,frag}` + `native/README.md`）/ **2(.gitkeep+两份 glsl) → 0** |
| `engine/` tracked | `git ls-files engine \| wc -l` | **124 → 127**（差恰为 3） |
| 入库总数守恒 | `git ls-files \| wc -l` | **857** 不变（+3 新路径、−2 旧 glsl、−1 `shaders/src/.gitkeep`） |
| 内核单测（清产物后重跑） | `rm -rf build/generated && tools/build/build_core.sh --platform=apple --test` | exit 0，**100% tests passed out of 52**，real **135.17s**，`error:` **0** 行 |
| SPIR-V / MSL 产物字节 | `ls -l build/generated/shaders/{spv,msl}` | `blit.vert.spv` **960B** / `blit.frag.spv` **548B** / `blit.vert.metal` **418B** / `blit.frag.metal` **410B** —— **四条搬家前后逐字节相等** |
| 生成头大小 | `ls -l build/generated/shaders/blit_msl.h` | **1665B → 1689B**；+24B 由 `git show HEAD:tools/shaders/build_shaders.py` 的 `HEADER_BANNER` 逐行比差算出（两行路径字面各 +12B），**精确对上** → 变的是 banner 不是转译结果 |
| GLSL 代码等价 | 剥离 `//` 注释后 md5 对比 `HEAD:shaders/src/*` | vert `568b81024e9e24d46e75f60fa0775eda`、frag `687a47617c0344e74f95f849726783d4` **两侧相同** → 红线 #6「Portable 禁平台扩展」未被顺手破 |
| 头纯净性 | `check_platform_headers.py` | `scanned **43** header(s) … **0** violation(s)`（与 032 基线逐字相同；N 变了说明误改扫描根） |

- ⚠️ **本批只跑模块级窄检**：全量 15 步门禁、双壳 `pod install`/`xcodebuild`、真机都**没跑**，归 INFRA-034 末批一趟。
  上面的 135.17s 是**清掉 `build/generated` 后**的重建耗时，与 032 的 149.75s(增量产物已存在) 不可直接比较。
- **防"静默假绿"的标准动作**（写进 `.agents/skills/cq-build-test`）：改 shader 输入路径后必须
  `rm -rf build/generated` 再构建，否则 CMake 会复用旧产物报绿、新 `DEPENDS` 路径写错也发现不了。
- 本批**没有**新的性能结论。

## 2026-10-16 · INFRA-034 治理补齐与收口（本机 = 集成机，**整改批末批 = 整批全量门禁 + 双壳**）

机器：macOS 26.7.1 / Xcode 26.6 / Swift 6.3.3 / **Intel x86_64** / cmake 4.4.3（不在 PATH，`$HOME/.workbuddy/...`）。

| 项 | 命令 | 数字 |
|---|---|---|
| 全量门禁 | `tools/ci/run_gate.sh`（**17 步**） | **PASS=17 / FAIL=0 / SKIP=0**，exit 0，墙钟 **10m57s**（23:31:05→23:42:02，暖缓存） |
| 内核单测 | `build_core.sh --platform=apple --test` | Debug **52/52** **78.96s**；Release **52/52** **74.55s** |
| 头纯净性 | `check_platform_headers.py` | `scanned **43** header(s) … **0** violation(s)`（与 032/033 基线逐字相同） |
| 图层卫生 | `check_uiview_layer_hygiene.py` | 两趟 **119** 文件，R1 违规 **0** |
| Swift 包测试 | `run_gate.sh` 包段 | bindings **26** / player **52** / camera **77** / import **16** / editor **81** = **252**，0 失败 → **与 P148/031/032/033 基线逐字相等** |
| golden | `tests/golden/verify.py --json` | `built_ok=21 / built_fail=0 / unbuilt=0 / total_bytes=901784` |
| iOS 切片只编译 | `tools/ci/check_ios_compile.sh`（P146 收口） | **暖机 2~6s**；`nm -a` 取证同一份 `audio_engine.mm` 的 `RegisterSessionObservers` 符号数 **ios-device 4 / ios-sim 3 / macos 0** |
| 双壳 | P129 配方（`bundle exec pod install` + `xcodebuild`） | ios **14/14 pods** + **BUILD SUCCEEDED**（error 0 / warning 24 行）；mac **7/7** + **BUILD SUCCEEDED**（error 0 / warning 11 行） |
| 壳内 shader 产物 | App 包 `*.metallib` | `beauty_bilateral` **9215B** / `face_warp` **5792B** / `beauty_guided` **8118B**（23:45:04 本次构建，与 031 基线**逐字节相等**，非 96B 空壳 P149） |
| 壳重写的生成头 | `build/generated/shaders/blit_msl.h` | **1689B** = 033 搬家后数字 → 壳吃的是 `engine/shaders/portable/` 那份 |
| 仓库卫生 | `tools/ci/check_repo_hygiene.sh` | **4/4 PASS**；tracked **856** 文件、产物命中 **0**；旧路径 raw 命中 **23** 行全部带迁移标记（**33 行**豁免 / 非豁免 **0**）；editorconfig 四条件 **0** 命中 |
| clang-format 基线 | 同上（**INFO，不判红**） | `engine/**` **79/115**（`.h` 48/65、`.cpp` 21/40、`.mm` 10/10）、`tests/**` **34/51** |
| 接口参考 | `gen_api_reference.py --check` | `docs/api/engine-api.md` **538 行 / 95 个 c 块 / 11 个 `###` 子节 / 9 个 `##` 大节**，符号 **103** |
| 文档链接 | `tools/ai/linkcheck_docs.py` | 修 checker 前 **10** 条命中（**10/10** 落在叙述域）→ 域豁免后 **0** 条，exit 0 |
| 门禁判据自证 | `PYTHON_BIN=/bin/ls tools/ci/run_gate.sh --fast` | 强制第 1 步红 → exit **1**、摘要**只有 1 行**、后续 16 步零行、`build/gate-logs/` 只剩 `deps.log`（P145 两层防御取证） |

### P160 干净复现（`rm -rf build` 逐遍重装，2026-10-17 09:06~09:48，workflow core 段的等价本机跑）

脚本：`/tmp/cirepro034b.sh`（run1/run2）+ `/tmp/ci3.sh`（run3）+ `/tmp/ci4.sh`（run4）= `rm -rf build` →
`CMAKE_BIN=cmake tools/build/build_shader_toolchain.sh` → `build_core.sh --platform=apple --config=Debug`
→ `ctest -N` 打印排除名单 → `ctest -E platform_apple_decode` → （run2/run4）`check_repo_hygiene.sh`。

| 遍 | 用的脚本 | toolchain | build_core | ctest `-E platform_apple_decode` | hygiene |
|---|---|---|---|---|---|
| run1 | ⚠️ **大小写修正前** | rc=0 | rc=0 | rc=0，**51/51**，**186.74s** | — |
| run2 | 大小写修正版 | rc=0 | rc=0 | rc=0，**51/51**，**172.84s** | rc=0 |
| run3 | 大小写修正版 + 本地补丁（见池 [23]） | rc=0 | rc=0 | rc=0，**51/51**，**271.32s** | — |
| run4 | **P162 修复后的交付版** | rc=0 | rc=0 | rc=0，**51/51**，**83.52s** | rc=0 |

- **四遍都打印了排除名单**：`Test #45: platform_apple_decode` —— 判据要求"日志里能看到被排除的用例名单"，
  靠 `ctest -N | grep` 显式取证，不靠 `ctest -E` 静默少跑一个（少跑与跑绿在日志里长一样）。
- **单次干净跑 ≈ 7~11min**（run4 整段 09:42:02→09:48:50 = **6m48s**；run2 段 09:16:03→09:25:30 含 hygiene）。
  其中工具链 ≈ **2min**（glslang ≈50s + SPIRV-Cross ≈65s，-j12）。
  ⚠️ **ctest 墙钟在四遍之间是 186.74 / 172.84 / 271.32 / 83.52s** —— 同是 51/51 全过，波动 3 倍以上，
  **本机 ctest 墙钟不可当指标**，可比的只有 rc 与通过数。
- 产物字节数（干净装配后，跨四遍稳定）：`glslang` **3 133 560 B**、`spirv-cross` **4 155 984 B**、
  `build/generated/shaders/blit_msl.h` **1689 B**。
- ⚠️ **本表不是"门禁变快"的证据**：17 步全量门禁的 10m57s 是**暖缓存**数字，
  与本表的干净复现数字（~9min 只覆盖 core 段）不同口径，不可互相替换。

### P162 幂等/只读自证（`build_shader_toolchain.sh`，2026-10-17 09:3x~09:4x，暖态）

| 场景 | 命令 | 结果 |
|---|---|---|
| 暖态完整跑 | `CMAKE_BIN=cmake tools/build/build_shader_toolchain.sh` | rc=**0**，两工具均 `产物已存在，跳过编译`，**"强制重编"零行**（修之前每遍都会删重编，多 ~65s） |
| 暖态只读校验 | 同上 `--check-only` | rc=**0**，两产物 `OK`，`spirv-cross` **md5 跑前后逐字节一致**（修之前这条命令会 `rm -rf build/tools/spirv-cross/`） |
| 负向（产物缺失） | 挪走 `build/tools/glslang/StandAlone/glslang` 后 `--check-only` | rc=**1**、报 `产物缺失`；恢复后 md5 一致、再跑 rc=**0** |

**新口径（替代旧数字使用方式）**

- **门禁步数从 15 → 17**：加 `api-doc`、`ios-compile`；原内联 `artifacts` 一步并入 `hygiene`
  （同一件事两套正则必然走偏，判据只留一份）。以后对基线请对 **17**。
- **摘要行数 = `PASS+FAIL+SKIP`**（P145）：`apple-*` 摘要行取 `Executed N tests, with M failures`，
  不再取只带时间戳的 `Test Suite … passed at`。
- **xcodebuild 的 `warning:` 行数不是可比数字**（032 记 6、034 记 11，差在增量重编了多少 TU）。
  可比的是 `error: 0` + 告警**类别**集合；引用 warning 行数时必须写清增量前提。
- **暖缓存门禁 10m57s**（032 冷缓存 18m58s）：`build/` 被 `--clean` 或搬家清过之后耗时会翻倍以上，
  不能拿 10m57s 去判"变快了"。
- 本机调 CocoaPods 的脚本**必须自带 locale**（`LANG`/`LC_ALL` 未设时 `pod install` 直接崩，见 P159）。
- 本批**没有新的性能结论**（治理与布局批）；上表全部是判据/守恒类数字。
- **P160（2026-10-17 立）：以后引用"门禁 17/17 绿"必须同时说明缓存状态。**（口径已升为 **ADR-0045**）
  `build/shader 工具链`（glslang + SPIRV-Cross）历史上只存在于**本机暖缓存**，仓库里没有任何脚本产出它
  → 上面 10m57s 的 17/17 与 10-16 之前所有"绿"都**只是暖缓存证据**，`--clean` / 新克隆 / CI 上必然红
  （实测：停在 27% SHADER-001，随后 `ctest rc=8`、50/51 "Could not find executable"）。
  现在的判据是**干净复现**（见上表），暖缓存绿不再算验收。

### 提交后基线（2026-10-17 10:3x，INFRA-026~035 落 main，**本机未 push**）

**tracked 文件数从 856 → 878**（本批 22 个新入库文件：CI workflow、`.clang-format`、`.editorconfig`、
3 个新脚本、ADR-0044/0045、RESEARCH-018、HANDOFF-025、`docs/archive/README.md`、TASK-INFRA-026~035 十张、
当日日志）。**以后 hygiene 的 tracked 数对 878，不再是 856。**

| 判据 | 提交前（未跟踪态） | 提交后复测 |
|---|---|---|
| `check_repo_hygiene.sh` | 4/4 PASS，tracked 856，legacy 非豁免 **0**（豁免 23 行） | 首跑 **3/4（FAIL legacy-paths 2 行）** → 修 P163 后 **4/4 PASS**，tracked **878**，豁免 **33 行** |
| `linkcheck_docs.py` | rc=0 | rc=0（不变） |
| `gen_api_reference.py --check` | rc=0 | rc=0（不变） |
| `sync_context.py --check` | rc=0 | rc=0（不变） |

- ⚠️ 这张表的重点不是数字，是**"提交前 4/4"与"提交后 4/4"是两次不同的测量**：判据脚本自己从未跟踪
  变跟踪会改变扫描集（P163）。**收工口径一律取提交后那一列。**

### 双壳进门禁（2026-10-17 11:0x~11:2x，TASK-INFRA-037，本机 Intel x86_64 集成机实测）

| 口径 | 数字 | 备注 |
|---|---|---|
| 双壳**冷**（空 derivedData，两端合计） | **280s** rc=0 error=0 | iOS derivedData 993MB + macOS 514MB |
| 双壳**暖**（本脚本 `build/gate-logs/dd-*`，两端合计） | **39s** rc=0 error=0 | warning 行 iOS 13 / mac 5（只留痕不判） |
| 单 iOS 端冷（历史独立测量，10:5x） | **199s** rc=0 error=0 | 那一趟的 derivedData 落错位置（P164），数字仍可信、产物已删 |
| `pod install` | rc=0，**14 个 pod**，两端各一次 | 完成行 `Pod installation complete!`；`grep -c Installing` 恒 0，不可当判据 |
| `check_repo_hygiene.sh` | **5/5 PASS**（新增判据 5 `scratch-dirs`） | tracked **878** 不变；legacy 豁免行数 33 → **64**（新纳入三代死根的 31 行历史标注），非豁免仍 **0** |

- **引用口径**：以后说"门禁全绿"必须带上「双壳是暖跑 39s 还是冷跑 280s」——这两数差 7 倍，
  差别只在 `rm -rf build/gate-logs/dd-*` 做过没有（同 P160 的暖缓存纪律）。

### 18 步全量门禁实测（2026-10-17 11:44:16 起，TASK-INFRA-037 收口趟，本机 Intel x86_64 集成机）

`tools/ci/run_gate.sh`（无参数）：**PASS=18 / FAIL=0 / SKIP=0，exit 0，墙钟 ≈20m40s**。
静态清点的 17→18 至此**已被实跑证实**，上面那句"还没被一次全量跑证实"作废。
core Debug **52/52**、Release **52/52**；6 包用例 26+52+77+16+81 = **252**（SharedUI 段无数字行，照旧）。

每步耗时由 `build/gate-logs/<step>.log` 的 mtime 差反推（**脚本本身不记时长**，这也是个待补的观测缺口）：

| 步 | 秒 | 缓存状态 |
|---|---|---|
| deps / headers / api-doc / golden | 0 / 1 / 0.8 / 5.6 | 纯静态检，与缓存无关 |
| hygiene | 4.5 | 5 条判据（含新 `scratch-dirs`） |
| ios-compile | 2.5 | **暖**（上一趟刚编）；冷态是一整棵 `ios-sim` 树 |
| core-dbg | **379.0** | 本批改了 `engine/core/cq/**` 头注释 → 脏集铺满 |
| core-rel | **438.4** | 同上 + LTO |
| apple-xcframework | 17.3 | **暖**；冷态是三切片 |
| apple-{swift-bindings,sharedui,player,camera,import,editor} | 47.7 / 29.2 / 52.2 / 46.1 / 58.7 / 71.4 | 增量 |
| apple-shells | 44.5 | 双壳**暖**（含 2×`pod install`） |

- **成本结构结论（这条是优化立项的依据）**：`core-dbg + core-rel` = **817s，占全程 66%**，
  是唯一有数量级可砍的两步；Apple/Swift 六包合计 305s（37%）。
  我先前口头判断"xcframework 三切片最贵"在暖缓存下**不成立**，已按实测更正。
- 参照：10-16 INFRA-034 那趟 17 步 **10m57s（暖）**、INFRA-032 那趟 **18m58s**。
  本趟更长是因为**注释改动照样把四棵 CMake 树的依赖图全打脏**——不是新增第 6 步的代价（那步只 44.5s）。
- ⚠️ 引用门禁时长必须带**缓存状态**（P160 铁律）：`ios-compile` 2.5s 与 `apple-xcframework` 17.3s
  都是暖态数字，拿来当"这两步天生便宜"是错的。

### 并行度 A/B（2026-10-17 12:0x，INFRA-038 立项依据，本机 Intel x86_64 / 12 逻辑核）

同一棵 `build/`（Release）、**同一脏集**：`touch engine/core/cq/base/chq_rational_time.h`
（被 67 个源文件直接 include，含传递则铺满 core）。

| 口径 | 结果 |
|---|---|
| `cmake --build build`（现状，无 `--parallel`，Unix Makefiles → 单线程） | **254s**，重编 **73** 个 TU |
| `cmake --build build --parallel 12` | **70s**，重编 **72** 个 TU |
| **加速比** | **3.6×** |

- 两次 rc 均为 0；TU 数差 1 是第二轮里有一个文件已被上一轮编到同哈希而跳过，不影响可比性。
- **外推口径（明确标 hypothesis）**：若 `core-dbg`/`core-rel` 按同比例，18 步全量的 817s 两兄弟步
  可降到 ~230s，全程 20m40s → 约 **10min**。这是外推，不是实测；**落地后要拿一次真实全量跑替换本行**。
- 现状只有 `tools/build/build_shader_toolchain.sh` 传了 `-j$(hw.ncpu)`；
  `build_core.sh:85` 与 `build_core_apple.sh:178` 都没传 —— 见 **P166**。
