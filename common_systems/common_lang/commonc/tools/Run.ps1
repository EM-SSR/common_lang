# Run.ps1 — commonc を三つの実行台で走らせ、式 (5.1) の byte 一致を見る。
#
#   1. common        commonc.cam を x86_64-hosted-w と lane64 の image へ落とす
#   2. common_host   C の実行台で commonc を走らせ、.cmn を compile する
#   3. vcpu.py       Python の vCPU で同じことをする
#   4. common        同じ .cmn を Haskell の compiler で落とす
#   5. 照合          三つの image が byte 単位で一致するかを見る
#   6. 実行          compile した image を走らせ、語 0 を読む
#   7. 降下の無い平文  両側とも image を出さないことを見る
#
# 三つ目が本章の要になる（19 §5）。
#
#     commonc(.cmn) = Compile_x86h(.cmn)                            式 (5.1)
#
# 覆いを揃える必要があるので、Haskell 側は語割付けの subtarget を選ぶ（19 §6）。
#
#   語 0   N     入力の byte 数        host が書く
#   語 1   IMGB  image の基底語番号    commonc が書く
#   語 2   nImg  image の byte 数      commonc が書く
#   語 3   nNeed 出来た program が要る語数
#
# 本文の基底は 96B で、B = max(N + 80, 4096) になる（commonc の冒頭）。
# 小さい入力では B = 4096 なので 96B = 393216 語になる。

param(
  [string]$Root = 'D:\work\common-continuous-republics'
)
# native command の stderr で止めない。GHC は警告を stderr へ書くので、
# 'Stop' のままだと警告一本で走らせる前に落ちる。判定は $LASTEXITCODE で取る
$ErrorActionPreference = 'Continue'

$out  = Join-Path $Root 'builds\commonc'
$cmn  = Join-Path $Root 'continuous_republic\examples\cmn'
$src  = Join-Path $Root 'continuous_republic\common_systems\common_lang\commonc\src\commonc.cam'
$vcpu = Join-Path $Root 'continuous_republic\common_systems\Python_vCPU\vcpu.py'
$host_= Join-Path $Root 'builds\common-host\common_host.exe'
$WORDS = 500000
$BASE  = 393216

Push-Location $Root
if (-not (Test-Path $out)) { New-Item -ItemType Directory -Force -Path $out | Out-Null }

Write-Host '== 1. commonc の image =='
& cabal run -v0 common --builddir=builds/dist -- $src -t x86_64-hosted-w -o (Join-Path $out 'commonc.bin') --no-sim
& cabal run -v0 common --builddir=builds/dist -- $src -t lane64 -o (Join-Path $out 'commonc-lane64.bin') --no-sim

# 19 §5.1 の表。語 0 は分子であり、深度は build 時の型なので現れない。
# 並びが検査の対象そのものになる。ここに無い .cmn は降下の表に無い箱を含み、
# commonc も Haskell 側も image を出さない（16 §5 の表）
$want = [ordered]@{ 'futatsu' = 2; 'hitotsu' = 2; 'tsuiki' = 2; 'yonbunnosan' = 3 }

$bad = 0
Write-Host '== 2. 三つの実行台で compile して照合 =='
foreach ($n in $want.Keys) {
  $s = Get-Item (Join-Path $cmn ("{0}.cmn" -f $n))
  $in  = Join-Path $out 'in.cmn'
  Copy-Item $s.FullName $in -Force
  $bHost = Join-Path $out ("host-{0}.bin" -f $n)
  $bVcpu = Join-Path $out ("vcpu-{0}.bin" -f $n)
  $bHs   = Join-Path $out ("hs-{0}.bin"   -f $n)

  & $host_ (Join-Path $out 'commonc.bin') --words $WORDS --in $in --in-base $BASE --emit $bHost | Out-Null
  & python $vcpu (Join-Path $out 'commonc-lane64.bin') --words $WORDS --in $in --in-base $BASE --emit $bVcpu | Out-Null
  & cabal run -v0 common --builddir=builds/dist -- $s.FullName -t x86_64-hosted-w -o $bHs | Out-Null

  $h = [System.IO.File]::ReadAllBytes($bHost)
  $v = [System.IO.File]::ReadAllBytes($bVcpu)
  $r = [System.IO.File]::ReadAllBytes($bHs)
  $same = (@(Compare-Object $h $v -SyncWindow 0).Count -eq 0) -and
          (@(Compare-Object $h $r -SyncWindow 0).Count -eq 0)

  # 出来た image を走らせる。ワイヤは語 64+w、出力境界は語 0 から積む
  $run = & $host_ $bHost --words 4096 --dump 1
  $got = ($run | Select-String -Pattern 'w\[0\]|語\[0\]' | Select-Object -First 1) -replace '.*=\s*', ''
  $okv = ($got -as [int]) -eq $want[$n]

  if ($same -and $okv) {
    Write-Host ("tu   {0,-14} {1,4} byte  三つ一致  値 {2}" -f $n, $h.Length, $got)
  } else {
    Write-Host ("te   {0,-14} byte 一致 {1}  値 {2}（期待 {3}）" -f $n, $same, $got, $want[$n])
    $bad = $bad + 1
  }
}

Write-Host '== 3. 降下の無い平文は image を出さない =='
foreach ($s in (Get-ChildItem -Path $cmn -Filter '*.cmn' | Sort-Object Name)) {
  $n = $s.BaseName
  if ($want.Contains($n)) { continue }
  Copy-Item $s.FullName (Join-Path $out 'in.cmn') -Force
  # commonc の側。降下の表に無い音節は BAD へ分離して te を報告する
  $r1 = & $host_ (Join-Path $out 'commonc.bin') --words $WORDS `
          --in (Join-Path $out 'in.cmn') --in-base $BASE 2>&1
  $ccKo = ($r1 | Select-String -Pattern 'Ko').Count -gt 0
  # Haskell の側。-o を付けたら image が出せないので失敗を返す
  & cabal run -v0 common --builddir=builds/dist -- $s.FullName `
      -t x86_64-hosted-w -o (Join-Path $out ("hs-{0}.bin" -f $n)) 2>&1 | Out-Null
  $hsKo = $LASTEXITCODE -ne 0
  if ($ccKo -and $hsKo) {
    Write-Host ("tu   {0,-14} 両側とも image を出さない" -f $n)
  } else {
    Write-Host ("te   {0,-14} commonc={1} Haskell={2}" -f $n, $ccKo, $hsKo)
    $bad = $bad + 1
  }
}

Pop-Location
if ($bad -eq 0) {
  Write-Host ''
  Write-Host 'tu   commonc は Haskell の compiler を byte 単位で再現し、C と Python の実行台で同じ結果を出す'
  exit 0
}
Write-Host ''
Write-Host ("te   {0} 件が不一致" -f $bad)
exit 1
