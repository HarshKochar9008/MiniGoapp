-- ============================================================================
-- 20261113000004_identity_retirement_final
-- ----------------------------------------------------------------------------
-- `users_update_self` (20260704000001) lets an owner UPDATE any column of
-- their own row: there are no column grants and no trigger on public.users.
-- So an authenticated client could
--   * clear its own `deleted_at`, bringing a retired code back to life;
--   * pick their own `short_code` (vanity or look-alike codes), or move
--     `auth_uid`/`id`;
--   * write `fcm_token` / `nickname` back onto a retired row — which older
--     app builds did on every start when their row had been retired.
--
-- A BEFORE UPDATE trigger now holds, for app roles (anon, authenticated):
--   * `id`, `auth_uid` and `short_code` never change (raises 42501).
--   * Retiring stays allowed — the app's reset and account deletion do it
--     with a plain UPDATE setting `deleted_at` — but the server stamps the
--     time and applies the scrub (nickname, fcm_token) itself.
--   * Retired is final. Writes to a retired row are absorbed rather than
--     rejected, so an older client retrying "delete account" still sees
--     success: `deleted_at` keeps its original value, nickname/fcm_token stay
--     NULL, public_key is left as it was.
--
-- Not affected: SECURITY DEFINER functions (retire_previous_identity, the
-- stale-identity sweep) run as their owner, and the service role and
-- migrations are trusted — the trigger only constrains anon/authenticated.
--
-- A trigger rather than column REVOKEs: revoking UPDATE (deleted_at) would
-- break the app's own retirement UPDATE, including in builds already shipped.
--
-- Idempotent: safe to re-run.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.users_guard_identity_columns()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF current_user NOT IN ('anon', 'authenticated') THEN
    RETURN NEW;
  END IF;

  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.auth_uid IS DISTINCT FROM OLD.auth_uid
     OR NEW.short_code IS DISTINCT FROM OLD.short_code THEN
    RAISE EXCEPTION 'users: id, auth_uid and short_code cannot be changed'
      USING ERRCODE = '42501';
  END IF;

  -- Retired is final: absorb the write.
  IF OLD.deleted_at IS NOT NULL THEN
    NEW.deleted_at := OLD.deleted_at;
    NEW.nickname   := NULL;
    NEW.fcm_token  := NULL;
    NEW.public_key := OLD.public_key;
    RETURN NEW;
  END IF;

  -- Retiring now: the server's clock, and the scrub always applied.
  IF NEW.deleted_at IS NOT NULL THEN
    NEW.deleted_at := now();
    NEW.nickname   := NULL;
    NEW.fcm_token  := NULL;
  END IF;

  RETURN NEW;
END;
$$;

-- Trigger functions can't be called through the API, but Supabase's default
-- privileges grant EXECUTE on every new function to app roles (see
-- 20260705000002): revoke it anyway so nothing lists it as callable.
REVOKE ALL ON FUNCTION public.users_guard_identity_columns()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS users_guard_identity_columns ON public.users;
CREATE TRIGGER users_guard_identity_columns
  BEFORE UPDATE ON public.users
  FOR EACH ROW
  EXECUTE FUNCTION public.users_guard_identity_columns();
