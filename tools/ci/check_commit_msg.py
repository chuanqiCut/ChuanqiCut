#!/usr/bin/env python3
# commit message 硬线判据（INFRA-047，2026-10-17 传哲裁定）。由来与实测数字：
#   docs/tasks/TASK-INFRA-047-commitmessage硬线判据.md · pitfalls P179 · baselines.md · ADR-0046
# H1 标题 ≤40 字；H2 标题与正文间必须空行（否则 git 里 %b 为空、%s 无限长）；
# H3 正文 ≤3 行；H4 每行 ≤40 字；H5 合计 ≤120 字；H6 禁表格符 | ；H7 禁行首小标题词；
# W1 标题不带任务 ID 只 WARN（修历史/回滚有正当理由）。
# 字 = Unicode 码点。豁免 Merge/Revert/fixup!/squash!。
# 用法：脚本 <消息文件>（钩子） | --commits=<a..b>（门禁） | --install-hook（写文件，不动 git config）

import os
import re
import subprocess
import sys

SUBJ_MAX = 40
BODY_LINES_MAX = 3
BODY_LINE_MAX = 40
BODY_TOTAL_MAX = 120

# H7 先剥项目符号再判：本仓真实形状是 `- 实测：…`，只认行首会整条放过（漏过一次）。
BANNED_LEAD = re.compile(r"^(实测|结论|原因|背景|验收|风险|根因|注|注意|说明)[：:]")
BULLET = re.compile(r"^[-*•]\s+")
TASK_PREFIX = re.compile(r"^[A-Z][A-Z0-9]*(?:-[0-9]+)?\b|^[A-Z]0\b")
SCISSORS = re.compile(r"^(#?)\s*(-{2,} >8 -{2,})$")
EXEMPT = re.compile(r"^(Merge |Revert \"|fixup!|squash!)")


def cleanup(raw):
    """git --cleanup=strip 口径。钩子跑在清理之前，文件里注释还在，必须自己剔。
    ⚠️ 剪刀线本身带 `#`，先认剪刀线再剔注释，顺序反了会让其下的 diff 混进正文。"""
    out = []
    for line in raw.split("\n"):
        if SCISSORS.match(line.strip()):
            break
        if line.lstrip().startswith("#"):
            continue
        out.append(line.rstrip())
    lines = []
    for line in out:
        if line.strip() == "" and lines and lines[-1].strip() == "":
            continue
        lines.append(line)
    while lines and lines[0].strip() == "":
        lines.pop(0)
    while lines and lines[-1].strip() == "":
        lines.pop()
    return lines


def check(lines, tag, fails, warns):
    if not lines:
        fails.append(f"{tag}: 空提交信息")
        return
    if EXEMPT.match(lines[0]):
        warns.append(f"{tag}: 豁免（Merge/Revert/fixup/squash 形状不由本仓控制），不判")
        return
    # 首段 = 标题；正文 = 首个空行之后的所有内容行
    first_blank = next((i for i, l in enumerate(lines) if l.strip() == ""), None)
    subject_para = lines[: first_blank if first_blank is not None else len(lines)]
    body = [l for l in lines[first_blank + 1 :]] if first_blank is not None else []

    n = len(subject_para[0])
    if n > SUBJ_MAX:
        fails.append(f"{tag} H1 标题 {n} 字 > {SUBJ_MAX}：{subject_para[0][:24]}…")
    if len(subject_para) > 1:
        lens = "/".join(str(len(l)) for l in subject_para)
        fails.append(
            f"{tag} H2 标题与正文之间缺空行：首段有 {len(subject_para)} 行（{lens} 字），"
            f"git 会把整段折成 `%s`、`%b` 为空"
        )
    if not TASK_PREFIX.match(subject_para[0]):
        warns.append(f"{tag} W1 标题不以任务 ID 开头：{subject_para[0]}")

    bl = [l for l in body if l.strip()]
    if len(bl) > BODY_LINES_MAX:
        fails.append(f"{tag} H3 正文 {len(bl)} 行 > {BODY_LINES_MAX}")
    total = 0
    for i, l in enumerate(bl, 1):
        n = len(l)
        total += n
        if n > BODY_LINE_MAX:
            fails.append(
                f"{tag} H4 正文第 {i} 行 {n} 字 > {BODY_LINE_MAX}：{l[:20]}…{l[-8:]}"
            )
    if total > BODY_TOTAL_MAX:
        fails.append(f"{tag} H5 正文合计 {total} 字 > {BODY_TOTAL_MAX}")

    for i, l in enumerate([subject_para[0]] + bl):
        where = "标题" if i == 0 else f"正文第 {i} 行"
        if "|" in l:
            fails.append(f"{tag} H6 出现表格符 `|`（{where}）：{l[:30]}")
        if BANNED_LEAD.match(BULLET.sub("", l.strip())):
            fails.append(f"{tag} H7 小标题词开头（{where}）：{l.strip()[:24]}")


def run_file(path):
    with open(path, encoding="utf-8") as fh:
        raw = fh.read()
    fails, warns = [], []
    check(cleanup(raw), "本条", fails, warns)
    for w in warns:
        print(f"WARN  {w}")
    for f in fails:
        print(f"FAIL  {f}")
    if fails:
        print(
            f"\n硬线：标题 ≤{SUBJ_MAX} 字 / 正文 ≤{BODY_LINES_MAX} 行、"
            f"每行 ≤{BODY_LINE_MAX} 字、合计 ≤{BODY_TOTAL_MAX} 字 / 禁 `|` 与行首小标题词。\n"
            "数字、表格、逐条实测不进提交 —— 进 `.ai/modules/<模块>.md` 与 `.ai/memory/baselines.md`。"
        )
        return 1
    print("commit-msg OK")
    return 0


def run_commits(spec):
    shas = (
        subprocess.run(
            ["git", "rev-list", spec], capture_output=True, text=True, check=True
        )
        .stdout
        .split()
    )
    fails, warns = [], []
    for sha in shas:
        raw = subprocess.run(
            ["git", "log", "-1", "--format=%B", sha],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
        check(cleanup(raw), sha[:7], fails, warns)
    print(f"commit-msg 审计 {spec}：{len(shas)} 笔")
    for w in warns:
        print(f"  WARN  {w}")
    for f in fails:
        print(f"  FAIL  {f}")
    if fails:
        print(f"\n{len(fails)} 条违规（水位之前的历史提交不追溯，见 run_gate.sh 2f 步的水位说明）")
        return 1
    print("  全部符合硬线")
    return 0


def install_hook():
    root = (
        subprocess.run(
            ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True
        )
        .stdout
        .strip()
    )
    path = os.path.join(root, ".git", "hooks", "commit-msg")
    body = (
        "#!/bin/sh\n"
        "# ChuanqiCut commit-msg 钩子 —— 由 `tools/ci/check_commit_msg.py --install-hook` 生成。\n"
        "# 不入库（.git/ 不跟踪），换机器/换开发机后重跑那条命令即可。\n"
        "# 跳过钩子（git commit -n）挡不住门禁：run_gate.sh 的 2f 步照判同一个区间。\n"
        'ROOT="$(git rev-parse --show-toplevel)"\n'
        'PY="${PYTHON_BIN:-python3}"\n'
        'command -v "$PY" >/dev/null 2>&1 || PY="$HOME/.workbuddy/binaries/python/versions/3.13.12/bin/python3"\n'
        'exec "$PY" "$ROOT/tools/ci/check_commit_msg.py" "$1" || {\n'
        '    echo "error: 提交信息不合硬线（见上）。规矩：标题 ≤40 字 / 正文 ≤3 行、每行 ≤40 字、合计 ≤120 字。" >&2\n'
        "    exit 1\n"
        "}\n"
    )
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(body)
    os.chmod(path, 0o755)
    print(f"已安装 {path}")
    return 0


def main(argv):
    args = argv[1:]
    if not args:
        print(__doc__ or "用法见文件头")
        return 2
    if args[0] == "--install-hook":
        return install_hook()
    if args[0].startswith("--commits"):
        spec = args[0].split("=", 1)[1] if "=" in args[0] else args[1]
        return run_commits(spec)
    return run_file(args[0])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
