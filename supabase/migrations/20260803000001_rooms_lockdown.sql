-- ============================================================================
-- 20260803000001_rooms_lockdown
-- ----------------------------------------------------------------------------
-- `rooms` and `room_members` were created out-of-band (README points at
-- supabase/rooms_schema.sql, which is not in this repo), so they never went
-- through the 2026-07-04 lockdown: no RLS, no policies — while
-- 20260710000001_rooms_realtime.sql added BOTH to the `supabase_realtime`
-- publication. Every client was therefore receiving every room's membership
-- events, and `setMemberCanShare` / `leaveRoom` / `listMembers` were callable
-- for any room id by any caller, despite the client comments claiming
-- "enforced by RLS".
--
-- This migration closes that. Access model:
--   rooms         SELECT  members + owner | INSERT owner | UPDATE/DELETE owner
--   room_members  SELECT  members | INSERT self | UPDATE host | DELETE self+host
--
-- Two things make that workable:
--
--  1. RECURSION. A policy on room_members that queries room_members recurses,
--     and a policy subquery is itself RLS-filtered — so `EXISTS (SELECT 1 FROM
--     rooms ...)` inside the join policy would see nothing for a non-member and
--     block every join. Both are solved with SECURITY DEFINER predicates
--     (is_room_member / is_room_owner / room_is_joinable) that read past RLS
--     and only ever answer questions about auth.uid()'s own relationship to a
--     room.
--
--  2. JOIN-BY-CODE. joinRoom() must resolve a room *before* membership exists,
--     which a membership-scoped SELECT policy forbids. Same fix as
--     lookup_user_by_code in 20260704000001: a narrow SECURITY DEFINER RPC.
--     It deliberately does NOT filter on expiry so the client keeps its
--     distinct "expired" vs "not found" errors.
--
-- Also re-creates the member-cap trigger as SECURITY DEFINER: the original one
-- counts room_members as the invoking user, and under the new SELECT policy a
-- joining non-member sees 0 rows — the 10-member cap would silently stop
-- working. Error strings ('room_full' / 'room_expired') are the ones
-- room_service.dart matches on.
--
-- Idempotent: safe to re-run.
-- ============================================================================

ALTER TABLE public.rooms ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.room_members ENABLE ROW LEVEL SECURITY;

-- ── SECURITY DEFINER predicates (recursion + visibility breakers) ───────────
-- All three answer only "what is auth.uid()'s relationship to this room", so
-- exposing them to app roles leaks nothing. app roles MUST keep EXECUTE:
-- policy expressions are evaluated as the calling role, and a missing grant
-- turns every room query into "permission denied for function".

CREATE OR REPLACE FUNCTION public.is_room_member(p_room_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.room_members m
    JOIN public.users u ON u.id = m.user_id
    WHERE m.room_id = p_room_id
      AND u.auth_uid = auth.uid()
  );
$$;

CREATE OR REPLACE FUNCTION public.is_room_owner(p_room_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.rooms r
    JOIN public.users u ON u.id = r.owner_id
    WHERE r.id = p_room_id
      AND u.auth_uid = auth.uid()
  );
$$;

-- "Does this room exist and is it still live" — needed by the room_members
-- INSERT policy, which runs before the joiner can see the room.
CREATE OR REPLACE FUNCTION public.room_is_joinable(p_room_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.rooms r
    WHERE r.id = p_room_id
      AND r.expires_at > now()
  );
$$;

REVOKE ALL ON FUNCTION public.is_room_member(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_room_owner(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.room_is_joinable(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_room_member(UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.is_room_owner(UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.room_is_joinable(UUID) TO anon, authenticated;

-- ── drop every existing policy on both tables (name-agnostic) ───────────────
DO $$
DECLARE p RECORD;
BEGIN
  FOR p IN
    SELECT tablename, policyname FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename IN ('rooms', 'room_members')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I',
                   p.policyname, p.tablename);
  END LOOP;
END $$;

-- ── rooms ───────────────────────────────────────────────────────────────────
-- Owner clause is not redundant: createRoom() does INSERT .. RETURNING, which
-- re-checks SELECT, and at that instant the owner has no room_members row yet.
CREATE POLICY rooms_select_member ON public.rooms
  FOR SELECT
  USING (
    public.is_room_member(id)
    OR owner_id IN (SELECT id FROM public.users WHERE auth_uid = auth.uid())
  );

CREATE POLICY rooms_insert_owner ON public.rooms
  FOR INSERT
  WITH CHECK (
    owner_id IN (SELECT id FROM public.users WHERE auth_uid = auth.uid())
  );

-- Nothing in the app updates rooms today; the rooms_freeze_expiry trigger
-- (20260710000002) still blocks expires_at / lifetime_minutes either way.
CREATE POLICY rooms_update_owner ON public.rooms
  FOR UPDATE
  USING (
    owner_id IN (SELECT id FROM public.users WHERE auth_uid = auth.uid())
  )
  WITH CHECK (
    owner_id IN (SELECT id FROM public.users WHERE auth_uid = auth.uid())
  );

-- Owner disbands the room for everyone (members cascade).
CREATE POLICY rooms_delete_owner ON public.rooms
  FOR DELETE
  USING (
    owner_id IN (SELECT id FROM public.users WHERE auth_uid = auth.uid())
  );

-- ── room_members ────────────────────────────────────────────────────────────
CREATE POLICY room_members_select_member ON public.room_members
  FOR SELECT
  USING (public.is_room_member(room_id));

-- Join: only ever as yourself, and only into a room that exists and is live.
-- Cannot require existing membership — that is the chicken-and-egg of joining.
CREATE POLICY room_members_insert_self ON public.room_members
  FOR INSERT
  WITH CHECK (
    user_id IN (SELECT id FROM public.users WHERE auth_uid = auth.uid())
    AND public.room_is_joinable(room_id)
  );

-- can_share is the host's switch alone.
CREATE POLICY room_members_update_host ON public.room_members
  FOR UPDATE
  USING (public.is_room_owner(room_id))
  WITH CHECK (public.is_room_owner(room_id));

-- Leave (self) or be removed by the host.
CREATE POLICY room_members_delete_self_or_host ON public.room_members
  FOR DELETE
  USING (
    user_id IN (SELECT id FROM public.users WHERE auth_uid = auth.uid())
    OR public.is_room_owner(room_id)
  );

-- ── member cap / expiry, re-enforced past RLS ───────────────────────────────
-- SECURITY DEFINER so count(*) sees every member, not just the ones the
-- joining user is allowed to SELECT.
CREATE OR REPLACE FUNCTION public.room_members_enforce_limits()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_expires TIMESTAMPTZ;
  v_count   INTEGER;
BEGIN
  SELECT r.expires_at INTO v_expires
  FROM public.rooms r WHERE r.id = NEW.room_id;

  IF v_expires IS NULL THEN
    RAISE EXCEPTION 'room_not_found';
  END IF;
  IF v_expires <= now() THEN
    RAISE EXCEPTION 'room_expired';
  END IF;

  SELECT count(*) INTO v_count
  FROM public.room_members m WHERE m.room_id = NEW.room_id;

  -- Mirrors AppConstants.maxRoomMembers.
  IF v_count >= 10 THEN
    RAISE EXCEPTION 'room_full';
  END IF;

  RETURN NEW;
END;
$$;

-- The original out-of-band trigger reads `rooms` as the *invoking* user. Now
-- that rooms is RLS-scoped, a joining non-member sees no row there, so that
-- trigger would either stop enforcing the cap or raise a spurious
-- "room_not_found" and break joining outright. The function above restores the
-- documented behaviour correctly, so any other BEFORE INSERT trigger on this
-- table is superseded. Narrowed to BEFORE INSERT so an AFTER trigger (e.g. a
-- member counter) is left alone, and each drop is announced.
DO $$
DECLARE t RECORD;
BEGIN
  FOR t IN
    SELECT tg.tgname
    FROM pg_trigger tg
    WHERE tg.tgrelid = 'public.room_members'::regclass
      AND NOT tg.tgisinternal
      AND tg.tgname <> 'room_members_enforce_limits'
      AND (tg.tgtype & 2) <> 0   -- BEFORE
      AND (tg.tgtype & 4) <> 0   -- INSERT
  LOOP
    RAISE NOTICE
      'rooms_lockdown: superseding BEFORE INSERT trigger % on room_members',
      t.tgname;
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.room_members', t.tgname);
  END LOOP;
END $$;

DROP TRIGGER IF EXISTS room_members_enforce_limits ON public.room_members;
CREATE TRIGGER room_members_enforce_limits
  BEFORE INSERT ON public.room_members
  FOR EACH ROW EXECUTE FUNCTION public.room_members_enforce_limits();

REVOKE ALL ON FUNCTION public.room_members_enforce_limits()
  FROM PUBLIC, anon, authenticated;

-- ── join-by-code RPC ────────────────────────────────────────────────────────
-- Returns the room for a code without granting broad SELECT on `rooms`.
-- Expiry is intentionally NOT filtered here: room_service.joinRoom() checks
-- Room.isExpired itself so it can raise RoomExpiredException rather than
-- collapsing "expired" into "no such room".
DROP FUNCTION IF EXISTS public.lookup_room_by_code(TEXT);
CREATE FUNCTION public.lookup_room_by_code(p_code TEXT)
RETURNS TABLE (
  id UUID,
  code TEXT,
  name TEXT,
  owner_id UUID,
  expires_at TIMESTAMPTZ
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
  SELECT r.id, r.code, r.name, r.owner_id, r.expires_at
  FROM public.rooms r
  WHERE r.code = upper(trim(p_code))
  LIMIT 1;
$$;

-- Joining requires a session; `anon` (no sign-in) has no business enumerating
-- room codes. See 20260705000002 for why the per-role revoke is required.
REVOKE ALL ON FUNCTION public.lookup_room_by_code(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lookup_room_by_code(TEXT) TO authenticated;
