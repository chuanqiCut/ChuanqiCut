---
name: cq-dependency-governance
description: 新增、升级、裁剪第三方依赖或模型资产时必须跑。含协议判定、体积/符号影响、双集成切换、SBOM。
---

# 依赖治理

## 触发
新增依赖 / 升级版本 / 改变 profile（如 FFmpeg 开启 codec）/ 新增模型资产 / 打上游补丁。

## 流程

### 1. 协议判定（第一步，判定不通过就不要往下做）
| 等级 | 协议 | 规则 |
|---|---|---|
| ALLOW | MIT / BSD / Apache-2.0 / ISC / Zlib / CC0 | 登记即可 |
| REVIEW | LGPL-2.1-or-later / LGPL-3.0 / MPL-2.0 | 需附加义务处置 + 负责人批准 |
| RESTRICTED | GPL / AGPL / SSPL / 商业试用 / nonfree | **默认构建禁止**，需 ADR + 法务 |

**注意**：`license` 必须是 SPDX 表达式。不要凭印象填协议 —— 去上游仓库读 LICENSE 文件。
（本项目已出过一次错：SoundTouch 被误标为 MIT，实为 LGPL v2.1。）

### 2. 登记 manifest
```toml
[[dep]]
name = "..."  version = "..."  upstream = "..."
license = "<SPDX 表达式>"
integration = "source" | "binary" | "auto"
profile = "..."  features = [...]  platforms = [...]
visibility = "private"  owner = "..."  strip = true
```
**二进制集成与源码集成必须暴露同一个 CMake target**，切换只改这个字段。

### 3. 能力裁剪（若适用）
以 FFmpeg 为例，三个档位：`demux`（默认，< 3MB）/ `demux+codec-fallback` / `full`（默认禁用）。
**绝不使用 `--enable-gpl`**，不链 libx264/x265/postproc/librubberband/libvidstab。

### 4. 影响评估
- 产物体积增量（arm64，strip 后）
- 导出符号数量
- 启动耗时 / 内存占用变化
- 是否引入新的运行时依赖（.so / dylib）

### 5. 门禁
```bash
tools/deps/check.py --strict           # manifest/lock 一致性 + 协议门禁
tools/compliance/scan_headers.py       # 公共头第三方符号扫描
tools/compliance/gen_sbom.py           # SBOM
```

## 检查清单
- [ ] 协议已从上**游 LICENSE 文件**核实，不是凭印象
- [ ] manifest 已登记，`deps.lock` 已重新生成
- [ ] 公共头未出现第三方类型/符号
- [ ] 体积与符号增量已实测并记录
- [ ] 双集成路径均可构建（若新增）
- [ ] SBOM 已更新
- [ ] 若涉及 LGPL/GPL：已有 ADR 与法务结论
- [ ] 模型资产已登记到 `third_party/models/manifest.toml`（若适用）

## 输出
PR 附：协议判定依据（上游 LICENSE 链接）、体积/符号前后对比、门禁结果。
