# Run.ps1 — lane64 の image を作り、Python の実行台で確かめる。
#
#   1. common    continuous_republic/examples の .cam を lane64 の image へ落とす
#   2. python    test_vcpu.py が 20 章 §10 の表を検査する
#
# venv は要らない。実行台は Python の標準機能だけで書いてある。

param(
  [string]$Root = 'D:\work\common-continuous-republics'
)
# native command の stderr で止めない。GHC は警告を stderr へ書くので、
# 'Stop' のままだと警告一本で走らせる前に落ちる。判定は $LASTEXITCODE で取る
$ErrorActionPreference = 'Continue'

$out      = Join-Path $Root 'builds\examples'
$examples = Join-Path $Root 'continuous_republic\examples'
$here     = Join-Path $Root 'continuous_republic\common_systems\Python_vCPU'

Push-Location $Root
if (-not (Test-Path $out)) { New-Item -ItemType Directory -Force -Path $out | Out-Null }

Write-Host '== 1. image =='
foreach ($s in (Get-ChildItem -Path $examples -Filter '*.cam' | Sort-Object Name)) {
  $bin = Join-Path $out ("{0}-lane64.bin" -f $s.BaseName)
  if ($s.BaseName -like '*_bench') {
    # 歩数が多いので、式 (43.2) の観測を package 内蔵 simulator で取らない
    & cabal run -v0 common --builddir=builds/dist -- $s.FullName -t lane64 -o $bin --no-sim
  } else {
    & cabal run -v0 common --builddir=builds/dist -- $s.FullName -t lane64 -o $bin
  }
  if ($LASTEXITCODE -ne 0) { Pop-Location; Write-Host 'te   compile が通らない'; exit 1 }
  Write-Host ("  {0}" -f (Split-Path $bin -Leaf))
}

Write-Host '== 2. 検査 =='
& python (Join-Path $here 'test_vcpu.py')
$rc = $LASTEXITCODE
Pop-Location
exit $rc
