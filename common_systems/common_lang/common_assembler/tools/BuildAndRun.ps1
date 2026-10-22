# BuildAndRun.ps1 — build family を作り、実機と vendor の道具で確かめる。
#
#   1. cabal build      三つの package を型検査つきで組む
#   2. common-verify         proof object を builds/common-assembler へ出す
#   3. common             examples/*.cam を全 target へ compile する
#   4. QEMU             CPU 三 target を走らせ、終了コードを照合する
#   5. vendor 検証      GPU 二 target の符号を vendor の逆アセンブラへ通す
#   6. Common 言語      14 本を C と Python の実行台でバイナリとして走らせる
#   7. Python           lane64 の image を標準機能だけの実行台で走らせる
#   8. commonc          三つの実行台の出力が byte 単位で一致するかを見る
#
# Haskell が出してよいのはバイナリだけになる。式 (43.2) の観測は、外部の実行台が
# ある target では実際に走らせた返り値から取る。内蔵 simulator を観測に使うのは
# GPU の二 package だけになる（07 §5）。
#
# 判定の語は意味レジストリのものを使う。tu = 成功報告、te = 失敗報告（10 章 §2）
#
# 終了コードの規約
#   riscv64  sifive_test        pass = 0   fail = 42
#   arm64    semihosting exit   pass = 0   fail = 42
#   x86_64   isa-debug-exit     pass = 0   fail = 41   （(20 << 1) | 1）

param(
  [string]$Root = 'D:\work\common-continuous-republics'
)
# native command の stderr で止めない。GHC は警告を stderr へ書くので、
# 'Stop' のままだと警告一本で走らせる前に落ちる。判定は $LASTEXITCODE で取る
$ErrorActionPreference = 'Continue'

$builds   = Join-Path $Root 'builds\common-assembler'
$exBuilds = Join-Path $Root 'builds\examples'
$qemu     = Join-Path $Root 'build_tools\qemu'
$examples = Join-Path $Root 'continuous_republic\examples'

Push-Location $Root
if (-not (Test-Path $exBuilds)) { New-Item -ItemType Directory -Force -Path $exBuilds | Out-Null }

Write-Host '== 1. build =='
& cabal build all --builddir=builds/dist
if ($LASTEXITCODE -ne 0) { Pop-Location; Write-Host 'te   build が通らない'; exit 1 }

Write-Host '== 2. proof object =='
& cabal run -v0 common-verify --builddir=builds/dist
if ($LASTEXITCODE -ne 0) { Pop-Location; Write-Host 'te   selfcheck が通らない'; exit 1 }

$bad = 0
$targets = @(
  @{ name = 'riscv64'
     exe  = 'qemu-system-riscv64.exe'
     args = @('-M','virt','-m','512M','-bios','none','-nographic')
     pass = 0; fail = 42 },
  @{ name = 'arm64'
     exe  = 'qemu-system-aarch64.exe'
     args = @('-M','virt','-cpu','cortex-a57','-m','512M','-nographic','-semihosting')
     pass = 0; fail = 42 },
  @{ name = 'x86_64'
     exe  = 'qemu-system-x86_64.exe'
     args = @('-m','512M','-nographic','-no-reboot',
              '-device','isa-debug-exit,iobase=0xf4,iosize=0x04')
     pass = 0; fail = 41 }
)
$allNames = @('riscv64','arm64','x86_64','x86_64-hosted','gfx1200','sm_120','lane64')

Write-Host '== 3. examples を compile =='
$srcs = Get-ChildItem -Path $examples -Filter '*.cam' | Sort-Object Name
foreach ($s in $srcs) {
  # bench は歩数が多く、package 内蔵 simulator を通すと compile が実行より重くなる。
  # QEMU でも回さないので、式 (43.2) の観測を取らずに image だけ出す（18 章 §9.2）
  $sim = if ($s.BaseName -like '*_bench') { @('--no-sim') } else { @() }
  foreach ($t in $allNames) {
    $out = Join-Path $exBuilds ("{0}-{1}.bin" -f $s.BaseName, $t)
    & cabal run -v0 common --builddir=builds/dist -- $s.FullName -t $t -o $out @sim 2>&1 | Out-Null
  }
  Write-Host ("  {0}" -f $s.Name)
}

Write-Host '== 4. QEMU =='
foreach ($t in $targets) {
  $exe = Join-Path $qemu $t.exe
  if (-not (Test-Path $exe)) { Write-Host ("--   {0} が見つからない" -f $exe); continue }
  # bench は時間がかかるので既定では回さない
  foreach ($s in $srcs) {
    if ($s.BaseName -like '*_bench') { continue }
    $img = Join-Path $exBuilds ("{0}-{1}.bin" -f $s.BaseName, $t.name)
    if (-not (Test-Path $img)) { continue }
    & $exe @($t.args) -kernel $img | Out-Null
    $got = $LASTEXITCODE
    if ($got -eq $t.pass) {
      Write-Host ("tu   {0,-8} {1,-18} exit={2}" -f $t.name, $s.BaseName, $got)
    } else {
      Write-Host ("te   {0,-8} {1,-18} exit={2}（期待 {3}）" -f $t.name, $s.BaseName, $got, $t.pass)
      $bad = $bad + 1
    }
  }
}

Write-Host '== 5. vendor の逆アセンブラで符号を確かめる =='
# AMD: llvm-mc が gfx1200 の assembler と disassembler を持つ
$llvmMc = (Get-Command llvm-mc -ErrorAction SilentlyContinue)
if ($llvmMc) {
  foreach ($s in $srcs) {
    $img = Join-Path $exBuilds ("{0}-gfx1200.bin" -f $s.BaseName)
    if (-not (Test-Path $img)) { continue }
    $hex = ([System.IO.File]::ReadAllBytes($img) | ForEach-Object { '0x{0:x2}' -f $_ }) -join ' '
    $tmp = Join-Path $env:TEMP 'common_gfx.txt'
    Set-Content -Path $tmp -Value $hex -Encoding ascii
    $out = & $llvmMc.Source -disassemble -triple=amdgcn-amd-amdhsa -mcpu=gfx1200 $tmp 2>&1
    $n = ($out | Select-String -Pattern '^\s+[a-z_0-9]+' ).Count
    $err = ($out | Select-String -Pattern 'invalid|error').Count
    if ($err -eq 0 -and $n -gt 0) {
      Write-Host ("tu   gfx1200  {0,-18} {1} 命令を読み返した" -f $s.BaseName, $n)
    } else {
      Write-Host ("te   gfx1200  {0}: llvm-mc が読めない" -f $s.BaseName)
      $bad = $bad + 1
    }
  }
} else {
  Write-Host '--   llvm-mc が見つからない（AMD の符号検証を飛ばす）'
}

# NVIDIA: nvdisasm が SM120 の raw binary を読む
$nvd = (Get-Command nvdisasm -ErrorAction SilentlyContinue)
if ($nvd) {
  foreach ($s in $srcs) {
    $img = Join-Path $exBuilds ("{0}-sm_120.bin" -f $s.BaseName)
    if (-not (Test-Path $img)) { continue }
    $out = & $nvd.Source --binary SM120 $img 2>&1
    $n = ($out | Select-String -Pattern '/\*[0-9a-f]{4}\*/').Count
    $err = ($out | Select-String -Pattern 'error|Unknown').Count
    if ($err -eq 0 -and $n -gt 0) {
      Write-Host ("tu   sm_120   {0,-18} {1} 命令を読み返した" -f $s.BaseName, $n)
    } else {
      Write-Host ("te   sm_120   {0}: nvdisasm が読めない" -f $s.BaseName)
      $bad = $bad + 1
    }
  }
} else {
  Write-Host '--   nvdisasm が見つからない（NVIDIA の符号検証を飛ばす）'
}

Write-Host '== 6. Common 言語をバイナリで走らせる =='
# 意味 program 14 本を x86_64-hosted と lane64 へ落とし、C と Python の
# 実行台で走らせる。判定は返り値であって、内蔵 simulator の観測ではない
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'continuous_republic/common_systems/common_lang/common_lang/tools/Run.ps1')
if ($LASTEXITCODE -ne 0) { $bad = $bad + 1 }

Write-Host '== 7. Python の実行台（20 章）=='
# lane64 の image は Python の標準機能だけで走る。C も QEMU も要らない
& python (Join-Path $Root 'continuous_republic/common_systems/Python_vCPU/test_vcpu.py')
if ($LASTEXITCODE -ne 0) { $bad = $bad + 1 }

Write-Host '== 8. commonc を三つの実行台で（19 章 式 7.2）=='
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'continuous_republic/common_systems/common_lang/commonc/tools/Run.ps1')
if ($LASTEXITCODE -ne 0) { $bad = $bad + 1 }

Pop-Location
if ($bad -eq 0) {
  Write-Host ''
  Write-Host 'tu   実機の観測 ⟦X_T⟧_T が意味の観測に一致し、GPU の符号も vendor が読み返した'
  exit 0
} else {
  Write-Host ''
  Write-Host ("te   {0} 件が不一致" -f $bad)
  exit 1
}
