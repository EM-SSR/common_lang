# InvokeGHC.ps1 — 全パスを設定して GHC コマンドを実行する共通ラッパー
# ビルド成果物 (.o/.hi) は builds/ghc/ に集約され、src を汚染しない
param(
  [Parameter(Mandatory)]
  [string]$GhcCmd,
  [Parameter(Mandatory)]
  [string]$Target,
  [string[]]$ExtraArgs = @(),
  [string]$Output = ""
)

$counterPlaneSrc = Join-Path $PSScriptRoot "..\..\..\counter_plane\src"
$nlSrc = Join-Path $PSScriptRoot "..\src"

$outDir = Join-Path $PSScriptRoot "..\..\..\..\builds\ghc"

$iFlags = @(
  "-i" + (Join-Path $counterPlaneSrc "core")
  "-i" + (Join-Path $counterPlaneSrc "dag")
  "-i" + (Join-Path $counterPlaneSrc "category\gcls_category")
  "-i" + (Join-Path $counterPlaneSrc "category\normalized_bool")
  "-i" + (Join-Path $counterPlaneSrc "category\counter_compute_system")
  "-i" + (Join-Path $nlsrc "chamber")
  "-i" + (Join-Path $nlsrc "word")
  "-i" + (Join-Path $nlsrc "grammar")
  "-i" + (Join-Path $nlsrc "info")
  "-i" + (Join-Path $nlsrc "totality")
  "-i" + (Join-Path $nlsrc "multimodal")
  "-i" + (Join-Path $nlsrc "speech")
)

$allArgs = @("-outputdir$($PSScriptRoot)\..\..\..\..\builds\ghc") + $iFlags + @($Target) + $ExtraArgs

if ($Output -ne "") {
  & $GhcCmd @allArgs -o $Output
} else {
  & $GhcCmd @allArgs
}
