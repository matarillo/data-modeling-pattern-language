param(
  [string]$PgBin=$env:PG_BIN,
  [string]$DbHost='127.0.0.1',
  [int]$DbPort=55467,
  [string]$Database='research_validation',
  [string]$DbUser='research'
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\..\harness\Common.ps1')
$params=@{Schema='v01_smoke';PgBin=$PgBin;DbHost=$DbHost;DbPort=$DbPort;Database=$Database;DbUser=$DbUser}
$checks=[System.Collections.Generic.List[object]]::new()
$observations=[System.Collections.Generic.List[object]]::new()
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
Reset-Schema @params | Out-Null
$flow=@'
SELECT seed_sku('SKU-1',10);
SELECT accept_order('O-1',1,10,NULL,'cmd-order-1');
SELECT accept_order('O-1',2,8,1,'cmd-order-2');
SELECT reserve('O-1',2,8,'RES-1','RF-1','cmd-reserve');
SELECT ship('O-1',2,'RES-1',3,'SHIP-1','cmd-ship');
SELECT cancel_remaining('O-1',2,'RES-1',5,'customer_cancel_remaining','CANCEL-1','cmd-cancel');
SELECT issue_invoice('INV-1','O-1',2,3000,'cmd-invoice');
SELECT record_cash_receipt('CASH-1','BANK-RCPT-1',3000,'JPY','INV-1','cmd-cash');
SELECT post_payment_entry_revision('PAY-ENTRY-1',1,'CASH-1',3300,NULL,NULL,'cmd-pay-1');
SELECT post_payment_entry_revision('PAY-ENTRY-1',2,'CASH-1',3000,1,'入力誤り。実受領額に訂正','cmd-pay-2');
'@
Invoke-Sql -Sql $flow @params | Out-Null
$fixed=Query "SELECT (b.on_hand=7 AND b.reserved=0 AND o.current_revision_no=2 AND o.ordered_qty=8 AND o.shipped_qty=3 AND o.cancelled_qty=5 AND o.reserved_qty=0 AND r.invoice_jpy=3000 AND r.cash_received_jpy=3000 AND r.payment_record_current_jpy=3000 AND (SELECT recorded_amount_jpy=3300 FROM payment_entry_revision WHERE payment_entry_id='PAY-ENTRY-1' AND revision_no=1) AND (SELECT amount_jpy=3000 FROM cash_receipt_fact WHERE receipt_id='CASH-1') AND (SELECT count(*)=1 AND sum(amount_jpy)=3000 FROM cash_receipt_fact))::text FROM inventory_balance_projection b JOIN order_fulfillment_projection o ON o.order_id='O-1' JOIN source_rebuild r ON r.order_id='O-1' WHERE b.sku_id='SKU-1';"
Check 'canonical flow, retained correction, real cash and no refund' 'true' $fixed
$agreement=Query "SELECT (r.current_revision_no=2 AND r.ordered_qty=8 AND r.shipped_qty=3 AND r.cancelled_qty=5 AND r.reserved_qty=0 AND r.rebuilt_on_hand=7 AND r.rebuilt_reserved=0 AND r.payment_record_current_revision_no=2 AND r.payment_record_current_jpy=3000)::text FROM source_rebuild r WHERE order_id='O-1';"
Check 'source rebuild agrees with canonical projections' 'true' $agreement
# The deliberate statement error exits psql; closing its open transaction rolls all work back.
$null=Query "SELECT accept_order('O-ROLL',1,1,NULL,'cmd-rollback-order');"
$rollbackError=''
try { Invoke-Sql -Sql "BEGIN; SELECT reserve('O-ROLL',1,1,'RES-ROLLBACK','RF-ROLLBACK','cmd-rollback'); SELECT 1/0; COMMIT;" @params | Out-Null; throw 'Expected deliberate division-by-zero failure' }
catch { $rollbackError=$_.Exception.Message }
Check 'rollback drill reached intentional division by zero' '22012' $(if($rollbackError -match '\b22012\b'){'22012'}else{'not-observed'})
$rolledBack=Query "SELECT (NOT EXISTS(SELECT 1 FROM reservation_fact WHERE fact_id='RF-ROLLBACK') AND NOT EXISTS(SELECT 1 FROM command_receipt WHERE command_key='cmd-rollback') AND (SELECT reserved=0 FROM inventory_balance_projection WHERE sku_id='SKU-1') AND (SELECT reserved_qty=0 FROM order_fulfillment_projection WHERE order_id='O-ROLL'))::text;"
Check 'rollback leaves no fact, command receipt or projection delta' 'true' $rolledBack
# Poison cached heads, verify source-derived leaves, then rebuild only projections.
$rebuild=@'
CREATE TEMP TABLE before_projection AS
SELECT b.sku_id,b.on_hand,b.reserved,o.order_id,o.current_revision_no,o.ordered_qty,o.shipped_qty,o.cancelled_qty,o.reserved_qty,pe.payment_entry_id,pe.current_revision_no payment_revision_no
FROM inventory_balance_projection b CROSS JOIN order_fulfillment_projection o CROSS JOIN payment_entry_head_projection pe
WHERE b.sku_id='SKU-1' AND o.order_id='O-1' AND pe.payment_entry_id='PAY-ENTRY-1';
UPDATE order_fulfillment_projection SET current_revision_no=1,ordered_qty=10 WHERE order_id='O-1';
UPDATE payment_entry_head_projection SET current_revision_no=1 WHERE payment_entry_id='PAY-ENTRY-1';
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM source_rebuild WHERE order_id='O-1' AND current_revision_no=2 AND payment_record_current_revision_no=2 AND ordered_qty=8 AND payment_record_current_jpy=3000) THEN RAISE EXCEPTION 'source_rebuild trusted stale cached head'; END IF;
END $$;
DELETE FROM order_fulfillment_projection WHERE order_id='O-1';
DELETE FROM payment_entry_head_projection WHERE payment_entry_id='PAY-ENTRY-1';
DELETE FROM inventory_balance_projection;
INSERT INTO inventory_balance_projection(sku_id,on_hand,reserved,version_no)
SELECT 'SKU-1',rebuilt_on_hand,rebuilt_reserved,0 FROM source_rebuild WHERE order_id='O-1';
INSERT INTO order_fulfillment_projection(order_id,current_revision_no,ordered_qty,shipped_qty,cancelled_qty,reserved_qty,version_no)
SELECT order_id,current_revision_no,ordered_qty,shipped_qty,cancelled_qty,reserved_qty,0 FROM source_rebuild WHERE order_id='O-1';
INSERT INTO payment_entry_head_projection(payment_entry_id,current_revision_no,version_no)
SELECT 'PAY-ENTRY-1',payment_record_current_revision_no,0 FROM source_rebuild WHERE order_id='O-1';
SELECT (b.on_hand=x.on_hand AND b.reserved=x.reserved AND o.current_revision_no=x.current_revision_no AND o.ordered_qty=x.ordered_qty AND o.shipped_qty=x.shipped_qty AND o.cancelled_qty=x.cancelled_qty AND o.reserved_qty=x.reserved_qty AND p.current_revision_no=x.payment_revision_no)::text
FROM before_projection x JOIN inventory_balance_projection b ON b.sku_id=x.sku_id JOIN order_fulfillment_projection o ON o.order_id=x.order_id JOIN payment_entry_head_projection p ON p.payment_entry_id=x.payment_entry_id;
'@
$rebuildResult=Query $rebuild
Check 'source facts rebuild deleted projections, ignoring stale cached heads' 'true' $rebuildResult
$observations.Add('Rollback error was SQLSTATE 22012; psql session disconnect rolled back the open transaction.')
$observations.Add('Cached order/payment heads were deliberately changed to revision 1; source_rebuild still selected revision-2 chain leaves.')
$observations.Add('Only v01_smoke was reset. No fixture SQL validation result is treated as a production permission or performance proof.')
$result=[ordered]@{task='V01';passed=$true;postgres_version=(Query 'SHOW server_version;');checks=$checks.ToArray();observations=$observations.ToArray()}
$result | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 (Join-Path $PSScriptRoot 'results.json')
$result | ConvertTo-Json -Depth 8
