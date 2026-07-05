-- ============================================================================
-- 20260705000002_function_privileges
-- ----------------------------------------------------------------------------
-- Hardens the identity-lifecycle functions against Supabase's default
-- privileges: the platform ALTER DEFAULT PRIVILEGES auto-grants EXECUTE on
-- every new public function to anon/authenticated/service_role, so the
-- REVOKE ... FROM PUBLIC in 20260705000001 did not actually block app roles
-- (verified live: the anon role could invoke retire_previous_identity and was
-- only stopped by its internal auth.uid() check — and
-- cleanup_stale_anonymous_identities has no such internal check, making a
-- caller-supplied tiny retention a mass-retirement primitive).
--
-- 1. Explicit REVOKEs per role, not just PUBLIC.
-- 2. Defense-in-depth: the cleanup function now refuses any call that arrives
--    through the API (PostgREST always sets request.jwt.claims); it is
--    reachable only by direct SQL — pg_cron, dashboard, migrations.
--
-- Idempotent: safe to re-run.
-- ============================================================================

-- ── explicit role revokes ────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.retire_previous_identity(UUID)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.retire_previous_identity(UUID)
  TO authenticated;

REVOKE ALL ON FUNCTION public.cleanup_stale_anonymous_identities(INTERVAL)
  FROM PUBLIC, anon, authenticated;

-- ── cleanup: refuse API callers outright ─────────────────────────────────────
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
  -- Maintenance-only. Every PostgREST request (any role, service_role
  -- included) carries request.jwt.claims; direct SQL sessions — pg_cron, the
  -- dashboard editor, migrations — do not. Grants alone are not enough here
  -- because platform default privileges re-expose new functions to app roles.
  IF COALESCE(current_setting('request.jwt.claims', true), '') <> '' THEN
    RAISE EXCEPTION 'cleanup_stale_anonymous_identities: maintenance only';
  END IF;

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

-- CREATE OR REPLACE re-triggers default privileges; revoke again, last.
REVOKE ALL ON FUNCTION public.cleanup_stale_anonymous_identities(INTERVAL)
  FROM PUBLIC, anon, authenticated;
