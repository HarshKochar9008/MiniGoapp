-- ============================================================================
-- 20260704000001_users_lockdown
-- ----------------------------------------------------------------------------
-- Restricts `users` to owner-only access and adds the E2E public key + a narrow
-- recipient-lookup RPC. Name-agnostic: drops EVERY existing policy on the table
-- first, so pre-existing policies under any name cannot survive and re-open
-- access (RLS combines policies with OR).
--
-- Idempotent: safe to re-run.
-- ============================================================================

ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

-- X25519 public key (base64url, 32 bytes). NULL until the device uploads it.
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS public_key TEXT;

-- Soft-delete marker (the client already filters on this).
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

-- Drop ALL existing policies on public.users, whatever they are named.
DO $$
DECLARE p RECORD;
BEGIN
  FOR p IN
    SELECT policyname FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'users'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.users', p.policyname);
  END LOOP;
END $$;

-- A caller may only read their OWN row.
CREATE POLICY users_select_self ON public.users
  FOR SELECT
  USING (auth_uid = auth.uid());

-- A caller may only insert a row bound to their own auth uid.
CREATE POLICY users_insert_self ON public.users
  FOR INSERT
  WITH CHECK (auth_uid = auth.uid());

-- A caller may only update their OWN row (nickname, fcm_token, public_key).
CREATE POLICY users_update_self ON public.users
  FOR UPDATE
  USING (auth_uid = auth.uid())
  WITH CHECK (auth_uid = auth.uid());

-- No DELETE policy: hard deletes are denied by default (app soft-deletes).

-- ============================================================================
-- Narrow recipient lookup. Returns ONLY what a sender needs to address +
-- encrypt to a recipient. SECURITY DEFINER so it can read past the owner-only
-- RLS above, but it never returns fcm_token or auth_uid.
-- ============================================================================
-- DROP first: the deployed function also returns `nickname` (added after the
-- initial lockdown), and CREATE OR REPLACE cannot change a return type.
DROP FUNCTION IF EXISTS public.lookup_user_by_code(TEXT);
CREATE FUNCTION public.lookup_user_by_code(p_code TEXT)
RETURNS TABLE (id UUID, short_code TEXT, public_key TEXT, nickname TEXT)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
  SELECT u.id, u.short_code, u.public_key, u.nickname
  FROM public.users u
  WHERE u.short_code = upper(trim(p_code))
    AND u.deleted_at IS NULL
  LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.lookup_user_by_code(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.lookup_user_by_code(TEXT) TO anon, authenticated;
