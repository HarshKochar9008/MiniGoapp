-- ============================================================================
-- 20260930000001_create_room_atomic
-- ----------------------------------------------------------------------------
-- createRoom() used to insert `rooms` and then, in a second request, the
-- owner's `room_members` row. When that second request failed (network drop,
-- app killed) the room was committed with no members — and since the rooms
-- list is read through room_members, it was invisible to its own owner and
-- sat there holding its code until expiry.
--
-- Both inserts now run in one function call, so one transaction.
--
-- SECURITY INVOKER on purpose: both inserts still pass the policies and
-- triggers from 20260803000001 / 20260803000004 exactly as the two client
-- requests did (rooms_insert_owner checks p_owner_id is the caller; the
-- member row's short_code/nickname are derived server-side). A unique
-- violation on `code` still surfaces as 23505, which the client retries.
--
-- Idempotent: safe to re-run.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.create_room(
  p_code TEXT,
  p_name TEXT,
  p_owner_id UUID,
  p_lifetime_minutes INTEGER
)
RETURNS public.rooms
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_room public.rooms;
BEGIN
  INSERT INTO public.rooms (code, name, owner_id, lifetime_minutes)
  VALUES (p_code, p_name, p_owner_id, p_lifetime_minutes)
  RETURNING * INTO v_room;

  INSERT INTO public.room_members (room_id, user_id)
  VALUES (v_room.id, p_owner_id);

  RETURN v_room;
END;
$$;

-- Per-role revoke: see 20260705000002 (Supabase default privileges).
REVOKE ALL ON FUNCTION public.create_room(TEXT, TEXT, UUID, INTEGER)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_room(TEXT, TEXT, UUID, INTEGER)
  TO authenticated;
