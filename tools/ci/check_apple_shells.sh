#!/usr/bin/env bash
# ChuanqiCut — 双 App 壳构建门禁（INFRA-037，收池 [18]，2026-10-17 传哲批准进门禁）
#
# 要补的洞：门禁里有 `ios-compile`（内核 iOS 切片"只编译"），但**没有任何一步真的把 App 壳编出来**。
# `run_gate.sh:233` 那句注释"Camera 实现层 iOS 专属不进 SPM，随双壳构建验证"长期是空头承诺 ——
# 双壳一直是**手工**按 P129 配方跑的，于是"壳里 podspec/Pbxproj/门面接线坏了、门禁照样绿"
# 这类事故只能靠人记得去跑（案底：P150 的 pod 根相对 glob 静默丢源码）。
#
# 用哪个工程：就用 **App 自己的 workspace**（`apps/apple/{ios,mac}/ChuanqiCut.xcworkspace`），
# 不另立判据工程。另立工程会复制一份"看起来像 App 但其实不是"的构建面，正是 ADR-0044 红线 1
# 打过的复发病（两套同源判据必然走偏）。
#
# 时长（本机 Intel x86_64 集成机实测，见 baselines「双壳进门禁」节）：
#   · P129 手工配方（**默认 DerivedData**，两端增量合计）**39s** —— 这是"暖"的上界参考，
#     与本脚本的 derivedData 不同目录，不能直接当作本脚本的暖跑数字；
#   · 冷（空 derivedData）iOS 端 **199s / rc=0 / error=0**，mac 端冷跑**未取到**（那次就是踩了下面的坑）；
#   · 本脚本自己目录下的暖跑数字 = 进门禁前必须补测的一项（TASK-INFRA-037 验收项）。
#
# ⚠️ 产物落点只能用绝对路径（P164）：本脚本在 `cd apps/apple/<壳>` 的子 shell 里调 xcodebuild，
#   那时 `../../build/...` 指向的是 **`apps/build/`**，不是仓库根 `build/` —— 实测一次就在源码树里
#   留下 1.5G derivedData。凡是"重定向到别处"的参数一律 `${ROOT_DIR}/` 开头，
#   并在下面用断言把它钉死（依赖 `cd` 之后还正确的相对路径，就是把 bug 藏进 cwd）。
#
# 本脚本**只读仓库**：不改任何入库文件（`pod install` 会重生成 `Pods/`，那份已在 .gitignore 里；
# `Podfile.lock` 若变了本脚本只报不修 —— 那是真改动，该由人确认后提交）。
# 一条删除都不走（P162）。
#
# 用法：
#   tools/ci/check_apple_shells.sh            # 两端都编
#   tools/ci/check_apple_shells.sh --shell=ios
#   tools/ci/check_apple_shells.sh --no-pod-install   # 跳过 pod install（只验编译）
# 退出码：0 = 两端 BUILD SUCCEEDED 且零 error；1 = 任一端失败；2 = 参数非法

set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

SHELL_FILTER="both"
POD_INSTALL=1
for arg in "$@"; do
    case "$arg" in
        --shell=*)            SHELL_FILTER="${arg#*=}" ;;
        --no-pod-install)     POD_INSTALL=0 ;;
        -h|--help)            grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)                    echo "!! 未知参数：$arg（-h 看用法）"; exit 2 ;;
    esac
done
case "$SHELL_FILTER" in both|ios|mac) ;; *) echo "!! --shell 只接受 both|ios|mac"; exit 2 ;; esac

# P159：非交互 shell 没有 LANG → `pod install` 在 Ruby unicode_normalize 里崩，
# 症状是"跟门禁无关的环境问题"，所以脚本自己带 locale，不依赖调用方。
export LANG="${LANG:-en_US.UTF-8}" LC_ALL="${LC_ALL:-en_US.UTF-8}"

# 日志与 derivedData 的落点必须先存在：P160 的同类坑就是重定向目标在新克隆机上没有，
# 真实失败被 shell 的"No such file or directory"盖掉。
mkdir -p build/gate-logs

RC=0
run_shell() {                       # $1=ios|mac  $2=scheme  $3...=xcodebuild 追加参数
    local name="$1" scheme="$2"; shift 2
    local dir="apps/apple/$name" dd="${ROOT_DIR}/build/gate-logs/dd-$name"
    local log="build/gate-logs/shell-$name.log"
    # 断言：产物根必须在仓库根 build/ 之下。本函数会在 `cd apps/apple/<壳>` 之后才把 dd 交给
    # xcodebuild，相对路径在那一刻的语义已经变了（P164 案底：apps/build/ 1.5G）。
    case "$dd" in
        "${ROOT_DIR}"/build/*) ;;
        *) echo "!! [$name] derivedData 落点非法：${dd}（必须是 ${ROOT_DIR}/build/ 之下）"; RC=1; return ;;
    esac
    echo "==> [$name] 壳构建：$dir / scheme=$scheme"
    echo "    derivedData=${dd#"$ROOT_DIR"/}"

    if [ "$POD_INSTALL" -eq 1 ]; then
        ( cd "$dir" && bundle exec pod install ) >"$log.pod" 2>&1
        local prc=$?
        # 留痕取 CocoaPods 的完成行而不是 `grep -c Installing`：Podfile 未变时它根本不打印
        # Installing/Using 行，计数恒 0 = 一条恒不命中的判据（P162 同款）；日志尾部是 xcodeproj
        # 生成噪声，也不能当摘要用。
        echo "    pod install rc=$prc  $(grep -o 'Pod installation complete!.*' "$log.pod" | tail -1)"
        if [ "$prc" -ne 0 ]; then
            echo "    !! [$name] pod install 失败，尾部 20 行："
            tail -20 "$log.pod" | sed 's/^/      /'
            RC=1; return
        fi
    fi

    # mac 端必须带 -arch + ONLY_ACTIVE_ARCH：Intel 机上 universal 编 arm64 时
    # SDK 没有该 slice 的预编译模块，会挂在系统库里而不是我们代码上（P96）——
    # 那类失败**不是代码回归**，别把它当成壳的 bug 去查。
    ( cd "$dir" && xcodebuild -workspace ChuanqiCut.xcworkspace -scheme "$scheme" \
        -derivedDataPath "$dd" build "$@" ) >"$log" 2>&1
    local brc=$?
    local okn; okn="$(grep -c 'BUILD SUCCEEDED' "$log")"
    local errs; errs="$(grep -c 'error:' "$log")"
    local warns; warns="$(grep -c 'warning:' "$log")"
    echo "    xcodebuild rc=$brc  BUILD SUCCEEDED=$okn  error 行=$errs  warning 行=$warns"
    echo "    （warning 行数只做留痕不做判据：跨趟不可比，来源多是 deployment-target 与 run-script 无输出项）"
    if [ "$brc" -ne 0 ] || [ "$okn" -eq 0 ] || [ "$errs" -ne 0 ]; then
        echo "    !! [$name] 壳构建不过，尾部 30 行："
        tail -30 "$log" | sed 's/^/      /'
        RC=1
    fi
}

if [ "$SHELL_FILTER" = both ] || [ "$SHELL_FILTER" = ios ]; then
    run_shell ios ChuanqiCutApp -destination generic/platform=iOS
fi
if [ "$SHELL_FILTER" = both ] || [ "$SHELL_FILTER" = mac ]; then
    run_shell mac ChuanqiCutMacApp -arch "$(uname -m)" ONLY_ACTIVE_ARCH=YES
fi

# Podfile.lock 变化只报不判：真改动该由人确认后随任务提交，门禁不替人改锁文件。
lock_dirty="$(git status --porcelain -- 'apps/apple/*/Podfile.lock' | wc -l | tr -d ' ')"
[ "$lock_dirty" != 0 ] && echo "  ℹ️ Podfile.lock 有 $lock_dirty 处变化（本脚本不改锁文件）"

# 跑完自查产物落点（P164）：check_repo_hygiene.sh 的同类判据在门禁里排在**本步之前**，
# 抓不到本步刚生成的目录，所以这里就地兜一次 —— 只认源码树下的 build/.build/DerivedData。
stray="$(find apps ui api engine -maxdepth 4 -type d \
    \( -name build -o -name .build -o -name DerivedData \) 2>/dev/null)"
if [ -n "$stray" ]; then
    echo "!! 源码树里出现了产物目录（应只落仓库根 build/）："
    printf '%s\n' "$stray" | sed 's/^/      /'
    RC=1
fi

if [ "$RC" -eq 0 ]; then echo "==> 双壳构建门禁 PASS"; else echo "!! 双壳构建门禁 FAIL"; fi
exit "$RC"
