"""deps.lock 的生成与校验（DEPS-002）。

设计要点
--------
1. deps.lock 由本工具生成，人手改动必须被 `check` 检测出来并失败。
   双保险：
     (a) 摘要防篡改（lock_digest）：对规范化后的锁定内容做 sha256，写入 lock 文件。
         `check` 重算摘要并与磁盘值比对，任何手改（commit / sha256 / version …）都会
         让摘要失配 → 失败。这是「手改检出」的核心机制（team-lead 明确要求）。
     (b) 语义一致性：`check` 以 manifest 的 pin_ref / artifact 为真源，确定性地重算
         「期望 lock」，再与磁盘 lock 逐字段比对。manifest 被改或 lock 被改都会失配。
   两者互补：摘要保证「这份 lock 文件字节级没被碰过」，语义保证「lock 与 manifest 没脱节」。

2. 锁定内容按 integration：
     source       → 不可变 commit（直接取自 manifest 的 pin_ref，离线、确定）+ 本地 patch 清单（path + sha256）
     auto         → 同时锁 commit（pin_ref）与每条 artifact 的 sha256 + size_bytes
     binary       → 每条 artifact 的 sha256 + size_bytes
   scope=build 的工具链（glslang / SPIRV-Cross / googletest）同样锁定（commit 路径），
   以保证不同构建机的工具版本一致、shader 产物可复现。

3. 占位 sha256（全同字符，如全 0/全 1/全 2，或哨兵词）一律拒绝；
   可用 --allow-placeholder 放行，但条目会打 lock_state=placeholder，
   check（严格模式）仍会失败 —— 不能带着占位进入构建。

4. 输出确定性：dep 按 name 升序、字段顺序固定、artifacts 按 platform 升序、
   patches 按 path 升序、无时间戳、无集合遍历。多人并行只动各自依赖时，
   各自 regen 出的 lock 在排序后是 canonical 的，冲突解决 = 重新跑一次 lock。

5. **不要提交占位版本的 deps.lock**。带 placeholder 标记的 lock 会让 CI 长期红，
   而「提交即失败」的门禁会训练所有人无视红色 —— 比没有门禁更糟。
   正确节奏：等 DEPS-010/011 拿到真实二进制 sha256 后，重跑
   `python3 tools/deps/deps.py lock <manifest>`（不带 --allow-placeholder）生成干净版本再提交。
   deps.lock 是 `lock` 一键 regenerate 的产物，删了也无妨。

6. upstream commit 存在性核对（ADR-0008「commit 须能在 canonical upstream 找到」）**不**在此做。
   原因：`git ls-remote <url> <sha>` 对历史 commit（非 ref tip）在 GitHub 上返回空，列出全部 ref
   又只能看到 ref tip，轻量网络检查会误杀合法历史 commit。正确落点是构建期实际
   `git fetch`/`checkout` 该 pin_ref（DEPS-010/011）：拉取成功既证明 commit 真实存在，也证明它是
   一个可完整构建的来源 —— 比单纯「存在性」更强。因此本模块不引入会误杀的门禁。

仅使用 Python 标准库。
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import tomllib
from typing import Any, Dict, List, Optional, Tuple

# lock 文件自身的 schema 版本，为将来的迁移器链（ADR-0006）留位置
LOCK_SCHEMA_VERSION = "1.0"

# --------------------------------------------------------------------------
# 占位 sha256 检测
# --------------------------------------------------------------------------
_HEX = set("0123456789abcdefABCDEF")
_PLACEHOLDER_WORDS = {"placeholder", "todo", "unresolved", "none", "n/a"}


def is_placeholder_sha256(s: str) -> bool:
    """全同字符（如 0000…/1111…/2222…/ffff…）或明显哨兵词 → 视为占位。"""
    if not s:
        return False
    if s.lower() in _PLACEHOLDER_WORDS:
        return True
    if len(s) == 64 and len(set(s)) == 1 and set(s) <= _HEX:
        return True
    return False


_COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")  # 完整 git SHA-1


# --------------------------------------------------------------------------
# resolver：可选的 commit 覆盖（bump 流程用，--commit / --resolve）
# --------------------------------------------------------------------------
def load_resolver_file(path: str) -> Dict[str, Dict[str, str]]:
    """读取 [[resolved]] 表：name = commit [resolved_ref = ...]。"""
    with open(path, "rb") as f:
        data = tomllib.load(f)
    out: Dict[str, Dict[str, str]] = {}
    for row in data.get("resolved", []):
        if not isinstance(row, dict) or "name" not in row or "commit" not in row:
            raise ValueError(f"resolver 条目缺少 name/commit：{row!r}")
        out[row["name"]] = {"commit": row["commit"], "resolved_ref": row.get("resolved_ref", "")}
    return out


def parse_commit_args(args: List[str]) -> Dict[str, Dict[str, str]]:
    """解析 --commit name=hash 形式的参数。"""
    out: Dict[str, Dict[str, str]] = {}
    for a in args:
        if "=" not in a:
            raise ValueError(f"--commit 参数格式应为 name=hash，得到：{a!r}")
        name, _, h = a.partition("=")
        out[name] = {"commit": h, "resolved_ref": ""}
    return out


def build_resolver(manifest_dir: str, resolve_path: Optional[str],
                   commit_args: List[str]) -> Dict[str, Dict[str, str]]:
    res: Dict[str, Dict[str, str]] = {}
    if resolve_path:
        res.update(load_resolver_file(resolve_path))
    res.update(parse_commit_args(commit_args))
    return res


# --------------------------------------------------------------------------
# upstream 完整性核对（ADR-0008「commit 必须能在 canonical upstream 找到」）
# --------------------------------------------------------------------------
# 注意：这一步**不**在 lock/check 里做，原因：
#   - `git ls-remote <url> <sha>` 对历史 commit（非 ref tip）在 GitHub 上返回空，
#     列出所有 ref 又只能看到 ref tip，无法确认某个历史 commit 真实存在；
#   - 轻量、确定、可离线才是 lock/check 的硬约束。
# 正确落点是在构建期实际 checkout/fetch 该 pin_ref（DEPS-010/011）：拉取成功即证明
# commit 存在，失败即报错。因此本模块不引入会误杀合法历史 commit 的网络门禁。
# --------------------------------------------------------------------------


# --------------------------------------------------------------------------
# 文件哈希（patch 用）
# --------------------------------------------------------------------------
def sha256_of_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


# --------------------------------------------------------------------------
# lock 生成
# --------------------------------------------------------------------------
def generate_lock(manifest_result, resolver: Dict[str, Dict[str, str]],
                  manifest_dir: str, allow_placeholder: bool = False,
                  allow_unresolved: bool = False) -> Tuple[Dict[str, Any], List[str]]:
    """从已解析的 manifest 生成期望的 lock 字典。

    返回 (lock_dict, hard_errors)。hard_errors 非空表示无法生成（调用方应中止写盘）：
      - source/auto 依赖无 commit（理论上是 parser 已拦，这里兜底）
      - 未开 --allow-placeholder 时遇到占位 sha256
      - （可选）--verify-upstream 时 commit 在 upstream 不可达
    """
    errors: List[str] = []
    locked: List[Dict[str, Any]] = []

    for dep in sorted(manifest_result.entries, key=lambda d: d.name):
        e: Dict[str, Any] = {
            "name": dep.name,
            "version": dep.version,
            "integration": dep.integration,
            "scope": dep.scope,
        }
        if dep.profile:
            e["profile"] = dep.profile

        is_source = dep.integration in ("source", "auto")

        # ---- commit 锁定（source / auto）----
        if is_source:
            commit = None
            if dep.name in resolver:
                commit = resolver[dep.name].get("commit")
            if not commit:
                commit = dep.pin_ref  # manifest 已声明且 parser 已校验为 40-hex
            if not commit:
                if not allow_unresolved:
                    errors.append(
                        f"{dep.name}: 无法锁定 commit（pin=commit 但 pin_ref 缺失；"
                        f"请声明 pin_ref，或用 --commit {dep.name}=HASH 覆盖）")
                    continue
                e["lock_state"] = "unresolved"
                e["commit"] = "UNRESOLVED"
                e["resolved_ref"] = ""
                e["patches"] = []
            else:
                e["commit"] = commit
                e["resolved_ref"] = commit
                e["lock_state"] = "locked"
                patches = []
                for p in sorted(dep.patches):
                    fpath = os.path.join(manifest_dir, p)
                    if not os.path.isfile(fpath):
                        errors.append(f"{dep.name}: patch 文件不存在，无法哈希：{p}")
                        continue
                    patches.append({"path": p, "sha256": sha256_of_file(fpath)})
                e["patches"] = patches
        else:
            e["lock_state"] = "locked"

        # ---- artifact 锁定（binary / auto）----
        if dep.artifacts:
            arts: List[Dict[str, Any]] = []
            any_ph = False
            for a in sorted(dep.artifacts, key=lambda x: x.platform):
                if is_placeholder_sha256(a.sha256):
                    if not allow_placeholder:
                        errors.append(
                            f"{dep.name}.artifact({a.platform}).sha256 为占位值"
                            f"（{a.sha256[:8]}…），lock 拒绝；请先填入真实校验和")
                        continue
                    any_ph = True
                arts.append({
                    "platform": a.platform,
                    "url": a.url,
                    "sha256": a.sha256,
                    **({"size_bytes": a.size_bytes} if a.size_bytes is not None else {}),
                })
            e["artifacts"] = arts
            # source/auto 已有 commit 的 lock_state；若 artifact 含占位则降级为 placeholder
            if any_ph:
                e["lock_state"] = "placeholder"
        elif not is_source:
            e["artifacts"] = []

        locked.append(e)

    lock = {
        "schema_version": LOCK_SCHEMA_VERSION,
        "generator": "tools/deps/deps.py",
        "locked": locked,
    }
    # 防篡改摘要：覆盖规范化内容（不含 lock_digest 自身）
    lock["lock_digest"] = compute_digest(lock)
    return lock, errors


# --------------------------------------------------------------------------
# 确定性 TOML 输出
# --------------------------------------------------------------------------
def _toml_scalar(v: Any) -> str:
    if isinstance(v, str):
        return json.dumps(v)  # 双引号 + 转义，合法 TOML 字符串
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if v is None:
        return "null"
    raise TypeError(f"无法序列化为 TOML 标量：{v!r}")


def _inline_table(d: Dict[str, Any], order: List[str]) -> str:
    parts = ", ".join(f"{k} = {_toml_scalar(d[k])}" for k in order if k in d and d[k] is not None)
    return "{" + parts + "}"


def emit_lock_toml(lock: Dict[str, Any]) -> str:
    """生成确定性 TOML 文本：注释固定、字段顺序固定、dep 按 name 升序。"""
    L: List[str] = []
    L.append("# ChuanqiCut dependency lock — GENERATED, do not edit by hand.")
    L.append("# Regenerate: python3 tools/deps/deps.py lock <manifest>")
    L.append("# 确定性输出（按 name 升序、字段顺序固定）；schema_version 预留迁移器链。")
    L.append("# lock_digest 为防篡改摘要，任何手改都会让 check 失败。")
    L.append(f'schema_version = {_toml_scalar(lock["schema_version"])}')
    L.append(f'generator = {_toml_scalar(lock["generator"])}')
    L.append(f'lock_digest = {_toml_scalar(lock["lock_digest"])}')
    L.append("")
    for e in lock["locked"]:
        L.append("[[locked]]")
        L.append(f'name = {_toml_scalar(e["name"])}')
        L.append(f'version = {_toml_scalar(e["version"])}')
        L.append(f'integration = {_toml_scalar(e["integration"])}')
        L.append(f'scope = {_toml_scalar(e["scope"])}')
        if e.get("profile"):
            L.append(f'profile = {_toml_scalar(e["profile"])}')
        if e["integration"] in ("source", "auto"):
            L.append(f'resolved_ref = {_toml_scalar(e["resolved_ref"])}')
            L.append(f'commit = {_toml_scalar(e["commit"])}')
            patches = e.get("patches", [])
            if patches:
                L.append("patches = [")
                for p in patches:
                    L.append("  " + _inline_table(p, ["path", "sha256"]) + ",")
                L.append("]")
            else:
                L.append("patches = []")
        # artifacts：binary 必有；auto 可能同时带二进制路径（如 ffmpeg 预编译产物）
        arts = e.get("artifacts")
        if arts:
            L.append("artifacts = [")
            for a in arts:
                L.append("  " + _inline_table(a, ["platform", "url", "sha256", "size_bytes"]) + ",")
            L.append("]")
        elif e["integration"] not in ("source", "auto"):
            L.append("artifacts = []")
        L.append(f'lock_state = {_toml_scalar(e["lock_state"])}')
        L.append("")
    return "\n".join(L)


def write_lock(path: str, text: str) -> None:
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
        if not text.endswith("\n"):
            f.write("\n")


# --------------------------------------------------------------------------
# 防篡改摘要（规范化 → sha256）
# --------------------------------------------------------------------------
def _canonical_locked(lock: Dict[str, Any]) -> Dict[str, Any]:
    """把 lock 转为与顺序无关的规范化结构，用于稳定摘要 / 比对。"""
    out_entries = []
    for e in sorted(lock.get("locked", []), key=lambda x: x["name"]):
        ne: Dict[str, Any] = {}
        for k in ("name", "version", "integration", "scope", "profile",
                  "resolved_ref", "commit", "lock_state"):
            if k in e and e[k] is not None:
                ne[k] = e[k]
        if "patches" in e:
            ne["patches"] = {
                p["path"]: {"path": p["path"], "sha256": p["sha256"]}
                for p in sorted(e["patches"], key=lambda p: p["path"])
            }
        if "artifacts" in e:
            na: Dict[str, Any] = {}
            for a in e["artifacts"]:
                na[a["platform"]] = {
                    k: a[k] for k in ("platform", "url", "sha256", "size_bytes")
                    if a.get(k) is not None
                }
            ne["artifacts"] = na
        out_entries.append(ne)
    return {"schema_version": lock.get("schema_version"), "locked": out_entries}


def compute_digest(lock: Dict[str, Any]) -> str:
    """对规范化内容做 sha256（不含 lock_digest 字段本身，避免循环）。"""
    canon = _canonical_locked(lock)
    blob = json.dumps(canon, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


def verify_digest(disk: Dict[str, Any]) -> Tuple[bool, str]:
    """校验磁盘 lock 的 lock_digest 与其内容是否一致（防篡改）。"""
    if "lock_digest" not in disk:
        return False, "lock 缺少 lock_digest（可能被手改，或来自旧格式）"
    expected = compute_digest(disk)
    if expected != disk["lock_digest"]:
        return False, (f"lock_digest 失配 —— lock 内容被改动："
                       f"期望 {expected[:16]}…，磁盘 {disk['lock_digest'][:16]}…")
    return True, ""


# --------------------------------------------------------------------------
# lock 解析 + 比对
# --------------------------------------------------------------------------
def parse_lock_file(path: str) -> Dict[str, Any]:
    with open(path, "rb") as f:
        return tomllib.load(f)


def canonicalize(locked: List[Dict[str, Any]]) -> Dict[str, Dict[str, Any]]:
    """把 artifacts/patches 数组归一为按 key 的字典，便于稳定比对（忽略 None）。"""
    out: Dict[str, Dict[str, Any]] = {}
    for e in locked:
        ne = {k: v for k, v in e.items() if v is not None}
        if isinstance(ne.get("artifacts"), list):
            ne["artifacts"] = {
                a["platform"]: {k: v for k, v in a.items() if v is not None}
                for a in ne["artifacts"]
            }
        if isinstance(ne.get("patches"), list):
            ne["patches"] = {
                p["path"]: {k: v for k, v in p.items() if v is not None}
                for p in ne["patches"]
            }
        out[e["name"]] = ne
    return out


def _diff(prefix: str, a: Any, b: Any, out: List[str]) -> None:
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b)):
            if k not in a:
                out.append(f"  {prefix}.{k}: 磁盘有值 {b[k]!r}，期望缺失")
            elif k not in b:
                out.append(f"  {prefix}.{k}: 期望 {a[k]!r}，磁盘缺失")
            else:
                _diff(f"{prefix}.{k}", a[k], b[k], out)
    elif isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            out.append(f"  {prefix}: 数组长度 期望 {len(a)} != 磁盘 {len(b)}")
        else:
            for i, (x, y) in enumerate(zip(a, b)):
                _diff(f"{prefix}[{i}]", x, y, out)
    else:
        if a != b:
            out.append(f"  {prefix}: 期望 {a!r} != 磁盘 {b!r}")


def diff_lock(expected: Dict[str, Any], disk: Dict[str, Any]) -> List[str]:
    out: List[str] = []
    exp = canonicalize(expected.get("locked", []))
    act = canonicalize(disk.get("locked", []))
    for name in sorted(set(exp) | set(act)):
        if name not in exp:
            out.append(f"lock 多出未声明条目：{name}")
        elif name not in act:
            out.append(f"lock 缺失条目：{name}")
        else:
            _diff(f"locked[{name}]", exp[name], act[name], out)
    if expected.get("schema_version") != disk.get("schema_version"):
        out.append(f"schema_version: 期望 {expected.get('schema_version')} "
                   f"!= 磁盘 {disk.get('schema_version')}")
    # 不允许把未锁定 / 占位的条目带入构建
    for e in disk.get("locked", []):
        if e.get("lock_state") in ("unresolved", "placeholder"):
            out.append(f"locked[{e['name']}].lock_state = {e['lock_state']}："
                       f"不允许进入构建（需先解析真实 commit / 真实 sha256）")
    return out


def check_lock(manifest_result, resolver: Dict[str, Dict[str, str]],
               lock_path: str, manifest_dir: str) -> Tuple[bool, List[str]]:
    """校验 manifest 与 lock 一致（CI 门禁入口）。

    双保险：
      1) 摘要防篡改：磁盘 lock 的 lock_digest 必须与其内容一致。
      2) 语义一致：以 manifest 真源重算期望 lock，与磁盘逐字段比对。
    严格模式：占位 / 未解析的条目均判失败。
    """
    if not os.path.isfile(lock_path):
        return False, [f"lock 文件不存在：{lock_path}"]
    try:
        disk = parse_lock_file(lock_path)
    except Exception as e:
        return False, [f"lock 文件解析失败：{e}"]

    diffs: List[str] = []

    # 1) 防篡改摘要
    digest_ok, digest_msg = verify_digest(disk)
    if not digest_ok:
        diffs.append(digest_msg)

    # 2) 语义一致性（manifest 为唯一真源，离线、确定）
    expected, hard_errors = generate_lock(
        manifest_result, resolver, manifest_dir,
        allow_placeholder=False, allow_unresolved=False)
    if hard_errors:
        return False, ["manifest 当前无法生成合法 lock："] + hard_errors

    diffs.extend(diff_lock(expected, disk))
    return (len(diffs) == 0), diffs


__all__ = [
    "LOCK_SCHEMA_VERSION", "is_placeholder_sha256", "load_resolver_file",
    "parse_commit_args", "build_resolver",
    "sha256_of_file", "generate_lock", "emit_lock_toml", "write_lock",
    "compute_digest", "verify_digest", "parse_lock_file", "check_lock",
]
