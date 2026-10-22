# 名詞の全列挙を CSV へ書き出す。
# テスト専用の Haskell エントリポイントは作らない。既存のデモランナー
# src/spec/PhraseDemo.hs の「例文 6」出力から、マーカー行以降の CSV 行を
# 抽出して builds/nouns.csv へ書き込むだけである。
param(
  [string]$CounterPlaneRoot = (Join-Path $PSScriptRoot '..\..\..\counter_plane')
)
$ErrorActionPreference = 'Stop'
$cp  = Join-Path $CounterPlaneRoot 'src'
$nl  = Join-Path $PSScriptRoot '..\src'
$outDir = Join-Path $PSScriptRoot '..\builds'
$out = Join-Path $outDir 'nouns.csv'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

$paths = @(
  "-i$cp\core", "-i$cp\dag",
  "-i$cp\category\gcls_category", "-i$cp\category\normalized_bool", "-i$cp\category\counter_compute_system",
  "-i$nl\chamber", "-i$nl\word", "-i$nl\grammar", "-i$nl\info", "-i$nl\totality",
  "-i$nl\multimodal", "-i$nl\speech", "-i$nl\noun", "-i$nl\spec"
)

$output = runghc @paths (Join-Path $nl 'spec\PhraseDemo.hs') 2>&1 | ForEach-Object { "$_" }

$startIdx = -1
for ($i = 0; $i -lt $output.Count; $i++) {
  if ($output[$i] -match '^-----8<----- nouns\.csv') { $startIdx = $i; break }
}
if ($startIdx -lt 0) { Write-Host "FAIL: マーカー行が見つからない"; exit 1 }

$rows = @($output[($startIdx + 1) .. ($output.Count - 1)] | Where-Object { $_ -match '^"' })
if ($rows.Count -lt 2) { Write-Host "FAIL: CSV 行が足りない"; exit 1 }

Set-Content -Path $out -Value $rows -Encoding UTF8
Write-Host ("ok   名詞レコード " + ($rows.Count - 1) + " 件 -> " + $out)
$rows | Select-Object -First 6 | ForEach-Object { Write-Host ("     " + $_) }
exit 0
