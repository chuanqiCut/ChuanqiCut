#!/usr/bin/env python3
"""docs/ 内 Markdown 相对链接与本地路径引用完整性检查。

检查两类引用（TASK-DOC-001 验收，ADR-0019 §8）：
1. docs/**.md 中的 Markdown 相对链接 [text](target) —— 相对于所在文件解析
2. docs/**.md 与 .ai/**.md 中反引号包裹的 `docs/**.md` 路径 —— 相对仓库根解析

刻意不查（避免噪音）：目录引用（尾随 /）、ID 式引用（无 .md 后缀）、占位符
（含 * < > ~、ADR-000x）、纯文本伪链接（目标既无 / 也无 .）。
退出码：0 = 全部可达；1 = 存在断链（打印清单）。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCAN_DIRS = ["docs", ".ai"]
MD_LINK = re.compile(r"\[[^\]]*\]\(([^)#\s]+)(?:#[^)]*)?\)")
BACKTICK_PATH = re.compile(r"`([^`\s]+\.md)`")
PLACEHOLDER = re.compile(r"[~*<>]|\b000x\b|\.\.\.")


def is_prose(target: str) -> bool:
    """伪链接：不是路径（无 / 且无 .），如 [PhotosPickerItem](按用户选择顺序)。"""
    return "/" not in target and "." not in target


broken: list[str] = []


def check(f: Path, target: str, base: Path, kind: str) -> None:
    if target.startswith(("http://", "https://", "mailto:")) or is_prose(target):
        return
    if target.endswith("/") or PLACEHOLDER.search(target):
        return
    if not (base / target).exists():
        broken.append(f"{f.relative_to(ROOT)}: {kind}断 -> {target}")


for d in SCAN_DIRS:
    for f in sorted((ROOT / d).rglob("*.md")):
        text = f.read_text(encoding="utf-8")
        for m in MD_LINK.finditer(text):
            check(f, m.group(1), f.parent, "链接")
        for m in BACKTICK_PATH.finditer(text):
            t = m.group(1)
            if t.startswith(("docs/", "../")):
                base = ROOT if t.startswith("docs/") else f.parent
                check(f, t, base, "路径")

if broken:
    print(f"❌ {len(broken)} 处断链：")
    for b in broken:
        print("  " + b)
    sys.exit(1)
print("✅ docs/ 与 .ai/ 全部 Markdown 链接与 .md 路径引用可达")
