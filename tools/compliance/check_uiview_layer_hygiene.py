#!/usr/bin/env python3
# ChuanqiCut — Apple 端「UIView 图层卫生」门禁扫描（UIA-042 期后新增，P131）
#
# 由来：2026-10-14 真机「进编辑页必现 SIGSEGV」—— `TimelineContentView.rebuild` 用
#   `layer.sublayers?.forEach { $0.removeFromSuperlayer() }` 全清自绘层，而 `layer` 是
#   UIView 的 backing layer，**子视图的 layer 也挂在里面**，被一起从树上拔掉 →
#   UIKit 仍持有该 view 而 layer 已离树 → CA 首次提交事务时 `superview` 读到野指针崩。
#   （完整复盘：docs/reviews/REVIEW-2026-10-14-进编辑页SIGSEGV复盘.md）
#
# 本脚本把「治理手段」落成机器可执行的规则，避免同类写法再次入库：
#
#   R1（FAIL）清空 UIView backing layer 的 sublayers：
#        layer.sublayers = nil / = []
#        layer.sublayers?.forEach { ... removeFromSuperlayer ... }
#        layer.sublayers?.removeAll() / removeAll(where:)
#        otherView.layer.sublayers = nil  （同类：动别人 view 的 backing layer）
#      → 自绘层一律挂**专用容器层**，清空只清容器层的 sublayers。
#
#   R2（WARN）同一文件里出现 ≥2 次 `layer.addSublayer(` —— 意味「自绘层直接与
#      UIView backing layer 混排」，建议收敛到一层容器层（R2 不计入失败）。
#
# 设计要点（对齐 tools/platform/check_platform_headers.py）：
#   * 匹配前**先剔除注释与行尾注释**，否则注释里引用反例就会误报（本仓库的
#     pitfalls/代码注释里确实写了反例文本，实测会误报，故必须剔除）。
#   * 纯标准库实现（无第三方依赖），可接入 CTest / CI / run_gate.sh。
#   * 排除 Pods / .build / build / vendor（第三方代码不在本门禁责任范围内）。
#
# 逃逸阀：确需清空的极少数场景，在该行加 `cq-allow: backing-layer-clear` 并写明理由
#         （评审时要能说出「该 UIView 确认没有任何子视图」）。
#
# 退出码：R1 命中 → 1；否则 0。输出格式：文件:行号: 规则: 命中内容: 原始行

import os
import re
import sys

# ---- 配置 ----
SCAN_EXTS = (".swift", ".m", ".mm")
EXCLUDE_DIR_PARTS = ("/Pods/", "/.build/", "/build/", "/vendor/", "/third_party/")

# R1：清空 backing layer 的 sublayers
#   接收者形态：`layer`（本类 UIView 的 backing layer）或 `xxx.layer` / `self.view.layer`
RECEIVER = r"(?:\blayer|[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\.layer)"
R1_PATTERNS = [
    # layer.sublayers = nil / = []
    (re.compile(RECEIVER + r"\.sublayers\s*=\s*(?:nil|\[\s*\])"), "backing-layer-clear(=nil/[])"),
    # layer.sublayers?.removeAll() / removeAll(where: ...)
    (re.compile(RECEIVER + r"\.sublayers\?\.removeAll\s*\("), "backing-layer-clear(removeAll)"),
    # layer.sublayers?.forEach { $0.removeFromSuperlayer() }（含跨行：整行内未闭合也算）
    (re.compile(RECEIVER + r"\.sublayers\?\.forEach\s*\{[^}]*removeFromSuperlayer"),
     "backing-layer-clear(forEach+removeFromSuperlayer)"),
    # layer.sublayers?.map { $0.removeFromSuperlayer() } 等变体
    (re.compile(RECEIVER + r"\.sublayers\?\.(?:map|filter)\s*\{[^}]*removeFromSuperlayer"),
     "backing-layer-clear(map/filter+removeFromSuperlayer)"),
]

# R2：同一文件内 `layer.addSublayer(` 的次数阈值（≥ 该值 = 自绘与 backing layer 混排）
R2_RE = re.compile(r"\blayer\.addSublayer\s*\(")
R2_THRESHOLD = 2

ALLOW_MARK = "cq-allow: backing-layer-clear"


def strip_comment(line: str) -> str:
    """剔除整行注释与行尾注释（朴素实现，够本规则用：Swift/ObjC 无行内字符串里的 // 风险场景）。"""
    # 行尾 // 注释（不处理字符串内的 // —— UI 代码里这种形态极罕见，宁可漏报不误报）
    idx = line.find("//")
    if idx >= 0:
        line = line[:idx]
    return line


def is_comment_line(stripped: str) -> bool:
    return stripped.startswith("//") or stripped.startswith("*") or stripped.startswith("/*")


def should_skip(path: str) -> bool:
    norm = path.replace(os.sep, "/")
    return any(part in norm for part in EXCLUDE_DIR_PARTS)


def scan_file(path: str):
    """返回 (violations, warnings)：元素为 (行号, 规则名, 命中内容, 原始行)。"""
    violations, warnings = [], []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError as e:
        print(f"warn: 无法读取 {path}: {e}", file=sys.stderr)
        return violations, warnings

    addsublayer_count = 0
    for i, raw in enumerate(lines, start=1):
        stripped = raw.strip()
        if is_comment_line(stripped):
            continue
        code = strip_comment(raw)
        if not code.strip():
            continue
        if ALLOW_MARK in raw:      # 逃逸阀：整行豁免（含写在行尾注释里的标记）
            continue

        for pattern, name in R1_PATTERNS:
            m = pattern.search(code)
            if m:
                violations.append((i, name, m.group(0).strip(), raw.strip()))
                break

        if R2_RE.search(code):
            addsublayer_count += 1

    if addsublayer_count >= R2_THRESHOLD:
        warnings.append((0, "mixed-selfdraw-on-backing-layer",
                         f"layer.addSublayer( ×{addsublayer_count}",
                         "自绘层建议收敛到一层专用容器层"))
    return violations, warnings


def main(argv):
    root = argv[1] if len(argv) > 1 else "apps/apple"
    if not os.path.exists(root):
        print(f"error: 扫描根不存在：{root}", file=sys.stderr)
        return 2

    total_v = 0
    files = 0
    for dirpath, _, filenames in os.walk(root):
        for fn in filenames:
            if not fn.endswith(SCAN_EXTS):
                continue
            path = os.path.join(dirpath, fn)
            if should_skip(path):
                continue
            files += 1
            v, w = scan_file(path)
            for (line, name, hit, raw) in v:
                total_v += 1
                print(f"FAIL {path}:{line}: {name}: `{hit}`: {raw}")
            for (line, name, hit, raw) in w:
                ln = "" if line == 0 else f":{line}"
                print(f"WARN {path}{ln}: {name}: `{hit}`: {raw}")

    print(f"---- 图层卫生扫描：扫描 {files} 个文件（根={root}），R1 违规 {total_v} 条 ----")
    if total_v:
        print("治理：自绘层一律挂专用容器层（private let canvasLayer = CALayer()），"
              "清空只清 canvasLayer.sublayers —— 子视图的 layer 永不被触碰。见 pitfalls P131。")
        return 1
    print("PASS：未发现「清空 UIView backing layer sublayers」的写法。")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
