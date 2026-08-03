-- ============================================================================
-- 20260803000003_lookup_rate_limit
-- ----------------------------------------------------------------------------
-- `lookup_user_by_code` was granted to `anon`, i.e. callable by anyone holding
-- the publishable anon key — which ships inside the APK. That made it an
-- unauthenticated enumeration oracle over the 6-char code space, returning
-- {id, short_code, public_key, nickname} with no session and no ceiling. The
-- harvested ids then fed the send-transfer-fcm dry-run presence check.
--
-- Two changes:
--
--  1. Drop the `anon` grant. The app never needed it — IdentityService
--     .findUserByCode() calls ensureValidSession() before every lookup, so it
--     always holds an `authenticated` session. Requiring one puts Supabase's
--     per-IP anonymous-signup limit (auth.rate_limit.anonymous_users) in front
--     of the enumerator, which is the control that actually bites.
--
--  2. A shared per-caller throttle, also used by the send-transfer-fcm
--     dry run. The limit is deliberately loose — a room send resolves one code
--     per member, so a heavy legitimate user can burn a few dozen lookups in a
--     minute — but it still turns "unbounded" into ~1200/hour per identity,
--     against a 31^6 ≈ 887M space.
--
-- Idempotent: safe to re-run.
-- ============================================================================

-- ── shared counter table ────────────────────────────────────────────────────
-- One row per (bucket, subject); the window slides forward on first hit after
-- it lapses. Never touched by app roles directly — only by SECURITY DEFINER
-- functions (running as owner) and the service role.
CREATE TABLE IF NOT EXISTS public.rate_limit_counters (
  bucket       TEXT        NOT NULL,
  subject      UUID        NOT NULL,
  window_start TIMESTAMPTZ NOT NULL DEFAULT now(),
  hits         INTEGER     NOT NULL DEFAULT 0,
  PRIMARY KEY (bucket, subject)
);

ALTER TABLE public.rate_limit_counters ENABLE ROW LEVEL SECURITY;
-- No policies on purpose: with RLS on and no policy, every app-role read or
-- write is denied. The owner (SECURITY DEFINER) and service_role bypass it.

REVOKE ALL ON TABLE public.rate_limit_counters FROM PUBLIC, anon, authenticated;

CREATE INDEX IF NOT EXISTS rate_limit_counters_window_idx
  ON public.rate_limit_counters (window_start);

-- ── the throttle ────────────────────────────────────────────────────────────
-- Returns TRUE when the call is allowed, FALSE when the subject is over the
-- limit for this bucket. Counts first, then compares, so the caller cannot
-- ride the boundary.
CREATE OR REPLACE FUNCTION public.rate_limit_hit(
  p_bucket  TEXT,
  p_subject UUID,
  p_limit   INTEGER,
  p_window  INTERVAL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_hits INTEGER;
BEGIN
  -- No identifiable subject → nothing to meter, so refuse rather than
  -- silently granting an unmetered path.
  IF p_subject IS NULL THEN
    RETURN false;
  END IF;

  INSERT INTO public.rate_limit_counters AS c (bucket, subject, window_start, hits)
  VALUES (p_bucket, p_subject, now(), 1)
  ON CONFLICT (bucket, subject) DO UPDATE
    SET window_start = CASE
          WHEN c.window_start < now() - p_window THEN now()
          ELSE c.window_start
        END,
        hits = CASE
          WHEN c.window_start < now() - p_window THEN 1
          ELSE c.hits + 1
        END
  RETURNING c.hits INTO v_hits;

  RETURN v_hits <= p_limit;
END;
$$;

-- Called by other SECURITY DEFINER functions (which run as the owner) and by
-- edge functions over PostgREST as service_role. App roles never call it.
REVOKE ALL ON FUNCTION public.rate_limit_hit(TEXT, UUID, INTEGER, INTERVAL)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rate_limit_hit(TEXT, UUID, INTEGER, INTERVAL)
  TO service_role;

-- ── prune ───────────────────────────────────────────────────────────────────
-- Subjects are anonymous auth uids, which churn on reinstall, so the table
-- would otherwise grow without bound.
CREATE OR REPLACE FUNCTION public.prune_rate_limit_counters()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_deleted INTEGER;
BEGIN
  DELETE FROM public.rate_limit_counters
  WHERE window_start < now() - INTERVAL '1 day';
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

REVOKE ALL ON FUNCTION public.prune_rate_limit_counters()
  FROM PUBLIC, anon, authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    PERFORM cron.schedule(
      'minigo-prune-rate-limit-counters',
      '15 4 * * *',
      $job$SELECT public.prune_rate_limit_counters();$job$
    );
  ELSE
    RAISE NOTICE 'pg_cron unavailable — schedule '
      'public.prune_rate_limit_counters() from an external scheduler.';
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron scheduling skipped: %', SQLERRM;
END $$;

-- ── lookup_user_by_code: authenticated only, and metered ────────────────────
-- Was `language sql STABLE`; metering requires a write, so it becomes plpgsql.
-- The returned column set is unchanged (id, short_code, public_key, nickname)
-- — IdentityService.findUserByCode and RoomSendScreen both read `public_key`
-- off it.
DROP FUNCTION IF EXISTS public.lookup_user_by_code(TEXT);
CREATE FUNCTION public.lookup_user_by_code(p_code TEXT)
RETURNS TABLE (id UUID, short_code TEXT, public_key TEXT, nickname TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'lookup_user_by_code: authentication required';
  END IF;

  -- ~1200 lookups/hour per identity. A 10-member room send costs 10.
  IF NOT public.rate_limit_hit(
        'lookup_user_by_code', auth.uid(), 200, INTERVAL '10 minutes') THEN
    RAISE EXCEPTION
      'lookup_user_by_code: too many lookups, please try again shortly';
  END IF;

  RETURN QUERY
    SELECT u.id, u.short_code, u.public_key, u.nickname
    FROM public.users u
    WHERE u.short_code = upper(trim(p_code))
      AND u.deleted_at IS NULL
    LIMIT 1;
END;
$$;

-- The `anon` revoke is the point of this migration. See 20260705000002 for why
-- the per-role revoke is required rather than just FROM PUBLIC.
REVOKE ALL ON FUNCTION public.lookup_user_by_code(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lookup_user_by_code(TEXT) TO authenticated;
