# Check.ps1 — commonc と Haskell を突き合わせる（19 式 5.1、7.2）
#
#   commonc_x86h(.cmn)  =  Compile_x86h(.cmn)            byte 単位
#   commonc_lane64(.cmn) を走らせた値  =  core 意味論の値
#
# Haskell は .cam を image へ落とす生成器としてだけ出てくる。
# .cmn を compile するのは常に commonc の image になる。
#
#   .\tools\Check.ps1              corpus を全部通す
#   .\tools\Check.ps1 -Src x.cmn   一本だけ通す

param(
  [string]$Src = '',
  [switch]$Rebuild,
  [switch]$Cupy
)

$ErrorActionPreference = 'Continue'
$root   = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))))
$common = Join-Path $root 'builds\dist\build\x86_64-windows\ghc-9.10.3\common-assembler-0.2.0.0\x\common\build\common\common.exe'
$python = Join-Path $root 'build_tools\venv\Scripts\python.exe'
$vcpu   = Join-Path $root 'continuous_republic\common_systems\Python_vCPU\vcpu.py'
$srcdir = Join-Path $root 'continuous_republic\common_systems\common_lang\commonc\src'
$out    = Join-Path $root 'builds\commonc'

New-Item -ItemType Directory -Force -Path $out | Out-Null

# ---- 第 1 段：Haskell が commonc を lane64 の image へ落とす。ここだけ ----
$ccx = Join-Path $out 'commonc_x86h.bin'
$ccl = Join-Path $out 'commonc_lane64.bin'
# .cam が通らなかったときに古い image で走ると、直したはずの誤りが残ったまま
# 検査が通る。落ちたらそこで止める
if ($Rebuild -or -not (Test-Path $ccx)) {
  foreach ($pair in @(@('commonc_x86h.cam', $ccx), @('commonc_lane64.cam', $ccl))) {
    Remove-Item $pair[1] -ErrorAction SilentlyContinue
    $log = & $common (Join-Path $srcdir $pair[0]) -t lane64 --no-sim -o $pair[1] 2>&1
    if (-not (Test-Path $pair[1])) {
      Write-Host ("te   {0} が image を出さない" -f $pair[0])
      $log | Where-Object { $_ -notmatch '^(utter|source)' } | Select-Object -First 3
      exit 1
    }
  }
}

# 作業領域の割付。刻みは入力から出る（19 式 3.1）
#   B = max(N + 80, 4096)
# 本文の基底は IMG の上に取る。x86h は箱あたり 33 byte、lane64 は 112 byte
function Layout([string]$path, [int]$baseMul) {
  $n = (Get-Item $path).Length
  $b = [Math]::Max($n + 80, 4096)
  return @{ N = $n; B = $b; InBase = $baseMul * $b; Words = $baseMul * $b + $n + 4096 }
}

$list = @()
if ($Src -ne '') {
  $list += (Resolve-Path $Src).Path
} else {
  $list += @(Get-ChildItem (Join-Path $root 'continuous_republic\examples\cmn\*.cmn') | ForEach-Object { $_.FullName })
  $list += @(Get-ChildItem (Join-Path $root 'continuous_republic\examples\intent\*.cmn') | ForEach-Object { $_.FullName })
  $list += @(Get-ChildItem (Join-Path $root 'continuous_republic\examples\vocabulary\*.cmn') | ForEach-Object { $_.FullName })
  $list += @(Get-ChildItem (Join-Path $root 'continuous_republic\examples\region\*.cmn') | ForEach-Object { $_.FullName })
}

$bad = 0
foreach ($f in $list) {
  $n = [System.IO.Path]::GetFileNameWithoutExtension($f)

  # ---- 式 (5.1)：同じ覆いで Haskell が出す image と byte 単位で比べる ----
  # 降下の表に無い箱を含む平文はどちらも image を出さない（16 §5）。
  # それも一致のうちなので、古い image を先に消してから比べる
  Remove-Item "$out\x_$n.bin" -ErrorAction SilentlyContinue
  Remove-Item "$out\h_$n.bin" -ErrorAction SilentlyContinue
  $L = Layout $f 128
  & $python $vcpu $ccx --words $L.Words --in-base $L.InBase --in $f --emit "$out\x_$n.bin" 2>$null | Out-Null
  & $common $f -t x86_64-hosted-w -o "$out\h_$n.bin" --no-sim 2>$null | Out-Null
  $hasX = Test-Path "$out\x_$n.bin"
  $hasH = Test-Path "$out\h_$n.bin"
  $okx = $false
  if ($hasX -and $hasH) {
    $a = [System.IO.File]::ReadAllBytes("$out\h_$n.bin")
    $b = [System.IO.File]::ReadAllBytes("$out\x_$n.bin")
    $okx = ($a.Length -eq $b.Length)
    if ($okx) { for ($i = 0; $i -lt $a.Length; $i++) { if ($a[$i] -ne $b[$i]) { $okx = $false; break } } }
  } elseif (-not $hasX -and -not $hasH) {
    $okx = $true
  }

  # ---- 式 (43.2)：lane64 版が出した image を走らせ、core 意味論と比べる ----
  $L2 = Layout $f 288
  Remove-Item "$out\l_$n.bin" -ErrorAction SilentlyContinue
  & $python $vcpu $ccl --words $L2.Words --in-base $L2.InBase --in $f --emit "$out\l_$n.bin" 2>$null | Out-Null
  $val = '—'
  if (Test-Path "$out\l_$n.bin") {
    $r = & $python $vcpu "$out\l_$n.bin" --words 4096 --dump 1 2>$null
    $m = $r | Select-String 'w\[0\] = (-?\d+)'
    if ($m) { $val = $m.Matches[0].Groups[1].Value }
  }
  # ---- GPU の実行台。語も述語も bit のまま走る（20 章、cuvcpu）----
  $gpu = '—'
  if ($Cupy -and (Test-Path "$out\l_$n.bin")) {
    $g = & $python $vcpu "$out\l_$n.bin" --words 4096 --dump 1 --cupy 2>$null
    $gm = $g | Select-String 'w\[0\] = (-?\d+)'
    if ($gm) { $gpu = $gm.Matches[0].Groups[1].Value }
  }

  $exp = '—'
  $hr = & $common $f --run 2>$null
  $hm = $hr | Select-String '出力\[0\] = (-?\d+)'
  if ($hm) { $exp = $hm.Matches[0].Groups[1].Value }

  # 境界が I の平文は出力語を持たない。どちらも読めなければ一致とみなす
  if ($exp -eq '—') { $val = '—'; $gpu = '—' }
  $okl = ($val -eq $exp)
  $okg = (-not $Cupy) -or ($gpu -eq $exp)
  if (-not $okx) { $bad = 1 }
  if (-not $okl) { $bad = 1 }
  if (-not $okg) { $bad = 1 }
  $line = '{0,-16} 式(5.1) {1,-6} 式(43.2) {2,-6} 分子 {3} / {4}' -f $n,
    $(if ($okx) { '一致' } else { '不一致' }),
    $(if ($okl) { '一致' } else { '不一致' }), $val, $exp
  if ($Cupy) { $line = $line + ('  GPU {0,-6} {1}' -f $(if ($okg) { '一致' } else { '不一致' }), $gpu) }
  $line
}

# 判定は $bad だけで決める。最後に走らせた native command の終了コードを
# そのまま返すと、値を持たない平文が corpus の末尾へ来たときに誤って落ちる
if ($bad -ne 0) { exit 1 }
exit 0
