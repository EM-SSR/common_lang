$rules = @{
  'RealUnit'           = @('CounterConstraints')
  'CounterInteger'     = @('CounterConstraints', 'RealUnit')
  'CounterUnits'       = @('CounterConstraints', 'RealUnit', 'CounterInteger')
  'CounterExtend'      = @('CounterConstraints', 'RealUnit', 'CounterInteger', 'CounterUnits')
  'DagPlane'           = @('CounterConstraints', 'RealUnit', 'CounterInteger', 'CounterUnits')
  'DagArith'           = @('CounterConstraints', 'RealUnit', 'CounterInteger', 'CounterUnits', 'DagPlane')
  'DagInfluence'       = @('CounterConstraints', 'RealUnit', 'CounterInteger', 'CounterUnits', 'DagPlane')
  'CounterDag'         = @('CounterConstraints', 'RealUnit', 'CounterInteger', 'CounterUnits')
  'GclsCategory'       = @('CounterConstraints', 'CounterInteger', 'CounterUnits', 'DagPlane')
  'NormalizedBool'     = @('CounterConstraints')
  'CounterComputeSystem' = @('CounterConstraints')
}

$needsPreludeGate = @(
  'RealUnit', 'CounterInteger', 'CounterUnits', 'CounterExtend',
  'DagPlane', 'DagArith', 'DagInfluence', 'CounterDag',
  'GclsCategory', 'NormalizedBool', 'CounterComputeSystem'
)

$fail = 0
$files = Get-ChildItem (Join-Path $PSScriptRoot '..\src\core\*.hs') +
         Get-ChildItem (Join-Path $PSScriptRoot '..\src\dag\*.hs') +
         Get-ChildItem (Join-Path $PSScriptRoot '..\src\category') -Recurse -Filter *.hs
$files | ForEach-Object {
  $mod = $_.BaseName
  if ($mod -in @('CounterType', 'CounterConstraints')) {
    Write-Host "base $mod (土台: base 語彙の使用を許す)"
    return
  }
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
