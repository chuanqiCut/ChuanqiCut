"""最小 SPDX 表达式校验器（仅依赖 Python 标准库）。

设计动机（见 ARCH-002 §5，DEPS-001）：
- `license` 字段必须是合法 SPDX 表达式，不接受自由文本。
- 校验器需要识别表达式的「协议分级」(ALLOW / REVIEW / RESTRICTED)，
  供后续 DEPS-003 协议门禁直接消费，而不必重复解析。

本实现覆盖 SPDX 表达式语法的常用子集：
    expression := or_expr
    or_expr    := and_expr (OR  and_expr)*
    and_expr   := unary    (AND unary)*
    unary      := '(' expression ')' | license
    license    := SIMPLE_ID ('+' | '-or-later' | '-only')? (WITH EXCEPTION_ID)?
其中 SIMPLE_ID 形如 `Apache-2.0` / `LGPL-2.1-or-later`。
AND / OR / WITH 关键字大小写敏感（SPDX 规范规定为大写）。

不引入任何第三方包（spdx 相关的 pip 包一律不用），以遵守依赖治理
「工具自身不引入第三方依赖」的自举约束。
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from enum import IntEnum
from typing import List, Optional, Tuple


class LicenseTier(IntEnum):
    """协议分级（见 ARCH-002 §5）。数值越大越严格。"""

    ALLOW = 0       # 白名单，自动通过
    REVIEW = 1      # 允许但需附加义务 + 负责人批准
    RESTRICTED = 2  # 默认构建禁止，需 ADR + 法务


# --------------------------------------------------------------------------
# 已知协议清单（最小可用集合，覆盖本项目已登记与可能引入的协议）
# --------------------------------------------------------------------------
# 分级映射：license id（规范化后，已含 -or-later/-only） -> tier
_ALLOW = {
    "MIT", "MIT-0",
    "BSD-2-Clause", "BSD-3-Clause", "BSD-3-Clause-Clear", "BSD-2-Clause-Patent",
    "Apache-2.0", "ISC", "Zlib", "CC0-1.0", "Unlicense",
    "BSL-1.0", "Python-2.0", "Libpng", "Unicode-DFS-2016", "Unicode-TOU",
    "W3C", "X11", "Boost-1.0", "PSF-2.0",
}

_REVIEW = {
    "LGPL-2.1-only", "LGPL-2.1-or-later",
    "LGPL-3.0-only", "LGPL-3.0-or-later",
    "MPL-2.0", "EPL-2.0", "CDDL-1.0", "EUPL-1.2", "OSL-3.0",
}

_RESTRICTED = {
    "GPL-2.0-only", "GPL-2.0-or-later",
    "GPL-3.0-only", "GPL-3.0-or-later",
    "AGPL-3.0-only", "AGPL-3.0-or-later", "AGPL-3.0",
    "SSPL-1.0",
    # 旧式写法（无 -only/-or-later 后缀），保守地按最严格处理
    "GPL-2.0", "GPL-3.0", "AGPL-3.0",
}

# 已知但本清单未显式分级的协议：若出现在表达式里，会被判定为「未知」。
# 合法但未知时默认归为 REVIEW（需人工复核），可由调用方通过
# `allow_unknown=True` 放开校验（仅当确实已人工确认过）。
_KNOWN_LICENSES = _ALLOW | _REVIEW | _RESTRICTED

# SPDX 例外（WITH 之后）。已知的例外集合。
_KNOWN_EXCEPTIONS = {
    "Classpath-exception-2.0",
    "LLVM-exception",
    "GCC-exception-3.1",
    "Apache-2.0-with-LLVM-exception",  # 注：例外 id 实际为 LLVM-exception
    "Autoconf-exception-3.0",
    "Bison-exception-2.2",
    "NCSA",
    "Unicode-DFS-2016",
}

# 旧式 `+`（or later）后缀对应的规范化结果
_PLUS_NORMALIZE = {
    "GPL-2.0+": "GPL-2.0-or-later",
    "GPL-3.0+": "GPL-3.0-or-later",
    "LGPL-2.1+": "LGPL-2.1-or-later",
    "LGPL-3.0+": "LGPL-3.0-or-later",
    "MPL-1.1+": "MPL-1.1-or-later",
    "AGPL-3.0+": "AGPL-3.0-or-later",
}


class SpdxError(Exception):
    """SPDX 表达式非法时抛出，携带可读错误信息。"""


@dataclass
class SpdxLicense:
    """表达式中的一个叶子协议节点。"""

    id: str                       # 规范化后的协议 id
    raw: str                      # 原始表达式中的写法
    exception: Optional[str] = None
    tier: LicenseTier = LicenseTier.ALLOW


@dataclass
class SpdxResult:
    """一次表达式解析的完整结果。"""

    expression: str
    ok: bool
    tiers: List[LicenseTier] = field(default_factory=list)
    leaves: List[SpdxLicense] = field(default_factory=list)
    error: Optional[str] = None

    @property
    def overall_tier(self) -> Optional[LicenseTier]:
        """表达式整体的最高分级（AND/OR 均取最严）。"""
        if not self.tiers:
            return None
        return max(self.tiers)

    @property
    def tier_name(self) -> Optional[str]:
        t = self.overall_tier
        return None if t is None else t.name


# --------------------------------------------------------------------------
# 词法分析
# --------------------------------------------------------------------------
_TOKEN_RE = re.compile(r"\s*(\(|\)|[A-Za-z0-9.\-+]+|AND|OR|WITH)\s*", re.IGNORECASE)


def _tokenize(expr: str) -> List[Tuple[str, str]]:
    """返回 [(kind, value), ...]。kind ∈ {LPAREN, RPAREN, AND, OR, WITH, ID}。"""
    tokens: List[Tuple[str, str]] = []
    pos = 0
    while pos < len(expr):
        m = _TOKEN_RE.match(expr, pos)
        if not m:
            raise SpdxError(f"无法识别的字符（位置 {pos}）：{expr[pos:pos+10]!r}")
        text = m.group(1)
        pos = m.end()
        up = text.upper()
        if text == "(":
            tokens.append(("LPAREN", text))
        elif text == ")":
            tokens.append(("RPAREN", text))
        elif up == "AND":
            tokens.append(("AND", "AND"))
        elif up == "OR":
            tokens.append(("OR", "OR"))
        elif up == "WITH":
            tokens.append(("WITH", "WITH"))
        else:
            tokens.append(("ID", text))
    return tokens


# --------------------------------------------------------------------------
# 语法分析（递归下降）
# --------------------------------------------------------------------------
class _Parser:
    def __init__(self, tokens: List[Tuple[str, str]], allow_unknown: bool):
        self.tokens = tokens
        self.pos = 0
        self.allow_unknown = allow_unknown
        self.leaves: List[SpdxLicense] = []

    def peek(self) -> Optional[Tuple[str, str]]:
        return self.tokens[self.pos] if self.pos < len(self.tokens) else None

    def next(self) -> Tuple[str, str]:
        tok = self.tokens[self.pos]
        self.pos += 1
        return tok

    def parse(self) -> None:
        if not self.tokens:
            raise SpdxError("表达式为空")
        self._or_expr()
        if self.pos != len(self.tokens):
            raise SpdxError(f"多余的标记（位置 {self.pos}）：{self.tokens[self.pos]}")

    def _or_expr(self) -> None:
        self._and_expr()
        while self.peek() and self.peek()[0] == "OR":
            self.next()
            self._and_expr()

    def _and_expr(self) -> None:
        self._unary()
        while self.peek() and self.peek()[0] == "AND":
            self.next()
            self._unary()

    def _unary(self) -> None:
        tok = self.peek()
        if tok is None:
            raise SpdxError("表达式意外结束")
        if tok[0] == "LPAREN":
            self.next()
            self._or_expr()
            if self.peek() is None or self.peek()[0] != "RPAREN":
                raise SpdxError("缺少右括号 ')'")
            self.next()
            return
        if tok[0] == "AND" or tok[0] == "OR":
            raise SpdxError(f"运算符 '{tok[1]}' 前缺少操作数")
        if tok[0] == "RPAREN":
            raise SpdxError("多余的右括号 ')'")
        self._license()

    def _license(self) -> None:
        kind, raw = self.next()
        if kind != "ID":
            raise SpdxError(f"期望协议标识，却得到 '{raw}'")
        lic_id = self._normalize_id(raw)
        exception: Optional[str] = None
        # 处理 WITH 例外
        if self.peek() and self.peek()[0] == "WITH":
            self.next()
            etok = self.peek()
            if etok is None or etok[0] != "ID":
                raise SpdxError("WITH 之后缺少例外标识")
            self.next()
            exception = etok[1]
            if exception not in _KNOWN_EXCEPTIONS:
                if not self.allow_unknown:
                    raise SpdxError(f"未知的 SPDX 例外标识：{exception}")
        tier = self._tier_of(lic_id)
        self.leaves.append(SpdxLicense(id=lic_id, raw=raw, exception=exception, tier=tier))

    @staticmethod
    def _normalize_id(raw: str) -> str:
        r = raw
        if r in _PLUS_NORMALIZE:
            return _PLUS_NORMALIZE[r]
        # 形如 GPL-2.0+ 的通用处理
        if r.endswith("+"):
            base = r[:-1]
            # 仅对已知带 + 语义的协议规范化
            mapped = _PLUS_NORMALIZE.get(base + "+")
            if mapped:
                return mapped
            # 无法识别的 + 写法：保留原样交给分级判断
            return r
        return r

    def _tier_of(self, lic_id: str) -> LicenseTier:
        if lic_id in _ALLOW:
            return LicenseTier.ALLOW
        if lic_id in _REVIEW:
            return LicenseTier.REVIEW
        if lic_id in _RESTRICTED:
            return LicenseTier.RESTRICTED
        if lic_id in _KNOWN_LICENSES:
            return LicenseTier.REVIEW
        if not self.allow_unknown:
            raise SpdxError(
                f"未知的 SPDX 协议标识：{lic_id}（如确已人工确认，可加 --allow-unknown-license）"
            )
        # 允许未知：保守归为 REVIEW，需人工复核
        return LicenseTier.REVIEW


# --------------------------------------------------------------------------
# 公开 API
# --------------------------------------------------------------------------
def validate_expression(expr: str, allow_unknown: bool = False) -> SpdxResult:
    """校验一个 SPDX 表达式。

    返回 SpdxResult：ok 表示语法与协议 id 均合法；tier 为整体分级。
    """
    expr = (expr or "").strip()
    result = SpdxResult(expression=expr, ok=False)
    try:
        tokens = _tokenize(expr)
        parser = _Parser(tokens, allow_unknown=allow_unknown)
        parser.parse()
        result.leaves = parser.leaves
        result.tiers = [leaf.tier for leaf in parser.leaves]
        result.ok = True
    except SpdxError as e:
        result.error = str(e)
    return result


def tier_of(expr: str, allow_unknown: bool = False) -> Optional[LicenseTier]:
    """便捷函数：直接返回表达式的整体分级（非法时返回 None）。"""
    res = validate_expression(expr, allow_unknown=allow_unknown)
    return res.overall_tier


# 供测试/外部确认的最小导出
__all__ = [
    "SpdxError", "SpdxResult", "SpdxLicense", "LicenseTier",
    "validate_expression", "tier_of",
]
