# -*- coding: utf-8 -*-
"""`python -m pytorch_cmn.check` の入口。"""
import sys

from . import boundary


def main(argv):
    which = argv[0] if argv else "all"
    bad = []
    if which in ("all", "ops"):
        from . import test_backend
        print("== 演算 1 つずつ ==")
        bad += test_backend.run()
        print()
    if which in ("all", "boundary"):
        print("== 合成の層の境界 ==")
        ok, b = boundary.run()
        bad += b
        print("   通った %d" % ok)
    print()
    if bad:
        print("落ちた: %s" % ", ".join(bad))
        return 1
    print("全部通りました")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
