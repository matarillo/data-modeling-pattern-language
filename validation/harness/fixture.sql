-- Minimal S03 fixture. Owner functions participate in caller transactions and never COMMIT.
CREATE TABLE inventory_opening_fact(opening_id text PRIMARY KEY, sku_id text NOT NULL UNIQUE, quantity integer NOT NULL CHECK(quantity>=0), occurred_at timestamptz NOT NULL DEFAULT clock_timestamp());
CREATE TABLE order_revision(order_id text NOT NULL, revision_no integer NOT NULL CHECK(revision_no>0), ordered_qty integer NOT NULL CHECK(ordered_qty>0), supersedes_revision_no integer, accepted_at timestamptz NOT NULL DEFAULT clock_timestamp(), command_key text NOT NULL, PRIMARY KEY(order_id,revision_no), UNIQUE(order_id,command_key), FOREIGN KEY(order_id,supersedes_revision_no) REFERENCES order_revision(order_id,revision_no), CHECK ((revision_no=1 AND supersedes_revision_no IS NULL) OR (revision_no>1 AND supersedes_revision_no IS NOT NULL AND supersedes_revision_no=revision_no-1)));
CREATE UNIQUE INDEX order_revision_one_child ON order_revision(order_id,supersedes_revision_no) WHERE supersedes_revision_no IS NOT NULL;
CREATE TABLE reservation_fact(fact_id text PRIMARY KEY, reservation_id text NOT NULL, reserve_fact_id text NOT NULL, order_id text NOT NULL, order_revision_no integer NOT NULL, action text NOT NULL CHECK(action IN ('RESERVE','CONSUME','RELEASE')), quantity integer NOT NULL CHECK(quantity>0), command_key text NOT NULL UNIQUE, occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(), FOREIGN KEY(order_id,order_revision_no) REFERENCES order_revision(order_id,revision_no), FOREIGN KEY(reserve_fact_id) REFERENCES reservation_fact(fact_id), CHECK ((action='RESERVE' AND fact_id=reserve_fact_id) OR (action<>'RESERVE' AND fact_id<>reserve_fact_id)));
CREATE UNIQUE INDEX reservation_one_root ON reservation_fact(reservation_id) WHERE action='RESERVE';
CREATE TABLE shipment_fact(shipment_id text PRIMARY KEY, order_id text NOT NULL, order_revision_no integer NOT NULL, reservation_id text NOT NULL, reserve_fact_id text NOT NULL REFERENCES reservation_fact(fact_id), quantity integer NOT NULL CHECK(quantity>0), external_receipt_id text NOT NULL UNIQUE, occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(), command_key text NOT NULL UNIQUE, FOREIGN KEY(order_id,order_revision_no) REFERENCES order_revision(order_id,revision_no));
CREATE TABLE cancellation_fact(cancellation_id text PRIMARY KEY, order_id text NOT NULL, order_revision_no integer NOT NULL, reservation_id text NOT NULL, reserve_fact_id text NOT NULL REFERENCES reservation_fact(fact_id), quantity integer NOT NULL CHECK(quantity>0), reason text NOT NULL, occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(), command_key text NOT NULL UNIQUE, FOREIGN KEY(order_id,order_revision_no) REFERENCES order_revision(order_id,revision_no));
CREATE TABLE invoice_fact(invoice_id text PRIMARY KEY, amount_jpy bigint NOT NULL CHECK(amount_jpy>=0), currency text NOT NULL CHECK(currency='JPY'), issued_at timestamptz NOT NULL DEFAULT clock_timestamp(), command_key text NOT NULL UNIQUE, order_id text NOT NULL UNIQUE, order_revision_no integer NOT NULL, FOREIGN KEY(order_id,order_revision_no) REFERENCES order_revision(order_id,revision_no));
CREATE TABLE cash_receipt_fact(receipt_id text PRIMARY KEY, external_receipt_id text NOT NULL UNIQUE, amount_jpy bigint NOT NULL CHECK(amount_jpy>0), currency text NOT NULL CHECK(currency='JPY'), received_at timestamptz NOT NULL DEFAULT clock_timestamp(), invoice_id text NOT NULL REFERENCES invoice_fact(invoice_id));
CREATE TABLE payment_entry_revision(payment_entry_id text NOT NULL, revision_no integer NOT NULL CHECK(revision_no>0), receipt_id text NOT NULL REFERENCES cash_receipt_fact(receipt_id), recorded_amount_jpy bigint NOT NULL CHECK(recorded_amount_jpy>=0), supersedes_revision_no integer, correction_reason text, PRIMARY KEY(payment_entry_id,revision_no), FOREIGN KEY(payment_entry_id,supersedes_revision_no) REFERENCES payment_entry_revision(payment_entry_id,revision_no), CHECK((revision_no=1 AND supersedes_revision_no IS NULL AND correction_reason IS NULL) OR (revision_no>1 AND supersedes_revision_no IS NOT NULL AND correction_reason IS NOT NULL AND supersedes_revision_no=revision_no-1 AND length(btrim(correction_reason))>0)));
CREATE UNIQUE INDEX payment_one_child ON payment_entry_revision(payment_entry_id,supersedes_revision_no) WHERE supersedes_revision_no IS NOT NULL;
CREATE UNIQUE INDEX payment_one_root_per_receipt ON payment_entry_revision(receipt_id) WHERE supersedes_revision_no IS NULL;
CREATE TABLE command_receipt(command_key text PRIMARY KEY, payload_digest text NOT NULL, result_kind text NOT NULL, result_id text NOT NULL, completed_at timestamptz NOT NULL DEFAULT clock_timestamp());
CREATE TABLE inventory_balance_projection(sku_id text PRIMARY KEY REFERENCES inventory_opening_fact(sku_id), on_hand integer NOT NULL CHECK(on_hand>=0), reserved integer NOT NULL CHECK(reserved>=0 AND reserved<=on_hand), version_no bigint NOT NULL CHECK(version_no>=0));
CREATE TABLE order_fulfillment_projection(order_id text PRIMARY KEY, current_revision_no integer NOT NULL, ordered_qty integer NOT NULL, shipped_qty integer NOT NULL CHECK(shipped_qty>=0), cancelled_qty integer NOT NULL CHECK(cancelled_qty>=0), reserved_qty integer NOT NULL CHECK(reserved_qty>=0), version_no bigint NOT NULL, FOREIGN KEY(order_id,current_revision_no) REFERENCES order_revision(order_id,revision_no), CHECK(shipped_qty+cancelled_qty+reserved_qty<=ordered_qty));
CREATE TABLE payment_entry_head_projection(payment_entry_id text PRIMARY KEY, current_revision_no integer NOT NULL, version_no bigint NOT NULL, FOREIGN KEY(payment_entry_id,current_revision_no) REFERENCES payment_entry_revision(payment_entry_id,revision_no));

CREATE FUNCTION _payload(op text, args jsonb) RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT encode(sha256(convert_to(op || ':' || args::text,'UTF8')),'hex') $$;
CREATE FUNCTION _command_start(k text, op text, args jsonb, rk text, rid text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE d text := _payload(op,args); old command_receipt%ROWTYPE;
BEGIN
 INSERT INTO command_receipt(command_key,payload_digest,result_kind,result_id) VALUES(k,d,rk,rid) ON CONFLICT DO NOTHING;
 IF FOUND THEN RETURN 'NEW'; END IF;
 SELECT * INTO old FROM command_receipt WHERE command_key=k FOR UPDATE;
 IF old.payload_digest<>d THEN RAISE EXCEPTION 'idempotency key payload conflict' USING ERRCODE='22000'; END IF;
 RETURN 'REPLAY:'||old.result_kind||':'||old.result_id;
END $$;

CREATE FUNCTION seed_sku(sku text,qty integer) RETURNS void LANGUAGE plpgsql AS $$ BEGIN
 INSERT INTO inventory_opening_fact(opening_id,sku_id,quantity) VALUES('OPEN-'||sku,sku,qty);
 INSERT INTO inventory_balance_projection VALUES(sku,qty,0,0);
END $$;
CREATE FUNCTION accept_order(oid text, rev integer, qty integer, parent_rev integer, k text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE result text; cur order_fulfillment_projection%ROWTYPE;
BEGIN
 result:=_command_start(k,'accept_order',jsonb_build_object('order_id',oid,'revision_no',rev,'ordered_qty',qty,'supersedes_revision_no',parent_rev),'order_revision',oid||':'||rev);
 IF result<>'NEW' THEN RETURN result; END IF;
 IF qty<=0 THEN RAISE EXCEPTION 'quantity must be positive' USING ERRCODE='23514'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(oid,0));
 SELECT * INTO cur FROM order_fulfillment_projection WHERE order_id=oid FOR UPDATE;
 IF cur.order_id IS NOT NULL THEN
   IF cur.shipped_qty<>0 OR cur.cancelled_qty<>0 OR cur.reserved_qty<>0 THEN RAISE EXCEPTION 'amendment after fulfillment starts' USING ERRCODE='23514'; END IF;
   IF parent_rev IS NULL OR parent_rev<>cur.current_revision_no OR rev<>parent_rev+1 THEN RAISE EXCEPTION 'stale or invalid revision' USING ERRCODE='23514'; END IF;
 ELSE
   IF rev<>1 OR parent_rev IS NOT NULL THEN RAISE EXCEPTION 'first revision must be root 1' USING ERRCODE='23514'; END IF;
 END IF;
 INSERT INTO order_revision VALUES(oid,rev,qty,parent_rev,clock_timestamp(),k);
 IF cur.order_id IS NULL THEN INSERT INTO order_fulfillment_projection VALUES(oid,rev,qty,0,0,0,0);
 ELSE UPDATE order_fulfillment_projection SET current_revision_no=rev,ordered_qty=qty,version_no=version_no+1 WHERE order_id=oid; END IF;
 UPDATE command_receipt SET result_id=oid||':'||rev WHERE command_key=k;
 RETURN oid||':'||rev;
END $$;
CREATE FUNCTION reserve(oid text, rev integer, qty integer, reservation text, fact text, k text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE o order_fulfillment_projection%ROWTYPE; b inventory_balance_projection%ROWTYPE; sku text; result text;
BEGIN
 result:=_command_start(k,'reserve',jsonb_build_object('order_id',oid,'revision_no',rev,'quantity',qty,'reservation_id',reservation),'reservation_fact',fact);
 IF result<>'NEW' THEN RETURN result; END IF;
 SELECT sku_id INTO sku FROM inventory_opening_fact ORDER BY sku_id LIMIT 1;
 SELECT * INTO o FROM order_fulfillment_projection WHERE order_id=oid FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'unknown order' USING ERRCODE='23503'; END IF;
 SELECT * INTO b FROM inventory_balance_projection WHERE sku_id=sku FOR UPDATE;
 IF qty<=0 OR rev<>o.current_revision_no OR qty>o.ordered_qty-o.shipped_qty-o.cancelled_qty-o.reserved_qty OR qty>b.on_hand-b.reserved THEN RAISE EXCEPTION 'reservation unavailable or stale' USING ERRCODE='23514'; END IF;
 INSERT INTO reservation_fact VALUES(fact,reservation,fact,oid,rev,'RESERVE',qty,k,clock_timestamp());
 UPDATE order_fulfillment_projection SET reserved_qty=reserved_qty+qty,version_no=version_no+1 WHERE order_id=oid;
 UPDATE inventory_balance_projection SET reserved=reserved+qty,version_no=version_no+1 WHERE sku_id=sku;
 RETURN fact;
END $$;
CREATE FUNCTION _move(oid text, rev integer, reservation text, qty integer, k text, op text, doc text, reason text DEFAULT NULL) RETURNS text LANGUAGE plpgsql AS $$
DECLARE o order_fulfillment_projection%ROWTYPE; b inventory_balance_projection%ROWTYPE; sku text; root reservation_fact%ROWTYPE; used integer; result text; fid text;
BEGIN
 result:=_command_start(k,op,jsonb_build_object('order_id',oid,'revision_no',rev,'reservation_id',reservation,'quantity',qty,'document',doc,'reason',reason),op,doc);
 IF result<>'NEW' THEN RETURN result; END IF;
 SELECT sku_id INTO sku FROM inventory_opening_fact ORDER BY sku_id LIMIT 1;
 SELECT * INTO o FROM order_fulfillment_projection WHERE order_id=oid FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'unknown order' USING ERRCODE='23503'; END IF;
 SELECT * INTO b FROM inventory_balance_projection WHERE sku_id=sku FOR UPDATE;
 SELECT * INTO root FROM reservation_fact WHERE reservation_id=reservation AND action='RESERVE';
 IF NOT FOUND OR root.order_id<>oid OR root.order_revision_no<>rev THEN RAISE EXCEPTION 'reservation root mismatch' USING ERRCODE='23514'; END IF;
 IF rev<>o.current_revision_no OR qty<=0 THEN RAISE EXCEPTION 'stale or invalid operation' USING ERRCODE='23514'; END IF;
 SELECT coalesce(sum(quantity),0) INTO used FROM reservation_fact WHERE reserve_fact_id=root.fact_id AND action IN ('CONSUME','RELEASE');
 IF qty>root.quantity-used OR qty>o.reserved_qty THEN RAISE EXCEPTION 'reservation exhausted' USING ERRCODE='23514'; END IF;
 IF op='ship' THEN
   IF qty>o.ordered_qty-o.shipped_qty-o.cancelled_qty OR qty>b.on_hand OR qty>b.reserved THEN RAISE EXCEPTION 'ship exceeds remaining quantity' USING ERRCODE='23514'; END IF;
   INSERT INTO shipment_fact VALUES(doc,oid,rev,reservation,root.fact_id,qty,doc,clock_timestamp(),k);
   fid:='CONSUME-'||doc;
   INSERT INTO reservation_fact VALUES(fid,reservation,root.fact_id,oid,rev,'CONSUME',qty,k||'-consume',clock_timestamp());
   UPDATE inventory_balance_projection SET on_hand=on_hand-qty,reserved=reserved-qty,version_no=version_no+1 WHERE sku_id=sku;
   UPDATE order_fulfillment_projection SET shipped_qty=shipped_qty+qty,reserved_qty=reserved_qty-qty,version_no=version_no+1 WHERE order_id=oid;
 ELSE
   IF qty>o.ordered_qty-o.shipped_qty-o.cancelled_qty THEN RAISE EXCEPTION 'cancel exceeds remaining quantity' USING ERRCODE='23514'; END IF;
   INSERT INTO cancellation_fact VALUES(doc,oid,rev,reservation,root.fact_id,qty,reason,clock_timestamp(),k);
   fid:='RELEASE-'||doc;
   INSERT INTO reservation_fact VALUES(fid,reservation,root.fact_id,oid,rev,'RELEASE',qty,k||'-release',clock_timestamp());
   UPDATE inventory_balance_projection SET reserved=reserved-qty,version_no=version_no+1 WHERE sku_id=sku;
   UPDATE order_fulfillment_projection SET cancelled_qty=cancelled_qty+qty,reserved_qty=reserved_qty-qty,version_no=version_no+1 WHERE order_id=oid;
 END IF;
 RETURN doc;
END $$;
CREATE FUNCTION ship(oid text, rev integer, reservation text, qty integer, doc text, k text) RETURNS text LANGUAGE sql AS $$ SELECT _move(oid,rev,reservation,qty,k,'ship',doc,NULL) $$;
CREATE FUNCTION cancel_remaining(oid text, rev integer, reservation text, qty integer, reason text, cancellation text, k text) RETURNS text LANGUAGE sql AS $$ SELECT _move(oid,rev,reservation,qty,k,'cancel_remaining',cancellation,reason) $$;
CREATE FUNCTION issue_invoice(inv text, oid text, rev integer, amount bigint, k text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE o order_fulfillment_projection%ROWTYPE; shipped integer; result text;
BEGIN
 result:=_command_start(k,'issue_invoice',jsonb_build_object('invoice_id',inv,'order_id',oid,'revision_no',rev,'amount_jpy',amount),'invoice_fact',inv);
 IF result<>'NEW' THEN RETURN result; END IF;
 SELECT * INTO o FROM order_fulfillment_projection WHERE order_id=oid FOR UPDATE;
 SELECT coalesce(sum(quantity),0) INTO shipped FROM shipment_fact WHERE order_id=oid;
 IF rev<>o.current_revision_no OR amount<>shipped*1000 THEN RAISE EXCEPTION 'invoice does not match shipment total' USING ERRCODE='23514'; END IF;
 INSERT INTO invoice_fact VALUES(inv,amount,'JPY',clock_timestamp(),k,oid,rev); RETURN inv;
END $$;
CREATE FUNCTION record_cash_receipt(receipt text, external_id text, amount bigint, currency text, inv text, k text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE result text;
BEGIN
 result:=_command_start(k,'record_cash_receipt',jsonb_build_object('receipt_id',receipt,'external_receipt_id',external_id,'amount_jpy',amount,'currency',currency,'invoice_id',inv),'cash_receipt_fact',receipt);
 IF result<>'NEW' THEN RETURN result; END IF;
 INSERT INTO cash_receipt_fact VALUES(receipt,external_id,amount,currency,clock_timestamp(),inv); RETURN receipt;
END $$;
CREATE FUNCTION post_payment_entry_revision(entry text, rev integer, receipt text, amount bigint, parent integer, reason text, k text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE head payment_entry_head_projection%ROWTYPE; result text;
BEGIN
 result:=_command_start(k,'post_payment_entry_revision',jsonb_build_object('payment_entry_id',entry,'revision_no',rev,'receipt_id',receipt,'recorded_amount_jpy',amount,'supersedes_revision_no',parent,'correction_reason',reason),'payment_entry_revision',entry||':'||rev);
 IF result<>'NEW' THEN RETURN result; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(entry,1));
 SELECT * INTO head FROM payment_entry_head_projection WHERE payment_entry_id=entry FOR UPDATE;
 IF head.payment_entry_id IS NULL THEN
   IF rev<>1 OR parent IS NOT NULL OR reason IS NOT NULL THEN RAISE EXCEPTION 'invalid payment root' USING ERRCODE='23514'; END IF;
 ELSE
   IF rev<>head.current_revision_no+1 OR parent IS NULL OR parent<>head.current_revision_no THEN RAISE EXCEPTION 'stale payment revision' USING ERRCODE='23514'; END IF;
   IF receipt IS DISTINCT FROM (SELECT receipt_id FROM payment_entry_revision WHERE payment_entry_id=entry AND revision_no=head.current_revision_no) THEN RAISE EXCEPTION 'payment revision cannot change receipt identity' USING ERRCODE='23514'; END IF;
 END IF;
 INSERT INTO payment_entry_revision VALUES(entry,rev,receipt,amount,parent,reason);
 IF head.payment_entry_id IS NULL THEN INSERT INTO payment_entry_head_projection VALUES(entry,rev,0);
 ELSE UPDATE payment_entry_head_projection SET current_revision_no=rev,version_no=version_no+1 WHERE payment_entry_id=entry; END IF;
 RETURN entry||':'||rev;
END $$;

CREATE VIEW source_rebuild AS
WITH order_leaf AS (SELECT r.* FROM order_revision r WHERE NOT EXISTS(SELECT 1 FROM order_revision c WHERE c.order_id=r.order_id AND c.supersedes_revision_no=r.revision_no)),
pay_leaf AS (SELECT r.* FROM payment_entry_revision r WHERE NOT EXISTS(SELECT 1 FROM payment_entry_revision c WHERE c.payment_entry_id=r.payment_entry_id AND c.supersedes_revision_no=r.revision_no)),
ship AS (SELECT order_id,sum(quantity)::int qty FROM shipment_fact GROUP BY order_id), cancel AS (SELECT order_id,sum(quantity)::int qty FROM cancellation_fact GROUP BY order_id), reserve AS (SELECT order_id,sum(quantity) FILTER(WHERE action='RESERVE')::int q, sum(quantity) FILTER(WHERE action='CONSUME')::int c, sum(quantity) FILTER(WHERE action='RELEASE')::int r FROM reservation_fact GROUP BY order_id)
SELECT l.order_id,l.revision_no current_revision_no,l.ordered_qty,coalesce(s.qty,0) shipped_qty,coalesce(c.qty,0) cancelled_qty,coalesce(rv.q,0)-coalesce(rv.c,0)-coalesce(rv.r,0) reserved_qty,
 (SELECT quantity FROM inventory_opening_fact ORDER BY sku_id LIMIT 1)-coalesce((SELECT sum(quantity) FROM shipment_fact),0) rebuilt_on_hand,
 (SELECT quantity FROM inventory_opening_fact ORDER BY sku_id LIMIT 1) opening_qty,
 (SELECT coalesce(sum(quantity) FILTER(WHERE action='RESERVE'),0)-coalesce(sum(quantity) FILTER(WHERE action IN ('CONSUME','RELEASE')),0) FROM reservation_fact) rebuilt_reserved,
 (SELECT amount_jpy FROM invoice_fact WHERE order_id=l.order_id) invoice_jpy,
 (SELECT coalesce(sum(cr.amount_jpy),0) FROM cash_receipt_fact cr JOIN invoice_fact i USING(invoice_id) WHERE i.order_id=l.order_id) cash_received_jpy,
 p.revision_no payment_record_current_revision_no,p.recorded_amount_jpy payment_record_current_jpy
FROM order_leaf l LEFT JOIN ship s USING(order_id) LEFT JOIN cancel c USING(order_id) LEFT JOIN reserve rv USING(order_id)
LEFT JOIN invoice_fact i ON i.order_id=l.order_id
LEFT JOIN cash_receipt_fact cr ON cr.invoice_id=i.invoice_id
LEFT JOIN pay_leaf p ON p.receipt_id=cr.receipt_id;
