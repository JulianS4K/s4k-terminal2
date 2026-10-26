-- Inbox need2Buy -> subs board.
-- The Gmail lifecycle Apps Script reports sale threads still labelled need2Buy 12h+
-- after the sale (inbox_n2b_report). Each order is mapped to its TEVO event through
-- the CRM (s4kcs_orders, mapped by event_mapper), falling back to n2s_items and, for
-- TEVO orders, evo_order_items. Mapped events are pulled from EVO, GoTickets and
-- SeatGeek through the existing N2S poller (n2s_pull_events -> n2s_mkt_drain, drained
-- every minute by n2s_pipeline_tick), and matched with the same six cover gates as
-- n2s_cover_candidates (inbox_n2b_cover_candidates). inbox_n2b_board feeds the
-- Apps Script "Subs" screen. Writes only to inbox_n2b; read-only everywhere else.

CREATE TABLE IF NOT EXISTS public.inbox_n2b (
  site              text NOT NULL,          -- Apps Script SITESV3 key
  site_order_id     text NOT NULL,          -- marketplace order # (email "Site Order #")
  order_no          text,                   -- internal order # (PEDDLING SALE RECEIVED <n>)
  thread_id         text,                   -- Gmail thread id, for the screen's link
  subject           text,
  sale_total        numeric,                -- from the email subject
  sale_at           timestamptz,            -- sale email date
  first_reported_at timestamptz NOT NULL DEFAULT now(),
  last_reported_at  timestamptz NOT NULL DEFAULT now(),
  crm_source        text,
  tevo_event_id     bigint,
  event_name        text,
  event_date        date,
  venue             text,
  section           text,
  "row"             text,
  quantity          integer,
  sold_ea           numeric,
  price_basis       text,                   -- crm | n2s | evo | email_total
  map_via           text,                   -- crm | n2s | evo_order | NULL (unmapped)
  PRIMARY KEY (site, site_order_id)
);
CREATE INDEX IF NOT EXISTS inbox_n2b_active_idx ON public.inbox_n2b (last_reported_at DESC);
ALTER TABLE public.inbox_n2b ENABLE ROW LEVEL SECURITY;   -- no policies: definer functions only
REVOKE ALL ON public.inbox_n2b FROM anon, authenticated;

-- A reported order counts as "still need2Buy" while the script keeps reporting it
-- (every 30 min); bought/filled threads stop being reported and age out.
CREATE OR REPLACE FUNCTION public.inbox_n2b_active_window() RETURNS interval
LANGUAGE sql IMMUTABLE AS $$ SELECT interval '2 hours' $$;

CREATE OR REPLACE FUNCTION public.inbox_n2b_check_secret_(p_shared_secret text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v text := get_app_secret('APPSCRIPT_INGEST_SECRET');
BEGIN
  IF v IS NULL OR v = '' THEN
    RAISE EXCEPTION 'APPSCRIPT_INGEST_SECRET unset in vault' USING ERRCODE = '42501';
  END IF;
  IF p_shared_secret IS NULL OR p_shared_secret <> v THEN
    RAISE EXCEPTION 'unauthorized: shared secret mismatch' USING ERRCODE = '42501';
  END IF;
END $$;
REVOKE ALL ON FUNCTION public.inbox_n2b_check_secret_(text) FROM PUBLIC, anon, authenticated;

/* ───────────── pull: listings for every active, mapped, live event ───────────── */
CREATE OR REPLACE FUNCTION public.inbox_n2b_pull(p_refresh_after interval DEFAULT interval '5 minutes')
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_events bigint[]; r record;
BEGIN
  SELECT array_agg(DISTINCT i.tevo_event_id) INTO v_events
    FROM public.inbox_n2b i
   WHERE i.last_reported_at > now() - public.inbox_n2b_active_window()
     AND i.tevo_event_id IS NOT NULL
     AND public.n2s_event_live(i.event_date::timestamp, i.tevo_event_id);
  IF v_events IS NULL THEN RETURN jsonb_build_object('events', 0); END IF;
  SELECT * INTO r FROM public.n2s_pull_events(v_events, p_refresh_after);
  RETURN jsonb_build_object('events', cardinality(v_events), 'evo_fired', r.evo_fired,
    'gt_fired', r.gt_fired, 'sg_queued', r.sg_queued,
    'evo_skipped_fresh', r.evo_skipped_fresh, 'gt_skipped_fresh', r.gt_skipped_fresh);
END $$;
REVOKE ALL ON FUNCTION public.inbox_n2b_pull(interval) FROM PUBLIC, anon, authenticated;

/* ───────────── report: the Apps Script sends its need2Buy 12h+ orders ───────────── */
-- p_orders: [{site, id, order_no, thread_id, subject, total, sale_at_ms}]  (max 500)
CREATE OR REPLACE FUNCTION public.inbox_n2b_report(p_orders jsonb, p_shared_secret text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_rows jsonb; v_pull jsonb;
BEGIN
  PERFORM public.inbox_n2b_check_secret_(p_shared_secret);
  IF jsonb_typeof(p_orders) <> 'array' THEN
    RAISE EXCEPTION 'p_orders must be a JSON array' USING ERRCODE = '22P02';
  END IF;
  IF jsonb_array_length(p_orders) > 500 THEN
    RAISE EXCEPTION 'p_orders: max 500 per call' USING ERRCODE = '54000';
  END IF;

  WITH req AS (
    SELECT DISTINCT ON (lower(btrim(o->>'site')), btrim(o->>'id'))
           lower(btrim(o->>'site')) AS site, btrim(o->>'id') AS id,
           NULLIF(btrim(o->>'order_no'), '') AS order_no,
           NULLIF(o->>'thread_id', '') AS thread_id,
           left(o->>'subject', 300) AS subject,
           CASE WHEN o->>'total' ~ '^\d+(\.\d+)?$' THEN (o->>'total')::numeric END AS total,
           CASE WHEN o->>'sale_at_ms' ~ '^\d{10,16}$'
                THEN to_timestamp((o->>'sale_at_ms')::bigint / 1000.0) END AS sale_at
      FROM jsonb_array_elements(p_orders) AS o
     WHERE COALESCE(btrim(o->>'id'), '') <> ''
     ORDER BY lower(btrim(o->>'site')), btrim(o->>'id')
  ),
  req2 AS (
    SELECT r.*,
           CASE r.site WHEN 'vivid' THEN 'Vivid Seats' WHEN 'seatgeek' THEN 'SeatGeek'
                       WHEN 'tickpick' THEN 'TickPick' WHEN 'gotickets' THEN 'GoTickets'
                       WHEN 'gametime' THEN 'Gametime' WHEN 'stubhub' THEN 'StubHub'
                       WHEN 'viagogo' THEN 'StubHub' END AS crm_source,
           CASE WHEN r.site = 'tevo' THEN regexp_replace(r.id, '^.*-', '') END AS evo_tail
      FROM req r
  ),
  m AS (
    SELECT r.*,
           c.tevo_event_id AS c_ev, c.event_name AS c_name, c.event_date AS c_date, c.venue_name AS c_venue,
           c.section AS c_sec, c."row" AS c_row, c.quantity AS c_qty,
           public.s4kcs_price_per_ticket(c.source, c.price, c.quantity) AS c_ea,
           n.tevo_event_id AS n_ev, n.event_name AS n_name, n.event_dt::date AS n_date, n.venue AS n_venue,
           n.section AS n_sec, n."row" AS n_row, n.qty AS n_qty, n.price_per_ticket AS n_ea,
           t.event_id AS t_ev, t.event_name AS t_name, t.occurs_at::date AS t_date, t.venue_name AS t_venue,
           t.ticket_group_section AS t_sec, t.ticket_group_row AS t_row, t.quantity AS t_qty, t.price AS t_ea
      FROM req2 r
      LEFT JOIN public.s4kcs_orders c ON c.source = r.crm_source AND c.s4k_order_id = r.id
      LEFT JOIN LATERAL (
             SELECT ni.* FROM public.n2s_items ni
              WHERE ni.order_number = r.id
                 OR (r.site = 'tevo' AND ni.order_number LIKE '%-' || r.evo_tail)
              ORDER BY ni.last_seen_at DESC NULLS LAST LIMIT 1) n ON true
      LEFT JOIN LATERAL (
             SELECT oi.* FROM public.evo_order_items oi
              WHERE r.site = 'tevo' AND r.evo_tail ~ '^\d{1,18}$' AND oi.evo_order_id = r.evo_tail::bigint
              ORDER BY oi.id LIMIT 1) t ON true
  ),
  up AS (
    INSERT INTO public.inbox_n2b AS i (
      site, site_order_id, order_no, thread_id, subject, sale_total, sale_at,
      first_reported_at, last_reported_at, crm_source, tevo_event_id, event_name, event_date,
      venue, section, "row", quantity, sold_ea, price_basis, map_via)
    SELECT m.site, m.id, m.order_no, m.thread_id, m.subject, m.total, m.sale_at, now(), now(),
           m.crm_source,
           COALESCE(m.c_ev, m.n_ev, m.t_ev),
           COALESCE(m.c_name, m.n_name, m.t_name),
           COALESCE(m.c_date, m.n_date, m.t_date),
           COALESCE(m.c_venue, m.n_venue, m.t_venue),
           COALESCE(m.c_sec, m.n_sec, m.t_sec),
           COALESCE(m.c_row, m.n_row, m.t_row),
           COALESCE(m.c_qty, m.n_qty, m.t_qty),
           COALESCE(m.c_ea, m.n_ea, m.t_ea,
                    m.total / NULLIF(COALESCE(m.c_qty, m.n_qty, m.t_qty), 0)),
           CASE WHEN m.c_ea IS NOT NULL THEN 'crm' WHEN m.n_ea IS NOT NULL THEN 'n2s'
                WHEN m.t_ea IS NOT NULL THEN 'evo'
                WHEN m.total IS NOT NULL AND COALESCE(m.c_qty, m.n_qty, m.t_qty) > 0 THEN 'email_total' END,
           CASE WHEN m.c_ev IS NOT NULL THEN 'crm' WHEN m.n_ev IS NOT NULL THEN 'n2s'
                WHEN m.t_ev IS NOT NULL THEN 'evo_order' END
      FROM m
    ON CONFLICT (site, site_order_id) DO UPDATE SET
      order_no = EXCLUDED.order_no, thread_id = EXCLUDED.thread_id, subject = EXCLUDED.subject,
      sale_total = EXCLUDED.sale_total, sale_at = EXCLUDED.sale_at,
      last_reported_at = now(), crm_source = EXCLUDED.crm_source,
      tevo_event_id = EXCLUDED.tevo_event_id, event_name = EXCLUDED.event_name,
      event_date = EXCLUDED.event_date, venue = EXCLUDED.venue, section = EXCLUDED.section,
      "row" = EXCLUDED."row", quantity = EXCLUDED.quantity, sold_ea = EXCLUDED.sold_ea,
      price_basis = EXCLUDED.price_basis, map_via = EXCLUDED.map_via
    RETURNING i.site, i.site_order_id, i.tevo_event_id, i.map_via, i.event_name
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object('site', site, 'id', site_order_id,
           'tevo_event_id', tevo_event_id, 'map_via', map_via, 'event_name', event_name)), '[]'::jsonb)
    INTO v_rows FROM up;

  v_pull := public.inbox_n2b_pull(interval '5 minutes');
  RETURN jsonb_build_object('orders', v_rows, 'pull', v_pull);
END $$;
REVOKE ALL ON FUNCTION public.inbox_n2b_report(jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.inbox_n2b_report(jsonb, text) TO anon, authenticated, service_role;

/* ───────────── covers: n2s_cover_candidates' six gates, over inbox orders ───────────── */
-- Same listing sources (n2s_evo_current / n2s_gt_current / n2s_sg_current), same zone
-- logic, same split/tier rules and the same gate table as n2s_cover_candidates; only the
-- order side differs (inbox_n2b instead of n2s_items). Keep the two in step.
CREATE OR REPLACE FUNCTION public.inbox_n2b_cover_candidates(
  p_max_listing_age interval DEFAULT interval '1 hour',
  p_per_order integer DEFAULT 3,
  p_sub_sources text[] DEFAULT NULL)
RETURNS TABLE(site text, site_order_id text, order_no text, event_name text, event_date date,
              venue text, tevo_event_id bigint, section text, order_row text, quantity integer,
              sold_ea numeric, sub_source text, sub_listing_id text, sub_section text, sub_row text,
              sub_qty integer, sub_avail integer, sub_ea numeric, sub_total numeric, cover_cost numeric,
              rows_closer integer, buy_url text, captured_at timestamptz, cover_rank bigint,
              cover_gate integer, cover_label text, order_zone text, sub_zone text)
LANGUAGE sql STABLE SET search_path TO 'public', 'pg_temp' AS $function$
  WITH o AS (
    SELECT i.site || ':' || i.site_order_id AS okey, i.site, i.site_order_id, i.order_no,
           i.event_name, i.event_date, i.venue, i.tevo_event_id, i.section, i."row" AS order_row,
           i.quantity, i.sold_ea,
           public.seat_row_kind(i."row")    AS ord_kind,
           public.seat_row_rank(i."row")    AS ord_rank,
           public.seat_section_norm(i.section) AS sec_norm,
           e.venue_id,
           (SELECT z.performer_id FROM public.performer_zones z
             WHERE z.venue_id = e.venue_id AND z.performer_id = ANY(e.performer_ids)
               AND z.source = 'curated' LIMIT 1) AS zperf
      FROM public.inbox_n2b i
      JOIN public.events e ON e.id = i.tevo_event_id
     WHERE i.last_reported_at > now() - public.inbox_n2b_active_window()
       AND i.quantity > 0 AND i.section IS NOT NULL
       AND public.n2s_event_live(i.event_date::timestamp, i.tevo_event_id)
  ),
  oz AS (SELECT o.*, public.n2s_zone_of(o.zperf, o.venue_id, o.section, o.order_row) AS order_zone FROM o),
  ev AS (SELECT DISTINCT tevo_event_id AS eid FROM o),
  p_evo AS (SELECT DISTINCT c.event_id AS eid FROM public.n2s_evo_current c
                WHERE c.event_id IN (SELECT eid FROM ev) AND c.pulled_at >= now() - p_max_listing_age),
  p_gtc AS (SELECT DISTINCT c.tevo_event_id AS eid FROM public.n2s_gt_current c
                WHERE c.tevo_event_id IN (SELECT eid FROM ev) AND c.pulled_at >= now() - p_max_listing_age),
  p_sgc AS (SELECT DISTINCT c.tevo_event_id AS eid FROM public.n2s_sg_current c
                WHERE c.tevo_event_id IN (SELECT eid FROM ev) AND c.pulled_at >= now() - p_max_listing_age),
  l AS (
    SELECT 'tevo'::text AS src, t.tevo_ticket_group_id::text AS lid, t.event_id AS eid,
           t.section AS sec, t."row" AS rw, t.quantity AS q, t.retail_price AS ea,
           'https://core.ticketevolution.com/buy/event/' || t.event_id::text
             || '/tickets/' || t.tevo_ticket_group_id::text AS url,
           t.pulled_at AS captured_at, t.splits
      FROM p_evo p JOIN public.n2s_evo_current t ON t.event_id = p.eid
     WHERE NOT t.is_owned AND NOT t.is_ancillary
       AND (p_sub_sources IS NULL OR 'tevo' = ANY(p_sub_sources))
    UNION ALL
    SELECT 'gotickets', g.gt_listing_id::text, g.tevo_event_id,
           g.section, g."row", g.quantity, g.all_in_price,
           'https://pro.gotickets.com/tickets/' || g.gt_event_id
             || '/?sortBy=price&sortDirection=asc&sections=' || g.section_id,
           g.pulled_at, g.splits
      FROM p_gtc p JOIN public.n2s_gt_current g ON g.tevo_event_id = p.eid
     WHERE (p_sub_sources IS NULL OR 'gotickets' = ANY(p_sub_sources))
    UNION ALL
    SELECT 'seatgeek', sc.sglid::text, sc.tevo_event_id,
           sc.section, sc."row", sc.quantity, sc.retail_price_all_in,
           CASE WHEN COALESCE(c.sg_url,'') <> '' AND COALESCE(sc.display_id,'') <> ''
                THEN c.sg_url || '#listing=' || sc.display_id ELSE NULL::text END,
           sc.pulled_at,
           CASE WHEN jsonb_typeof(sc.splits) = 'array'
                THEN ARRAY(SELECT e::int FROM jsonb_array_elements_text(sc.splits) AS e
                            WHERE e ~ '^[0-9]+$')
                ELSE NULL::int[] END
      FROM p_sgc p JOIN public.n2s_sg_current sc ON sc.tevo_event_id = p.eid
      LEFT JOIN public.sg_events_canonical c ON c.sg_event_id = sc.sg_event_id
     WHERE NOT sc.is_broker_owned
       AND (p_sub_sources IS NULL OR 'seatgeek' = ANY(p_sub_sources))
  ),
  evz AS MATERIALIZED (SELECT DISTINCT tevo_event_id AS eid, zperf, venue_id
            FROM oz WHERE zperf IS NOT NULL AND order_zone IS NOT NULL),
  zrule AS MATERIALIZED (
    SELECT evz.eid, z.name AS zone,
           public._sec_norm(r.section_from) AS sf_n, public._sec_norm(r.section_to) AS st_n,
           (r.section_from ~ '^[0-9]+$' AND r.section_to ~ '^[0-9]+$') AS sec_num,
           NULLIF(regexp_replace(r.section_from,'\D','','g'),'')::bigint AS sf_i,
           NULLIF(regexp_replace(r.section_to  ,'\D','','g'),'')::bigint AS st_i,
           public._sec_prefix(r.section_from) AS sf_p, public._sec_prefix(r.section_to) AS st_p,
           public._sec_suffix(r.section_from) AS sf_s, public._sec_suffix(r.section_to) AS st_s,
           r.row_from, r.row_to,
           (r.row_from ~ '^[0-9]+$' AND r.row_to ~ '^[0-9]+$') AS row_num,
           NULLIF(regexp_replace(coalesce(r.row_from,''),'\D','','g'),'')::bigint AS rf_i,
           NULLIF(regexp_replace(coalesce(r.row_to  ,''),'\D','','g'),'')::bigint AS rt_i,
           lower(coalesce(r.row_from,'')) AS rf_lc, lower(coalesce(r.row_to,'')) AS rt_lc
      FROM evz
      JOIN public.performer_zones z
        ON z.performer_id = evz.zperf AND z.venue_id = evz.venue_id
       AND z.source = 'curated' AND z.name NOT ILIKE '%fifa%'
      JOIN public.performer_zone_rules r ON r.zone_id = z.id
  ),
  lcoord0 AS MATERIALIZED (SELECT DISTINCT l.eid, l.sec, l.rw FROM l JOIN evz ON evz.eid = l.eid),
  lcoord AS MATERIALIZED (
    SELECT eid, sec, rw,
           public._sec_norm(sec) AS c_n,
           (sec ~ '^[0-9]+$') AS c_num,
           NULLIF(regexp_replace(coalesce(sec,''),'\D','','g'),'')::bigint AS c_i,
           public._sec_prefix(sec) AS c_p, public._sec_suffix(sec) AS c_s,
           (rw ~ '^[0-9]+$') AS r_num,
           NULLIF(regexp_replace(coalesce(rw,''),'\D','','g'),'')::bigint AS r_i,
           lower(coalesce(rw,'')) AS r_lc
      FROM lcoord0
  ),
  lz AS (
    SELECT c.eid, c.sec, c.rw,
           CASE WHEN count(DISTINCT zr.zone) = 1 THEN min(zr.zone) END AS zone
      FROM lcoord c
      JOIN zrule zr ON zr.eid = c.eid
     WHERE ( (zr.sf_n = zr.st_n AND c.c_n = zr.sf_n)
          OR (zr.sec_num AND c.c_num AND c.c_i BETWEEN zr.sf_i AND zr.st_i)
          OR (zr.sf_p <> '' AND zr.sf_p = zr.st_p AND zr.sf_p = c.c_p
              AND zr.sf_s IS NOT NULL AND zr.st_s IS NOT NULL AND c.c_s IS NOT NULL
              AND c.c_s BETWEEN zr.sf_s AND zr.st_s) )
       AND ( (zr.row_from IS NULL AND zr.row_to IS NULL)
          OR (zr.rf_lc = zr.rt_lc AND c.r_lc = zr.rf_lc)
          OR (zr.row_num AND c.r_num AND c.r_i BETWEEN zr.rf_i AND zr.rt_i) )
     GROUP BY c.eid, c.sec, c.rw
  ),
  match_exact AS (
    SELECT oz.*, l.src, l.lid, l.sec, l.rw, l.q, l.ea, l.url, l.captured_at, l.splits,
           lz.zone AS sub_zone, true AS sec_exact
      FROM oz
      JOIN l ON l.eid = oz.tevo_event_id
            AND public.seat_section_norm(l.sec) = oz.sec_norm
            AND public.seat_row_kind(l.rw) = oz.ord_kind
      LEFT JOIN lz ON lz.eid = l.eid AND lz.sec IS NOT DISTINCT FROM l.sec
                                     AND lz.rw  IS NOT DISTINCT FROM l.rw
     WHERE public.seat_row_rank(l.rw) <= oz.ord_rank + 5
  ),
  match_zone AS (
    SELECT oz.*, l.src, l.lid, l.sec, l.rw, l.q, l.ea, l.url, l.captured_at, l.splits,
           lz.zone AS sub_zone, false AS sec_exact
      FROM oz
      JOIN lz ON lz.eid = oz.tevo_event_id AND lz.zone = oz.order_zone
      JOIN l  ON l.eid = lz.eid AND l.sec IS NOT DISTINCT FROM lz.sec
                                AND l.rw  IS NOT DISTINCT FROM lz.rw
     WHERE oz.order_zone IS NOT NULL
       AND public.seat_row_kind(l.rw) = oz.ord_kind
       AND public.seat_row_rank(l.rw) <= oz.ord_rank + 5
       AND public.seat_section_norm(l.sec) <> oz.sec_norm
  ),
  u AS (SELECT * FROM match_exact UNION ALL SELECT * FROM match_zone),
  mm AS (
    SELECT u.*,
           CASE WHEN u.q = u.quantity
                  OR (u.q > u.quantity AND u.quantity = ANY(u.splits)) THEN 1
                WHEN u.q = u.quantity + 1 THEN 2 ELSE 3 END AS tier,
           CASE WHEN u.q = u.quantity
                  OR (u.q > u.quantity AND u.quantity = ANY(u.splits)) THEN u.quantity
                WHEN u.q = u.quantity + 1 THEN u.q
                ELSE u.quantity + 1 END AS buy_qty
      FROM u
     WHERE ( (u.q = u.quantity AND (u.splits IS NULL OR u.q = ANY(u.splits)))
          OR (u.q > u.quantity AND u.quantity = ANY(u.splits))
          OR (u.q = u.quantity + 1 AND (u.splits IS NULL OR u.q = ANY(u.splits)))
          OR (u.q > u.quantity + 1 AND (u.quantity + 1) = ANY(u.splits)
              AND public.n2s_landed_total(u.src, u.ea, u.quantity + 1) <= u.sold_ea * u.quantity) )
  ),
  g AS (
    SELECT mm.*,
           public.n2s_landed_total(mm.src, mm.ea, mm.buy_qty)          AS landed,
           public.seat_row_rank(mm.rw) <= mm.ord_rank                  AS row_ok,
           public.n2s_landed_total(mm.src, mm.ea, mm.buy_qty)
             < mm.sold_ea * mm.quantity                                AS profitable,
           (mm.sold_ea IS NULL OR mm.sold_ea <= 0
             OR public.n2s_landed_total(mm.src, mm.ea, mm.buy_qty)
                <= 2 * mm.sold_ea * mm.quantity)                       AS within_cap,
           mm.sub_zone IS NOT DISTINCT FROM mm.order_zone              AS zone_ok
      FROM mm
  ),
  gg AS (
    SELECT g.*,
           CASE WHEN sec_exact AND row_ok AND profitable THEN 1
                WHEN sec_exact AND row_ok AND within_cap THEN 2
                WHEN NOT sec_exact AND row_ok AND profitable THEN 3
                WHEN NOT sec_exact AND row_ok AND within_cap THEN 4
                WHEN NOT row_ok AND zone_ok AND profitable THEN 5
                WHEN NOT row_ok AND zone_ok AND within_cap THEN 6
           END AS cover_gate
      FROM g
  ),
  ded AS (
    SELECT DISTINCT ON (okey, src, lid) *
      FROM gg WHERE cover_gate IS NOT NULL
     ORDER BY okey, src, lid, cover_gate
  ),
  m AS (
    SELECT ded.*,
           CASE ded.cover_gate WHEN 1 THEN 'Index'
                               WHEN 2 THEN 'S4KTrading'
                               WHEN 3 THEN 'Index offer subs'
                               WHEN 4 THEN 'offer subs s4ktrading'
                               WHEN 5 THEN 'Index Down offer subs'
                               WHEN 6 THEN 'Down offer subs S4KTrading' END
             || CASE WHEN ded.cover_gate >= 5 AND ded.order_zone IS NULL
                     THEN ' zone unverified' ELSE '' END
             || CASE WHEN ded.quantity = 1 THEN ' single ticket' ELSE '' END
             || CASE WHEN ded.buy_qty > ded.quantity THEN ' repost single' ELSE '' END
             AS cover_label,
           row_number() OVER (PARTITION BY ded.okey
                              ORDER BY ded.cover_gate, ded.tier,
                                       ded.landed, (ded.q - ded.quantity)) AS rn
      FROM ded
  )
  SELECT site, site_order_id, order_no, event_name, event_date, venue, tevo_event_id,
         section, order_row, quantity, sold_ea, src, lid, sec, rw,
         buy_qty AS sub_qty, q AS sub_avail, ea,
         round(landed, 2) AS sub_total,
         round(landed - sold_ea * quantity, 2) AS cover_cost,
         (ord_rank - public.seat_row_rank(rw)) AS rows_closer,
         url, captured_at, rn, cover_gate, cover_label, order_zone, sub_zone
    FROM m
   WHERE rn <= p_per_order
   ORDER BY cover_gate, cover_cost, site_order_id;
$function$;
REVOKE ALL ON FUNCTION public.inbox_n2b_cover_candidates(interval, integer, text[]) FROM PUBLIC, anon, authenticated;

/* ───────────── board: what the Apps Script "Subs" screen renders ───────────── */
CREATE OR REPLACE FUNCTION public.inbox_n2b_board(p_shared_secret text, p_per_order integer DEFAULT 3)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v jsonb;
BEGIN
  PERFORM public.inbox_n2b_check_secret_(p_shared_secret);
  WITH act AS (
    SELECT i.* FROM public.inbox_n2b i
     WHERE i.last_reported_at > now() - public.inbox_n2b_active_window()
  ),
  cov AS (
    SELECT c.site, c.site_order_id,
           jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
             'source', c.sub_source, 'section', c.sub_section, 'row', c.sub_row,
             'qty', c.sub_qty, 'avail', c.sub_avail, 'ea', c.sub_ea, 'total', c.sub_total,
             'cover_cost', c.cover_cost, 'rows_closer', c.rows_closer, 'gate', c.cover_gate,
             'label', c.cover_label, 'zone', c.sub_zone, 'url', c.buy_url,
             'captured_at', c.captured_at)) ORDER BY c.cover_rank) AS covers
      FROM public.inbox_n2b_cover_candidates(interval '1 hour', p_per_order) c
     GROUP BY c.site, c.site_order_id
  ),
  fresh AS (
    SELECT a.tevo_event_id,
           (SELECT max(pulled_at) FROM public.n2s_evo_current x WHERE x.event_id = a.tevo_event_id)      AS evo_at,
           (SELECT max(pulled_at) FROM public.n2s_gt_current  x WHERE x.tevo_event_id = a.tevo_event_id) AS gt_at,
           (SELECT max(pulled_at) FROM public.n2s_sg_current  x WHERE x.tevo_event_id = a.tevo_event_id) AS sg_at
      FROM (SELECT DISTINCT tevo_event_id FROM act WHERE tevo_event_id IS NOT NULL) a
  )
  SELECT jsonb_build_object(
           'generated_at', now(),
           'orders', COALESCE(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
             'site', a.site, 'site_order_id', a.site_order_id, 'order_no', a.order_no,
             'thread_id', a.thread_id, 'subject', a.subject, 'sale_total', a.sale_total,
             'sale_at', a.sale_at,
             'hours_waiting', round(extract(epoch FROM now() - COALESCE(a.sale_at, a.first_reported_at)) / 3600.0, 1),
             'event_name', a.event_name, 'event_date', a.event_date, 'venue', a.venue,
             'tevo_event_id', a.tevo_event_id, 'section', a.section, 'row', a."row",
             'quantity', a.quantity, 'sold_ea', a.sold_ea, 'price_basis', a.price_basis,
             'map_via', a.map_via,
             'listings', jsonb_strip_nulls(jsonb_build_object('evo', f.evo_at, 'gotickets', f.gt_at, 'seatgeek', f.sg_at)),
             'covers', COALESCE(c.covers, '[]'::jsonb)))
             ORDER BY (c.covers IS NULL), a.event_date NULLS LAST, a.sale_at), '[]'::jsonb))
    INTO v
    FROM act a
    LEFT JOIN cov c ON c.site = a.site AND c.site_order_id = a.site_order_id
    LEFT JOIN fresh f ON f.tevo_event_id = a.tevo_event_id;
  RETURN v;
END $$;
REVOKE ALL ON FUNCTION public.inbox_n2b_board(text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.inbox_n2b_board(text, integer) TO anon, authenticated, service_role;

/* ───────────── keep listings fresh between script reports ───────────── */
SELECT cron.schedule('inbox_n2b_pull_5min', '*/5 * * * *', $cron$ SELECT public.inbox_n2b_pull(); $cron$);
