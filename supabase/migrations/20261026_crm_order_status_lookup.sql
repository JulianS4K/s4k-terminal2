-- crm_order_status_lookup: targeted CRM status lookup for the Gmail order-lifecycle
-- Apps Script (S4K_OrderLifecycleV3). The script sends ONLY the marketplace order #s
-- it still has open in the inbox; nothing here pulls the whole book.
--
-- Auth: same shared-secret pattern as tickpick_orders_ingest_from_apps_script
-- (vault APPSCRIPT_INGEST_SECRET), callable with the anon key. Read-only.
--
-- Input  p_orders: [{"site":"vivid","id":"80937492"}, ...]   (max 500)
--        site = Apps Script SITESV3 key: tevo|vivid|seatgeek|tickpick|gotickets|gametime|viagogo|stubhub
-- Output jsonb array, one object per input (same order), with `verdict`:
--   filled     marketplace order table reports a delivered/completed state (definitive)
--   cancelled  marketplace table or CRM reports cancelled / rejected (definitive)
--   open       still on the CRM open-orders feed (still owed to the buyer), or off the
--              feed but a marketplace table refreshed since still shows it live
--   closed     was on the CRM open-orders feed, has been absent for >= CRM_GONE_GRACE
--              while the feed kept refreshing -> no longer owed (fulfilled, or cancelled
--              with no marketplace record saying so)
--   feed_stale CRM feed for that marketplace has not refreshed recently; do not act
--   not_found  CRM has never seen this order
--
-- Why "absent for >= 35 min": s4kcs_orders is a snapshot of OPEN orders refreshed every
-- 10 min (s4kcs_orders_queue/process). Closed orders are never deleted; their last_seen_at
-- simply stops moving. Pulls are occasionally partial (e.g. 15.5k of 18.3k rows), so one
-- missed pull means nothing -- three in a row does.
CREATE OR REPLACE FUNCTION public.crm_order_status_lookup(p_orders jsonb, p_shared_secret text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_expected_secret text;
  v_out             jsonb;
  c_gone_grace      constant interval := interval '35 minutes';
  c_feed_max_age    constant interval := interval '45 minutes';
BEGIN
  v_expected_secret := get_app_secret('APPSCRIPT_INGEST_SECRET');
  IF v_expected_secret IS NULL OR v_expected_secret = '' THEN
    RAISE EXCEPTION 'APPSCRIPT_INGEST_SECRET unset in vault' USING ERRCODE = '42501';
  END IF;
  IF p_shared_secret IS NULL OR p_shared_secret <> v_expected_secret THEN
    RAISE EXCEPTION 'unauthorized: shared secret mismatch' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(p_orders) <> 'array' THEN
    RAISE EXCEPTION 'p_orders must be a JSON array' USING ERRCODE = '22P02';
  END IF;
  IF jsonb_array_length(p_orders) > 500 THEN
    RAISE EXCEPTION 'p_orders: max 500 per call' USING ERRCODE = '54000';
  END IF;

  WITH req AS (
    SELECT t.ord,
           lower(btrim(t.o->>'site')) AS site,
           btrim(t.o->>'id')          AS id
      FROM jsonb_array_elements(p_orders) WITH ORDINALITY AS t(o, ord)
  ),
  req2 AS (
    SELECT r.*,
           CASE r.site
             WHEN 'vivid'     THEN 'Vivid Seats'
             WHEN 'seatgeek'  THEN 'SeatGeek'
             WHEN 'tickpick'  THEN 'TickPick'
             WHEN 'gotickets' THEN 'GoTickets'
             WHEN 'gametime'  THEN 'Gametime'
             WHEN 'stubhub'   THEN 'StubHub'
             WHEN 'viagogo'   THEN 'StubHub'
           END AS crm_source,
           -- TEVO site order #s arrive as "<office>-<order>"; the order id is the tail.
           CASE WHEN r.site = 'tevo' THEN regexp_replace(r.id, '^.*-', '') END AS evo_tail
      FROM req r
  ),
  feed AS (
    SELECT o.source, max(o.last_seen_at) AS last_pull
      FROM public.s4kcs_orders o
     WHERE o.source IN (SELECT DISTINCT crm_source FROM req2 WHERE crm_source IS NOT NULL)
     GROUP BY o.source
  ),
  j AS (
    SELECT r.ord, r.site, r.id, r.crm_source,
           c.s4k_order_id AS c_id, c.order_status AS c_status, c.event_name, c.event_date,
           c.venue_name, c.section, c."row", c.quantity, c.price, c.delivery,
           c.inhand_date, c.payout_date, c.purchase_date, c.notes, c.last_seen_at,
           f.last_pull,
           x.canonical_status, x.is_terminal, x.is_sale_succeeded,
           m.m_status, m.m_fulfilled, m.m_seen_at,
           n.n2s_status, n.n2s_label, n.fail_reason, n.timer_expires_at, n.timer_expired,
           n.subbed_at, n.po_number, n.total_cost, n.profit_loss, n.n2s_seen_at,
           pc.cover_label, pc.cover_gate, pc.profit AS cover_profit, pc.buy_url,
           pc.sub_section, pc.sub_row, pc.sub_qty, pc.sub_view
      FROM req2 r
      LEFT JOIN public.s4kcs_orders c
             ON c.source = r.crm_source AND c.s4k_order_id = r.id
      LEFT JOIN feed f ON f.source = r.crm_source
      LEFT JOIN LATERAL (
             SELECT x1.canonical_status, x1.is_terminal, x1.is_sale_succeeded
               FROM public.order_status_xref x1
              WHERE x1.source = 's4kcs' AND lower(x1.source_status) = lower(c.order_status)
              LIMIT 1) x ON true
      LEFT JOIN LATERAL (
             -- Marketplace order tables: only their TERMINAL states are trusted below;
             -- their open states can be weeks stale.
             SELECT e.state AS m_status, NULL::boolean AS m_fulfilled, e.last_seen_at AS m_seen_at
               FROM public.evo_orders e
              WHERE r.site = 'tevo' AND r.evo_tail ~ '^\d{1,18}$' AND e.evo_order_id = r.evo_tail::bigint
             UNION ALL
             SELECT s.status, NULL, s.last_status_at
               FROM public.seatgeek_orders s
              WHERE r.site = 'seatgeek' AND s.sg_order_id = r.id
             UNION ALL
             SELECT g.seller_status, g.fulfilled, g.pulled_at
               FROM public.gotickets_sales g
              WHERE r.site = 'gotickets' AND r.id ~ '^\d{1,18}$' AND g.gt_sale_id = r.id::bigint
             UNION ALL
             SELECT v.status, NULL, v.last_seen_at
               FROM public.vivid_orders v
              WHERE r.site = 'vivid' AND v.vivid_order_id = r.id
             UNION ALL
             SELECT t.status, NULL, t.last_seen_at
               FROM public.tickpick_orders t
              WHERE r.site = 'tickpick' AND t.tp_order_id = r.id
             LIMIT 1) m ON true
      LEFT JOIN LATERAL (
             SELECT ni.status AS n2s_status, ni.status_label AS n2s_label, ni.fail_reason,
                    ni.timer_expires_at, ni.timer_expired, ni.subbed_at, ni.po_number,
                    ni.total_cost, ni.profit_loss, ni.last_seen_at AS n2s_seen_at, ni.n2s_id
               FROM public.n2s_items ni
              WHERE ni.order_number = r.id
                 OR (r.site = 'tevo' AND ni.order_number LIKE '%-' || r.evo_tail)
              ORDER BY ni.last_seen_at DESC NULLS LAST
              LIMIT 1) n ON true
      LEFT JOIN LATERAL (
             SELECT p.* FROM public.n2s_profitable_cover p
              WHERE p.n2s_id = n.n2s_id
              ORDER BY p.profit DESC NULLS LAST
              LIMIT 1) pc ON true
  ),
  v AS (
    SELECT j.*,
           CASE
             WHEN j.m_fulfilled
               OR lower(j.m_status) IN ('completed','fulfilled','delivered','shipped','filled')
               THEN 'filled'
             WHEN lower(j.m_status) ~ '(cancel|reject)' THEN 'cancelled'
           END AS market_verdict,
           (j.last_pull IS NOT NULL AND j.last_pull > now() - c_feed_max_age) AS feed_ok,
           (j.c_id IS NOT NULL AND j.last_seen_at >= j.last_pull - c_gone_grace) AS in_feed,
           -- Marketplace table refreshed AFTER the order left the CRM feed and still shows a
           -- live seller-side state: trust the fresher source. PENDING_TRANSFER_PROOF is
           -- excluded -- our transfer is done, and the CRM drops those by design.
           (j.m_status IS NOT NULL AND j.m_seen_at IS NOT NULL
             AND j.m_seen_at > COALESCE(j.last_seen_at, '-infinity'::timestamptz) + interval '1 hour'
             AND upper(j.m_status) ~ '(PENDING|UNCONFIRMED|CONFIRMED|ACCEPTED|OPEN)'
             AND upper(j.m_status) <> 'PENDING_TRANSFER_PROOF') AS market_open_fresh
      FROM j
  )
  SELECT COALESCE(jsonb_agg(
           jsonb_strip_nulls(jsonb_build_object(
             'site', v.site,
             'id', v.id,
             'verdict',
               CASE
                 WHEN v.market_verdict IS NOT NULL                           THEN v.market_verdict
                 WHEN v.c_id IS NOT NULL AND v.is_terminal AND v.is_sale_succeeded THEN 'filled'
                 WHEN v.c_id IS NOT NULL AND v.is_terminal                   THEN 'cancelled'
                 WHEN v.in_feed                                              THEN 'open'
                 WHEN v.c_id IS NOT NULL AND v.market_open_fresh             THEN 'open'
                 WHEN v.c_id IS NOT NULL AND NOT v.feed_ok                   THEN 'feed_stale'
                 WHEN v.c_id IS NOT NULL                                     THEN 'closed'
                 ELSE 'not_found'
               END,
             'verdict_source',
               CASE
                 WHEN v.market_verdict IS NOT NULL THEN 'marketplace'
                 WHEN v.c_id IS NOT NULL AND NOT v.in_feed AND v.market_open_fresh THEN 'marketplace'
                 WHEN v.c_id IS NOT NULL           THEN 'crm'
               END,
             'crm_status', v.c_status,
             'canonical_status', v.canonical_status,
             'market_status', v.m_status,
             'event_name', v.event_name,
             'event_date', v.event_date,
             'venue', v.venue_name,
             'section', v.section,
             'row', v."row",
             'quantity', v.quantity,
             'price', v.price,
             'delivery', v.delivery,
             'inhand_date', v.inhand_date,
             'payout_date', v.payout_date,
             'purchase_date', v.purchase_date,
             'notes', NULLIF(v.notes, ''),
             'crm_last_seen_at', v.last_seen_at,
             'crm_feed_pulled_at', v.last_pull,
             'n2s', CASE WHEN v.n2s_status IS NOT NULL THEN jsonb_strip_nulls(jsonb_build_object(
                      'status', v.n2s_status, 'label', v.n2s_label, 'fail_reason', v.fail_reason,
                      'timer_expires_at', v.timer_expires_at, 'timer_expired', v.timer_expired,
                      'subbed_at', v.subbed_at, 'po_number', v.po_number,
                      'total_cost', v.total_cost, 'profit_loss', v.profit_loss,
                      'seen_at', v.n2s_seen_at)) END,
             'cover', CASE WHEN v.cover_label IS NOT NULL OR v.buy_url IS NOT NULL THEN jsonb_strip_nulls(jsonb_build_object(
                      'label', v.cover_label, 'gate', v.cover_gate, 'profit', v.cover_profit,
                      'section', v.sub_section, 'row', v.sub_row, 'qty', v.sub_qty,
                      'view', v.sub_view, 'buy_url', v.buy_url)) END
           )) ORDER BY v.ord), '[]'::jsonb)
    INTO v_out
    FROM v;

  RETURN v_out;
END;
$function$;

REVOKE ALL ON FUNCTION public.crm_order_status_lookup(jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.crm_order_status_lookup(jsonb, text) TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.crm_order_status_lookup(jsonb, text) IS
  'Apps Script order lifecycle: targeted CRM/marketplace status for the site order #s the inbox still has open. Shared-secret auth (APPSCRIPT_INGEST_SECRET). Read-only.';
