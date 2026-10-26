-- Retire the inbox_n2b need2Buy board (20261026_inbox_need2buy_subs, _inbox_n2b_auto_site,
-- _inbox_n2b_board_view). Superseded by Terminal-2's N2B intake (n2b_ingest_from_apps_script,
-- JulianS4K/Terminal-2 mig 20261009180000, applied 2026-10-26): need2Buy sales from Gmail now
-- become n2s_items rows (status n2b) and show on the Terminal SUBS page. Operator decision
-- 2026-10-26. crm_order_status_lookup is NOT part of this and stays.
SELECT cron.unschedule('inbox_n2b_pull_5min')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'inbox_n2b_pull_5min');

DROP FUNCTION IF EXISTS public.inbox_n2b_board_view(text, boolean, integer);
DROP FUNCTION IF EXISTS public.inbox_n2b_board(text, integer);
DROP FUNCTION IF EXISTS public.inbox_n2b_cover_candidates(interval, integer, text[]);
DROP FUNCTION IF EXISTS public.inbox_n2b_report(jsonb, text);
DROP FUNCTION IF EXISTS public.inbox_n2b_pull(interval);
DROP FUNCTION IF EXISTS public.inbox_n2b_check_secret_(text);
DROP FUNCTION IF EXISTS public.inbox_n2b_active_window();
DROP TABLE IF EXISTS public.inbox_n2b_view_key;
DROP TABLE IF EXISTS public.inbox_n2b;
