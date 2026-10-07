# 模块：依赖治理

> **归属**：集成机（依赖治理 + 热点文件） —— 归属表见 docs/tasks/PLAN-三线并行.md §1a / ADR-0029（双机分工与门禁跑批，2026-10-07）

**边界**：`third_party/`、`tools/deps/`、`tools/compliance/`、`tools/build/`

## 三份文件
- `manifest.toml` — 人写：要什么、什么协议、什么档位、源码还是二进制
- `deps.lock` — 机器生成：确切 commit / 校验和 / 产物路径（禁止手改）
- `patches/<name>/*.patch` — 对上游的补丁，升级时重放

## 双集成
`integration = source | binary | auto`。两种集成暴露**同一个 CMake target**，切换只改 manifest 字段，不改上层代码。
**CI 两条路径都要跑**（只允许一条会导致另一条腐烂）。

## 能力裁剪（FFmpeg 为核心案例）
| profile | 内容 | 体积目标 | 协议 |
|---|---|---|---|
| `demux`（默认） | avformat + avutil + avcodec parser | < 3MB | LGPL-2.1-or-later |
| `demux+codec-fallback` | + 白名单软解码器 | < 8MB | LGPL-2.1-or-later |
| `full` | + encoder/muxer/filter/swscale | — | **默认禁用**，可能升 GPL |

**绝不使用 `--enable-gpl`**，不链 libx264/x265/postproc/librubberband/libvidstab。

## 协议分级
- **ALLOW**：MIT / BSD / Apache-2.0 / ISC / Zlib / CC0
- **REVIEW**：LGPL-2.1-or-later / LGPL-3.0 / MPL-2.0（需附加义务处置）
- **RESTRICTED**：GPL / AGPL / SSPL / 商业试用 / nonfree → **默认构建禁止**，需 ADR + 法务

**LGPL 静态链接义务**：iOS/macOS 走"目标文件归档"；Android 走动态链接；商业授权优先评估。
该处置**必须由负责人 + 法务确认后落为 ADR，不得由 AI 或单人决定**。

## 硬约束
1. 第三方类型/符号不得出现在公共头文件（CI 扫描）
2. 所有依赖 `-fvisibility=hidden` 静态链接，产物 strip
3. 模型资产同样治理（`third_party/models/manifest.toml`）
4. 禁止在 checkout 目录直接改源码（会被覆盖），一律走 patches/

## 验证
```bash
tools/deps/check.py --strict          # manifest/lock 一致性 + 协议门禁
tools/compliance/scan_headers.py      # 公共头第三方符号扫描
tools/compliance/gen_sbom.py          # SBOM 生成
```

## 相关
ARCH-002、`DEPS-0xx` 任务、Skill `cq-dependency-governance`
