-- ============================================================================
-- 20261113000005_rooms_keys_unblock
-- ----------------------------------------------------------------------------
-- Follow-ups to 20261113000003_rooms_lifecycle_hardening (which must be
-- applied first: room_member_blocks lives there).
--
--  1. room_presence(room_id). After a realtime disconnect the app reloads
--     the member list, and finding itself missing from it can mean three
--     things: the room was deleted, it expired, or this user was removed.
--     Membership-scoped RLS makes all three look like an empty list; this
--     tells them apart so the app only says "room ended" when it did.
--
--  2. list_room_blocks / unblock_room_user. A block (room_member_blocks)
--     outlives the membership row, so a host could block someone who then
--     left and had no way to undo it: the can_share switch needs a row. These
--     owner-only RPCs list blocked people who are NOT current members and
--     lift a block. A current member is still unblocked with the switch, so
--     the block row and can_share never disagree.
--
--  3. room_members DELETE. The old policy let the owner delete their own
--     membership row, leaving a live room whose host could no longer see it
--     in their list or send in it. Now: a member may delete their own row
--     unless they own the room; the owner may delete other members' rows but
--     not their own (closing the room is the owner's way out). Deleting the
--     room still cascades to every member row: referential actions bypass
--     RLS.
--
--  4. room_member_public_keys(room_id). Room sends looked up each
--     recipient's encryption key by short code — one rate-limited call per
--     member, and keyed by a code rather than the user the transfer actually
--     goes to. This returns every member's key by user id in one call, for
--     callers who are members of the live room.
--
-- Error strings are the ones lib/features/rooms/room_service.dart matches:
-- 'room_not_owner', 'room_not_member', 'room_expired', 'room_member_present'.
--
-- Idempotent: safe to re-run.
-- ============================================================================

-- ── 1. room_presence ────────────────────────────────────────────────────────
-- 'gone' | 'not_member' | 'expired' | 'live'. Reveals only whether a room id
-- exists (ids are random UUIDs) and the caller's own relationship to it.
CREATE OR REPLACE FUNCTION public.room_presence(p_room_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
DECLARE
  v_expires TIMESTAMPTZ;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'room_presence: authentication required';
  END IF;

  SELECT r.expires_at INTO v_expires
  FROM public.rooms r WHERE r.id = p_room_id;
  IF NOT FOUND THEN
    RETURN 'gone';
  END IF;
  IF NOT public.is_room_member(p_room_id) THEN
    RETURN 'not_member';
  END IF;
  IF v_expires <= now() THEN
    RETURN 'expired';
  END IF;
  RETURN 'live';
END;
$$;

REVOKE ALL ON FUNCTION public.room_presence(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.room_presence(UUID) TO authenticated;

-- ── 2. blocks of people who left ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.list_room_blocks(p_room_id UUID)
RETURNS TABLE (user_id UUID, short_code TEXT, nickname TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
#variable_conflict use_column
BEGIN
  IF NOT public.is_room_owner(p_room_id) THEN
    RAISE EXCEPTION 'room_not_owner';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.rooms r
    WHERE r.id = p_room_id
      AND r.expires_at > now()
  ) THEN
    RAISE EXCEPTION 'room_expired';
  END IF;

  RETURN QUERY
    SELECT b.user_id, u.short_code, u.nickname
    FROM public.room_member_blocks b
    JOIN public.users u ON u.id = b.user_id
    WHERE b.room_id = p_room_id
      AND NOT EXISTS (
        SELECT 1 FROM public.room_members m
        WHERE m.room_id = b.room_id
          AND m.user_id = b.user_id
      )
    ORDER BY b.blocked_at;
END;
$$;

REVOKE ALL ON FUNCTION public.list_room_blocks(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_room_blocks(UUID) TO authenticated;

-- Returns whether a block was lifted (false: there was none).
CREATE OR REPLACE FUNCTION public.unblock_room_user(
  p_room_id UUID,
  p_user_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_room_owner(p_room_id) THEN
    RAISE EXCEPTION 'room_not_owner';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.rooms r
    WHERE r.id = p_room_id
      AND r.expires_at > now()
  ) THEN
    RAISE EXCEPTION 'room_expired';
  END IF;
  -- A current member is unblocked with the can_share switch, which keeps the
  -- block row and the member row in step (room_members_track_blocks).
  IF EXISTS (
    SELECT 1 FROM public.room_members m
    WHERE m.room_id = p_room_id
      AND m.user_id = p_user_id
  ) THEN
    RAISE EXCEPTION 'room_member_present';
  END IF;

  DELETE FROM public.room_member_blocks b
  WHERE b.room_id = p_room_id
    AND b.user_id = p_user_id;
  RETURN FOUND;
END;
$$;

REVOKE ALL ON FUNCTION public.unblock_room_user(UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.unblock_room_user(UUID, UUID) TO authenticated;

-- ── 3. room_members DELETE ──────────────────────────────────────────────────
-- Same name as the 20260803000001 policy it replaces.
DROP POLICY IF EXISTS room_members_delete_self_or_host ON public.room_members;
CREATE POLICY room_members_delete_self_or_host ON public.room_members
  FOR DELETE
  USING (
    CASE
      -- The owner removes others, never themselves.
      WHEN public.is_room_owner(room_id) THEN
        user_id NOT IN (
          SELECT u.id FROM public.users u WHERE u.auth_uid = auth.uid()
        )
      -- Everyone else leaves only as themselves.
      ELSE
        user_id IN (
          SELECT u.id FROM public.users u WHERE u.auth_uid = auth.uid()
        )
    END
  );

-- ── 4. members' encryption keys, by user id ─────────────────────────────────
-- A retired identity (users.deleted_at set) gets no key, matching
-- lookup_user_by_code, which doesn't return retired users at all.
CREATE OR REPLACE FUNCTION public.room_member_public_keys(p_room_id UUID)
RETURNS TABLE (user_id UUID, public_key TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
#variable_conflict use_column
BEGIN
  IF NOT public.is_room_member(p_room_id) THEN
    RAISE EXCEPTION 'room_not_member';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.rooms r
    WHERE r.id = p_room_id
      AND r.expires_at > now()
  ) THEN
    RAISE EXCEPTION 'room_expired';
  END IF;

  RETURN QUERY
    SELECT m.user_id,
           CASE WHEN u.deleted_at IS NULL THEN u.public_key END
    FROM public.room_members m
    JOIN public.users u ON u.id = m.user_id
    WHERE m.room_id = p_room_id;
END;
$$;

REVOKE ALL ON FUNCTION public.room_member_public_keys(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.room_member_public_keys(UUID) TO authenticated;
