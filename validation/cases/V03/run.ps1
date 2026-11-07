param(
    [string]$PgBin=$env:PG_BIN,
    [string]$DbHost='127.0.0.1',
    [int]$DbPort=55467,
    [string]$Database='research_validation',
    [string]$DbUser='research'
)
. (Join-Path (Split-Path $PSScriptRoot -Parent | Split-Path -Parent | Split-Path -Parent) 'validation/harness/Common.ps1')
$ErrorActionPreference='Stop'
$schema='v03_smoke'
$caseDir=$PSScriptRoot
$resultPath=Join-Path $caseDir 'results.json'
$checks=[Collections.Generic.List[object]]::new()
$observations=[Collections.Generic.List[string]]::new()
$sessionA=$null; $sessionB=$null
$postgresVersion=$null
$failure=$null

function Add-Check([string]$Name,[string]$Expected,[string]$Actual) {
    $ok=($Expected -ceq $Actual)
    $checks.Add([pscustomobject]@{name=$Name; expected=$Expected; actual=$Actual; passed=$ok})
    if (-not $ok) { throw "Check '$Name' failed: expected [$Expected], actual [$Actual]" }
}
function Get-Marker([string]$Sql,[string]$Marker='VALUE=') {
    $r=Invoke-Sql -Sql $Sql -Schema $schema -PgBin $PgBin -DbHost $DbHost -DbPort $DbPort -Database $Database -DbUser $DbUser
    $m=[regex]::Match($r.Output,"(?m)$([regex]::Escape($Marker))([^\r\n]*)")
    if (-not $m.Success) { throw "Output marker $Marker missing from psql result: $($r.Output)" }
    return $m.Groups[1].Value.Trim()
}
function Expect-SqlState([string]$Name,[string]$Sql,[string]$SqlState) {
    try {
        Invoke-Sql -Sql $Sql -Schema $schema -PgBin $PgBin -DbHost $DbHost -DbPort $DbPort -Database $Database -DbUser $DbUser | Out-Null
        Add-Check $Name $SqlState 'SUCCEEDED'
    } catch {
        $actual=if ($_.Exception.Message -match '(?m)ERROR:\s+([0-9A-Z]{5}):') { $Matches[1] } else { 'NO_SQLSTATE' }
        Add-Check $Name $SqlState $actual
    }
}
function Wait-Value([string]$Sql,[string]$Expected,[int]$TimeoutSeconds=12) {
    $end=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try { $v=Get-Marker $Sql }
        catch {
            if ($_.Exception.Message -like 'Output marker * missing from psql result:*') { $v='<not-ready>' }
            else { throw }
        }
        if ($v -ceq $Expected) { return $v }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $end)
    throw "Timed out observing expected database state [$Expected]; last value [$v]"
}
function Stop-SessionSafely($s) {
    if ($null -eq $s) { return }
    try {
        if (-not $s.Process.HasExited) {
            $s.Process.StandardInput.WriteLine('ROLLBACK;')
            $s.Process.StandardInput.Flush()
            $s.Process.StandardInput.Close()
            if (-not $s.Process.WaitForExit(5000)) { $s.Process.Kill($true) }
        }
    } catch { try { if (-not $s.Process.HasExited) { $s.Process.Kill($true) } } catch {} }
}

try {
    Reset-Schema -Schema $schema -PgBin $PgBin -DbHost $DbHost -DbPort $DbPort -Database $Database -DbUser $DbUser | Out-Null
    $postgresVersion=Get-Marker "SELECT 'VALUE='||current_setting('server_version');"
    # Prepare a valid order and invoice through fixture APIs: shipped quantity 3 x JPY 1,000.
    Invoke-Sql -Schema $schema -PgBin $PgBin -DbHost $DbHost -DbPort $DbPort -Database $Database -DbUser $DbUser -Sql "SELECT seed_sku('SKU-V03',10); SELECT accept_order('O-V03',1,3,NULL,'v03-order'); SELECT reserve('O-V03',1,3,'RES-V03','RF-V03','v03-reserve'); SELECT ship('O-V03',1,'RES-V03',3,'SHIP-V03','v03-ship'); SELECT issue_invoice('INV-V03','O-V03',1,3000,'v03-invoice');" | Out-Null

    $first="SELECT 'VALUE='||record_cash_receipt('CASH-V03-1','BANK-V03-1',3000,'JPY','INV-V03','v03-replay-1');"
    Invoke-Sql -Sql $first -Schema $schema -PgBin $PgBin -DbHost $DbHost -DbPort $DbPort -Database $Database -DbUser $DbUser | Out-Null # Response intentionally discarded: model lost acknowledgement.
    $replayed=Get-Marker $first
    Add-Check 'committed request replay returns original result' 'REPLAY:cash_receipt_fact:CASH-V03-1' $replayed
    $afterReplay=Get-Marker "SELECT 'VALUE='||count(*)||'|'||coalesce(sum(amount_jpy),0)||'|'||(SELECT count(*) FROM command_receipt WHERE command_key='v03-replay-1') FROM cash_receipt_fact WHERE external_receipt_id='BANK-V03-1';"
    Add-Check 'replay leaves one fact, original amount, one receipt' '1|3000|1' $afterReplay

    $beforeConflict=Get-Marker "SELECT 'VALUE='||count(*)||'|'||coalesce(sum(amount_jpy),0)||'|'||(SELECT payload_digest FROM command_receipt WHERE command_key='v03-replay-1') FROM cash_receipt_fact WHERE external_receipt_id='BANK-V03-1';"
    Expect-SqlState 'same command key changed amount conflicts' "SELECT record_cash_receipt('CASH-V03-1','BANK-V03-1',2500,'JPY','INV-V03','v03-replay-1');" '22000'
    $afterConflict=Get-Marker "SELECT 'VALUE='||count(*)||'|'||coalesce(sum(amount_jpy),0)||'|'||(SELECT payload_digest FROM command_receipt WHERE command_key='v03-replay-1') FROM cash_receipt_fact WHERE external_receipt_id='BANK-V03-1';"
    Add-Check 'payload conflict leaves committed fact/digest unchanged' $beforeConflict $afterConflict

    Expect-SqlState 'new command key cannot repeat external receipt' "SELECT record_cash_receipt('CASH-V03-DUP','BANK-V03-1',3000,'JPY','INV-V03','v03-new-key-duplicate');" '23505'
    $afterExternalDup=Get-Marker "SELECT 'VALUE='||count(*)||'|'||coalesce(sum(amount_jpy),0)||'|'||(SELECT count(*) FROM command_receipt WHERE command_key='v03-new-key-duplicate') FROM cash_receipt_fact WHERE external_receipt_id='BANK-V03-1';"
    Add-Check 'external duplicate rollback removes command receipt' '1|3000|0' $afterExternalDup

    # Race: A writes but holds its READ COMMITTED transaction; B uses the same key and blocks on command_receipt uniqueness.
    $appA='v03-race-a'; $appB='v03-race-b'
    $sessionA=Start-PsqlSession -Schema $schema -ApplicationName $appA -PgBin $PgBin -DbHost $DbHost -DbPort $DbPort -Database $Database -DbUser $DbUser
    Send-Sql $sessionA "BEGIN ISOLATION LEVEL READ COMMITTED; SELECT record_cash_receipt('CASH-V03-RACE','BANK-V03-RACE',500,'JPY','INV-V03','v03-race-key');"
    [void](Wait-Value "SELECT 'VALUE='||count(*) FROM pg_stat_activity WHERE application_name='$appA' AND state='idle in transaction' AND query LIKE '%record_cash_receipt%';" '1')
    $aHeld=Get-Marker "SELECT 'VALUE='||state||'|'||(query LIKE '%record_cash_receipt%') FROM pg_stat_activity WHERE application_name='$appA';"
    Add-Check 'first backend holds receipt in open transaction' 'idle in transaction|true' $aHeld
    $sessionB=Start-PsqlSession -Schema $schema -ApplicationName $appB -PgBin $PgBin -DbHost $DbHost -DbPort $DbPort -Database $Database -DbUser $DbUser
    Send-Sql $sessionB "BEGIN ISOLATION LEVEL READ COMMITTED; SELECT record_cash_receipt('CASH-V03-RACE','BANK-V03-RACE',500,'JPY','INV-V03','v03-race-key');"
    $waitSql="SELECT 'VALUE='||state||'|'||wait_event_type||'|'||wait_event FROM pg_stat_activity WHERE application_name='$appB' AND state='active' AND wait_event_type='Lock' AND wait_event='transactionid' AND query LIKE '%record_cash_receipt%';"
    $waited=Wait-Value $waitSql 'active|Lock|transactionid' 15
    $observations.Add("pg_stat_activity observed application_name=$appB, state=active, wait_event_type=Lock, wait_event=transactionid, while same-key record_cash_receipt was blocked.")
    Add-Check 'same-key concurrent call observed waiting on uncommitted unique key' 'active|Lock|transactionid' $waited
    Send-Sql $sessionA 'COMMIT;'
    $aDone=Complete-Session $sessionA -TimeoutSeconds 10; $sessionA=$null
    $observations.Add('First backend committed; second backend resumed and completed its idempotent lookup.')
    [void](Wait-Value "SELECT 'VALUE='||count(*) FROM pg_stat_activity WHERE application_name='$appB' AND state='idle in transaction' AND query LIKE '%record_cash_receipt%';" '1')
    Send-Sql $sessionB 'COMMIT;'
    $bDone=Complete-Session $sessionB -TimeoutSeconds 10; $sessionB=$null
    if ($bDone.Output -notmatch 'REPLAY:cash_receipt_fact:CASH-V03-RACE') { throw "Concurrent retry did not return original result: $($bDone.Output)" }
    $checks.Add([pscustomobject]@{name='same-key concurrent caller returns saved result'; expected='REPLAY:cash_receipt_fact:CASH-V03-RACE'; actual='REPLAY:cash_receipt_fact:CASH-V03-RACE'; passed=$true})
    $raceFinal=Get-Marker "SELECT 'VALUE='||count(*)||'|'||coalesce(sum(amount_jpy),0)||'|'||(SELECT count(*) FROM command_receipt WHERE command_key='v03-race-key') FROM cash_receipt_fact WHERE external_receipt_id='BANK-V03-RACE';"
    Add-Check 'concurrent retry leaves one receipt and one command result' '1|500|1' $raceFinal

    $observations.Add('All calls used fixture record_cash_receipt; server computed SHA-256 payload identity from operation and supplied business arguments.')
} catch {
    $failure=$_.Exception.Message
} finally {
    Stop-SessionSafely $sessionA
    Stop-SessionSafely $sessionB
    $passed=($null -eq $failure) -and (@($checks | Where-Object { -not $_.passed }).Count -eq 0)
    $result=[ordered]@{task='V03'; passed=$passed; postgres_version=$postgresVersion; checks=@($checks.ToArray()); observations=@($observations.ToArray())}
    if ($failure) { $result.error=$failure }
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath -Encoding utf8
}
if (-not $passed) { throw "V03 failed; see $resultPath. $failure" }
Write-Output "V03 passed on PostgreSQL $postgresVersion; results: $resultPath"
