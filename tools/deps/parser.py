"""third_party/manifest.toml（及 models/manifest.toml）的解析与校验器。

职责边界（DEPS-001，不越界）：
- 校验 schema 合法性（必填字段、枚举、类型）
- 校验 SPDX 协议表达式合法性（委托 spdx.py），并给出整体分级
- 校验来源登记（SOURCE_REGISTRY）、档位/feature 矛盾、二进制集成必须带校验和
- 输出结构化结果（dict / JSON），供 DEPS-002(lock) / 003(门禁) / 004(符号) / 005(SBOM) 消费

不在此实现（归其它任务）：
- deps.lock 生成与校验（DEPS-002）
- 协议分级 CI 门禁（DEPS-003）
- 公共头符号扫描（DEPS-004）
- SBOM 生成（DEPS-005）
- 任何 CMakeLists.txt 改动（归 INFRA-001/002）
"""

from __future__ import annotations

import json
import re
import tomllib
from dataclasses import dataclass, field, asdict
from typing import Any, Dict, List, Optional

import schema as S
from spdx import LicenseTier, validate_expression

# 错误码（供 CI / 后续任务机器识别）
E_MISSING_FIELD = "MISSING_FIELD"
E_BAD_TYPE = "BAD_TYPE"
E_BAD_ENUM = "BAD_ENUM"
E_UNKNOWN_SOURCE = "UNKNOWN_SOURCE"        # 来源未登记
E_INVALID_SPDX = "INVALID_SPDX"
E_UNKNOWN_LICENSE = "UNKNOWN_LICENSE"
E_PROFILE_CONTRADICTION = "PROFILE_CONTRADICTION"
E_BINARY_NEEDS_ARTIFACT = "BINARY_NEEDS_ARTIFACT"
E_BAD_SHA256 = "BAD_SHA256"
E_DUPLICATE_NAME = "DUPLICATE_NAME"
E_BAD_ARTIFACT = "BAD_ARTIFACT"
E_INVALID_VALUE = "INVALID_VALUE"
E_TOML_SYNTAX = "TOML_SYNTAX"
E_UNPINNED_VCS = "UNPINNED_VCS"      # git 来源未锁到不可变引用（ADR-0008）
E_BAD_PIN_REF = "BAD_PIN_REF"        # pin_ref 不是合法 commit hash
E_BAD_BUMP_POLICY = "BAD_BUMP_POLICY"

_ARTIFACT_PLATFORM_RE = re.compile(r"^(apple|android|ohos|host)(-[A-Za-z0-9_]+)*$")


@dataclass
class Issue:
    path: str          # 出错位置，如 dep[ffmpeg].license
    code: str
    message: str

    def to_dict(self) -> Dict[str, str]:
        return {"path": self.path, "code": self.code, "message": self.message}


@dataclass
class Artifact:
    platform: str
    url: str
    sha256: str
    path: Optional[str] = None
    size_bytes: Optional[int] = None

    def to_dict(self) -> Dict[str, Any]:
        d = {"platform": self.platform, "url": self.url, "sha256": self.sha256}
        if self.path is not None:
            d["path"] = self.path
        if self.size_bytes is not None:
            d["size_bytes"] = self.size_bytes
        return d


@dataclass
class DepEntry:
    name: str
    version: str
    upstream: str
    license: str
    integration: str
    visibility: str
    owner: str
    platforms: List[str]
    # 可选
    license_note: Optional[str] = None
    profile: Optional[str] = None
    features: List[str] = field(default_factory=list)
    scope: str = "runtime"
    strip: bool = True
    restricted_approval: bool = False
    patches: List[str] = field(default_factory=list)
    notes: Optional[str] = None
    artifacts: List[Artifact] = field(default_factory=list)
    # VCS 锁定（ADR-0008）
    vcs: str = "none"
    pin: Optional[str] = None
    pin_ref: Optional[str] = None
    bump_policy: Optional[str] = None
    # 派生
    license_valid: bool = False
    license_tier: Optional[str] = None
    license_error: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        d = asdict(self)
        d["artifacts"] = [a.to_dict() for a in self.artifacts]
        return d


@dataclass
class ModelEntry:
    name: str
    source: str
    version: str
    license: str
    sha256: str
    purpose: str
    inputs: List[Dict[str, Any]] = field(default_factory=list)
    outputs: List[Dict[str, Any]] = field(default_factory=list)
    target_precision: Optional[str] = None
    estimated_latency_ms: Optional[float] = None
    platforms: List[str] = field(default_factory=list)
    notes: Optional[str] = None
    # 派生
    license_valid: bool = False
    license_tier: Optional[str] = None
    license_error: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


@dataclass
class ManifestResult:
    kind: str                       # "dep" | "model"
    path: str
    schema_version: str = S.SCHEMA_VERSION
    ok: bool = False
    errors: List[Issue] = field(default_factory=list)
    warnings: List[Issue] = field(default_factory=list)
    entries: List[Any] = field(default_factory=list)

    def add_error(self, path: str, code: str, message: str) -> None:
        self.errors.append(Issue(path, code, message))

    def add_warning(self, path: str, code: str, message: str) -> None:
        self.warnings.append(Issue(path, code, message))

    def to_dict(self) -> Dict[str, Any]:
        return {
            "kind": self.kind,
            "path": self.path,
            "schema_version": self.schema_version,
            "ok": self.ok,
            "errors": [e.to_dict() for e in self.errors],
            "warnings": [w.to_dict() for w in self.warnings],
            "entries": [e.to_dict() for e in self.entries],
            "summary": self.summary(),
        }

    def summary(self) -> Dict[str, Any]:
        total = len(self.entries)
        by_tier: Dict[str, int] = {}
        by_integration: Dict[str, int] = {}
        for e in self.entries:
            t = getattr(e, "license_tier", None)
            if t:
                by_tier[t] = by_tier.get(t, 0) + 1
            if hasattr(e, "integration"):
                by_integration[e.integration] = by_integration.get(e.integration, 0) + 1
        return {
            "total": total,
            "by_license_tier": by_tier,
            "by_integration": by_integration,
            "error_count": len(self.errors),
            "warning_count": len(self.warnings),
        }


# --------------------------------------------------------------------------
# 校验辅助
# --------------------------------------------------------------------------
def _host_of(url: str) -> Optional[str]:
    m = re.match(r"^[a-zA-Z][a-zA-Z0-9+.\-]*://([^/?#]+)", url.strip())
    if not m:
        return None
    host = m.group(1).lower()
    if host.startswith("www."):
        host = host[4:]
    return host


def _is_registered_source(url: str) -> bool:
    host = _host_of(url)
    if host is None:
        return False
    if host in S.SOURCE_REGISTRY_HOSTS:
        return True
    return any(host.endswith(suf) for suf in S.SOURCE_REGISTRY_SUFFIXES)


def _as_str(value: Any, key: str, path: str, issues: List[Issue]) -> Optional[str]:
    if value is None:
        return None  # 缺失由调用方的 MISSING_FIELD 负责，避免重复报错
    if not isinstance(value, str):
        issues.append(Issue(path + "." + key, E_BAD_TYPE, f"{key} 必须是字符串，实际为 {type(value).__name__}"))
        return None
    return value


def _as_list_of_str(value: Any, key: str, path: str, issues: List[Issue]) -> Optional[List[str]]:
    if value is None:
        return None
    if not isinstance(value, list) or not all(isinstance(x, str) for x in value):
        issues.append(Issue(path + "." + key, E_BAD_TYPE, f"{key} 必须是字符串数组"))
        return None
    return list(value)


def _validate_spdx(license_str: str, path: str, issues: List[Issue]) -> tuple[bool, Optional[str], Optional[str]]:
    res = validate_expression(license_str, allow_unknown=False)
    if not res.ok:
        issues.append(Issue(path + ".license", E_INVALID_SPDX, f"非法 SPDX 表达式：{res.error}"))
        return False, None, res.error
    tier = res.overall_tier
    # 注意：LicenseTier.ALLOW == 0，必须用 `is not None` 而非真值判断
    return True, (tier.name if tier is not None else None), None


# --------------------------------------------------------------------------
# 顶层解析
# --------------------------------------------------------------------------
def parse_text(text: str, path: str = "<string>") -> ManifestResult:
    try:
        data = tomllib.loads(text)
    except Exception as e:  # tomllib.TOMLDecodeError 是 Exception 子类
        r = ManifestResult(kind="unknown", path=path)
        r.add_error(path, E_TOML_SYNTAX, f"TOML 解析失败：{e}")
        return r

    if S.DEP_TABLE in data:
        return _parse_dep_manifest(data, path)
    if S.MODEL_TABLE in data:
        return _parse_model_manifest(data, path)
    r = ManifestResult(kind="unknown", path=path)
    r.add_error(path, E_INVALID_VALUE, f"未识别的清单类型：顶层需包含 [[{S.DEP_TABLE}]] 或 [[{S.MODEL_TABLE}]]")
    return r


def parse_file(file_path: str) -> ManifestResult:
    with open(file_path, "rb") as f:
        text = f.read().decode("utf-8")
    return parse_text(text, path=file_path)


# --------------------------------------------------------------------------
# dep 清单
# --------------------------------------------------------------------------
def _parse_dep_manifest(data: Dict[str, Any], path: str) -> ManifestResult:
    result = ManifestResult(kind="dep", path=path)
    rows = data.get(S.DEP_TABLE, [])
    if not isinstance(rows, list):
        result.add_error(path, E_BAD_TYPE, f"[[{S.DEP_TABLE}]] 必须是数组")
        result.ok = False
        return result

    seen_names: Dict[str, int] = {}
    for idx, raw in enumerate(rows):
        if not isinstance(raw, dict):
            result.add_error(f"{S.DEP_TABLE}[{idx}]", E_BAD_TYPE, "条目必须是表（TOML table）")
            continue
        entry, errs, warns = _validate_dep_entry(raw, idx)
        result.errors.extend(errs)
        result.warnings.extend(warns)
        result.entries.append(entry)
        if entry.name in seen_names:
            result.add_error(
                f"{S.DEP_TABLE}[{entry.name}]", E_DUPLICATE_NAME,
                f"依赖名重复：{entry.name}（首次出现于第 {seen_names[entry.name]} 条）",
            )
        else:
            seen_names[entry.name] = idx + 1

    result.ok = len(result.errors) == 0
    return result


def _validate_dep_entry(raw: Dict[str, Any], idx: int) -> tuple[DepEntry, List[Issue], List[Issue]]:
    errs: List[Issue] = []
    warns: List[Issue] = []
    path = f"{S.DEP_TABLE}[{idx}]"
    name_val = raw.get("name", f"#{idx}")

    # 必填字段存在性
    for fld in S.DEP_REQUIRED:
        if fld not in raw:
            errs.append(Issue(f"{path}.{fld}", E_MISSING_FIELD, f"缺少必填字段：{fld}"))

    name = _as_str(raw.get("name"), "name", path, errs) or name_val
    version = _as_str(raw.get("version"), "version", path, errs)
    upstream = _as_str(raw.get("upstream"), "upstream", path, errs)
    license_str = _as_str(raw.get("license"), "license", path, errs)
    integration = _as_str(raw.get("integration"), "integration", path, errs)
    visibility = _as_str(raw.get("visibility"), "visibility", path, errs)
    owner = _as_str(raw.get("owner"), "owner", path, errs)
    platforms = _as_list_of_str(raw.get("platforms"), "platforms", path, errs)

    entry = DepEntry(
        name=str(name), version=str(version or ""), upstream=str(upstream or ""),
        license=str(license_str or ""), integration=str(integration or ""),
        visibility=str(visibility or ""), owner=str(owner or ""),
        platforms=list(platforms or []),
    )

    # 枚举校验
    if integration is not None and integration not in S.INTEGRATION_VALUES:
        errs.append(Issue(
            f"{path}.integration", E_BAD_ENUM,
            f"integration 取值非法：{integration!r}（合法值：{S.INTEGRATION_VALUES}）",
        ))
    if visibility is not None and visibility not in S.VISIBILITY_VALUES:
        errs.append(Issue(
            f"{path}.visibility", E_BAD_ENUM,
            f"visibility 取值非法：{visibility!r}（合法值：{S.VISIBILITY_VALUES}）",
        ))
    if platforms is not None:
        for p in platforms:
            if p not in S.PLATFORM_VALUES:
                errs.append(Issue(
                    f"{path}.platforms", E_BAD_ENUM,
                    f"platforms 含非法取值：{p!r}（合法值：{S.PLATFORM_VALUES}）",
                ))

    # scope（可选，默认 runtime）
    scope = raw.get("scope", "runtime")
    if not isinstance(scope, str) or scope not in S.SCOPE_VALUES:
        errs.append(Issue(
            f"{path}.scope", E_BAD_ENUM,
            f"scope 取值非法：{scope!r}（合法值：{S.SCOPE_VALUES}）",
        ))
    else:
        entry.scope = scope

    # strip（可选，默认 true）
    strip = raw.get("strip", True)
    if not isinstance(strip, bool):
        errs.append(Issue(f"{path}.strip", E_BAD_TYPE, "strip 必须是布尔值"))
    else:
        entry.strip = strip

    # restricted_approval（可选，默认 false）
    ra = raw.get("restricted_approval", False)
    if not isinstance(ra, bool):
        errs.append(Issue(f"{path}.restricted_approval", E_BAD_TYPE, "restricted_approval 必须是布尔值"))
    else:
        entry.restricted_approval = ra

    # license_note / notes / patches
    if "license_note" in raw and isinstance(raw["license_note"], str):
        entry.license_note = raw["license_note"]
    if "notes" in raw and isinstance(raw["notes"], str):
        entry.notes = raw["notes"]
    if "patches" in raw:
        pl = _as_list_of_str(raw["patches"], "patches", path, errs)
        if pl is not None:
            entry.patches = pl

    # features（可选）
    if "features" in raw:
        fl = _as_list_of_str(raw["features"], "features", path, errs)
        if fl is not None:
            entry.features = fl

    # ---- VCS 与锁定策略（ADR-0008：源码依赖必须锁到不可变引用）----
    vcs = raw.get("vcs", "none")
    if not isinstance(vcs, str) or vcs not in S.VCS_VALUES:
        errs.append(Issue(
            f"{path}.vcs", E_BAD_ENUM,
            f"vcs 取值非法：{vcs!r}（合法值：{S.VCS_VALUES}）",
        ))
    else:
        entry.vcs = vcs

    if "pin" in raw:
        pin = _as_str(raw.get("pin"), "pin", path, errs)
        if pin is not None:
            if pin not in S.PIN_VALUES:
                errs.append(Issue(
                    f"{path}.pin", E_BAD_ENUM,
                    f"pin 取值非法：{pin!r}（合法值：{S.PIN_VALUES}）",
                ))
            entry.pin = pin

    if "pin_ref" in raw:
        pin_ref = _as_str(raw.get("pin_ref"), "pin_ref", path, errs)
        if pin_ref is not None:
            entry.pin_ref = pin_ref
            if entry.pin == "commit" and not S.GIT_SHA_RE.match(pin_ref):
                errs.append(Issue(
                    f"{path}.pin_ref", E_BAD_PIN_REF,
                    f"pin=commit 要求 pin_ref 为 40 位十六进制 commit hash，实际为 {pin_ref!r}",
                ))
            elif entry.pin == "digest" and not S.SHA256_RE.match(pin_ref):
                errs.append(Issue(
                    f"{path}.pin_ref", E_BAD_PIN_REF,
                    f"pin=digest 要求 pin_ref 为 64 位十六进制摘要，实际为 {pin_ref!r}",
                ))

    if "bump_policy" in raw:
        bp = _as_str(raw.get("bump_policy"), "bump_policy", path, errs)
        if bp is not None:
            if bp not in ("human", "auto", "none"):
                errs.append(Issue(
                    f"{path}.bump_policy", E_BAD_BUMP_POLICY,
                    f"bump_policy 取值非法：{bp!r}（合法值：human | auto | none）",
                ))
            entry.bump_policy = bp

    # 核心门禁：以源码方式集成、且来源是 git 仓库的依赖，必须锁到 commit
    source_integrated = integration in ("source", "auto")
    if source_integrated and upstream is not None and S.looks_like_git_repo(upstream):
        if entry.pin is None:
            errs.append(Issue(
                f"{path}.pin", E_UNPINNED_VCS,
                f"源码集成的 git 依赖必须显式锁定：声明 pin=\"commit\" 与 40 位 pin_ref。"
                f"「定期拉最新」通过 bump pin_ref 实现（人工评审 + CI），不允许跟随分支 HEAD，"
                f"否则失去可复现构建（见 ADR-0008）",
            ))
        elif entry.pin == "tag" and name not in S.TAG_PIN_ALLOWLIST:
            errs.append(Issue(
                f"{path}.pin", E_UNPINNED_VCS,
                f"pin=\"tag\" 不是不可变引用（tag 可被上游 force-push），不得用于源码集成。"
                f"请改为 pin=\"commit\"。确属必要需加入 schema.TAG_PIN_ALLOWLIST 并走 ADR。",
            ))
        elif entry.pin == "commit" and not entry.pin_ref:
            errs.append(Issue(
                f"{path}.pin_ref", E_UNPINNED_VCS,
                f"已声明 pin=\"commit\" 但缺少 pin_ref",
            ))

    # profile（可选）
    profile = raw.get("profile")
    if profile is not None:
        if not isinstance(profile, str):
            errs.append(Issue(f"{path}.profile", E_BAD_TYPE, "profile 必须是字符串"))
        else:
            entry.profile = profile

    # 来源登记校验
    if upstream is not None:
        if not _is_registered_source(upstream):
            host = _host_of(upstream) or "<无法解析主机>"
            errs.append(Issue(
                f"{path}.upstream", E_UNKNOWN_SOURCE,
                f"来源未登记：{upstream}（主机 {host} 不在 SOURCE_REGISTRY 白名单，需经治理流程登记）",
            ))

    # SPDX 校验 + 分级
    if license_str is not None:
        ok, tier, err = _validate_spdx(license_str, path, errs)
        entry.license_valid = ok
        entry.license_tier = tier
        entry.license_error = err

    # 档位 / feature 矛盾校验
    if entry.profile is not None and entry.name:
        _validate_profile(entry, path, errs)

    # 二进制集成必须带 artifact + 校验和
    artifacts_raw = raw.get("artifact", [])
    if not isinstance(artifacts_raw, list):
        errs.append(Issue(f"{path}.artifact", E_BAD_TYPE, "artifact 必须是数组"))
    else:
        for ai, ar in enumerate(artifacts_raw):
            if not isinstance(ar, dict):
                errs.append(Issue(f"{path}.artifact[{ai}]", E_BAD_TYPE, "artifact 条目必须是表"))
                continue
            a, aerrs = _validate_artifact(ar, f"{path}.artifact[{ai}]")
            errs.extend(aerrs)
            entry.artifacts.append(a)

    if integration == "binary":
        if not entry.artifacts:
            errs.append(Issue(
                f"{path}.artifact", E_BINARY_NEEDS_ARTIFACT,
                "integration=binary 必须声明至少一个预编译产物 [[dep.artifact]]（含 platform/url/sha256）",
            ))
    elif integration == "source" and entry.artifacts:
        # auto 的 binary 路径同样需要 artifact，因此只对纯 source 告警
        warns.append(Issue(
            f"{path}.artifact", E_BAD_ARTIFACT,
            "integration=source 下声明 artifact 没有意义（artifact 仅用于 binary/auto 的二进制路径）",
        ))

    return entry, errs, warns


def _validate_profile(entry: DepEntry, path: str, errs: List[Issue]) -> None:
    cat = S.profile_catalog_for(entry.name, entry.profile)
    if cat is None:
        # 未知 (name, profile) 组合：仅记录，不强制
        return
    # 需要审批的档位（如 full）必须显式开启 restricted_approval
    if cat.get("requires_approval") and not entry.restricted_approval:
        errs.append(Issue(
            f"{path}.profile", E_PROFILE_CONTRADICTION,
            f"档位 {entry.profile!r} 可能引入受限协议（GPL 等），"
            f"需 restricted_approval=true 并登记 ADR + 法务审批（{cat.get('note','')}）",
        ))
    allowed = cat.get("allowed_features")
    if allowed is not None and entry.features:
        bad = [f for f in entry.features if f not in allowed]
        if bad:
            errs.append(Issue(
                f"{path}.features", E_PROFILE_CONTRADICTION,
                f"档位 {entry.profile!r} 不允许声明 feature：{bad}；"
                f"该档位允许的 feature 为：{sorted(allowed)}",
            ))


def _validate_artifact(raw: Dict[str, Any], path: str) -> tuple[Artifact, List[Issue]]:
    errs: List[Issue] = []
    for fld in S.ARTIFACT_REQUIRED:
        if fld not in raw:
            errs.append(Issue(f"{path}.{fld}", E_MISSING_FIELD, f"artifact 缺少必填字段：{fld}"))
    platform = raw.get("platform")
    url = raw.get("url")
    sha = raw.get("sha256")
    platform = _as_str(platform, "platform", path, errs) or ""
    url = _as_str(url, "url", path, errs) or ""
    sha = _as_str(sha, "sha256", path, errs) or ""

    if platform and not _ARTIFACT_PLATFORM_RE.match(platform):
        errs.append(Issue(
            f"{path}.platform", E_INVALID_VALUE,
            f"artifact.platform 非法：{platform!r}（应为 <apple|android|ohos|host>[-<arch>]...）",
        ))
    if sha and not S.SHA256_RE.match(sha):
        errs.append(Issue(
            f"{path}.sha256", E_BAD_SHA256,
            f"sha256 必须是 64 位十六进制字符串，实际长度 {len(sha)}",
        ))

    path_val = raw.get("path")
    if path_val is not None and not isinstance(path_val, str):
        errs.append(Issue(f"{path}.path", E_BAD_TYPE, "artifact.path 必须是字符串"))
    size = raw.get("size_bytes")
    if size is not None and not isinstance(size, int):
        errs.append(Issue(f"{path}.size_bytes", E_BAD_TYPE, "artifact.size_bytes 必须是整数"))

    art = Artifact(
        platform=platform, url=url, sha256=sha,
        path=path_val if isinstance(path_val, str) else None,
        size_bytes=size if isinstance(size, int) else None,
    )
    return art, errs


# --------------------------------------------------------------------------
# model 清单
# --------------------------------------------------------------------------
def _parse_model_manifest(data: Dict[str, Any], path: str) -> ManifestResult:
    result = ManifestResult(kind="model", path=path)
    rows = data.get(S.MODEL_TABLE, [])
    if not isinstance(rows, list):
        result.add_error(path, E_BAD_TYPE, f"[[{S.MODEL_TABLE}]] 必须是数组")
        result.ok = False
        return result

    seen: Dict[str, int] = {}
    for idx, raw in enumerate(rows):
        if not isinstance(raw, dict):
            result.add_error(f"{S.MODEL_TABLE}[{idx}]", E_BAD_TYPE, "条目必须是表")
            continue
        entry, errs, warns = _validate_model_entry(raw, idx)
        result.errors.extend(errs)
        result.warnings.extend(warns)
        result.entries.append(entry)
        if entry.name in seen:
            result.add_error(
                f"{S.MODEL_TABLE}[{entry.name}]", E_DUPLICATE_NAME,
                f"模型名重复：{entry.name}",
            )
        else:
            seen[entry.name] = idx + 1

    result.ok = len(result.errors) == 0
    return result


def _validate_model_entry(raw: Dict[str, Any], idx: int) -> tuple[ModelEntry, List[Issue], List[Issue]]:
    errs: List[Issue] = []
    warns: List[Issue] = []
    path = f"{S.MODEL_TABLE}[{idx}]"

    for fld in S.MODEL_REQUIRED:
        if fld not in raw:
            errs.append(Issue(f"{path}.{fld}", E_MISSING_FIELD, f"缺少必填字段：{fld}"))

    name = _as_str(raw.get("name"), "name", path, errs) or f"#{idx}"
    source = _as_str(raw.get("source"), "source", path, errs)
    version = _as_str(raw.get("version"), "version", path, errs)
    license_str = _as_str(raw.get("license"), "license", path, errs)
    sha = _as_str(raw.get("sha256"), "sha256", path, errs)
    purpose = _as_str(raw.get("purpose"), "purpose", path, errs)

    entry = ModelEntry(
        name=str(name), source=str(source or ""), version=str(version or ""),
        license=str(license_str or ""), sha256=str(sha or ""), purpose=str(purpose or ""),
    )

    if source is not None and not _is_registered_source(source):
        host = _host_of(source) or "<无法解析主机>"
        errs.append(Issue(
            f"{path}.source", E_UNKNOWN_SOURCE,
            f"模型来源未登记：{source}（主机 {host} 不在 SOURCE_REGISTRY 白名单）",
        ))

    if license_str is not None:
        ok, tier, err = _validate_spdx(license_str, path, errs)
        entry.license_valid = ok
        entry.license_tier = tier
        entry.license_error = err

    if sha is not None and not S.SHA256_RE.match(sha):
        errs.append(Issue(
            f"{path}.sha256", E_BAD_SHA256,
            f"sha256 必须是 64 位十六进制字符串，实际长度 {len(sha)}",
        ))

    if "inputs" in raw and isinstance(raw["inputs"], list):
        entry.inputs = raw["inputs"]
    if "outputs" in raw and isinstance(raw["outputs"], list):
        entry.outputs = raw["outputs"]
    if "target_precision" in raw and isinstance(raw["target_precision"], str):
        entry.target_precision = raw["target_precision"]
    if "estimated_latency_ms" in raw and isinstance(raw["estimated_latency_ms"], (int, float)):
        entry.estimated_latency_ms = float(raw["estimated_latency_ms"])
    if "platforms" in raw:
        pl = _as_list_of_str(raw["platforms"], "platforms", path, errs)
        if pl is not None:
            entry.platforms = pl
    if "notes" in raw and isinstance(raw["notes"], str):
        entry.notes = raw["notes"]

    return entry, errs, warns


# --------------------------------------------------------------------------
# 序列化便捷
# --------------------------------------------------------------------------
def to_json(result: ManifestResult, indent: int = 2) -> str:
    return json.dumps(result.to_dict(), indent=indent, ensure_ascii=False)


__all__ = [
    "parse_text", "parse_file", "to_json", "ManifestResult",
    "DepEntry", "ModelEntry", "Artifact", "Issue",
]
