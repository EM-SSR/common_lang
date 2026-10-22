$rules = @{
  'CommonChamber'     = @('CounterConstraints', 'CounterUnits', 'CounterComputeSystem', 'DagArith', 'GclsCategory')
  'Ideogram'          = @('CounterConstraints', 'CounterUnits', 'DagPlane', 'CommonChamber', 'CounterComputeSystem')
  'SparseTensor'      = @('CounterConstraints', 'CommonChamber')
  'Totality'         = @('CounterConstraints', 'CommonChamber', 'CounterUnits', 'DagArith', 'CounterComputeSystem')
'Multimodal'        = @('CounterConstraints', 'CommonChamber')
'Speech'            = @('CounterConstraints', 'CommonChamber', 'InfoTheory', 'CounterComputeSystem')
'Abbrev'            = @('CounterConstraints', 'CommonChamber', 'Speech', 'CounterComputeSystem', 'InfoTheory')
'NounNet'           = @('CounterConstraints', 'CounterUnits', 'CommonChamber', 'GclsCategory')
'Metanoun'          = @('CounterConstraints', 'CounterComputeSystem', 'CounterUnits', 'CommonChamber', 'DagPlane', 'Ideogram', 'GclsCategory', 'Multimodal', 'NounNet', 'Abbrev', 'Speech')
'InfoTheory'        = @('CounterConstraints', 'CommonChamber', 'CounterUnits', 'CounterComputeSystem', 'DagArith', 'GclsCategory')
'SentenceGrammar'   = @('CounterConstraints', 'DagArith', 'Ideogram', 'CommonChamber', 'SparseTensor', 'CounterUnits', 'GclsCategory')
'PathAlgebra'       = @('CounterConstraints', 'CounterUnits', 'GclsCategory', 'NounNet', 'Metanoun', 'Ideogram', 'CommonChamber')
}

$needsPreludeGate = @('CommonChamber', 'Ideogram', 'SparseTensor', 'SentenceGrammar', 'InfoTheory', 'Totality', 'Multimodal', 'Speech', 'Abbrev', 'NounNet', 'Metanoun', 'PathAlgebra')

$fail = 0
$files = Get-ChildItem (Join-Path $PSScriptRoot '..\src') -Recurse -Filter *.hs |
  Where-Object { $_.Directory.Name -ne 'spec' }
$files | ForEach-Object {
  $mod = $_.BaseName
  if (-not $rules.ContainsKey($mod)) { Write-Host "skip $mod (検証ランナー)"; return }
  $imports = Select-String -Path $_.FullName -Pattern '^import\s+([A-Za-z0-9_.]+)' |
    ForEach-Object { $_.Matches[0].Groups[1].Value }
  $bad = @($imports | Where-Object { $_ -notin $rules[$mod] })
  if ($bad.Count -gt 0) {
    Write-Host "VIOLATION ${mod} imports: $($bad -join ', ')"; $fail++
  } else {
    Write-Host "ok   ${mod} imports"
  }
  if ($mod -in $needsPreludeGate) {
    $gate = Select-String -Path $_.FullName -Pattern 'NoImplicitPrelude'
    if (-not $gate) { Write-Host "VIOLATION ${mod}: NoImplicitPrelude がない"; $fail++ }
    else { Write-Host "ok   ${mod} prelude gate" }
  }
}
Write-Host "violations: $fail"
exit $fail










