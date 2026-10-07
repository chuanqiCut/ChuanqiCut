#!/usr/bin/env bash
# ChuanqiCut — 本机总门禁（INFRA-010，2026-10-05）
#
# 场景：其他开发机代码合并后的守门（cq-code-review 流程 A）、本机提交前自审（流程 B）。
# 原则：**门禁口径以本机为准** —— 远端"已验证"一律按未验证处理，全量在本机重跑。
#
# 检查项（按序执行，任一失败立即非零退出 = 一票否决）：
#   1. deps      依赖治理 manifest 校验（需 Python >= 3.11 / tomllib）
#   2. headers   PAL/公共头纯净性（tools/pal/check_pal_headers.py）
#   2b. artifacts 产物入库检查（P84：.build/、根 build/、DerivedData 等一律不得被 git 跟踪）
#   3. core-dbg  内核 Debug 构建 + 全量单测（-Werror）
#   4. core-rel  内核 Release 构建 + 全量单测（-Werror + LTO）
#   5. apple     XCFramework 三切片 + Swift 绑定测试 + SharedUI/功能 Pod 测试
#   6. golden    golden 样本齐备性（tests/golden/verify.py）
#
# 用法：
#   tools/ci/run_gate.sh                 # 全量（默认）
#   tools/ci/run_gate.sh --fast          # 快速档：跳过 4/5（Release 与 Apple/Swift）
#   tools/ci/run_gate.sh --skip-apple    # 跳过 5（XCFramework + Swift + SharedUI）
#   PYTHON_BIN=/path/to/python3 tools/ci/run_gate.sh   # 指定 Python >= 3.11
#
# 报告：每步日志落 build/gate-logs/<step>.log；结尾打印门禁摘要（含 ctest 数字）。

set -u
PIPESTATUS_OK=1

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
LOG_DIR="$ROOT_DIR/build/gate-logs"
mkdir -p "$LOG_DIR"

FAST=0
SKIP_APPLE=0
for arg in "$@"; do
    case "$arg" in
        --fast)       FAST=1; SKIP_APPLE=1 ;;
        --skip-apple) SKIP_APPLE=1 ;;
        -h|--help)    grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "error: unknown argument '$arg' (try --help)" >&2; exit 2 ;;
    esac
done

PASS=0; FAIL=0; SKIP=0

print_summary() {
    echo "=============================================================="
    echo " 门禁摘要：PASS=${PASS}  FAIL=${FAIL}  SKIP=${SKIP}"
    for step in core-dbg core-rel; do
        if [ -f "${LOG_DIR}/${step}.log" ]; then
            grep -hE '[0-9]+% tests passed' "${LOG_DIR}/${step}.log" | sed "s/^/ ${step}: /"
        fi
    done
    for step in apple-swift-bindings apple-sharedui apple-player; do
        if [ -f "${LOG_DIR}/${step}.log" ]; then
            grep -hE "Test Suite '.*' (passed|failed)" "${LOG_DIR}/${step}.log" | tail -2 | sed "s/^/ ${step}: /"
        fi
    done
    echo "=============================================================="
}

# ---- 步骤执行器：PASS/FAIL/SKIP 记账；失败打印尾部日志并一票否决退出 ----
run_step() {
    local name="$1"; shift
    local log="${LOG_DIR}/${name}.log"
    echo "==> [${name}] $*"
    if "$@" >"${log}" 2>&1; then
        echo "    PASS（日志：${log}）"
        PASS=$((PASS+1))
    else
        local rc=$?
        echo "    FAIL（rc=${rc}）—— 最后 30 行："
        tail -30 "${log}" | sed 's/^/    /'
        FAIL=$((FAIL+1))
        print_summary
        exit 1
    fi
}

skip_step() {
    # $2 含全角字符时调用方负责加引号；此处仅拼接打印
    echo "==> [$1] SKIP：$2"
    SKIP=$((SKIP+1))
}

# ---- Python >= 3.11（tomllib）：env 指定 > 托管版本 > ~/.local > 系统（探测）----
PY="${PYTHON_BIN:-}"
if [ -z "${PY}" ]; then
    for cand in "${HOME}/.workbuddy/binaries/python/versions/3.13.12/bin/python3" \
                "${HOME}/.local/bin/python3.12"; do
        if [ -x "${cand}" ] && "${cand}" -c 'import tomllib' >/dev/null 2>&1; then
            PY="${cand}"; break
        fi
    done
fi
if [ -z "${PY}" ]; then
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import tomllib' >/dev/null 2>&1; then
        PY=python3
    fi
fi

echo "=============================================================="
echo " ChuanqiCut 本机门禁 @ $(date '+%F %T')  host=$(hostname -s)"
echo "=============================================================="

# 1. 依赖治理
if [ -n "${PY}" ]; then
    run_step "deps" "${PY}" tools/deps/deps.py validate third_party/manifest.toml
else
    skip_step "deps" "未找到 Python 3.11+（tomllib）。可用 PYTHON_BIN=... 指定。"
fi

# 2. PAL/公共头纯净性
run_step "headers" python3 tools/pal/check_pal_headers.py

# 2b. 产物入库检查（P84 规则兜底：构建产物永不入库；SPM 产物统一 --scratch-path 到 /build/spm/）
artifacts_bad="$(git ls-files | grep -E '(^|/)\.build/|^build/|/DerivedData/|\.xcuserstate$|\.DS_Store$' || true)"
if [ -n "${artifacts_bad}" ]; then
    echo "==> [artifacts] FAIL —— 以下构建产物被 git 跟踪（前 20 条）："
    echo "${artifacts_bad}" | head -20 | sed 's/^/    /'
    echo "    规则：新建包目录必须确认 .gitignore 覆盖（apps/apple/packages/*/.build/ 通配）；"
    echo "    SPM 跑测试一律 --scratch-path \"\$ROOT/build/spm/<包名>\"（临时编译统一目录 /build/）。"
    FAIL=$((FAIL+1)); print_summary; exit 1
else
    echo "==> [artifacts] PASS（无构建产物被 git 跟踪）"
    PASS=$((PASS+1))
fi

# 3. 内核 Debug + 全量单测
run_step "core-dbg" tools/build/build_core.sh --platform=apple --config=Debug --test

# 4. 内核 Release + 全量单测
if [ "${FAST}" -eq 1 ]; then
    skip_step "core-rel" "--fast 快速档"
else
    run_step "core-rel" tools/build/build_core.sh --platform=apple --config=Release --test
fi

# 5. XCFramework + Swift 绑定 + SharedUI
if [ "${SKIP_APPLE}" -eq 1 ]; then
    skip_step "apple" "跳过（--fast / --skip-apple）"
else
    run_step "apple-xcframework" tools/build/build_core_apple.sh --config=Release
    run_step "apple-prepare" "${ROOT_DIR}/bindings/swift/prepare.sh"
    if (cd bindings/swift && swift test --disable-sandbox --scratch-path "${ROOT_DIR}/build/spm/bindings") >"${LOG_DIR}/apple-swift-bindings.log" 2>&1; then
        echo "    PASS [apple-swift-bindings]（日志：${LOG_DIR}/apple-swift-bindings.log）"
        PASS=$((PASS+1))
    else
        echo "    FAIL [apple-swift-bindings] —— 最后 30 行："
        tail -30 "${LOG_DIR}/apple-swift-bindings.log" | sed 's/^/    /'
        FAIL=$((FAIL+1)); print_summary; exit 1
    fi
    if (cd apps/apple/packages/SharedUI && swift test --disable-sandbox --scratch-path "${ROOT_DIR}/build/spm/SharedUI") >"${LOG_DIR}/apple-sharedui.log" 2>&1; then
        echo "    PASS [apple-sharedui]（日志：${LOG_DIR}/apple-sharedui.log）"
        PASS=$((PASS+1))
    else
        echo "    FAIL [apple-sharedui] —— 最后 30 行："
        tail -30 "${LOG_DIR}/apple-sharedui.log" | sed 's/^/    /'
        FAIL=$((FAIL+1)); print_summary; exit 1
    fi
    # 功能 Pod 测试逐包跑（ADR-0031 分治；新增 Pod 时在此追加同款块）
    if (cd apps/apple/packages/ChuanqiCutPlayer && swift test --disable-sandbox --scratch-path "${ROOT_DIR}/build/spm/ChuanqiCutPlayer") >"${LOG_DIR}/apple-player.log" 2>&1; then
        echo "    PASS [apple-player]（日志：${LOG_DIR}/apple-player.log）"
        PASS=$((PASS+1))
    else
        echo "    FAIL [apple-player] —— 最后 30 行："
        tail -30 "${LOG_DIR}/apple-player.log" | sed 's/^/    /'
        FAIL=$((FAIL+1)); print_summary; exit 1
    fi
fi

# 6. golden 样本齐备性
if [ -n "${PY}" ]; then
    run_step "golden" "${PY}" tests/golden/verify.py --json
else
    skip_step "golden" "未找到 Python 3.11+"
fi

print_summary
echo " 门禁通过（以本机实测为准）"
exit 0
