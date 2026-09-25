#!/usr/bin/env python3
"""manifest.toml 解析器 CLI（DEPS-001）。

子命令：
  validate  校验清单合法性，错误以可读形式输出；合法退出码 0，非法退出码 1
  parse     解析为结构化 JSON（供 DEPS-002/003/004/005 消费），并打印到 stdout
  summarize 输出人类可读摘要（不退出非零，仅展示）

用法：
  python3 tools/deps/deps.py validate third_party/manifest.toml
  python3 tools/deps/deps.py parse    third_party/manifest.toml --json
  python3 tools/deps/deps.py summarize third_party/manifest.toml

仅依赖 Python 标准库（tomllib 需要 3.11+，本仓统一用 3.13）。
"""

from __future__ import annotations

import argparse
import json
import os
import sys

# 让本脚本可直接 `python3 tools/deps/deps.py ...` 运行
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import parser as dep_parser  # noqa: E402
import locker as dep_locker  # noqa: E402

EXIT_OK = 0
EXIT_INVALID = 1
EXIT_USAGE = 2


def _cmd_validate(args: argparse.Namespace) -> int:
    result = dep_parser.parse_file(args.path)
    if result.errors:
        print(f"✗ {args.path}: 校验失败，{len(result.errors)} 个错误\n", file=sys.stderr)
        for e in result.errors:
            print(f"  [{e.code}] {e.path}\n      {e.message}", file=sys.stderr)
    else:
        print(f"✓ {args.path}: 校验通过（{result.summary()['total']} 条条目）", file=sys.stderr)
    if result.warnings:
        print(f"\n⚠ {len(result.warnings)} 条警告：", file=sys.stderr)
        for w in result.warnings:
            print(f"  [{w.code}] {w.path}: {w.message}", file=sys.stderr)
    return EXIT_OK if result.ok else EXIT_INVALID


def _cmd_parse(args: argparse.Namespace) -> int:
    result = dep_parser.parse_file(args.path)
    payload = result.to_dict()
    if args.json:
        print(json.dumps(payload, indent=2, ensure_ascii=False))
    else:
        print(json.dumps(payload, indent=2, ensure_ascii=False))
    return EXIT_OK if result.ok else EXIT_INVALID


def _cmd_summarize(args: argparse.Namespace) -> int:
    result = dep_parser.parse_file(args.path)
    s = result.summary()
    print(f"清单类型 : {result.kind}")
    print(f"文件路径 : {result.path}")
    print(f"Schema   : v{result.schema_version}")
    print(f"条目总数 : {s['total']}")
    print(f"协议分级 : {s['by_license_tier']}")
    if result.kind == "dep":
        print(f"集成方式 : {s['by_integration']}")
    print(f"错误/警告: {s['error_count']} / {s['warning_count']}")
    print()
    if result.kind == "dep":
        hdr = f"  {'name':<22} {'ver':<10} {'integration':<9} {'scope':<8} {'tier':<10} {'profile'}"
        print(hdr)
        for e in result.entries:
            print(f"  {e.name:<22} {e.version:<10} {e.integration:<9} {e.scope:<8} "
                  f"{(e.license_tier or '-'):<10} {e.profile or '-'}")
    else:
        hdr = f"  {'name':<28} {'ver':<10} {'tier':<10} {'precision'}"
        print(hdr)
        for e in result.entries:
            print(f"  {e.name:<28} {e.version:<10} {(e.license_tier or '-'):<10} {e.target_precision or '-'}")
    if result.errors:
        print("\n错误：")
        for e in result.errors:
            print(f"  [{e.code}] {e.path}: {e.message}")
    if result.warnings:
        print("\n警告：")
        for w in result.warnings:
            print(f"  [{w.code}] {w.path}: {w.message}")
    return EXIT_OK if result.ok else EXIT_INVALID


def _cmd_lock(args: argparse.Namespace) -> int:
    result = dep_parser.parse_file(args.path)
    if not result.ok:
        print(f"✗ manifest 解析失败，无法生成 lock：", file=sys.stderr)
        for e in result.errors:
            print(f"  [{e.code}] {e.path}: {e.message}", file=sys.stderr)
        return EXIT_INVALID
    manifest_dir = os.path.dirname(os.path.abspath(args.path))
    resolver = dep_locker.build_resolver(manifest_dir, args.resolve, args.commit)
    lock, errors = dep_locker.generate_lock(
        result, resolver, manifest_dir,
        allow_placeholder=args.allow_placeholder,
        allow_unresolved=args.allow_unresolved,
    )
    if errors:
        print(f"✗ lock 生成失败，{len(errors)} 个错误：\n", file=sys.stderr)
        for m in errors:
            print(f"  - {m}", file=sys.stderr)
        return EXIT_INVALID
    text = dep_locker.emit_lock_toml(lock)
    out = args.out or os.path.join(manifest_dir, "deps.lock")
    dep_locker.write_lock(out, text)
    print(f"✓ 已生成 lock：{out}（{len(lock['locked'])} 条锁定条目）", file=sys.stderr)
    return EXIT_OK


def _cmd_check(args: argparse.Namespace) -> int:
    result = dep_parser.parse_file(args.path)
    if not result.ok:
        print(f"✗ manifest 解析失败，无法校验 lock：", file=sys.stderr)
        for e in result.errors:
            print(f"  [{e.code}] {e.path}: {e.message}", file=sys.stderr)
        return EXIT_INVALID
    manifest_dir = os.path.dirname(os.path.abspath(args.path))
    resolver = dep_locker.build_resolver(manifest_dir, args.resolve, args.commit)
    lock_path = args.lock or os.path.join(manifest_dir, "deps.lock")
    ok, diffs = dep_locker.check_lock(
        result, resolver, lock_path, manifest_dir,
    )
    if ok:
        print(f"✓ lock 校验通过：{lock_path}", file=sys.stderr)
        return EXIT_OK
    print(f"✗ lock 校验失败：{lock_path}\n", file=sys.stderr)
    for d in diffs:
        print(f"  {d}", file=sys.stderr)
    return EXIT_INVALID


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="deps", description="ChuanqiCut manifest.toml 解析器 / 锁文件工具")
    sub = p.add_subparsers(dest="command", required=True)

    v = sub.add_parser("validate", help="校验清单合法性")
    v.add_argument("path", help="manifest.toml 路径")
    v.set_defaults(func=_cmd_validate)

    pa = sub.add_parser("parse", help="解析为结构化 JSON")
    pa.add_argument("path", help="manifest.toml 路径")
    pa.add_argument("--json", action="store_true", help="输出 JSON（默认即为 JSON）")
    pa.set_defaults(func=_cmd_parse)

    su = sub.add_parser("summarize", help="人类可读摘要")
    su.add_argument("path", help="manifest.toml 路径")
    su.set_defaults(func=_cmd_summarize)

    lk = sub.add_parser("lock", help="生成/更新 deps.lock（人手改动会被 check 检测）")
    lk.add_argument("path", help="manifest.toml 路径")
    lk.add_argument("--resolve", help="resolver 文件：[[resolved]] name= commit= [resolved_ref=]")
    lk.add_argument("--commit", action="append", default=[], metavar="NAME=HASH",
                    help="覆盖某依赖的 commit（可重复）")
    lk.add_argument("--allow-placeholder", action="store_true",
                    help="允许占位 sha256 进入 lock（会打 lock_state=placeholder 标记，check 仍失败）")
    lk.add_argument("--allow-unresolved", action="store_true",
                    help="允许未解析的 source 依赖进入 lock（会打 lock_state=unresolved，check 仍失败）")
    lk.add_argument("--out", help="输出路径（默认 <manifest目录>/deps.lock）")
    lk.set_defaults(func=_cmd_lock)

    ck = sub.add_parser("check", help="校验 manifest 与 lock 一致（CI 门禁入口）")
    ck.add_argument("path", help="manifest.toml 路径")
    ck.add_argument("--resolve", help="resolver 文件（与 lock 时一致）")
    ck.add_argument("--commit", action="append", default=[], metavar="NAME=HASH",
                    help="覆盖某依赖的 commit（可重复，须与 lock 时一致）")
    ck.add_argument("--lock", help="lock 文件路径（默认 <manifest目录>/deps.lock）")
    ck.set_defaults(func=_cmd_check)

    return p


def main(argv: list[str] | None = None) -> int:
    parser_cli = build_parser()
    args = parser_cli.parse_args(argv)
    try:
        return args.func(args)
    except FileNotFoundError as e:
        print(f"文件不存在：{e}", file=sys.stderr)
        return EXIT_USAGE
    except Exception as e:  # 兜底，避免堆栈直接抛给用户
        print(f"内部错误：{e}", file=sys.stderr)
        return EXIT_USAGE


if __name__ == "__main__":
    sys.exit(main())
