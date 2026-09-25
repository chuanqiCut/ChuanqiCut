# ARCH-002：第三方依赖治理与开源 SDK 能力管理

> 版本：v1.0（待 Review）
> 日期：2026-09-23
> 适用：`third_party/` 下一切第三方代码（开源库、SDK、模型资产）

---

## 1. 治理目标

1. **可裁剪**：同一个库能按"能力档位"构建，例如 FFmpeg 可以只集成解封装、不集成编解码。
2. **双集成**：每个库既能源码集成（可调试、可打补丁），也能二进制集成（构建快、可分发），切换不改动上层代码。
3. **协议可控**：协议分级 + CI 门禁，禁止高风险协议在无人审批的情况下进入默认构建。
4. **可追溯**：版本锁定、校验和、SBOM、补丁记录齐全，任何人能回答"我们用的是什么"。
5. **不泄漏**：第三方符号与类型不得出现在 SDK 公共头文件与 ABI 边界。

---

## 2. 目录与清单

```
third_party/
├── manifest.toml          # 人写的声明：要什么、什么协议、什么档位
├── deps.lock              # 机器生成的锁定：确切 commit / 校验和 / 产物路径
├── patches/<name>/*.patch # 对上游的补丁，升级时重放
├── prebuilt/              # 二进制集成的制品（按 platform/profile 分目录）
│   └── ffmpeg/7.1/demux/apple-arm64/{libffmpeg.a, include/}
└── <name>/                # 源码集成的 checkout（submodule 或 FetchContent 缓存）
```

### 2.1 `manifest.toml` 格式

```toml
[[dep]]
name        = "ffmpeg"
version     = "7.1"
upstream    = "https://git.ffmpeg.org/ffmpeg.git"
license     = "LGPL-2.1-or-later"     # 必须填写 SPDX 表达式
license_note = "仅当启用 profile=full 且链接 libx264 时整体升为 GPL-2.0-only"
integration = "source"                # source | binary | auto
profile     = "demux"                 # 能力档位，见 §3
features    = ["demux", "seek", "probe", "bitstream-filter"]
platforms   = ["apple", "android", "ohos"]
scope       = "runtime"               # runtime | build
visibility  = "private"               # private = 不得出现在公共头文件
owner       = "media"
strip       = true

[[dep.artifact]]                      # 仅 integration 含 binary 时必填
platform = "apple-arm64"
url      = "https://artifacts.internal/..."
sha256   = "<64位十六进制>"           # manifest 只验格式，真伪由 deps.lock 锁定
path     = "prebuilt/ffmpeg/7.1/demux/apple-arm64"
```

字段规则：
- `license` **必须是 SPDX 表达式**，不接受自由文本。
- `integration = "auto"` 表示：本地开发优先用 `binary`（快），CI 与发布必须用 `source`（可审计）。
- `visibility = "private"` 由 CI 静态检查强制：扫描 `core/include/cq/**` 与 `bindings/**` 的公共头，出现第三方符号即失败。
- **`scope = runtime | build`**（DEPS-001 实现时补入，原 §2.1 缺失此维度）：`build` 表示**仅构建期工具链**（glslang / SPIRV-Cross / 测试框架），代码不进入任何发布产物，因此不受 `visibility` 与 SBOM 的运行时约束；缺省为 `runtime`。没有这个字段，构建期工具会被误当运行时依赖纳入协议审计与 SBOM，产生大量噪声。
- **`[[dep.artifact]]`**：`integration` 为 `binary` 或 `auto` 时必填。manifest 是**声明层**（验格式），`deps.lock` 是**锁定层**（验真伪）。校验和真伪不在 manifest 里保证。
- **`vcs` / `pin` / `pin_ref` / `bump_policy`**（ADR-0008）：源码集成的 git 依赖**必须** `pin = "commit"` 且 `pin_ref` 为 40 位 hash。禁止 `pin = "tag"`（tag 是可变引用，可被上游 force-push，会摧毁可复现构建）。「定期拉最新」通过**人工 bump `pin_ref` + 完整 CI** 实现，**不允许 CI 自动跟随任何分支**。

### 2.2 `deps.lock`（自动生成，禁止手改）

```toml
[[locked]]
name = "ffmpeg"
resolved = "n7.1"
commit = "2f3c9a1e..."
artifact_sha256 = "..."
profile = "demux"
built_by = "tools/build/build_ffmpeg.sh@abc123"
```

CI 校验：lock 与 manifest 不一致、或 checksum 不匹配，构建直接失败。

---

## 3. 能力裁剪机制（以 FFmpeg 为核心案例）

### 3.1 三个档位

| profile | 包含 | 用途 | 实测参考体积 | 协议 |
|---|---|---|---|---|
| **`demux`**（默认） | `libavformat` + `libavutil` + `libavcodec` 的 **parser 部分** | 解封装、精确 seek、探测、码流 Annex-B 转换 | 常用子集档位：待回填（全量档位实测 4.88 MB @apple-x86_64） | LGPL-2.1-or-later |
| **`demux+codec-fallback`** | 上述 + **显式白名单的软解码器** | 平台硬解不支持的格式兜底（如 iPhone 上的 VP9、旧 Mac 上的 AV1、Intel 上的 ProRes） | 未构建，待实测 | LGPL-2.1-or-later |
| **`full`** | 再 + encoder / muxer / filter / swscale / swresample | **默认禁用**，仅研究用途 | 未构建，待实测 | 若链接 libx264/x265/postproc → **GPL-2.0-only，需审批** |

> ⚠️ **该列是实测参考值，不是硬目标**（2026-09-25 修订：原列名为「体积目标(arm64)」，值为 `< 3 MB` / `< 8 MB`）。
> 体积是**裁剪的结果**而非约束 —— 先按实际需求定组件范围（可按需增减），再记录实测值。
> 反过来用阈值反推该裁哪些格式，会为了凑数砍掉用户真正需要的能力。
> 全平台实测值以 `.ai/memory/baselines.md` 为准；arm64 待 DEPS-011/012 在对应平台构建后回填。

**这就是"FFmpeg 可选择是否集成编解码部分"的落地方式**：档位在 manifest 中声明，映射到 CMake 选项与 configure 参数，上层代码通过 `CQ_HAVE_FFMPEG_CODEC` 宏做条件编译。

### 3.2 `demux` 档位的实际构建配置

```bash
# tools/build/build_ffmpeg.sh --profile=demux --platform=apple
./configure \
  --disable-everything \
  --disable-autodetect \
  --enable-protocol=file,pipe \
  --enable-demuxer=mov,mp4,m4a,matroska,webm,avi,wav,flac,aac,mp3 \
  --enable-parser=h264,hevc,aac,av1,vp9,mpeg4video,mjpeg \
  --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc,extract_extradata \
  --disable-avdevice \
  --disable-swscale --disable-swresample --disable-postproc \
  --disable-decoders --disable-encoders --disable-hwaccels \
  --disable-muxers --disable-filters \
  --disable-ffmpeg --disable-ffplay --disable-ffprobe \
  --disable-doc --disable-htmlpages --disable-manpages \
  --disable-shared --enable-static --enable-pic \
  --disable-debug
```

关键说明：
- `--disable-everything` 后必须**逐项显式 enable**，避免误带入不需要的组件。
- 保留 parser 是因为 libavformat 依赖 libavcodec 的 parser 做码流分析；这**不等于集成了编解码器**。
- **绝不使用 `--enable-gpl`**，也不链接任何 GPL 外部库 → 整体停留在 LGPL v2.1+。
- 体积与符号表必须在 CI 中实测并写入 `.ai/memory/baselines.md`。
  ⚠️ **这里的实测值只作参考基准，不是硬阈值**（2026-09-25 修订：原写「目标 < 3 MB，超标即告警」）。
  体积是**裁剪的结果**而非约束：先按实际需求确定组件范围（可按需增减），再记录实测体积。
  若反过来用一个拍脑袋的阈值去反推该裁掉哪些格式，会为了凑数砍掉用户真正需要的能力
  （典型如单张图片输入）。符号表（GPL 符号为 0）**仍是硬门禁**，与体积区分对待。

### 3.3 能力是否启用的运行时可见性

编译期裁剪不能让上层"以为有"。SDK 暴露：

```c
typedef enum {
  CQ_FEATURE_FFMPEG_DEMUX   = 1 << 0,
  CQ_FEATURE_FFMPEG_CODEC   = 1 << 1,
  CQ_FEATURE_FFMPEG_MUXER   = 1 << 2,
} CQFeature;

bool cq_has_feature(CQFeature f);
```

上层（含 UI）在需要某能力前先查询，缺失时给出明确降级路径而不是崩溃。

---

## 4. 源码集成 vs 二进制集成

| 维度 | `source` | `binary` |
|---|---|---|
| 构建耗时 | 慢（首次 5–20 分钟/库） | 秒级 |
| 可调试 | ✅ 可步进进库内部 | ❌ 只有头文件 |
| 可打补丁 | ✅ `third_party/patches/` | ❌ |
| 可审计 | ✅ 源码在库内 | 需制品库留档 + checksum |
| 分发友好 | ❌ | ✅ |
| **默认用于** | CI、发布分支、需要改上游时 | 本地日常开发、CI 缓存命中时 |

**切换规则**：
- 上层代码与 CMake target 名保持一致（`cq::ffmpeg`），两种集成方式暴露**完全相同的 target 接口**，切换只改 manifest 的 `integration` 字段。
- 二进制制品由 `tools/build/build_<dep>.sh` 产出并上传到制品库，`deps.lock` 记录 `artifact_sha256`。
- **CI 必须两条路径各跑一次**：`integration=source` 的发布流水线、`integration=binary` 的日常流水线。只允许一条路径会导致另一条腐烂。

---

## 5. 协议分级与门禁

| 等级 | 协议 | 规则 |
|---|---|---|
| **ALLOW** | MIT / BSD-2/3 / Apache-2.0 / ISC / Zlib / CC0 / Unlicense | 白名单，自动通过；仍需登记到 manifest 与 SBOM |
| **REVIEW** | LGPL-2.1-or-later / LGPL-3.0-or-later / MPL-2.0 | 允许，但必须满足附加义务并记录处置方式 |
| **RESTRICTED** | GPL-2.0-only / GPL-3.0-only / AGPL / SSPL / 商业试用 / nonfree | **默认构建禁止**。需要时走独立 ADR + 负责人审批，且只能存在于独立 flavor，不得进入任何发布产物 |

### 5.1 LGPL 的附加义务处置（针对 FFmpeg）

LGPL v2.1 对静态链接的核心要求是**接收者能够用修改过的库版本替换并重新链接**。处置方式（三选一，需法务确认后写入 ADR）：

1. **提供目标文件归档**：随发布提供 `.a`/`.o` 与链接脚本，使接收者可重链接（桌面平台最稳妥）。
2. **商业授权**：向 FFmpeg 官方/授权代理购买商业许可，彻底免除此义务。
3. **动态链接**：Android 可行（`.so` 随包），iOS/macOS 上 app bundle 内 framework 的技术可行性需法务确认，通常不被认可为合规替代。

**本方案默认路径：iOS/macOS 走「目标文件归档」；Android 走「动态链接」；若商业上可行，优先评估购买商业授权以消除不确定性。** 该处置结论必须由负责人 + 法务确认后落为 ADR，不得由 AI 或单人决定。

### 5.2 CI 门禁

```yaml
# .github/workflows/deps.yml（要点）
- 解析 manifest.toml，校验 license 为合法 SPDX 表达式
- 校验 deps.lock 与 manifest 一致、checksum 匹配
- 校验无 RESTRICTED 协议出现在默认 profile
- 扫描 core/include/cq/** 与 bindings/** 公共头，禁止出现第三方符号
- 生成 SBOM（CycloneDX JSON + SPDX），随构建产物归档
- 二进制产物体积与符号数对比基线，超标告警
```

---

## 6. 符号与头文件隔离

1. 所有第三方库以 `-fvisibility=hidden` 静态链接进内核，最终产物 strip 非导出符号。
2. SDK 公共头 `include/cq/cq_sdk.h` 只允许出现：基础 C 类型、opaque 句柄、项目自有枚举与结构体。
3. 跨 PAL 边界传递平台原生图像对象时，统一包装为 `CQNativeImageHandle`（opaque）。平台类型转换只在 `pal/<platform>/` 内部进行。
4. 若必须引入某个库的头文件到内部实现，只允许出现在 `.cpp`/`.mm` 中，不允许出现在任何 `.h`。

---

## 7. 依赖清单（首版）

| 库 | 用途 | 协议 | 集成 | 档位 | 平台 | 备注 |
|---|---|---|---|---|---|---|
| **FFmpeg** | 解封装 / 精确 seek / 兜底软解 | LGPL-2.1-or-later | source+binary | `demux` | 全 | 见 §3；REVIEW 级 |
| **signalsmith-stretch** | 音频时间拉伸 / 变声（含 formant 补偿） | **MIT** | source（header-only） | — | 全 | 替代 SoundTouch，见 ADR-0004 |
| **glslang** | GLSL → SPIR-V | BSD-3-Clause / Apache-2.0 | source | 构建期 | 构建机 | 仅构建期依赖 |
| **SPIRV-Cross** | SPIR-V → MSL / GLSL ES | **Apache-2.0** | source | 构建期 | 构建机 | 仅构建期依赖 |
| **Oboe** | Android 低延迟音频 | **Apache-2.0** | source | — | Android | AAudio 优先，OpenSL 回退 |
| **CoreML / Vision / Metal / VideoToolbox** | Apple 平台能力 | 系统框架 | — | — | Apple | 非第三方，无需登记 |
| **MediaCodec / AHardwareBuffer / NDK** | Android 平台能力 | 系统 | — | — | Android | 同上 |
| **AVCodecKit / XComponent / OHAudio** | 鸿蒙平台能力 | 系统 | — | — | OHOS | 同上（P2） |
| **TFLite / MindSpore Lite** | 端侧推理 | Apache-2.0 | binary 优先 | — | Android / OHOS | 见 ADR-0005 |
| **GoogleTest** | 内核单测 | BSD-3-Clause | source | — | 构建机 | 测试期依赖 |
| **cxxopts / nlohmann-json**（或自研） | 工具与序列化 | MIT | source | — | 全 | 序列化建议自研以满足 schema 迁移需求 |
| ~~SoundTouch~~ | — | ~~LGPL-2.1~~ | — | — | — | **已移除**（原文档误标为 MIT） |
| ~~Rubber Band~~ | — | GPL / 商业 | — | — | — | **禁止** |
| ~~MetalPetal~~ | — | MIT | — | — | — | 不引入（锁死 Apple 端），见 ADR-0002 |
| ~~Flutter Engine~~ | — | BSD-3 | — | — | — | 不引入，见 RESEARCH-001 F7 |

### 7.1 模型资产（非代码依赖，但同样治理）

模型文件（`.tflite` / `.mlpackage` / `.ms`）纳入独立清单 `third_party/models/manifest.toml`，记录：来源、版本、输入/输出张量规格、许可、SHA-256、目标精度与实测耗时。**模型是依赖，不是资源。**

| 模型 | 来源 | 协议 | 用途 | 说明 |
|---|---|---|---|---|
| MediaPipe `face_landmark.tflite`（468 点） | MediaPipe 官方模型仓库 | **Apache-2.0** | 人脸 468 点 | **引入模型文件**；Apple 端走路径 A（coremltools 转 `.mlpackage`），回退路径 B 需引入 LiteRT 运行时 |
| MediaPipe `face_detection_short_range.tflite` | 同上 | Apache-2.0 | 人脸检测框 | 引入模型文件，同上 |
| 语义分割 / matting 模型 | 待选（MODNet / 自训） | 待定 | 磨皮 mask / AI 抠像 | MVP 可用 Vision 分割替代，后续引入 |

> **注意区分**：引入的是 **MediaPipe 的模型资产**，**不是 MediaPipe SDK**。
> MediaPipe SDK 不引入（体积大、鸿蒙无支持、各平台有更优后端、calculator graph 会绑架管线结构）。详见 ADR-0005 §决策 0。

---

## 8. 升级与补丁流程

1. 升级：改 `manifest.toml` 的 version → 重新生成 `deps.lock` → 重放 `patches/` → 跑全量门禁 → PR 必须附体积/性能/符号差异。
2. 补丁：一律以 `third_party/patches/<name>/NNNN-<简述>.patch` 管理，补丁头须写清「为什么改、上游 issue 链接、何时可移除」。
3. 禁止在 checkout 目录里直接改源码（会被下次拉取覆盖）。

---

## 9. 责任与审批

| 事项 | 需要 |
|---|---|
| 新增 ALLOW 级依赖 | PR + 1 名 Reviewer |
| 新增 REVIEW 级依赖 | ADR + 负责人批准 |
| 新增/启用 RESTRICTED 级 | ADR + 负责人 + 法务批准 |
| 改变某个库的 profile（如 FFmpeg 开启 codec） | ADR，说明体积/协议/性能影响 |
| 升级版本 | PR + 门禁全绿 + 差异说明 |

---

## 10. 与任务系统的对应

治理机制不是文档，是代码与 CI。落地任务见 `docs/tasks/TASK-BACKLOG.md` 的 `DEPS-0xx` 组。
