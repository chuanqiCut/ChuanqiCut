# ADR-0008：FFmpeg 源码依赖采用「本地 git 管理 + 显式 bump」，禁止跟随分支 HEAD

- **状态**：已采纳（版本号待确认，见 §待确认）
- **日期**：2026-09-24
- **相关**：ADR-0003、ARCH-002 §2.1 / §3 / §5.1、DEPS-001 / DEPS-002

## 背景

传哲决定：FFmpeg 用 `https://github.com/FFmpeg/FFmpeg.git` **下载到本地管理，可以定期拉最新**。

这条指令有两个必须拆开处理的部分：
1. **用什么地址拉** —— 纯事实问题，已核验。
2. **"定期拉最新"怎么实现** —— 这是设计问题。字面实现（跟随某个分支）会摧毁可复现构建。

## 决策

### 1. upstream 使用 GitHub 官方镜像

`ffmpeg.org` 官方下载页的 Git Repositories 表中，`https://github.com/FFmpeg/FFmpeg` 被登记为
**"Mirror of the main repository"**，属官方镜像，不是第三方野库。
canonical upstream 仍是 `https://git.ffmpeg.org/ffmpeg.git`，**两者都在 SOURCE_REGISTRY 白名单中保留**。

选择 GitHub 镜像的理由：CI 拉取速度与连通性优于 `git.ffmpeg.org`。
风险：镜像理论上存在同步延迟。缓解：`deps.py check` 记录的 commit 必须同时能在 canonical upstream 找到，
这一条作为构建期的完整性核对（待 DEPS-002 实现）。

### 2. "定期拉最新" = 显式 bump 到新 commit，不是跟随 HEAD

这是本 ADR 的核心。**没有任何形式的自动跟随**。

- 所有源码集成的 git 依赖**必须** `pin = "commit"` 且 `pin_ref` 为 40 位 hash。
- `pin = "tag"` **禁止**用于源码集成：tag 是可变引用，可被上游 force-push。
- **理由**：跟随分支意味着同一份仓库源码，今天编译和明天编译得到的 FFmpeg 可能不同。
  demux/seek 行为的细微变化会让 golden 测试和 PSNR 对比**随机失败**，
  而排查时会误以为是自己代码的回归。这类 bug 的排查成本极高，且会持续消耗团队信任。
  此外，LGPL 合规审计要求能指认出**具体哪一份源码**被编进了发布产物 —— 跟随 HEAD 做不到这一点。

### 3. bump 流程（人工评审 + CI，不自动化）

```
1. 拉取上游新 tag / commit（人工或定时任务触发，不由 CI 自动执行）
2. 更新 manifest.toml 的 version 与 pin_ref
3. 完整 CI：编译 + 单测 + golden 回归 + FFmpeg 体积/符号门禁（DEPS-013）
4. 人工评审差异后合入
```

`bump_policy = "human"` 表达此语义。`"auto"` 目前**不启用** —— 自动化 bump 的前提是先有稳定的
golden 回归与自动化评审，现在没有。

## 落到机器上的约束

已在 `tools/deps/` 实现为可执行门禁（不是文档约定）：

| 新增字段 | 语义 |
|---|---|
| `vcs` | `git` \| `archive` \| `none` |
| `pin` | `commit` \| `tag` \| `digest`；源码集成的 git 依赖必须 `commit` |
| `pin_ref` | 不可变引用，`pin=commit` 时须为 40 位 hash |
| `bump_policy` | `human` \| `auto` \| `none` |

新增错误码：`UNPINNED_VCS`（未锁定 / 用 tag 锁）、`BAD_PIN_REF`（格式非法）、`BAD_BUMP_POLICY`。
自测从 14 例增至 **18 例**（新增 4 例专门覆盖本 ADR 的规则），全通过。

## 核验中发现的事实错误（DEPS-001 遗留）

引入 `git ls-remote` 核对后，发现 manifest 里**有多个版本号是编造的** —— 这比没有版本号更糟，
因为它让清单看起来可审计而实际上不可信：

| 依赖 | 原写 | 实际核验结果 | 已改为 |
|---|---|---|---|
| `ffmpeg` | `7.1` / `git.ffmpeg.org` | 7.1 已落后两个大版本 | `9.0.2` + GitHub 官方镜像 commit |
| `signalsmith-stretch` | `1.0` | **上游 0 个 tag**，不存在 1.0 | `git-57b93f4`（诚实表达：只能按 commit 标识） |
| `SPIRV-Cross` | `1.3.296.0` | **上游无 tag**，无法核对 | `git-aa217ae` |
| `oboe` | `1.9.2` | **该 tag 不存在**（只有 1.9.0 / 1.9.3） | `1.9.3` |
| `glslang` | `15.0.0` | 存在，但最新为 16.0.0 | `16.0.0` |
| `googletest` | `1.14.0` | 存在，但最新为 v1.15.2 | `1.15.2`（选型仍归 INFRA-002） |

**防复发**：`version` 字段不得手写 arrived-at 版本号；
凡是 `pin=commit` 的依赖，`version` 必须能从 `pin_ref`（tag 解引用）或 commit 推导得到。

## 顺带修复的一个既有缺陷

`tools/deps/parser.py` 的 `_validate_artifact()` 使用了未定义的常量 `E_BAD_VALUE`，
一旦 artifact.platform 非法会抛 `NameError` 而非给出校验错误。已改为 `E_INVALID_VALUE`。

## 后果

**正面**
- FFmpeg 源码纳入本地 git 管理符合原意，同时保住可复现构建
- 「必须锁 commit」变成机器门禁，不依赖人的自觉
- 顺带揪出 6 处不可信的版本声明

**负面 / 成本**
- 每个源码依赖多三个字段，manifest 变长
- bump 需要人工跑流程，短期不如自动跟随省事
- 依赖清单里的版本号现在必须与真实 tag 一致，写文档时不能"差不多就行"

## 反转条件

- 若 CI 与 golden 回归足够稳定，**可以**把某个 scope=build 的工具依赖改为 `bump_policy = "auto"`；
  运行时依赖（含 FFmpeg）**不得**启用，因为它的行为直接进入发布产物。

## 待确认

**FFmpeg 版本是我改的，需要传哲确认。** 理由与反悔成本：
- 原本写的 `7.1` 是上一轮造 manifest 时顺手写的大版本号，没有经过任何决策；
  而当前最新稳定版是 **9.0.2（2026-09-18 发布）**，8.1.3 也在维护中。
- 项目此刻还没有任何代码依赖 FFmpeg，**现在是切换成本最低的时刻**（零迁移成本）。
- 我们只用 demux 档位的 `libavformat` / `libavutil` / `avcodec-parser` 窄接口，
  大版本跳跃的风险相对可控，但仍需 DEPS-010 构建脚本实跑验证 < 3MB 与无 GPL 符号。
- 若坚持 7.1：把 `version` 改回 `7.1.5`、`pin_ref` 改为 `3a0867c2bfda4a4d4309ca1a8cbdc6175e67f587` 即可，
  无其他连带改动。

## 落地任务

`DEPS-002`（deps.lock 需消费 pin_ref）、`DEPS-010/011/012`（按 pin_ref checkout 后构建 demux 档位）、
`DEPS-013`（体积/符号基线需记录对应 commit）
