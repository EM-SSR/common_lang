# RunAll.ps1 — 全テストとデモを実行する
param(
  [string]$CounterPlaneRoot = (Join-Path $PSScriptRoot '..\..\..\counter_plane')
)
$cpsrc = Join-Path $CounterPlaneRoot 'src'
$nlsrc = Join-Path $PSScriptRoot '..\src'
$ispec = @(
  "-i$(Join-Path $cpsrc 'core')"
  "-i$(Join-Path $cpsrc 'dag')"
  "-i$(Join-Path $cpsrc 'category\gcls_category')"
  "-i$(Join-Path $cpsrc 'category\normalized_bool')"
  "-i$(Join-Path $cpsrc 'category\counter_compute_system')"
  "-i$(Join-Path $nlsrc 'chamber')"
  "-i$(Join-Path $nlsrc 'word')"
  "-i$(Join-Path $nlsrc 'grammar')"
  "-i$(Join-Path $nlsrc 'info')"
  "-i$(Join-Path $nlsrc 'totality')"
  "-i$(Join-Path $nlsrc 'multimodal')"
  "-i$(Join-Path $nlroot 'src\speech')"
)

Write-Host "=== counter_plane テスト ==="
runghc @paths "$cp\spec\SelfCheck.hs" 2>&1 | Select-String "total|FAIL"

Write-Host "=== コモン公用語テスト ==="
runghc @paths "$nl\spec\SelfCheck.hs" 2>&1 | Select-String "total|FAIL"

Write-Host "=== import gate ==="
& (Join-Path $PSScriptRoot 'CheckImports.ps1') 2>&1 | Select-String "violations"


