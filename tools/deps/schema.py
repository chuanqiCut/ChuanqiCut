"""manifest.toml 的 schema 常量定义（DEPS-001）。

集中放置枚举取值、必填字段、来源登记白名单、档位能力目录，
供 parser.py 与 CLI 共享，避免在多处散落硬编码。

设计说明（architectural judgment，需在报告中说明）：
1. ARCH-002 §2.1 的字段里没有显式区分「运行时依赖」与「构建期工具链」。
   但 §7 明确把 glslang/SPIRV-Cross 标为「仅构建期依赖 / 构建机」。
   因此本 schema 新增 `scope` 字段：
       scope = "runtime" (默认) | "build"
   scope=build 表示只在主机跑、不进入最终产物的工具链（如 shader 编译器）。
   这是 ARCH-002 未覆盖但实现必需的扩展，已在报告中标注。
2. 二进制集成需要「预编译产物 + 校验和」。ARCH-002 把它们放在 deps.lock，
   但本任务要求 manifest 自身就能表达二进制集成形态，因此新增
   `[[dep.artifact]]` 子表（platform / url / sha256）。deps.lock（DEPS-002）
   会基于此处做锁定与校验，parser 只做「声明层」校验。
3. 模型资产走独立清单 third_party/models/manifest.toml（ARCH-002 §7.1），
   顶层用 [[model]]，与代码依赖 [[dep]] 区分，便于后续 SBOM/审计分别处理。
"""

from __future__ import annotations

from typing import Dict, List

# manifest 文件顶层数组键，用于自动识别清单类型
DEP_TABLE = "dep"
MODEL_TABLE = "model"

SCHEMA_VERSION = "1.0"

# --------------------------------------------------------------------------
# 枚举取值
# --------------------------------------------------------------------------
INTEGRATION_VALUES = ["source", "binary", "auto"]
VISIBILITY_VALUES = ["public", "private"]
SCOPE_VALUES = ["runtime", "build"]
PLATFORM_VALUES = ["apple", "android", "ohos", "host"]

# VCS 来源的锁定策略（ADR-0008）
# "定期拉最新" 不等于"跟随分支 HEAD"。可复现构建要求每次拉取都必须落在
# 一个不可变的引用上，因此 git 依赖一律锁到 40 位 commit hash。
VCS_VALUES = ["git", "archive", "none"]
PIN_VALUES = ["commit", "tag", "digest"]
# 允许 pin="tag" 的依赖白名单：目前为空 —— 任何 git 依赖都必须 pin=commit。
# tag 是可变引用（可被上游 force-push），不可作为可复现构建的锚点。
TAG_PIN_ALLOWLIST: set = set()

# --------------------------------------------------------------------------
# 必填 / 可选字段
# --------------------------------------------------------------------------
DEP_REQUIRED = [
    "name",
    "version",
    "upstream",
    "license",
    "integration",
    "visibility",
    "owner",
    "platforms",
]

DEP_OPTIONAL = [
    "license_note",
    "profile",
    "features",
    "scope",
    "strip",
    "restricted_approval",
    "patches",
    "notes",
    "artifact",   # 二进制集成产物列表
    "vcs",        # git | archive | none（ADR-0008）
    "pin",        # commit | tag | digest —— git 来源必须 pin=commit
    "pin_ref",    # 具体不可变引用：40 位 commit hash / digest
    "bump_policy",  # human/auto/none —— 是否允许自动跟随上游
]

MODEL_REQUIRED = [
    "name",
    "source",
    "version",
    "license",
    "sha256",
    "purpose",
]

MODEL_OPTIONAL = [
    "inputs",
    "outputs",
    "target_precision",
    "estimated_latency_ms",
    "platforms",
    "notes",
]

# artifact 子表字段
ARTIFACT_REQUIRED = ["platform", "url", "sha256"]
ARTIFACT_OPTIONAL = ["path", "size_bytes"]

# --------------------------------------------------------------------------
# 来源登记白名单（SOURCE REGISTRY）
# --------------------------------------------------------------------------
# 「来源未登记」是任务要求的失败类别之一。upstream / source 的主机名
# 必须落在下列白名单内，否则解析失败。白名单刻意保持小且可审计，
# 新增来源需经治理流程（见 ARCH-002 §9）。
SOURCE_REGISTRY_HOSTS = {
    "git.ffmpeg.org",
    "github.com",
    "gitlab.com",
    "chromium.googlesource.com",
    "source.android.com",     # 系统框架，通常不是第三方依赖来源
    "storage.googleapis.com",  # MediaPipe 模型等
    "tfhub.dev",
    "huggingface.co",          # 模型资产
    "sourceware.org",
    "boostorg.jfrog.io",
}

# 允许的域后缀（覆盖子域名，如 *.googlesource.com）
SOURCE_REGISTRY_SUFFIXES = [
    ".googlesource.com",
    ".google.com",
    ".github.com",  # 已含 github.com 本身，这里保留以防 host 解析差异
]

# --------------------------------------------------------------------------
# 档位能力目录（PROFILE CATALOG）
# --------------------------------------------------------------------------
# 以 FFmpeg 为核心案例（ARCH-002 §3）。profile 是「库相关」的，
# 因此用 (name, profile) 维度定义。未知 (name, profile) 组合不做矛盾判定，
# 仅记录，避免对其它库过度约束。
#
# 每条目：
#   allowed_features : 该档位允许出现的 feature 子集（声明了不在其中的 feature => 矛盾）
#   requires_approval: 该档位是否可能引入受限协议（如 GPL），需 restricted_approval=true
#   note             : 人类可读说明
FFMPEG_PROFILES: Dict[str, Dict] = {
    "demux": {
        "allowed_features": {
            "demux", "seek", "probe", "bitstream-filter",
            "avformat", "avutil", "avcodec-parser",
        },
        "requires_approval": False,
        # 体积不是约束，是裁剪的结果。曾有 "< 3MB" 硬数字写在这里（2026-09-25 移除）：
        # 用一个拍脑袋的阈值去反推该裁掉哪些格式，是本末倒置 —— 会导致为了凑数而砍掉
        # 用户真正需要的能力。正确顺序：先按**实际需求**定组件范围（可按需增减），
        # 再把实测体积记进 .ai/memory/baselines.md 作为**参考基准**，而不是卡死阈值。
        "note": (
            "默认档位：libavformat + libavutil + avcodec 的 parser/bsf 部分。"
            "组件范围按实际需求确定并可按需增减（如只保留常用容器子集）；"
            "不设硬性体积上限 —— 体积是裁剪结果而非约束，实测值记入 "
            ".ai/memory/baselines.md 作参考基准。LGPL-2.1+"
        ),
    },
    "demux+codec-fallback": {
        "allowed_features": {
            "demux", "seek", "probe", "bitstream-filter",
            "avformat", "avutil", "avcodec-parser",
            # 显式白名单的软解码器（兜底，不引入 GPL）
            "decoder-vp9", "decoder-av1", "decoder-prores", "decoder-flac",
        },
        "requires_approval": False,
        # 同 demux：不设硬体积上限，实测值记入 baselines.md 作参考基准。
        "note": (
            "demux + 显式白名单的软解码器（兜底，不引入 GPL）。"
            "软解码器同样按实际需求增减；体积为裁剪结果，非约束。LGPL-2.1+"
        ),
    },
    "full": {
        "allowed_features": None,  # 全开；但可能升 GPL
        "requires_approval": True,
        "note": "默认禁用；若链接 libx264/x265/postproc -> GPL-2.0-only，需 ADR + 法务",
    },
}

# 仅记录、不强制约束的通用档位（占位，便于未来扩展）
GENERIC_PROFILES = {"none", "minimal", "full"}


def profile_catalog_for(name: str, profile: str) -> Dict | None:
    """返回 (name, profile) 对应的档位定义；未知则返回 None。"""
    if name == "ffmpeg":
        return FFMPEG_PROFILES.get(profile)
    return None


# --------------------------------------------------------------------------
# sha256 / commit 校验
# --------------------------------------------------------------------------
SHA256_RE = __import__("re").compile(r"^[0-9a-fA-F]{64}$")
# git 完整 commit hash（40 位十六进制）
GIT_SHA_RE = __import__("re").compile(r"^[0-9a-f]{40}$")


def looks_like_git_repo(url: str) -> bool:
    """粗略判断 upstream 是否指向 git 仓库。"""
    u = url.strip().rstrip("/")
    return u.endswith(".git") or "github.com" in u or "gitlab.com" in u or u.endswith(".git/")
