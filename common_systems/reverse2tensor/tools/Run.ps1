# Run.ps1 — reverse2tensor を組んで走らせ、基準実装と突き合わせる。
#
#   1. common          reverse2tensor.cam を x86_64-hosted の image へ落とす
#   2. gcc             common_host を組む。メモリ確保と thread はここが持つ
#   3. common_host     音節列を入れて直方体を取り出す
#   4. 照合           SparseTensor.encodeTensor と同じ byte 列になるかを見る
#
# 期待値は SparseTensor の selfcheck が同じ数式から立てているものと同じである。
# 二つの実装が独立に同じ byte を出すことが、この突き合わせの内容になる。
#
#   入力            意味                                        期待
#   sekasoka        beta ; fold                                 1 1 2 0 | 1 1 1 | 6 7
#   noka            addd（入力二本）                            1 2 1 0 | 2 1   | 17 0
#   kihaka          無声ワイヤ + negd                           1 2 1 0 | 2 2   | 0 18
#   nokaseka        addd ; beta                                 1 2 2 0 | 2 1 1 | 17 0 6 0
#   kisekanoka      (無声 + beta) ; addd                        1 2 2 0 | 2 2 1 | 0 6 17 0
#   三語            上の最初の三つを並べたもの                  4 + 3·((2+1)+2·2) = 25 byte

param(
  [string]$Root = 'D:\work\common-continuous-republics'
)
# native command の stderr で止めない。GHC は警告を stderr へ書くので、
# 'Stop' のままだと警告一本で走らせる前に落ちる。判定は $LASTEXITCODE で取る
$ErrorActionPreference = 'Continue'

$src   = Join-Path $Root 'continuous_republic\common_systems\reverse2tensor\src\reverse2tensor.cam'
$host_ = Join-Path $Root 'continuous_republic\common_systems\common_lang\common_host\common_host.c'
$out   = Join-Path $Root 'builds\reverse2tensor'
if (-not (Test-Path $out)) { New-Item -ItemType Directory -Force -Path $out | Out-Null }

Push-Location $Root

Write-Host '== 1. image =='
& cabal run -v0 common -- $src -t x86_64-hosted -o (Join-Path $out 'r2t.bin') --no-sim

Write-Host '== 2. host =='
& gcc -O2 -o (Join-Path $out 'common_host.exe') $host_

Write-Host '== 3. 照合 =='
$cases = @(
  @{ text = "sekasoka`n";                   want = '1 1 2 0 1 1 1 6 7' },
  @{ text = "noka`n";                       want = '1 2 1 0 2 1 17 0' },
  @{ text = "kihaka`n";                     want = '1 2 1 0 2 2 0 18' },
  @{ text = "nokaseka`n";                   want = '1 2 2 0 2 1 1 17 0 6 0' },
  @{ text = "kisekanoka`n";                 want = '1 2 2 0 2 2 1 0 6 17 0' },
  @{ text = "sekasoka`nnoka`nkihaka`n";     want = '3 2 2 0 1 1 1 6 0 7 0 2 1 0 17 0 0 0 2 2 0 0 18 0 0' }
)

$bad = 0
foreach ($c in $cases) {
  $inp = Join-Path $out 'in.cmn'
  $res = Join-Path $out 'out.bin'
  [System.IO.File]::WriteAllText($inp, $c.text)
  & (Join-Path $out 'common_host.exe') (Join-Path $out 'r2t.bin') `
      --lanes 1 --words 8192 --in-base 4096 --in $inp --emit $res | Out-Null
  $got = (([System.IO.File]::ReadAllBytes($res)) | ForEach-Object { $_ }) -join ' '
  $label = $c.text -replace "`n", '/'
  if ($got -eq $c.want) {
    Write-Host ("  ok   {0,-26} {1}" -f $label, $got)
  } else {
    Write-Host ("  FAIL {0,-26} 得た {1} / 期待 {2}" -f $label, $got, $c.want)
    $bad = $bad + 1
  }
}

Pop-Location
if ($bad -gt 0) { Write-Host "不一致 $bad 件"; exit 1 }
Write-Host '全件一致'
