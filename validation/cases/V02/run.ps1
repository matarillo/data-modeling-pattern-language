param(
  [string]$PgBin=$env:PG_BIN,
  [string]$DbHost='127.0.0.1',
  [int]$DbPort=55467,
  [string]$Database='research_validation',
  [string]$DbUser='research'
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\..\harness\Common.ps1')
$params=@{Schema='v02_smoke';PgBin=$PgBin;DbHost=$DbHost;DbPort=$DbPort;Database=$Database;DbUser=$DbUser}
$checks=[System.Collections.Generic.List[object]]::new()
$observations=[System.Collections.Generic.List[object]]::new()
$sessions=[System.Collections.Generic.List[object]]::new()
function Query([string]$Sql) {
  $r=Invoke-Sql -Sql ("\pset format unaligned`n\pset tuples_only on`n"+$Sql) @params
  $lines=@($r.Output -split "`r?`n" | Where-Object { $_.Trim() -ne '' -and $_ -notmatch '^Output format is unaligned' -and $_ -notmatch '^Tuples only is on' })
  if(-not $lines.Count){throw "No scalar output for SQL: $Sql`n$($r.Output)"}
  return $lines[-1].Trim()
}
function Check([string]$Name,[string]$Expected,[string]$Actual) {
  $ok=$Expected -ceq $Actual
  $checks.Add([ordered]@{name=$Name;expected=$Expected;actual=$Actual;passed=$ok})
  if(-not $ok){throw "Check failed: $Name expected=[$Expected] actual=[$Actual]"}
}
function Observe-IdleTransaction([string]$App,[string]$QueryPattern) {
  if(-not (Wait-Activity -ApplicationName $App -State 'idle in transaction' -QueryLike $QueryPattern @params)) { throw "Did not observe $App idle in transaction at expected barrier" }
}
Reset-Schema @params | Out-Null
$setup=@'
CREATE TABLE unsafe_stock(on_hand integer NOT NULL,reserved integer NOT NULL);
INSERT INTO unsafe_stock VALUES(10,0);
CREATE TABLE unsafe_attempt(order_id text PRIMARY KEY,quantity integer NOT NULL,observed_available integer NOT NULL);
CREATE TABLE unsafe_read(order_id text PRIMARY KEY,quantity integer NOT NULL,observed_available integer NOT NULL,approved boolean NOT NULL);
SELECT seed_sku('SKU-1',10);
SELECT accept_order('A',1,7,NULL,'cmd-order-A');
SELECT accept_order('B',1,6,NULL,'cmd-order-B');
'@
Invoke-Sql -Sql $setup @params | Out-Null

# Deliberately unsafe control: both READ COMMITTED sessions record the same available stock before either writes.
try {
$unsafeA=Start-PsqlSession -Schema 'v02_smoke' -ApplicationName 'v02-unsafe-a' -PgBin $PgBin -DbHost $DbHost -DbPort $DbPort -Database $Database -DbUser $DbUser
$sessions.Add($unsafeA)
$unsafeB=Start-PsqlSession -Schema 'v02_smoke' -ApplicationName 'v02-unsafe-b' -PgBin $PgBin -DbHost $DbHost -DbPort $DbPort -Database $Database -DbUser $DbUser
$sessions.Add($unsafeB)
$unsafeReadA=@'
\pset format unaligned
\pset tuples_only on
BEGIN ISOLATION LEVEL READ COMMITTED;
INSERT INTO unsafe_read SELECT 'A',7,on_hand-reserved,(on_hand-reserved)>=7 FROM unsafe_stock;
'@
$unsafeReadB=@'
\pset format unaligned
\pset tuples_only on
BEGIN ISOLATION LEVEL READ COMMITTED;
INSERT INTO unsafe_read SELECT 'B',6,on_hand-reserved,(on_hand-reserved)>=6 FROM unsafe_stock;
'@
Send-Sql $unsafeA $unsafeReadA
Observe-IdleTransaction 'v02-unsafe-a' '%INSERT INTO unsafe_read%'
Send-Sql $unsafeB $unsafeReadB
Observe-IdleTransaction 'v02-unsafe-b' '%INSERT INTO unsafe_read%'
$unsafeWriteA=@'
INSERT INTO unsafe_attempt SELECT order_id,quantity,observed_available FROM unsafe_read WHERE order_id='A';
UPDATE unsafe_stock SET reserved=reserved+7;
COMMIT;
'@
$unsafeWriteB=@'
INSERT INTO unsafe_attempt SELECT order_id,quantity,observed_available FROM unsafe_read WHERE order_id='B';
UPDATE unsafe_stock SET reserved=reserved+6;
COMMIT;
'@
Send-Sql $unsafeA $unsafeWriteA
Send-Sql $unsafeB $unsafeWriteB
$unsafeOutputA=Complete-Session $unsafeA
$unsafeOutputB=Complete-Session $unsafeB
$unsafeObserved=Query "SELECT min(observed_available)||','||max(observed_available)||','||(SELECT reserved FROM unsafe_stock)||','||(SELECT sum(quantity) FROM unsafe_attempt) FROM unsafe_read;"
Check 'unguarded check-then-insert both read 10 then write 13' '10,10,13,13' $unsafeObserved
$observations.Add('Unsafe control: both READ COMMITTED sessions independently observed available=10 and approved 7/6; unguarded additive writes produced reserved=13 against stock=10.')

# Safe owner function path: hold A open, observe B blocked on the stock row lock, then commit A.
$safeA=Start-PsqlSession -Schema 'v02_smoke' -ApplicationName 'v02-safe-a' -PgBin $PgBin -DbHost $DbHost -DbPort $DbPort -Database $Database -DbUser $DbUser
$sessions.Add($safeA)
$safeB=$null
try {
  Send-Sql $safeA "\pset format unaligned`n\pset tuples_only on`nBEGIN ISOLATION LEVEL READ COMMITTED;`nSELECT reserve('A',1,7,'RA','RFA','cmd-reserve-A');"
  Observe-IdleTransaction 'v02-safe-a' "%reserve('A',1,7%"
  $safeB=Start-PsqlSession -Schema 'v02_smoke' -ApplicationName 'v02-safe-b' -PgBin $PgBin -DbHost $DbHost -DbPort $DbPort -Database $Database -DbUser $DbUser
  $sessions.Add($safeB)
  Send-Sql $safeB "\pset format unaligned`n\pset tuples_only on`nBEGIN ISOLATION LEVEL READ COMMITTED;`nSELECT reserve('B',1,6,'RB','RFB','cmd-reserve-B');"
  if(-not (Wait-Activity -ApplicationName 'v02-safe-b' -State 'active' -QueryLike "%reserve('B',1,6%" -WaitEvent 'transactionid' -TimeoutSeconds 15 @params)) { throw 'Did not observe B waiting on A transaction lock' }
  $waitState=Query "SELECT wait_event_type||'/'||wait_event||'/'||state FROM pg_stat_activity WHERE application_name='v02-safe-b' AND state='active' AND query LIKE '%reserve(''B'',1,6%';"
  if($waitState -notmatch '^Lock/transactionid/active$'){throw "Unexpected lock observation: $waitState"}
  Check 'pg_stat_activity confirms lock wait before releasing A' 'Lock/transactionid/active' $waitState
  $observations.Add("Safe race observed postgres pg_stat_activity state: $waitState (backend B's reserve was waiting on A's transaction).")
  Send-Sql $safeA 'COMMIT;'
  $safeAResult=Complete-Session $safeA
  try { $safeBResult=Complete-Session $safeB; throw 'Expected competing B reservation to fail after A commits' }
  catch {
    $safeBError=$_.Exception.Message
    if($safeBError -notmatch '\b23514\b'){throw "B did not fail with expected SQLSTATE 23514: $safeBError"}
  }
  Check 'competing B reserve is rejected after A commits' '23514' ([regex]::Match($safeBError,'\b23514\b').Value)
} finally {
  foreach($session in $sessions){ if($session -and -not $session.Process.HasExited){$session.Process.Kill($true);[void]$session.Process.WaitForExit(5000)} }
}
$safeState=Query "SELECT b.on_hand||','||b.reserved||','||oA.reserved_qty||','||oB.reserved_qty||','||(SELECT count(*) FROM reservation_fact WHERE action='RESERVE')||','||(SELECT count(*) FROM command_receipt WHERE command_key IN ('cmd-reserve-A','cmd-reserve-B')) FROM inventory_balance_projection b JOIN order_fulfillment_projection oA ON oA.order_id='A' JOIN order_fulfillment_projection oB ON oB.order_id='B' WHERE b.sku_id='SKU-1' AND EXISTS(SELECT 1 FROM reservation_fact WHERE fact_id='RFA' AND order_id='A' AND action='RESERVE' AND quantity=7) AND NOT EXISTS(SELECT 1 FROM reservation_fact WHERE fact_id='RFB' OR command_key='cmd-reserve-B') AND EXISTS(SELECT 1 FROM command_receipt WHERE command_key='cmd-reserve-A') AND NOT EXISTS(SELECT 1 FROM command_receipt WHERE command_key='cmd-reserve-B');"
Check 'guarded final state on_hand,reserved,A-reserved,B-reserved,facts,receipts' '10,7,7,0,1,1' $safeState
$noLeaked=Query "SELECT (count(*)=0)::text FROM pg_stat_activity WHERE application_name LIKE 'v02-%';"
Check 'all labeled race sessions have exited' 'true' $noLeaked
$observations.Add('Safe READ COMMITTED result: order A=7 reserved and committed; order B=6 rejected with SQLSTATE 23514 after lock release; stock remains 10 and reserved=7.')
$result=[ordered]@{task='V02';passed=$true;postgres_version=(Query 'SHOW server_version;');checks=$checks.ToArray();observations=$observations.ToArray()}
$result | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 (Join-Path $PSScriptRoot 'results.json')
$result | ConvertTo-Json -Depth 8
} finally {
  foreach($session in $sessions){ if($session -and -not $session.Process.HasExited){$session.Process.Kill($true);[void]$session.Process.WaitForExit(5000)} }
}
