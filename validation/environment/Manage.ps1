param(
  [ValidateSet('Start','Stop','Status')][string]$Action = 'Status',
  [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path,
  [string]$PgBin = $env:PG_BIN,
  [int]$Port = 55467
)
$ErrorActionPreference = 'Stop'
if (-not $PgBin) { throw 'Set PgBin or PG_BIN to the PostgreSQL bin directory.' }
$PSNativeCommandUseErrorActionPreference = $false
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
$runtime = Join-Path $RepoRoot '.local/postgres'
$data = Join-Path $runtime 'data'
$pgctl = Join-Path $PgBin 'pg_ctl.exe'
$psql = Join-Path $PgBin 'psql.exe'
function Invoke-Pg([string]$Sql) {
  $out = & $psql -X -w -h 127.0.0.1 -p $Port -U research -d postgres -v ON_ERROR_STOP=1 -At -c $Sql 2>&1
  if ($LASTEXITCODE -ne 0) { throw ($out -join "`n") }
  return ($out -join "`n").Trim()
}
if ($Action -eq 'Start') {
  New-Item -ItemType Directory -Force -Path $runtime | Out-Null
  if (!(Test-Path (Join-Path $data 'PG_VERSION'))) {
    & (Join-Path $PgBin 'initdb.exe') -D $data -U research --auth=trust --encoding=UTF8 --locale=C *> (Join-Path $runtime 'initdb.log')
    if ($LASTEXITCODE -ne 0) { throw "initdb failed; inspect $runtime/initdb.log" }
  }
  & $pgctl status -D $data *> $null
  if ($LASTEXITCODE -ne 0) {
    $pgArgs = @('start','-D',('"' + $data + '"'),'-l',('"' + (Join-Path $runtime 'server.log') + '"'),'-o',('"-h 127.0.0.1 -p ' + $Port + '"'),'-w','-t','30')
    $starter = Start-Process -FilePath $pgctl -ArgumentList $pgArgs -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $runtime 'start.log') -RedirectStandardError (Join-Path $runtime 'start-error.log')
    if (!$starter.WaitForExit(40000)) { throw 'pg_ctl start timed out' }
    if ($starter.ExitCode -ne 0) { throw "pg_ctl start failed; inspect $runtime/start.log" }
  }
  $actualData = Invoke-Pg 'SHOW data_directory'
  if ([IO.Path]::GetFullPath($actualData) -ne [IO.Path]::GetFullPath($data)) { throw 'Unexpected database server; refusing to use it' }
  if ((Invoke-Pg "SELECT count(*) FROM pg_database WHERE datname='research_validation'") -eq '0') {
    Invoke-Pg 'CREATE DATABASE research_validation' | Out-Null
  }
}
if ($Action -eq 'Stop') {
  if (Test-Path (Join-Path $data 'PG_VERSION')) {
    & $pgctl status -D $data *> $null
    if ($LASTEXITCODE -eq 0) {
      & $pgctl stop -D $data -m fast -w -t 30 *> (Join-Path $runtime 'stop.log')
      if ($LASTEXITCODE -ne 0) { throw 'pg_ctl stop failed' }
    }
  }
  [ordered]@{action='Stop';stopped=$true;data=$data} | ConvertTo-Json
  exit 0
}
& $pgctl status -D $data *> $null
$running = $LASTEXITCODE -eq 0
[ordered]@{action=$Action;running=$running;host='127.0.0.1';port=$Port;database='research_validation';user='research';version=$(if($running){Invoke-Pg 'SELECT version()'}else{$null});data=$data} | ConvertTo-Json
