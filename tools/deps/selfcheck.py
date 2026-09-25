#!/usr/bin/env python3
"""DEPS-001 自测：用真实解析器跑合法 / 非法样例，校验行为符合预期。

覆盖任务要求的五类非法样例（逐条解析失败并给出可读错误）：
  1) 缺字段         MISSING_FIELD
  2) 来源未登记      UNKNOWN_SOURCE
  3) SPDX 表达式非法  INVALID_SPDX
  4) 集成方式取值非法  BAD_ENUM (integration)
  5) 档位声明矛盾     PROFILE_CONTRADICTION
另含若干边界（二进制缺 artifact、sha256 非法、name 重复）作为健壮性补充。

运行：python3 tools/deps/selfcheck.py
退出码 0 = 全部符合预期；非 0 = 有不符合预期的情况。
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import parser as dep_parser  # noqa: E402

# 合法基底：所有字段齐全、来源已登记、协议合法
_BASE_DEP = """[[dep]]
name = "foo"
version = "1.0"
upstream = "https://github.com/acme/foo"
vcs = "git"
pin = "commit"
pin_ref = "0123456789abcdef0123456789abcdef01234567"
bump_policy = "human"
license = "MIT"
integration = "source"
visibility = "private"
owner = "x"
platforms = ["apple"]
"""

_CASES = []


def case(name: str, toml: str, expect_ok: bool, expect_codes=()):
    _CASES.append((name, toml, expect_ok, set(expect_codes)))


# ---- 合法样例（应全部通过）----
case("valid:dep", _BASE_DEP, True)
case("valid:binary", _BASE_DEP.replace('integration = "source"', 'integration = "binary"') +
     '[[dep.artifact]]\nplatform = "apple-arm64"\nurl = "https://artifacts.internal/foo.a"\n'
     'sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"\n', True)
case("valid:spdx-or", "[[dep]]\n" + _BASE_DEP.split("[[dep]]", 1)[1].replace(
    'license = "MIT"', 'license = "MIT OR Apache-2.0"'), True)
case("valid:model", """[[model]]
name = "m1"
source = "https://github.com/acme/model"
version = "1.0"
license = "Apache-2.0"
sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
purpose = "test"
""", True)

# ---- ADR-0008：git 源码依赖必须锁到不可变 commit ----
# 2a) 完全没有 pin 字段 —— 「定期拉最新」最容易退化成的形态，必须被拦下
case("invalid:unpinned_vcs", """[[dep]]
name = "foo"
version = "1.0"
upstream = "https://github.com/acme/foo"
license = "MIT"
integration = "source"
visibility = "private"
owner = "x"
platforms = ["apple"]
""", False, {"UNPINNED_VCS"})

# 2b) pin 到 tag —— tag 是可变引用（可被 force-push），同样不允许
case("invalid:tag_pin", """[[dep]]
name = "foo"
version = "1.0"
upstream = "https://github.com/acme/foo"
vcs = "git"
pin = "tag"
pin_ref = "v1.0"
license = "MIT"
integration = "source"
visibility = "private"
owner = "x"
platforms = ["apple"]
""", False, {"UNPINNED_VCS"})

# 2c) 声明了 pin=commit 但 pin_ref 不是 40 位 hash
case("invalid:bad_pin_ref", """[[dep]]
name = "foo"
version = "1.0"
upstream = "https://github.com/acme/foo"
vcs = "git"
pin = "commit"
pin_ref = "v1.0"
license = "MIT"
integration = "source"
visibility = "private"
owner = "x"
platforms = ["apple"]
""", False, {"BAD_PIN_REF"})

# 2d) integration=binary 不受此约束（走 artifact + sha256）
case("valid:binary_no_pin", """[[dep]]
name = "foo"
version = "1.0"
upstream = "https://github.com/acme/foo"
license = "MIT"
integration = "binary"
visibility = "private"
owner = "x"
platforms = ["apple"]
[[dep.artifact]]
platform = "apple-arm64"
url = "https://artifacts.internal/foo.a"
sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
""", True)

# ---- 非法样例 1：缺字段（缺 version）----
case("invalid:missing_field", """[[dep]]
name = "foo"
upstream = "https://github.com/acme/foo"
license = "MIT"
integration = "source"
visibility = "private"
owner = "x"
platforms = ["apple"]
""", False, {"MISSING_FIELD"})

# ---- 非法样例 2：来源未登记 ----
case("invalid:unknown_source", """[[dep]]
name = "foo"
version = "1.0"
upstream = "https://evil.example.com/foo.git"
license = "MIT"
integration = "source"
visibility = "private"
owner = "x"
platforms = ["apple"]
""", False, {"UNKNOWN_SOURCE"})

# ---- 非法样例 3：SPDX 表达式非法（未知协议）----
case("invalid:bad_spdx", """[[dep]]
name = "foo"
version = "1.0"
upstream = "https://github.com/acme/foo"
license = "FooBar-1.0"
integration = "source"
visibility = "private"
owner = "x"
platforms = ["apple"]
""", False, {"INVALID_SPDX"})

# ---- 非法样例 3b：SPDX 语法错误（尾部 AND）----
case("invalid:bad_spdx_syntax", """[[dep]]
name = "foo"
version = "1.0"
upstream = "https://github.com/acme/foo"
license = "MIT AND"
integration = "source"
visibility = "private"
owner = "x"
platforms = ["apple"]
""", False, {"INVALID_SPDX"})

# ---- 非法样例 4：集成方式取值非法 ----
case("invalid:bad_integration", """[[dep]]
name = "foo"
version = "1.0"
upstream = "https://github.com/acme/foo"
license = "MIT"
integration = "container"
visibility = "private"
owner = "x"
platforms = ["apple"]
""", False, {"BAD_ENUM"})

# ---- 非法样例 5：档位声明矛盾（feature 超出 demux 档位允许集）----
case("invalid:profile_contradiction", """[[dep]]
name = "ffmpeg"
version = "7.1"
upstream = "https://git.ffmpeg.org/ffmpeg.git"
license = "LGPL-2.1-or-later"
integration = "source"
visibility = "private"
owner = "media"
platforms = ["apple"]
profile = "demux"
features = ["demux", "decoder"]
""", False, {"PROFILE_CONTRADICTION"})

# ---- 非法样例 5b：full 档位未审批 ----
case("invalid:profile_full_no_approval", """[[dep]]
name = "ffmpeg"
version = "7.1"
upstream = "https://git.ffmpeg.org/ffmpeg.git"
license = "LGPL-2.1-or-later"
integration = "source"
visibility = "private"
owner = "media"
platforms = ["apple"]
profile = "full"
""", False, {"PROFILE_CONTRADICTION"})

# ---- 健壮性补充：二进制集成缺 artifact ----
case("invalid:binary_no_artifact", """[[dep]]
name = "foo"
version = "1.0"
upstream = "https://github.com/acme/foo"
license = "MIT"
integration = "binary"
visibility = "private"
owner = "x"
platforms = ["apple"]
""", False, {"BINARY_NEEDS_ARTIFACT"})

# ---- 健壮性补充：sha256 非法 ----
case("invalid:bad_sha256", """[[dep]]
name = "foo"
version = "1.0"
upstream = "https://github.com/acme/foo"
license = "MIT"
integration = "binary"
visibility = "private"
owner = "x"
platforms = ["apple"]
[[dep.artifact]]
platform = "apple-arm64"
url = "https://artifacts.internal/foo.a"
sha256 = "deadbeef"
""", False, {"BAD_SHA256"})

# ---- 健壮性补充：name 重复 ----
case("invalid:dup_name", _BASE_DEP + _BASE_DEP, False, {"DUPLICATE_NAME"})


def main() -> int:
    passed = 0
    failed = 0
    print("=" * 72)
    print("DEPS-001 解析器自测")
    print("=" * 72)
    for name, toml, expect_ok, expect_codes in _CASES:
        res = dep_parser.parse_text(toml, path=f"<{name}>")
        got_codes = {e.code for e in res.errors}
        ok = (res.ok == expect_ok)
        if expect_codes:
            ok = ok and expect_codes.issubset(got_codes)
        status = "PASS" if ok else "FAIL"
        if ok:
            passed += 1
        else:
            failed += 1
        print(f"[{status}] {name}")
        print(f"        expect_ok={expect_ok} got_ok={res.ok} "
              f"expect_codes={sorted(expect_codes)} got_codes={sorted(got_codes)}")
        if not ok:
            for e in res.errors:
                print(f"        ERR [{e.code}] {e.path}: {e.message}")
    print("-" * 72)
    print(f"总计 {passed + failed}：通过 {passed}，失败 {failed}")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
