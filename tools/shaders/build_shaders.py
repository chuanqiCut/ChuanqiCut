#!/usr/bin/env python3
# ChuanqiCut — Portable shader 编译链（SHADER-001 / SHADER-010）
#
# 链路：engine/shaders/portable/<name>.{vert,frag}（Portable，Vulkan GLSL 450）
#         -- glslang -V -->  *.spv  -- spirv-cross --msl -->  *.metal
#         -- 本脚本拼装 -->  <out-dir>/<name>_msl.h（raw string 常量，供 .mm include）
#
# 一个 shader = 一份头（SHADER-010 起有多个，故按组登记见 SHADER_GROUPS）。
# 加一行就多出一种产物：产物名、宏卫、常量名全部由组名派生，**不复制粘贴脚本**。
#
# 为什么用 Python 而不是在 CMake 里直接串两条 COMMAND：
#   * 工具缺失 / 步骤失败要给出**可读**的诊断（缺哪个工具、哪一步挂了），
#     而不是让 make 吐一个 "Error 1" 把原因埋进日志；
#   * 需要把多段 MSL 拼进同一个 .h，且要检查分隔符冲突（MSL 里出现 )MSL" 会
#     静默截断源码——这类 bug 在运行时才炸，且表现为「shader 编译失败」，
#     极难定位）。这段逻辑写进 CMake 会退化成不可维护的转义串；
#   * 一次只写一个 .h，天然幂等，配合 add_custom_command 的 OUTPUT 即增量正确。
#
# 产物全部落在 build/ 下（--out-dir），**不入库**（AGENTS：禁止提交 shader 生成产物）。
# 入库的只有本脚本与 engine/shaders/portable/*.glsl。
#
# 用法：
#   python3 tools/shaders/build_shaders.py --repo-root . --out-dir build/generated/shaders
# 工具路径可用 CQ_GLSLANG / CQ_SPIRV_CROSS 环境变量或命令行参数覆盖，
# 默认取 build/tools/ 下由 tools/deps 构建的版本（源码产物不入库，故不在仓库里）。

from __future__ import annotations

import argparse
import os
import shlex
import subprocess
import sys
from pathlib import Path

# (组名, ((stage, Portable GLSL 文件名, 生成的 C++ 常量名), ...))
# 一组 = 一个逻辑 shader = 一份 `<组名>_msl.h`。SHADER-010 起有了第二组，
# 产物名 / 宏卫 / 常量名全部由组名派生，不在脚本里复制粘贴第二遍。
SHADER_GROUPS = (
    ("blit", (("vert", "blit.vert", "kBlitVertMsl"),
              ("frag", "blit.frag", "kBlitFragMsl"))),
    ("transform", (("vert", "transform.vert", "kTransformVertMsl"),
                   ("frag", "transform.frag", "kTransformFragMsl"))),
)

RAW_DELIM = "MSL"

HEADER_BANNER = """// 自动生成文件 —— 请勿编辑，改 engine/shaders/portable/*.glsl 后重新构建。
//
// 来源：engine/shaders/portable/{name}.vert / {name}.frag（Portable，Vulkan GLSL 450）
//       → glslang(SPIR-V) → spirv-cross(MSL)
// 生成者：tools/shaders/build_shaders.py
//
// 为什么是 .h 而不是运行时读 .metal：Platform 没有可用的资源加载接口，
// 运行时读文件会引入「打包遗漏」这条新的失败路径却换不来收益（见红线 #6 注释）。
"""


def log(msg: str) -> None:
    print(f"[shaders] {msg}")


def run(cmd: list[str]) -> None:
    print("         $ " + " ".join(shlex.quote(c) for c in cmd))
    subprocess.run(cmd, check=True)


def resolve_tool(explicit: str | None, env_var: str, repo_root: Path, rel: str) -> Path:
    """定位工具链二进制。优先级：命令行参数 > 环境变量 > build/tools/ 默认位置。"""
    candidates = [explicit, os.environ.get(env_var), str(repo_root / rel)]
    for c in candidates:
        if c:
            p = Path(c)
            if p.is_file() and os.access(p, os.X_OK):
                return p
    raise SystemExit(
        f"error: shader 工具链不可用（试过：{', '.join(filter(None, candidates))}）\n"
        f"       先构建工具链（tools/deps），或用 {env_var} 指定已编译好的二进制。"
    )


def render_header(name: str, entries: list[tuple[str, str]]) -> str:
    guard = f"CQ_GENERATED_SHADERS_{name.upper()}_MSL_H_"
    out = [HEADER_BANNER.format(name=name), "\n"]
    out.append(f"#ifndef {guard}\n")
    out.append(f"#define {guard}\n\n")
    out.append("namespace cq {\nnamespace apple {\nnamespace shaders {\n")  # MSL 产物：归 apple 命名空间
    for const, msl in entries:
        terminator = f"){RAW_DELIM}\""
        if terminator in msl:
            raise SystemExit(
                f"error: {const} 的 MSL 里出现了 raw string 终止符 {terminator}，"
                "内联进 .h 会被静默截断。请调整 RAW_DELIM。"
            )
        out.append(f'\ninline constexpr char {const}[] = R"{RAW_DELIM}(\n{msl}){RAW_DELIM}";\n')
    out.append("\n}  // namespace shaders\n}  // namespace apple\n}  // namespace cq\n\n")
    out.append(f"#endif  // {guard}\n")
    return "".join(out)


def main() -> int:
    ap = argparse.ArgumentParser(description="Portable GLSL → SPIR-V → MSL → C++ 头（SHADER-001）")
    ap.add_argument("--repo-root", required=True, type=Path, help="仓库根目录")
    ap.add_argument("--out-dir", required=True, type=Path, help="产物目录（必须在 build/ 下）")
    ap.add_argument("--glslang", default=None, help="glslang 二进制路径")
    ap.add_argument("--spirv-cross", default=None, help="spirv-cross 二进制路径")
    args = ap.parse_args()

    repo_root = args.repo_root.resolve()
    out_dir = args.out_dir if args.out_dir.is_absolute() else (Path.cwd() / args.out_dir)
    src_dir = repo_root / "engine" / "shaders" / "portable"
    spv_dir = out_dir / "spv"
    msl_dir = out_dir / "msl"
    spv_dir.mkdir(parents=True, exist_ok=True)
    msl_dir.mkdir(parents=True, exist_ok=True)

    glslang = resolve_tool(args.glslang, "CQ_GLSLANG", repo_root,
                           "build/tools/glslang/StandAlone/glslang")
    spirv_cross = resolve_tool(args.spirv_cross, "CQ_SPIRV_CROSS", repo_root,
                               "build/tools/spirv-cross/spirv-cross")

    built = 0
    for group, stages in SHADER_GROUPS:
        entries: list[tuple[str, str]] = []
        for stage, glsl_name, const_name in stages:
            src = src_dir / glsl_name
            if not src.is_file():
                raise SystemExit(f"error: Portable shader 缺失：{src}")
            spv = spv_dir / f"{group}.{stage}.spv"
            msl = msl_dir / f"{group}.{stage}.metal"
            log(f"{glsl_name} → {spv.name}")
            # -V：产出 SPIR-V；--target-env vulkan1.1：按 Vulkan 语义校验（GLSL 450 的归宿）。
            run([str(glslang), "-V", "--target-env", "vulkan1.1", "-o", str(spv), str(src)])
            log(f"{spv.name} → {msl.name}")
            run([str(spirv_cross), "--msl", str(spv), "--output", str(msl)])
            entries.append((const_name, msl.read_text(encoding="utf-8")))

        header = out_dir / f"{group}_msl.h"
        header.write_text(render_header(group, entries), encoding="utf-8")
        log(f"生成 {header}")
        built += 1
    log(f"共 {built} 组 shader → {out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
