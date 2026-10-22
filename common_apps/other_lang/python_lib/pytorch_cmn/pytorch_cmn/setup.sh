#!/bin/sh
# pytorch_cmn の環境をこのフォルダの中だけで揃える。
#
#   sh setup.sh
#   sh setup.sh --serve --model ../../../../data/Qwen3.8-27b-Q6
#
# 入れるもの: venv、torch、cupy、transformers、numpy、そして
# common_vcpu（Common の実行環境）と pytorch_cmn 自身。
# 外の python は触らない。ファイルの複製もしない（パッケージとして入れる）。
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../../.." && pwd)
VENV="$HERE/venv"
PY="$VENV/bin/python"
SERVE=0
MODEL=""
PORT=8000
SKIP=0

while [ $# -gt 0 ]; do
  case "$1" in
    --serve) SERVE=1 ;;
    --model) MODEL="$2"; shift ;;
    --port) PORT="$2"; shift ;;
    --skip-check) SKIP=1 ;;
    *) echo "知らない引数: $1" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '[pytorch_cmn] %s\n' "$1"; }

if [ ! -x "$PY" ]; then
  say "venv を作ります"
  command -v python3 >/dev/null || { echo "python3 がありません。3.10 以上を入れてください" >&2; exit 1; }
  python3 -m venv "$VENV"
fi

say "依存を入れます"
"$PY" -m pip install --upgrade pip --quiet
"$PY" -m pip install --quiet numpy "torch>=2.7" "transformers>=5.0" "cupy-cuda12x" || {
  say "cupy が入りません。GPU なしで進めます"
  "$PY" -m pip install --quiet numpy "torch>=2.7" "transformers>=5.0"
}

say "common_vcpu と pytorch_cmn をパッケージとして入れます"
"$PY" -m pip install --quiet -e "$ROOT/continuous_republic/common_systems/common_vcpu"
"$PY" -m pip install --quiet -e "$HERE"

CC="$ROOT/builds/commonc/commonc_lane64.bin"
if [ ! -f "$CC" ]; then
  echo "commonc の image が見つかりません: $CC" >&2
  echo "  common commonc_lane64.cam -t lane64 --no-sim -o $CC" >&2
  exit 1
fi
say "commonc の image: $CC"

if [ "$SKIP" -eq 0 ]; then
  say "テストを回します"
  "$PY" -m pytorch_cmn.check
fi

say "できました。API サーバーは次で立ちます"
printf '  %s -m pytorch_cmn.serve --model <モデルの置き場> --port %s\n' "$PY" "$PORT"

if [ "$SERVE" -eq 1 ]; then
  [ -n "$MODEL" ] || { echo "--serve には --model が要ります" >&2; exit 2; }
  exec "$PY" -m pytorch_cmn.serve --model "$MODEL" --port "$PORT"
fi
