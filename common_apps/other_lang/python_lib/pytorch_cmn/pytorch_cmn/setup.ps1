# pytorch_cmn の環境をこのフォルダの中だけで揃える。
#
#   powershell -ExecutionPolicy Bypass -File setup.ps1
#   powershell -ExecutionPolicy Bypass -File setup.ps1 -Serve -Model ..\..\..\..\data\Qwen3.8-27b-Q6
#
# 入れるもの: venv、torch、cupy、transformers、numpy、そして common_vcpu と pytorch_cmn。
# 外の python は触らない。ファイルの複製もしない。

param([switch]$Serve, [string]$Model = "", [int]$Port = 8000, [switch]$SkipCheck)

$ErrorActionPreference = "Stop"
$Here = $PSScriptRoot
$Root = (Resolve-Path (Join-Path $Here "..\..\..\..")).Path
$Venv = Join-Path $Here "venv"
$Py = Join-Path $Venv "Scripts\python.exe"

function Say($m) { Write-Host "[pytorch_cmn] $m" -ForegroundColor Cyan }

if (-not (Test-Path $Py)) {
  Say "venv を作ります"
  $sys = Get-Command python -ErrorAction SilentlyContinue
  if (-not $sys) { throw "python が PATH にありません。3.10 以上を入れてください" }
  & $sys.Source -m venv $Venv
}

Say "依存を入れます"
& $Py -m pip install --upgrade pip --quiet
try {
  & $Py -m pip install --quiet numpy "torch>=2.7" "transformers>=5.0" "cupy-cuda12x"
} catch {
  Say "cupy が入りません。GPU なしで進めます"
  & $Py -m pip install --quiet numpy "torch>=2.7" "transformers>=5.0"
}

Say "common_vcpu と pytorch_cmn をパッケージとして入れます"
& $Py -m pip install --quiet -e (Join-Path $Root "continuous_republic\common_systems\common_vcpu")
& $Py -m pip install --quiet -e $Here

$Cc = Join-Path $Root "builds\commonc\commonc_lane64.bin"
if (-not (Test-Path $Cc)) {
  throw "commonc の image が見つかりません: $Cc"
}
Say "commonc の image: $Cc"

if (-not $SkipCheck) {
  Say "テストを回します"
  & $Py -m pytorch_cmn.check
  if ($LASTEXITCODE -ne 0) { throw "テストが通りません" }
}

Say "できました。API サーバーは次で立ちます"
Write-Host "  $Py -m pytorch_cmn.serve --model <モデルの置き場> --port $Port"

if ($Serve) {
  if (-not $Model) { throw "-Serve には -Model が要ります" }
  & $Py -m pytorch_cmn.serve --model $Model --port $Port
}
