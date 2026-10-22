# -*- coding: utf-8 -*-
"""旧いパスとの互換。中身は `common_vcpu.toolchain` そのもの。

`sys.path` にこのディレクトリを足して `import toolchain` と書いている場所のために置いてある。
`sys.modules` を差し替えるので、返るのはパッケージ側と**同一のモジュール**になる。
新しく書くところは `from common_vcpu import toolchain` を使う。
"""
import sys

from common_vcpu import toolchain as _same

sys.modules[__name__] = _same
