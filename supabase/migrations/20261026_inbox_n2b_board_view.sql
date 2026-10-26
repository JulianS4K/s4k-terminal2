-- Read-only access to the need2Buy subs board for the S4K Terminal (s4k_explorer.html SUBS
-- tab), which calls Supabase directly with the publishable key. Guarded by a view key
-- (only its sha256 is stored here); it can read the board and nudge a listings re-pull,
-- nothing else. The ingest secret never leaves the Apps Script.
CREATE TABLE IF NOT EXISTS public.inbox_n2b_view_key (
  key_sha256 text PRIMARY KEY,
  label      text,
  created_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz
);
ALTER TABLE public.inbox_n2b_view_key ENABLE ROW LEVEL SECURITY;   -- no policies
REVOKE ALL ON public.inbox_n2b_view_key FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.inbox_n2b_board_view(p_view_key text, p_pull boolean DEFAULT false,
                                                       p_per_order integer DEFAULT 3)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions', 'pg_temp' AS $$
DECLARE v_pull jsonb;
BEGIN
  IF p_view_key IS NULL OR NOT EXISTS (
       SELECT 1 FROM public.inbox_n2b_view_key k
        WHERE k.revoked_at IS NULL
          AND k.key_sha256 = encode(extensions.digest(p_view_key, 'sha256'), 'hex')) THEN
    RAISE EXCEPTION 'unauthorized: bad view key' USING ERRCODE = '42501';
  END IF;
  IF p_pull THEN v_pull := public.inbox_n2b_pull(interval '2 minutes'); END IF;
  RETURN public.inbox_n2b_board(public.get_app_secret('APPSCRIPT_INGEST_SECRET'),
                                LEAST(GREATEST(COALESCE(p_per_order, 3), 1), 10))
         || jsonb_strip_nulls(jsonb_build_object('pull', v_pull));
END $$;
REVOKE ALL ON FUNCTION public.inbox_n2b_board_view(text, boolean, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.inbox_n2b_board_view(text, boolean, integer) TO anon, authenticated, service_role;
-- The key itself is inserted out of band (its hash only):
--   INSERT INTO public.inbox_n2b_view_key(key_sha256, label) VALUES ('<sha256 hex>', 'terminal');
