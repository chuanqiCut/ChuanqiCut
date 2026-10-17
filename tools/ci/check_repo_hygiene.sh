#!/usr/bin/env bash
# ChuanqiCut — 仓库卫生门禁（INFRA-034，2026-10-16）
#
# 存在的理由：搬家批（INFRA-026~033）留下的四类"静默失效"都不会让编译变红，
# 只会让下一个人拿到一个看起来干净、实际缺东西的仓库。全部做成退出码：
#   1 ignore-anchoring  .gitignore 规则锚定探针 + 死规则扫描（P144）
#   2 legacy-paths      活文档里的旧仓库路径零残留（ADR-0044 搬家债的收口判据）
#   3 tracked-artifacts 构建产物未被 git 跟踪（P84）
#   4 editorconfig      与 .editorconfig 同口径的四条（CRLF / 行尾空白 / 末行换行 / tab）
#
# ⚠️ 三条判据口径（都是踩出来的，别再改回去）：
#   · 判定范围**只认入库文件**（`git ls-files`）。裸 `grep -r` 会命中已忽略的本机二进制
#     （`xcuserdata/*.xcuserstate`），把某条判据变成恒假 → 脚本长红 → 被人加 `|| true` 废掉（P153）。
#   · 扫描一律 `-z` 分记录，不得逐行 `for f in $(git ls-files)`：`git ls-files` 会把**非 ASCII
#     路径加引号转义**，中文文件名的行既匹配不上磁盘路径也进不了判据，于是整批静默漏检（P155）。
#   · 判据不许"越写清单越红"：搬家批**故意**在文档里留「原 xxx」标注行（让历史可读），
#     含迁移标记的行按豁免处理，见 check 2 的 MARKER。
#
# 退出码 = 本次失败的检查项数（0 = 全清）。clang-format 违规数只报不判（基线非零，
# 见 .clang-format 头部与 .ai/modules/core.md；把它做成红闸只会逼出 `|| true`）。
#
# 用法：tools/ci/check_repo_hygiene.sh [--verbose]

set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1
FAILED=0
TOTAL=0

# 计数由 pass/fail 自己记，结尾的 "n/n" 恒等于真实检查项数（写死 4/4 会在加第 5 条时骗人）。
pass() { echo "  PASS [$1] $2"; TOTAL=$((TOTAL + 1)); return 0; }
fail() {
    echo "  FAIL [$1] $2"
    [ -n "${3:-}" ] && printf '%s\n' "${3}" | sed 's/^/      /'
    FAILED=$((FAILED + 1)); TOTAL=$((TOTAL + 1))
    return 0
}

echo "=============================================================="
echo " 仓库卫生检查 @ $(date '+%F %T')  host=$(hostname -s)"
echo "=============================================================="

# ==== 1. 忽略规则锚定探针 ====================================================
# 每条 = "探针路径<TAB>期望命中的 源:行号:模式"。规则被删、被改宽、锚定层级写错，这里当场红。
# 负探针 = 必须**不被忽略**的源码（案底：裸 `build/` 曾连带忽略 tools/build/ 下三个构建脚本，
# git status 干净、文件其实从未入库 —— 静默误忽略是 P144 的正身）。
probes_out="$(python3 - <<'PY'
import subprocess
POS = [
    ("engine/shaders/generated/x",                 ".gitignore:45:engine/shaders/generated/"),
    ("api/swift/Frameworks/ChuanqiCut.xcframework/a", ".gitignore:66:api/swift/Frameworks/"),
    ("ui/SharedUI/.build/x",                       ".gitignore:78:ui/*/.build/"),
    ("build/spm/x",                                ".gitignore:17:/build/"),
    ("tmpABCD123/x",                               ".gitignore:60:tmp*/"),
    ("third_party/src/y",                          ".gitignore:49:third_party/src/"),
    ("engine/vendor/v",                            ".gitignore:94:engine/vendor/"),
    ("Pods/x",                                     ".gitignore:88:Pods/"),
    ("apps/apple/ios/build/y",                     ".gitignore:84:apps/apple/*/build/"),
]
NEG = ["tools/ci/run_gate.sh", "tools/build/build_core.sh",
       "engine/shaders/portable/blit.vert", "api/swift/Package.swift",
       "ui/SharedUI/Package.swift"]

def hit(path):
    r = subprocess.run(["git", "check-ignore", "-v", path],
                       capture_output=True, text=True)
    return r.stdout.split("\t")[0].strip() if r.returncode == 0 else ""

bad = []
for path, want in POS:
    got = hit(path)
    if got != want:
        bad.append(f"{path}: 命中 {got!r}，期望 {want!r}")
for path in NEG:
    got = hit(path)
    if got:
        bad.append(f"{path}: 被 {got} 忽略 —— 源码会静默漏出版本库")
print(f"PROBES\t{len(POS)}\t{len(NEG)}")
print("\n".join(bad))
PY
)"
[ "${VERBOSE}" -eq 1 ] && printf '%s\n' "${probes_out}" | tail -n +2 | sed 's/^/      /'

# 死规则扫描：带目录段的模式，其字面目录前缀必须真实存在。
# 案底：INFRA-032 把门面搬到 api/swift/ 之后，`engine/bindings/swift/{Frameworks,.build}/` 四条
# 指向不存在的目录，静默失效了一整个搬家批（027 为"搬迁期两边都留着"故意保留，034 删除）。
dead_rules="$(python3 - <<'PY'
import os, pathlib, re
out = []
for ig in (".gitignore", ".zcodeignore"):
    p = pathlib.Path(ig)
    if not p.exists():
        continue
    for ln, line in enumerate(p.read_text().split("\n"), 1):
        s = line.strip()
        if not s or s.startswith(("#", "!")):
            continue
        pat = s.rstrip("/").lstrip("/")
        if "/" not in pat:
            continue                       # 裸模式匹配任意层级，无从判定
        prefix = re.split(r"[*?\[]", pat)[0].rstrip("/") if re.search(r"[*?\[]", pat) else os.path.dirname(pat)
        if prefix and not os.path.isdir(prefix):
            out.append(f"{ig}:{ln}: 模式 {s!r} 的目录段 {prefix!r} 不存在")
print("\n".join(out))
PY
)"
probe_bad="$(printf '%s\n' "${probes_out}" | tail -n +2)"
if [ -n "${probe_bad}" ]; then
    fail ignore-anchoring "锚定探针未命中期望规则" "${probe_bad}"
elif [ -n "${dead_rules}" ]; then
    fail ignore-anchoring "存在指向不存在目录的忽略规则（搬家后没跟上）" "${dead_rules}"
else
    pass ignore-anchoring "锚定探针 $(printf '%s\n' "${probes_out}" | head -1 | awk '{print $2"+"$3}') 全过，无死规则"
fi

# ==== 2. 活文档旧路径零残留 ==================================================
# EXEMPT = 红线 5 的 append-only 域（历史记录不回改）。其余入库文件里的旧路径都是活债。
legacy="$(python3 - <<'PY'
import pathlib, re, subprocess
PAT = re.compile(
    r"apps/apple/packages|engine/bindings|(^|[^a-z])bindings/swift|shaders/src"
    r"|(^|[^/a-z])shaders/generated|tools/probe"
    r"|tests/unit/[a-z_0-9]+\.(cpp|c)")
MARKER = re.compile(r"原 |已迁|自 |当时在|INFRA-0|ADR-0|更名|拆 |→|作废|旧|历史")
# 本脚本自己的 PAT 定义行天生就是旧路径字面量，任何 MARKER 都盖不住；而且它未跟踪时
# 不在 `git ls-files` 射程内、一提交就把自己判红（P163）→ 显式排除自己。
SELF = "tools/ci/check_repo_hygiene.sh"
EXEMPT = ("docs/decisions/", "docs/research/", "docs/reports/", "docs/handoff/",
          "docs/reviews/", "docs/tasks/", "docs/archive/", ".workbuddy/", ".ai/memory/")
files = [f for f in subprocess.run(["git", "ls-files", "-z"],
                                   capture_output=True).stdout.decode().split("\0") if f]
hits, exempted = [], 0
for f in files:
    if f == SELF or f.startswith(EXEMPT):
        continue
    try:
        text = pathlib.Path(f).read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        continue
    for i, line in enumerate(text.split("\n"), 1):
        if not PAT.search(line):
            continue
        if MARKER.search(line):
            exempted += 1
        else:
            hits.append(f"{f}:{i}: {line.strip()[:140]}")
print(f"SUM\t{len(hits)}\t{exempted}")
print("\n".join(hits))
PY
)"
legacy_hits="$(printf '%s\n' "${legacy}" | head -1 | awk '{print $2}')"
legacy_exempt="$(printf '%s\n' "${legacy}" | head -1 | awk '{print $3}')"
if [ "${legacy_hits:-0}" -gt 0 ]; then
    fail legacy-paths "活文档残留旧路径 ${legacy_hits} 行" "$(printf '%s\n' "${legacy}" | tail -n +2)"
else
    [ "${VERBOSE}" -eq 1 ] && printf '%s\n' "${legacy}" | tail -n +2 | grep -v '^$' | sed 's/^/      EXEMPT /'
    pass legacy-paths "零残留（迁移标记豁免 ${legacy_exempt} 行）"
fi

# ==== 3. 构建产物不得被 git 跟踪 =============================================
artifacts="$(git ls-files | grep -E '(^|/)\.build/|^build/|/DerivedData/|\.xcuserstate$|\.DS_Store$|^Pods/|^engine/vendor/|^apps/apple/[^/]+/build/|\.o$|\.obj$|\.dylib$' || true)"
if [ -n "${artifacts}" ]; then
    fail tracked-artifacts "$(printf '%s\n' "${artifacts}" | wc -l | tr -d ' ') 个构建产物被跟踪" "$(printf '%s\n' "${artifacts}" | head -20)"
else
    pass tracked-artifacts "tracked $(git ls-files | wc -l | tr -d ' ') 个文件，无构建产物"
fi

# ==== 4. .editorconfig 四条件 ================================================
# 口径逐条来自 .editorconfig 的显式声明（豁免不是随手加的白名单）：
#   · 跳过 git 判定为非文本（i/-text）与空文件（i/none）；
#   · 行尾空白：md / pbxproj / plist 声明 trim=false（md 行尾两空格是硬换行语义）；
#   · 末行换行：pbxproj / plist 声明 insert_final_newline=false；
#     Assets.xcassets/**/Contents.json 由 Xcode 写、无末行换行，豁免并注明；
#   · tab 缩进：pbxproj / plist 声明 indent_style=tab。
ed_out="$(python3 - <<'PY'
import pathlib, re, subprocess
raw = subprocess.run(["git", "ls-files", "-z", "--eol"], capture_output=True).stdout.decode()
EXCL_WS = (".md", ".pbxproj", ".plist")
EXCL_FN = (".pbxproj", ".plist")
EXCL_TAB = (".pbxproj", ".plist")
crlf, trail, nofinal, tabs, missing = [], [], [], [], []
for rec in raw.split("\0"):
    if not rec.strip():
        continue
    m = re.match(r"^i/(\S+)\s+w/\S+\s+attr/\S*\s+(.*)$", rec, re.S)
    if not m:
        continue
    eol, path = m.group(1), m.group(2)
    if eol in ("-text", "none"):
        continue
    if eol != "lf":
        crlf.append(f"{path}: i/{eol}")
    try:
        data = pathlib.Path(path).read_bytes()
    except OSError:
        missing.append(path + ": 已跟踪但工作区缺文件")
        continue
    suffix = pathlib.Path(path).suffix
    if data and not data.endswith(b"\n") and suffix not in EXCL_FN \
            and "/Assets.xcassets/" not in "/" + path:
        nofinal.append(path)
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        continue
    if suffix not in EXCL_WS:
        for i, line in enumerate(text.split("\n"), 1):
            if re.search(r"[ \t]+$", line):
                trail.append(f"{path}:{i}")
                break
    if suffix not in EXCL_TAB and re.search(r"^(\t+|[ ]{1,3}\t)", text, re.M):
        tabs.append(path)
buckets = (("MISSING_FILE", missing), ("CRLF", crlf), ("TRAIL_WS", trail),
           ("NO_FINAL_NEWLINE", nofinal), ("TAB_INDENT", tabs))
total = sum(len(x) for _, x in buckets)
print("SUM\t%d\t%s" % (total, " ".join(f"{n}={len(x)}" for n, x in buckets)))
for name, lst in buckets:
    for x in lst[:15]:
        print(f"{name} {x}")
PY
)"
ed_total="$(printf '%s\n' "${ed_out}" | head -1 | awk '{print $2}')"
ed_counts="$(printf '%s\n' "${ed_out}" | head -1 | cut -f3-)"
if [ "${ed_total:-0}" -gt 0 ]; then
    fail editorconfig "与 .editorconfig 口径不符（${ed_counts}）" \
        "$(printf '%s\n' "${ed_out}" | tail -n +2)"
else
    pass editorconfig "CRLF / 行尾空白 / 末行换行 / tab 四条件全零命中"
fi

# ==== 参考信息：clang-format 违规数（不判红，基线非零）======================
CF="${CLANG_FORMAT:-}"
if [ -z "${CF}" ]; then
    CF="$(command -v clang-format || true)"
    [ -z "${CF}" ] && CF="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang-format"
fi
if [ -x "${CF}" ]; then
    cf_bad=0
    cf_all=0
    while IFS= read -r -d '' f; do
        cf_all=$((cf_all + 1))
        "${CF}" --dry-run --Werror "$f" >/dev/null 2>&1 || cf_bad=$((cf_bad + 1))
    done < <(git ls-files -z 'engine/*.h' 'engine/*.cpp' 'engine/*.mm' 'engine/*.c')
    echo "  INFO [clang-format] 违规 ${cf_bad}/${cf_all} 个文件（基线口径见 .clang-format 头部；本批不重排，重排另开卡）"
else
    echo "  INFO [clang-format] 未找到可执行文件，跳过统计（不影响退出码）"
fi

echo "=============================================================="
if [ "${FAILED}" -eq 0 ]; then
    echo " 仓库卫生：${TOTAL}/${TOTAL} PASS"
else
    echo " 仓库卫生：$((TOTAL - FAILED))/${TOTAL} PASS（FAIL ${FAILED} 项）"
fi
echo "=============================================================="
exit "${FAILED}"
