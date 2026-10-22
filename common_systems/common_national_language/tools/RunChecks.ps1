# コモン公用語の検証ランナー。counter_plane 側のモジュールパスも必要とする。
param(
  [string]$CounterPlaneRoot = (Join-Path $PSScriptRoot '..\..\..\counter_plane')
)
$cp = Join-Path $CounterPlaneRoot 'src'
$nl = Join-Path $PSScriptRoot '..\src'
$paths = @(
  "-i$cp\core", "-i$cp\dag",
  "-i$cp\category\gcls_category", "-i$cp\category\normalized_bool", "-i$cp\category\counter_compute_system",
  "-i$nl\chamber", "-i$nl\word", "-i$nl\grammar", "-i$nl\info", "-i$nl\totality", "-i$nl\multimodal", "-i$nl\speech", "-i$nl\noun", "-i$nl\spec",
  "-i$nl\learn", "-i$nl\text"
)
runghc -outputdir (Join-Path $PSScriptRoot "..\..\..\..\builds\ghci-obj") @paths "$nl\spec\SelfCheck.hs"
Write-Host "--- import gate ---"
& (Join-Path $PSScriptRoot 'CheckImports.ps1')


