-- ============================================================================
-- 20260705000001_identity_lifecycle
-- ----------------------------------------------------------------------------
-- Closes the orphaned-identity gap: when a device's anonymous auth identity is
-- replaced (session revoked, anon-user cleanup, DB reset), its old `users` row
-- previously stayed live forever — the old short code kept validating, so
-- senders would target a dead identity (stale fcm_token / public_key) and
-- files sat undeliverable until the transfer TTL.
--
-- Two complementary mechanisms:
--
-- 1. retire_previous_identity(uuid) — called by the app the moment it detects
--    its auth uid changed (it still holds the old uid in local prefs). Applies
--    the same scrub as the in-app reset (lib/core/app_reset.dart): stamp
--    deleted_at, clear nickname + fcm_token. Knowledge of the old auth uid is
--    the proof of ownership — auth uids are unguessable UUIDs that no policy
--    or RPC ever exposes to other users.
--
-- 2. cleanup_stale_anonymous_identities() — sweeps identities that can never
--    retire themselves (true wipe/reinstall: the device forgot its old uid).
--    Deletes anonymous auth users with no session activity inside the
--    retention window, then soft-retires `users` rows whose auth user is gone.
--    Scheduled daily via pg_cron where available.
--
-- Soft-retired rows are kept forever on purpose: transfers FK-reference
-- users.id, and keeping retired codes under the short_code unique constraint
-- means a code is never recycled to a different person.
--
-- Idempotent: safe to re-run.
-- ============================================================================

-- ── 1. app-invoked retirement of a replaced identity ────────────────────────
CREATE OR REPLACE FUNCTION public.retire_previous_identity(p_old_auth_uid UUID)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_retired INTEGER;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'retire_previous_identity: not authenticated';
  END IF;

  -- The caller's *current* identity is not "previous"; refuse no-ops loudly
  -- in the data rather than scrubbing a live row.
  IF p_old_auth_uid = auth.uid() THEN
    RETURN 0;
  END IF;

  -- Only anonymous-origin identities are retirable this way. If the app ever
  -- gains credentialed accounts, knowing a uid must not be enough to kill one.
  IF EXISTS (
    SELECT 1 FROM auth.users au
    WHERE au.id = p_old_auth_uid AND au.is_anonymous IS NOT TRUE
  ) THEN
    RETURN 0;
  END IF;

  UPDATE public.users u
  SET deleted_at = now(),
      nickname   = NULL,
      fcm_token  = NULL
  WHERE u.auth_uid = p_old_auth_uid
    AND u.deleted_at IS NULL;
  GET DIAGNOSTICS v_retired = ROW_COUNT;

  RETURN v_retired;
END;
$$;

REVOKE ALL ON FUNCTION public.retire_previous_identity(UUID) FROM PUBLIC;
-- Anonymous sign-in yields the `authenticated` role; `anon` (no session) has
-- no business retiring anything.
GRANT EXECUTE ON FUNCTION public.retire_previous_identity(UUID) TO authenticated;

-- ── 2. scheduled sweep of identities that can never call in ─────────────────
CREATE OR REPLACE FUNCTION public.cleanup_stale_anonymous_identities(
  p_retention INTERVAL DEFAULT INTERVAL '90 days'
)
RETURNS TABLE (deleted_auth_users INTEGER, retired_user_rows INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_deleted INTEGER;
  v_retired INTEGER;
BEGIN
  -- Anonymous auth users whose newest session activity is outside the
  -- retention window. Devices refresh their session on every app open, so
  -- "no refresh in 90 days" means uninstalled/abandoned. A false positive
  -- self-heals: the app re-registers with a fresh identity on next launch
  -- (IdentityService dead-session recovery), at the cost of a new code.
  DELETE FROM auth.users au
  WHERE au.is_anonymous IS TRUE
    AND au.created_at < now() - p_retention
    AND NOT EXISTS (
      SELECT 1 FROM auth.sessions s
      WHERE s.user_id = au.id
        AND COALESCE(s.refreshed_at, s.updated_at, s.created_at)
              > now() - p_retention
    );
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  -- Soft-retire app rows whose auth user no longer exists — both the ones
  -- deleted above and any orphaned earlier (wipes, dashboard deletions).
  UPDATE public.users u
  SET deleted_at = now(),
      nickname   = NULL,
      fcm_token  = NULL
  WHERE u.deleted_at IS NULL
    AND NOT EXISTS (SELECT 1 FROM auth.users au WHERE au.id = u.auth_uid);
  GET DIAGNOSTICS v_retired = ROW_COUNT;

  RETURN QUERY SELECT v_deleted, v_retired;
END;
$$;

-- Maintenance-only: not callable by app roles. pg_cron runs it as the job
-- owner (postgres), which needs no grant.
REVOKE ALL ON FUNCTION public.cleanup_stale_anonymous_identities(INTERVAL) FROM PUBLIC;

-- ── 3. daily schedule (pg_cron, when available) ─────────────────────────────
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    -- cron.schedule() upserts by job name, so re-running stays idempotent.
    PERFORM cron.schedule(
      'minigo-cleanup-stale-anon-identities',
      '30 3 * * *',
      $job$SELECT public.cleanup_stale_anonymous_identities();$job$
    );
  ELSE
    RAISE NOTICE 'pg_cron unavailable — schedule '
      'public.cleanup_stale_anonymous_identities() from an external scheduler.';
  END IF;
EXCEPTION WHEN OTHERS THEN
  -- Never fail the migration over scheduling; the functions above are the
  -- important part. Surface the reason for whoever reads the logs.
  RAISE NOTICE 'pg_cron scheduling skipped: %', SQLERRM;
END $$;
