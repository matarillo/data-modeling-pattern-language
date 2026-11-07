Set-StrictMode -Version Latest

function Get-PsqlPath {
    param([string]$PgBin = $env:PG_BIN)
    if (-not $PgBin) { throw 'Set PgBin or PG_BIN to the PostgreSQL bin directory or psql executable.' }
    if (Test-Path -LiteralPath $PgBin -PathType Container) { return (Join-Path $PgBin 'psql.exe') }
    return $PgBin
}

function Start-PsqlSession {
    param([string]$Schema, [string]$ApplicationName, [string]$PgBin = $env:PG_BIN,
          [string]$DbHost = '127.0.0.1', [int]$DbPort = 55467,
          [string]$Database = 'research_validation', [string]$DbUser = 'research')
    if ($Schema -notmatch '^v[0-9a-z_]+$') { throw "Unsafe schema name: $Schema" }
    $exe = Get-PsqlPath $PgBin
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $exe
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $utf8=[Text.UTF8Encoding]::new($false)
    $psi.StandardInputEncoding=$utf8; $psi.StandardOutputEncoding=$utf8; $psi.StandardErrorEncoding=$utf8
    foreach ($arg in @('-X','-w','-h',$DbHost,'-p',"$DbPort",'-U',$DbUser,'-d',$Database,'-v','ON_ERROR_STOP=1','-v',"application_name=$ApplicationName")) { [void]$psi.ArgumentList.Add($arg) }
    $proc = [Diagnostics.Process]::new(); $proc.StartInfo=$psi
    if (-not $proc.Start()) { throw 'Could not start psql' }
    $outTask=$proc.StandardOutput.ReadToEndAsync(); $errTask=$proc.StandardError.ReadToEndAsync()
    $proc.StandardInput.WriteLine("\set VERBOSITY verbose`nSET application_name = '$($ApplicationName.Replace("'","''"))'; SET search_path = `"$Schema`", public;")
    $proc.StandardInput.Flush()
    return [pscustomobject]@{ Process=$proc; OutputTask=$outTask; ErrorTask=$errTask; Schema=$Schema; ApplicationName=$ApplicationName }
}

function Send-Sql {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Sql)
    if ($Session.Process.HasExited) { throw "psql session exited: $($Session.ErrorTask.Result)" }
    $Session.Process.StandardInput.WriteLine($Sql)
    $Session.Process.StandardInput.Flush()
}

function Complete-Session {
    param([Parameter(Mandatory)]$Session, [int]$TimeoutSeconds=20)
    $Session.Process.StandardInput.Close()
    if (-not $Session.Process.WaitForExit($TimeoutSeconds*1000)) { $Session.Process.Kill($true); throw 'psql session timed out' }
    $out=$Session.OutputTask.GetAwaiter().GetResult(); $err=$Session.ErrorTask.GetAwaiter().GetResult()
    if ($Session.Process.ExitCode -ne 0) { throw "psql exit $($Session.Process.ExitCode): $err`n$out" }
    return [pscustomobject]@{ ExitCode=$Session.Process.ExitCode; Output=$out; Error=$err }
}

function Invoke-Sql {
    param([Parameter(Mandatory)][string]$Sql, [string]$Schema='v00_smoke', [string]$PgBin=$env:PG_BIN,
          [string]$DbHost='127.0.0.1', [int]$DbPort=55467, [string]$Database='research_validation', [string]$DbUser='research', [int]$TimeoutSeconds=30)
    $s=Start-PsqlSession -Schema $Schema -ApplicationName "harness-$Schema" -PgBin $PgBin -DbHost $DbHost -DbPort $DbPort -Database $Database -DbUser $DbUser
    Send-Sql $s $Sql
    return Complete-Session $s $TimeoutSeconds
}

function Reset-Schema {
    param([Parameter(Mandatory)][string]$Schema, [string]$PgBin=$env:PG_BIN,
          [string]$DbHost='127.0.0.1', [int]$DbPort=55467, [string]$Database='research_validation', [string]$DbUser='research')
    $allowed=@('v00_smoke','v01_smoke','v02_smoke','v03_smoke','v04_smoke')
    if ($Schema -notmatch '^v[0-9a-z_]+$' -or $Schema -notin $allowed) { throw "Schema not explicitly allowed for reset: $Schema" }
    $quoted='"'+$Schema.Replace('"','""')+'"'
    $sql="DROP SCHEMA IF EXISTS $quoted CASCADE; CREATE SCHEMA $quoted; SET search_path=$quoted,public;`n"+(Get-Content -Raw (Join-Path $PSScriptRoot 'fixture.sql'))
    Invoke-Sql -Sql $sql -Schema $Schema -PgBin $PgBin -DbHost $DbHost -DbPort $DbPort -Database $Database -DbUser $DbUser
}

function Wait-Activity {
    param([Parameter(Mandatory)][string]$ApplicationName, [string]$State, [string]$QueryLike, [string]$WaitEvent,
          [int]$TimeoutSeconds=10, [string]$Schema='v00_smoke', [string]$PgBin=$env:PG_BIN,
          [string]$DbHost='127.0.0.1', [int]$DbPort=55467, [string]$Database='research_validation', [string]$DbUser='research')
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $filters=@("application_name = '$($ApplicationName.Replace("'","''"))'")
        if ($State) { $filters += "state = '$($State.Replace("'","''"))'" }
        if ($QueryLike) { $filters += "query LIKE '$($QueryLike.Replace("'","''"))'" }
        if ($WaitEvent) { $filters += "wait_event = '$($WaitEvent.Replace("'","''"))'" }
        $sql="SELECT count(*) FROM pg_stat_activity WHERE $($filters -join ' AND ') AND pid<>pg_backend_pid();"
        $r=Invoke-Sql -Sql $sql -Schema $Schema -PgBin $PgBin -DbHost $DbHost -DbPort $DbPort -Database $Database -DbUser $DbUser
        if ($r.Output -match '(?m)^\s*([1-9][0-9]*)\s*$') { return $true }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Assert-True { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw "ASSERT: $Message" } }

function Invoke-SqlExpectError {
    param([Parameter(Mandatory)][string]$Sql, [Parameter(Mandatory)][string]$SqlState,
          [string]$Schema='v00_smoke', [string]$PgBin=$env:PG_BIN,
          [string]$DbHost='127.0.0.1', [int]$DbPort=55467, [string]$Database='research_validation', [string]$DbUser='research')
    try { Invoke-Sql -Sql $Sql -Schema $Schema -PgBin $PgBin -DbHost $DbHost -DbPort $DbPort -Database $Database -DbUser $DbUser | Out-Null }
    catch {
        if ($_.Exception.Message -match "(?m)\b$([regex]::Escape($SqlState))\b") { return $_.Exception.Message }
        throw
    }
    throw "Expected SQLSTATE $SqlState, but command succeeded"
}
