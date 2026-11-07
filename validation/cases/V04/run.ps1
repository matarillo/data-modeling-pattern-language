param(
    [string]$PgBin=$env:PG_BIN,
    [string]$DbHost='127.0.0.1',
    [int]$DbPort=55467,
    [string]$Database='research_validation',
    [string]$DbUser='research'
)
. (Join-Path (Split-Path $PSScriptRoot -Parent | Split-Path -Parent | Split-Path -Parent) 'validation/harness/Common.ps1')
$ErrorActionPreference='Stop'
$schema='v04_smoke'
$conn=@{ Schema=$schema; PgBin=$PgBin; DbHost=$DbHost; DbPort=$DbPort; Database=$Database; DbUser=$DbUser }
$checks=[System.Collections.Generic.List[object]]::new()
$observations=[System.Collections.Generic.List[object]]::new()
$sessions=[System.Collections.Generic.List[object]]::new()
$results=[ordered]@{task='V04';passed=$false;postgres_version=$null;checks=$checks;observations=$observations}
$fatal=$null

function Add-Check([string]$Name,$Expected,$Actual) {
    $ok=([string]$Expected -ceq [string]$Actual)
    $checks.Add([ordered]@{name=$Name;expected=$Expected;actual=$Actual;passed=$ok})
    return $ok
}
function Require-Check([string]$Name,$Expected,$Actual) {
    if (-not (Add-Check $Name $Expected $Actual)) { throw "Check failed: $Name expected=[$Expected] actual=[$Actual]" }
}
function Invoke-Local([string]$Sql) { Invoke-Sql -Sql $Sql @conn }
function Read-CopyRow([string]$Sql) {
    $query=$Sql.Trim().TrimEnd(';')
    $r=Invoke-Local "COPY ($query) TO STDOUT;"
    $line=($r.Output -split "`r?`n" | Where-Object { $_.Trim() -and $_.Trim() -notmatch '^(SET|COPY \d+)$' } | Select-Object -First 1)
    if (-not $line) { throw "COPY row not found in psql output: $($r.Output) $($r.Error)" }
    return $line
}
function Wait-PgRow([string]$App,[string]$State,[string]$WaitType,[int]$TimeoutSeconds=15,[string]$QueryLike='') {
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $appSql=$App.Replace("'","''")
        $filters="application_name='$appSql' AND pid<>pg_backend_pid()"
        if ($State) { $filters += " AND state='$($State.Replace("'","''"))'" }
        if ($WaitType) { $filters += " AND wait_event_type='$($WaitType.Replace("'","''"))'" }
        if ($QueryLike) { $filters += " AND query LIKE '$($QueryLike.Replace("'","''"))'" }
        $sql="SELECT concat_ws('|',pid::text,state,coalesce(wait_event_type,''),coalesce(wait_event,''),array_to_string(pg_blocking_pids(pid),','),replace(query,E'\\n',' ')) FROM pg_stat_activity WHERE $filters"
        $r=Invoke-Local "COPY ($sql) TO STDOUT;"
        $line=($r.Output -split "`r?`n" | Where-Object { $_ -match '^\d+\|' } | Select-Object -First 1)
        if ($line) { return $line }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for pg_stat_activity row: app=$App state=$State wait=$WaitType"
}
function Finish-Psql($Session) {
    if (-not $Session.Process.HasExited) {
        try { Send-Sql $Session '\q' } catch {}
        try { return Complete-Session $Session 10 } catch {
            if (-not $Session.Process.HasExited) { throw }
        }
    }
    $out=$Session.OutputTask.GetAwaiter().GetResult()
    $err=$Session.ErrorTask.GetAwaiter().GetResult()
    return [pscustomobject]@{ExitCode=$Session.Process.ExitCode;Output=$out;Error=$err}
}
function Stop-AnySession($Session) {
    if ($Session -and -not $Session.Process.HasExited) {
        try { $Session.Process.Kill($true); [void]$Session.Process.WaitForExit(5000) } catch {}
        try { [void]$Session.OutputTask.GetAwaiter().GetResult() } catch {}
        try { [void]$Session.ErrorTask.GetAwaiter().GetResult() } catch {}
    }
}
function Reset-And-Seed([string]$Label) {
    Reset-Schema -Schema $schema -PgBin $PgBin -DbHost $DbHost -DbPort $DbPort -Database $Database -DbUser $DbUser | Out-Null
    Invoke-Local "SELECT seed_sku('SKU-1',10); SELECT accept_order('O-1',1,8,NULL,'$Label-order'); SELECT reserve('O-1',1,8,'RES-1','RF-1','$Label-reserve'); SELECT ship('O-1',1,'RES-1',3,'SHIP-1','$Label-ship3');" | Out-Null
}
function Read-State([string]$LosingKey) {
    $lose=$LosingKey.Replace("'","''")
    $sql=@"
SELECT concat_ws('|',b.on_hand,b.reserved,b.version_no,o.current_revision_no,o.ordered_qty,o.shipped_qty,o.cancelled_qty,o.reserved_qty,o.version_no,r.rebuilt_on_hand,r.rebuilt_reserved,r.shipped_qty,r.cancelled_qty,r.reserved_qty,(SELECT count(*) FROM shipment_fact),(SELECT count(*) FROM cancellation_fact),(SELECT count(*) FROM reservation_fact),(SELECT count(*) FROM command_receipt WHERE command_key='$lose'))
FROM inventory_balance_projection b JOIN order_fulfillment_projection o ON o.order_id='O-1' JOIN source_rebuild r ON r.order_id=o.order_id WHERE b.sku_id='SKU-1';
"@
    return (Read-CopyRow $sql).Split('|')
}
function Run-Race([string]$Label,[ValidateSet('ship','cancel')][string]$Winner,[ValidateSet('ship','cancel')][string]$Loser) {
    Reset-And-Seed $Label
    $before=Read-State "$Label-never"
    Require-Check "$Label baseline on_hand" '7' $before[0]
    Require-Check "$Label baseline reserved" '5' $before[1]
    Require-Check "$Label baseline shipped/cancelled" '3/0' "$($before[5])/$($before[6])"

    $aApp="v04-$Label-a-$Winner"
    $bApp="v04-$Label-b-$Loser"
    $a=Start-PsqlSession -Schema $schema -ApplicationName $aApp -PgBin $PgBin -DbHost $DbHost -DbPort $DbPort -Database $Database -DbUser $DbUser
    $sessions.Add($a)
    $aCall=if($Winner -eq 'ship') { "SELECT ship('O-1',1,'RES-1',5,'SHIP-RACE-$Label','cmd-$Label-winner');" } else { "SELECT cancel_remaining('O-1',1,'RES-1',5,'customer_cancel_remaining','CANCEL-RACE-$Label','cmd-$Label-winner');" }
    Send-Sql $a "BEGIN ISOLATION LEVEL READ COMMITTED;`n$aCall"
    $aIdle=Wait-PgRow $aApp 'idle in transaction' '' 15 -QueryLike "%cmd-$Label-winner%"
    $observations.Add([ordered]@{race=$Label;phase='winner_function_returned_inside_open_transaction';backend=$aIdle})

    $b=Start-PsqlSession -Schema $schema -ApplicationName $bApp -PgBin $PgBin -DbHost $DbHost -DbPort $DbPort -Database $Database -DbUser $DbUser
    $sessions.Add($b)
    $bCall=if($Loser -eq 'ship') { "SELECT ship('O-1',1,'RES-1',5,'SHIP-LOSER-$Label','cmd-$Label-loser');" } else { "SELECT cancel_remaining('O-1',1,'RES-1',5,'customer_cancel_remaining','CANCEL-LOSER-$Label','cmd-$Label-loser');" }
    Send-Sql $b "BEGIN ISOLATION LEVEL READ COMMITTED;`n$bCall"
    $blocked=Wait-PgRow $bApp 'active' 'Lock' 20 -QueryLike "%cmd-$Label-loser%"
    $observations.Add([ordered]@{race=$Label;phase='loser_blocked_on_database_lock';backend=$blocked})
    $parts=$blocked -split '\|',6
    $winnerPid=($aIdle -split '\|',2)[0]
    Require-Check "$Label losing backend state" 'active' $parts[1]
    Require-Check "$Label lock wait type" 'Lock' $parts[2]
    Require-Check "$Label has blocking backend" $true ([bool]($parts[4]))
    Require-Check "$Label blocked by winning backend" $winnerPid $parts[4]

    Send-Sql $a 'COMMIT;'
    [void](Finish-Psql $a)
    $aResult='committed'
    $bResult=$null
    try { $bResult=Finish-Psql $b } catch { $bResult=[pscustomobject]@{ExitCode=3;Output='';Error=$_.Exception.Message} }
    $errorText="$($bResult.Error)`n$($bResult.Output)"
    $sqlState=if($errorText -match '(?m)\b23514\b') {'23514'} else {'not-observed'}
    $observations.Add([ordered]@{race=$Label;phase='loser_error';winner=$aResult;loser_exit_code=$bResult.ExitCode;sqlstate=$sqlState;error=$errorText.Trim()})
    Require-Check "$Label losing operation SQLSTATE" '23514' $sqlState

    $after=Read-State "cmd-$Label-loser"
    $expected=if($Winner -eq 'ship') {@('2','0','3','1','8','8','0','0','3','2','0','8','0','0','2','0','3','0')} else {@('7','0','3','1','8','3','5','0','3','7','0','3','5','0','1','1','3','0')}
    $names=@('on_hand','inventory_reserved','inventory_version','current_revision','ordered_qty','shipped_qty','cancelled_qty','order_reserved','order_version','source_on_hand','source_reserved','source_shipped','source_cancelled','source_reserved_qty','shipment_fact_count','cancellation_fact_count','reservation_fact_count','loser_command_receipt_count')
    for($i=0;$i -lt $names.Count;$i++) { Require-Check "$Label final $($names[$i])" $expected[$i] $after[$i] }
    Require-Check "$Label committed guard projection version advanced" ([string]([int]$before[2]+1)) $after[2]
    Require-Check "$Label committed order projection version advanced" ([string]([int]$before[8]+1)) $after[8]
    $fresh=[ordered]@{connection='new psql connection';on_hand=$after[0];reserved=$after[1];inventory_version=$after[2];order_version=$after[8];source_rebuild_matches=($after[0] -eq $after[9] -and $after[1] -eq $after[10] -and $after[5] -eq $after[11] -and $after[6] -eq $after[12] -and $after[7] -eq $after[13])}
    $observations.Add([ordered]@{race=$Label;phase='fresh_connection_committed_read';state=$fresh})
    Require-Check "$Label fresh source rebuild equals projection" $true $fresh.source_rebuild_matches
}

try {
    $version=Read-CopyRow 'SELECT version()'
    $results.postgres_version=$version
    Reset-And-Seed 'preflight'
    Run-Race 'ship_wins' 'ship' 'cancel'
    Run-Race 'cancel_wins' 'cancel' 'ship'
    Run-Race 'cancel_cancel' 'cancel' 'cancel'
    $leaks=Read-CopyRow "SELECT count(*)::text FROM pg_stat_activity WHERE application_name LIKE 'v04-%'"
    Require-Check 'no leaked V04 sessions or transactions' '0' $leaks
} catch {
    $fatal=$_.Exception.ToString()
    $observations.Add([ordered]@{phase='fatal';error=$fatal})
} finally {
    foreach($s in $sessions) { Stop-AnySession $s }
    $results.passed=(-not $fatal -and @($checks | Where-Object { -not $_.passed }).Count -eq 0)
    $results | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'results.json') -Encoding utf8
}
if($fatal) { throw $fatal }
if(-not $results.passed) { throw 'V04 failed; inspect results.json' }
Write-Output "V04 passed on $($results.postgres_version): ship/cancel races and competing cancellations serialized under observed row locks."
