#!/usr/bin/env python3
"""engine/bindings/swift/Sources/CChuanqiCut/include/cq_sdk.h → docs/api/engine-api.md

接口展示生成器（传哲「展示头文件接口可以单独搞个展示逻辑」）：
解析 C ABI 头文件的 ===大节 / ----子节 注释结构与顶层声明，生成 Markdown 接口参考。
头文件是唯一真源；只读头文件、只写一个 md。用法：
  python3 tools/docs/gen_api_reference.py [--check]   # --check 供门禁比对是否过期
"""
import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HEADER = ROOT / "engine/bindings/swift/Sources/CChuanqiCut/include/cq_sdk.h"
OUT = ROOT / "docs/api/engine-api.md"

MAJOR_RE = re.compile(r"/\* =+\n \* (.+?)\n \* =+\n(?: \*.*\n)* \*/")
SUB_RE = re.compile(r"/\* ---- (.+?) ----.*?\*/")
FUNC_RE = re.compile(
    r"^(?:typedef[^\n{;]*|(?:(?:const )?(?:int32_t|int64_t|uint32_t|uint64_t|void|char|double|float|bool)"
    r"|(?:const )?CQ\w+ ?\*+)[\w \*\(\),\[\]]*?)\b(cq_\w+|CQ\w+)\s*\([^;{}]*\)\s*;",
    re.M,
)
STRUCT_RE = re.compile(r"typedef struct\s+(\w+)\s*\{[^}]*\}\s*\1;", re.S)
SIMPLE_TYPEDEF_RE = re.compile(r"^typedef[^;{}]*;\s*$", re.M)


def strip_comments_keep_len(text: str) -> str:
    """把块/行注释替换成等长空白：偏移量与原文对齐（段落归属判定用）。"""
    text = re.sub(r"/\*.*?\*/", lambda m: re.sub(r"[^\n]", " ", m.group()), text, flags=re.S)
    text = re.sub(r"//[^\n]*", lambda m: " " * len(m.group()), text)
    return text


def line_of(offset: int, stripped: str) -> int:
    return stripped.count("\n", 0, offset)


def preceding_doc(original: str, decl_line: int) -> list[str]:
    """decl_line 上一行向上收集紧邻的块注释文本（允许空行），返回 doc 行列表。"""
    lines = original.splitlines()
    j = decl_line - 1
    while j >= 0 and lines[j].strip() == "":
        j -= 1
    if j < 0 or not lines[j].rstrip().endswith("*/") or "/*" not in lines[j]:
        # 注释尾行可能形如 " */" 或 "... */"
        return []
    block = []
    k = j
    while k >= 0:
        line = lines[k]
        block.append(line.strip().strip("/*").strip(" *\t"))
        if "/*" in line:
            break
        if len(block) > 30:
            return []
        k -= 1
    return [b for b in reversed(block) if b]


def parse_header(original: str):
    stripped = strip_comments_keep_len(original)
    lines = original.splitlines()

    # 段落锚点（行号 → 标题）
    anchors = []  # (line, title, is_major)
    for m in MAJOR_RE.finditer(original):
        anchors.append((line_of(m.start(), original), m.group(1).strip(), True))
    for m in SUB_RE.finditer(original):
        anchors.append((line_of(m.start(), original), m.group(1).strip(), False))
    anchors.sort()

    def section_of(ln):
        major, sub = "（未分组）", None
        for a_ln, title, is_major in anchors:
            if a_ln > ln:
                break
            if is_major:
                major, sub = title, None
            else:
                sub = title
        return major, sub

    # 声明收集（函数 + typedef struct + 简单 typedef）
    decls = []
    for m in FUNC_RE.finditer(stripped):
        sig = re.sub(r"\s+", " ", m.group()).strip()
        ln = line_of(m.start(), stripped)
        decls.append((ln, sig, preceding_doc(original, ln)))
    for m in STRUCT_RE.finditer(stripped):
        ln = line_of(m.start(), stripped)
        decls.append((ln, re.sub(r"\s+", " ", m.group()), preceding_doc(original, ln)))

    decls.sort(key=lambda x: x[0])

    sections = []
    for ln, sig, doc in decls:
        major, sub = section_of(ln)
        sec = next((s for s in sections if s["title"] == major), None)
        if sec is None:
            sec = {"title": major, "items": []}
            sections.append(sec)
        sec["items"].append((sub, sig, doc))
    return sections


def render(sections) -> str:
    out = ["# ChuanqiCutEngine 公共接口参考（C ABI）", "",
           "> 由 `tools/docs/gen_api_reference.py` 从",
           "> `engine/bindings/swift/Sources/CChuanqiCut/include/cq_sdk.h` 自动生成",
           "> ——**不要手改本文件**；接口变更后重跑生成器。红线 #7：这是唯一对外接口。", ""]
    for sec in sections:
        subs = {}
        for sub, sig, doc in sec["items"]:
            subs.setdefault(sub, []).append((sig, doc))
        out.append(f"## {sec['title']}")
        out.append("")
        for sub, items in subs.items():
            if sub:
                out.append(f"### {sub}")
                out.append("")
            for sig, doc in items:
                if doc:
                    out.append("```text")
                    out += doc
                    out.append("```")
                    out.append("")
                out.append("```c")
                out.append(sig)
                out.append("```")
                out.append("")
    return "\n".join(out) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    sections = parse_header(HEADER.read_text())
    text = render(sections)
    if args.check:
        if not OUT.exists() or OUT.read_text() != text:
            print("engine-api.md 过期：重跑 python3 tools/docs/gen_api_reference.py", file=sys.stderr)
            return 1
        print("engine-api.md 与 cq_sdk.h 一致")
        return 0
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text)
    n = sum(len(sec["items"]) for sec in sections)
    print(f"生成 {OUT.relative_to(ROOT)}（{len(sections)} 节 / {n} 条声明）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
