-- inbox_n2b: accept site = 'auto' for sale threads with no marketplace label. The CRM is
-- searched by marketplace order # across every source (s4kcs_orders_order_id_idx), and an
-- "<office>-<order>" id is treated as TEVO. The board reports the source the CRM found.
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
                       WHEN 'viagogo' THEN 'StubHub' END AS want_source,
           CASE WHEN r.site = 'tevo' OR (r.site = 'auto' AND r.id ~ '^\d+-\d+$')
                THEN regexp_replace(r.id, '^.*-', '') END AS evo_tail
      FROM req r
  ),
  m AS (
    SELECT r.*,
           c.source AS c_source,
           c.tevo_event_id AS c_ev, c.event_name AS c_name, c.event_date AS c_date, c.venue_name AS c_venue,
           c.section AS c_sec, c."row" AS c_row, c.quantity AS c_qty,
           public.s4kcs_price_per_ticket(c.source, c.price, c.quantity) AS c_ea,
           n.s4k_source AS n_source,
           n.tevo_event_id AS n_ev, n.event_name AS n_name, n.event_dt::date AS n_date, n.venue AS n_venue,
           n.section AS n_sec, n."row" AS n_row, n.qty AS n_qty, n.price_per_ticket AS n_ea,
           t.event_id AS t_ev, t.event_name AS t_name, t.occurs_at::date AS t_date, t.venue_name AS t_venue,
           t.ticket_group_section AS t_sec, t.ticket_group_row AS t_row, t.quantity AS t_qty, t.price AS t_ea
      FROM req2 r
      LEFT JOIN LATERAL (
             SELECT c1.* FROM public.s4kcs_orders c1
              WHERE c1.s4k_order_id = r.id
                AND (r.site = 'auto' OR c1.source = r.want_source)
              ORDER BY c1.last_seen_at DESC NULLS LAST LIMIT 1) c ON true
      LEFT JOIN LATERAL (
             SELECT ni.* FROM public.n2s_items ni
              WHERE ni.order_number = r.id
                 OR (r.evo_tail IS NOT NULL AND ni.order_number LIKE '%-' || r.evo_tail)
              ORDER BY ni.last_seen_at DESC NULLS LAST LIMIT 1) n ON true
      LEFT JOIN LATERAL (
             SELECT oi.* FROM public.evo_order_items oi
              WHERE r.evo_tail ~ '^\d{1,18}$' AND oi.evo_order_id = r.evo_tail::bigint
              ORDER BY oi.id LIMIT 1) t ON true
  ),
  up AS (
    INSERT INTO public.inbox_n2b AS i (
      site, site_order_id, order_no, thread_id, subject, sale_total, sale_at,
      first_reported_at, last_reported_at, crm_source, tevo_event_id, event_name, event_date,
      venue, section, "row", quantity, sold_ea, price_basis, map_via)
    SELECT m.site, m.id, m.order_no, m.thread_id, m.subject, m.total, m.sale_at, now(), now(),
           COALESCE(m.c_source, m.n_source, m.want_source, CASE WHEN m.t_ev IS NOT NULL THEN 'EVO' END),
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
    RETURNING i.site, i.site_order_id, i.crm_source, i.tevo_event_id, i.map_via, i.event_name
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object('site', site, 'id', site_order_id, 'source', crm_source,
           'tevo_event_id', tevo_event_id, 'map_via', map_via, 'event_name', event_name)), '[]'::jsonb)
    INTO v_rows FROM up;

  v_pull := public.inbox_n2b_pull(interval '5 minutes');
  RETURN jsonb_build_object('orders', v_rows, 'pull', v_pull);
END $$;
REVOKE ALL ON FUNCTION public.inbox_n2b_report(jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.inbox_n2b_report(jsonb, text) TO anon, authenticated, service_role;

-- board: also return the CRM source, so the screen can name the marketplace for auto rows
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
             'site', a.site, 'source', a.crm_source, 'site_order_id', a.site_order_id, 'order_no', a.order_no,
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

