param(
  [string]$PgBin=$env:PG_BIN,
  [string]$DbHost='127.0.0.1',
  [int]$DbPort=55467,
  [string]$Database='research_validation',
  [string]$DbUser='research'
)
$ErrorActionPreference='Stop'
$connection=@{PgBin=$PgBin;DbHost=$DbHost;DbPort=$DbPort;Database=$Database;DbUser=$DbUser}
$cases=[Collections.Generic.List[object]]::new()
foreach($task in @('V01','V02','V03','V04')) {
  $folder=Join-Path $PSScriptRoot "cases/$task"
  try {
    & (Join-Path $folder 'run.ps1') @connection | Out-Null
    $result=Get-Content -LiteralPath (Join-Path $folder 'results.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if($result.task -ne $task -or !$result.passed -or @($result.checks | Where-Object {!$_.passed}).Count) { throw "Invalid or failed result: $task" }
    $cases.Add([ordered]@{task=$task;passed=$true;checks=@($result.checks).Count;postgres_version=$result.postgres_version;result_file="validation/cases/$task/results.json"})
  } catch {
    $cases.Add([ordered]@{task=$task;passed=$false;checks=0;error=$_.Exception.Message})
  }
}
$passed=@($cases | Where-Object {!$_.passed}).Count -eq 0
$summary=[ordered]@{scope='single-SKU PostgreSQL invariant proofs; no performance or production-permission claim';fixture_sha256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'harness/fixture.sql') -Algorithm SHA256).Hash.ToLowerInvariant();passed=$passed;cases=$cases.ToArray()}
$summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'results.json') -Encoding UTF8
$summary | ConvertTo-Json -Depth 10
if(!$passed){throw 'Validation suite failed; inspect validation/results.json. Failed invocations never reuse previous pass records.'}
