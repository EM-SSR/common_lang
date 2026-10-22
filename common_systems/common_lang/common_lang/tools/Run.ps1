# Run.ps1 — Common 言語の意味 program を、バイナリとして走らせて確かめる。
#
# Haskell が出してよいのはバイナリだけになる。判定は package 内蔵 simulator の
# 観測ではなく、実際に走らせた返り値で取る。
#
#   1. common       14 本を x86_64-hosted と lane64 の image へ落とす（--no-sim）
#   2. common_host  C の実行台で x86_64 の機械語を走らせる         18 章 式 (7.1)
#   3. vcpu.py      Python の実行台で lane64 の機械語を走らせる    20 章 §11
#   4. 照合         二つの実行台の報告が一致するかを見る
#
# program は自分で入力表と期待表を置き、出力と期待値を 1 語ずつ突き合わせて
# Ok / Ko を返す。だから host は返り値だけを読めばよい（13 章 §5）。
#
#     [[X_T]]_T = tu   OUT = EXP
#               = te   一致しない                                式 (5.1)
#
# 二つの実行台は互いに独立に書いてある。どちらか一方の誤りは突き合わせで出る。

param(
  [string]$Root = 'D:\work\common-continuous-republics'
)
# native command の stderr で止めない。GHC は警告を stderr へ書くので、
# 'Stop' のままだと警告一本で走らせる前に落ちる。判定は $LASTEXITCODE で取る
$ErrorActionPreference = 'Continue'

$src   = Join-Path $Root 'continuous_republic\common_systems\common_lang\common_lang\src'
$out   = Join-Path $Root 'builds\common-lang'
$vcpu  = Join-Path $Root 'continuous_republic\common_systems\Python_vCPU\vcpu.py'
$host_ = Join-Path $Root 'builds\common-host\common_host.exe'
$hostC = Join-Path $Root 'continuous_republic\common_systems\common_lang\common_host\common_host.c'
$WORDS = 65536

Push-Location $Root
if (-not (Test-Path $out)) { New-Item -ItemType Directory -Force -Path $out | Out-Null }

if (-not (Test-Path $host_)) {
  Write-Host '== 0. C の実行台を組む =='
  & gcc -O2 -o $host_ $hostC
  if ($LASTEXITCODE -ne 0) { Pop-Location; Write-Host 'te   common_host が組めない'; exit 1 }
}

$srcs = Get-ChildItem -Path $src -Recurse -Filter '*.cam' | Sort-Object Name
$bad = 0

Write-Host '== 1. image を出す（Haskell はここだけ）=='
foreach ($s in $srcs) {
  $n = $s.BaseName
  & cabal run -v0 common --builddir=builds/dist -- $s.FullName `
      -t x86_64-hosted -o (Join-Path $out ("{0}-x86.bin" -f $n)) --no-sim | Out-Null
  if ($LASTEXITCODE -ne 0) { Write-Host ("te   {0}: x86_64-hosted へ落ちない" -f $n); $bad = $bad + 1 }
  & cabal run -v0 common --builddir=builds/dist -- $s.FullName `
      -t lane64 -o (Join-Path $out ("{0}-lane64.bin" -f $n)) --no-sim | Out-Null
  if ($LASTEXITCODE -ne 0) { Write-Host ("te   {0}: lane64 へ落ちない" -f $n); $bad = $bad + 1 }
}
Write-Host ("     {0} 本" -f $srcs.Count)

Write-Host '== 2. 二つの実行台で走らせる =='
foreach ($s in $srcs) {
  $n  = $s.BaseName
  $bx = Join-Path $out ("{0}-x86.bin" -f $n)
  $bl = Join-Path $out ("{0}-lane64.bin" -f $n)
  if (-not ((Test-Path $bx) -and (Test-Path $bl))) { continue }

  $rc = & $host_ $bx --words $WORDS
  $cOk = ($rc | Select-String -Pattern 'Ok').Count -gt 0

  & python $vcpu $bl --words $WORDS | Out-Null
  $pOk = $LASTEXITCODE -eq 0

  $bxLen = (Get-Item $bx).Length
  $blLen = (Get-Item $bl).Length
  if ($cOk -and $pOk) {
    Write-Host ("tu   {0,-10} C {1,6} byte   Python {2,6} byte" -f $n, $bxLen, $blLen)
  } else {
    Write-Host ("te   {0,-10} C={1} Python={2}" -f $n, $cOk, $pOk)
    $bad = $bad + 1
  }
}

Pop-Location
if ($bad -eq 0) {
  Write-Host ''
  Write-Host 'tu   Common 言語の意味 program は、二つの実行台でバイナリとして走り tu を返す'
  exit 0
}
Write-Host ''
Write-Host ("te   {0} 件が不一致" -f $bad)
exit 1
