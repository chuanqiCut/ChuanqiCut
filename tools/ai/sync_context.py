#!/usr/bin/env python3
"""
同步 AI 工具入口文件。

单一真源：.ai/source/AGENTS.root.md
生成产物：AGENTS.md / CLAUDE.md / .cursorrules / .github/copilot-instructions.md / .windsurfrules

用法:
    python3 tools/ai/sync_context.py           # 生成
    python3 tools/ai/sync_context.py --check   # 只校验一致性（CI 用），不一致则退出码 1
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / ".ai" / "source" / "AGENTS.root.md"
ENTRIES_DIR = ROOT / ".ai" / "source" / "entries"

GENERATED_MARK = "<!-- GENERATED"

# 目标文件 → 模板文件。AGENTS.md 特殊：直接由真源全文生成。
TARGETS: dict[str, str] = {
    "CLAUDE.md": "CLAUDE.md.tpl",
    ".cursorrules": ".cursorrules.tpl",
    ".github/copilot-instructions.md": "copilot-instructions.md.tpl",
    ".windsurfrules": ".windsurfrules.tpl",
}

HEADER = "{mark} from .ai/source/AGENTS.root.md — DO NOT EDIT -->"


def build_agents_md(root_text: str) -> str:
    """AGENTS.md 是通用入口，直接承载真源全文，避免二次跳转。"""
    header = HEADER.format(mark="<!-- GENERATED")
    return f"{header}\n{root_text}"


def build_entry(tpl_text: str) -> str:
    header = HEADER.format(mark="<!-- GENERATED")
    return f"{header}\n{tpl_text}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="只校验，不写入")
    args = parser.parse_args()

    if not SOURCE.exists():
        print(f"[sync-context] 缺少真源: {SOURCE}", file=sys.stderr)
        return 1

    root_text = SOURCE.read_text(encoding="utf-8").rstrip() + "\n"

    expected: dict[Path, str] = {
        ROOT / "AGENTS.md": build_agents_md(root_text),
    }
    for target, tpl_name in TARGETS.items():
        tpl_path = ENTRIES_DIR / tpl_name
        if not tpl_path.exists():
            print(f"[sync-context] 缺少模板: {tpl_path}", file=sys.stderr)
            return 1
        expected[ROOT / target] = build_entry(
            tpl_path.read_text(encoding="utf-8").rstrip() + "\n"
        )

    if args.check:
        drifted = []
        for path, content in expected.items():
            if not path.exists() or path.read_text(encoding="utf-8") != content:
                drifted.append(str(path.relative_to(ROOT)))
        if drifted:
            print("[sync-context] 以下入口文件与真源不一致，请运行 "
                  "python3 tools/ai/sync_context.py:", file=sys.stderr)
            for d in drifted:
                print(f"  - {d}", file=sys.stderr)
            return 1
        print("[sync-context] 所有入口文件与真源一致")
        return 0

    for path, content in expected.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        print(f"[sync-context] 已生成 {path.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
