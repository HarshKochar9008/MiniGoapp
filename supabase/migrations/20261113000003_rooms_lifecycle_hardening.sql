-- ============================================================================
-- 20261113000003_rooms_lifecycle_hardening
-- ----------------------------------------------------------------------------
-- Room membership and expiry, made consistent between client and server:
--
--  1. server_now(). Room expiry (`expires_at`) is computed from the database
--     clock, but the app compared it with the device clock — a fast phone hid
--     live rooms and refused joins, a slow one offered expired rooms. The app
--     now measures its offset against this function once (ServerClock) and
--     applies it to every expiry decision and countdown.
--
--  2. A host's block survives leave + rejoin. `can_share = false` lived only
--     on the membership row, which leaving deletes; the rejoin row took the
--     column default and the member could share again. Blocks are now
--     recorded in `room_member_blocks` whenever the host flips the switch
--     and re-applied by the join trigger. The table dies with the room.
--
--  3. room_members.room_id / user_id are frozen on UPDATE. The host's UPDATE
--     policy only checks that the (new) room is theirs, so a host could
--     rewrite a row's user_id (put anyone into their room) or room_id (move
--     a member into another of their rooms) without passing the join checks,
--     which run on INSERT only.
--
--  4. An existing member re-joining a full room got 'room_full': the cap was
--     counted before the duplicate key could fire. The join trigger now
--     reports a duplicate of the caller's own membership as a unique
--     violation (23505), which RoomService.joinRoom treats as success.
--     Concurrent joins to one room are serialised so the cap can't be
--     overshot by two joins counting at the same moment.
--
--  5. can_share changes are refused once the room has expired ('room_expired',
--     the string RoomService.setMemberCanShare maps).
--
-- Everything else in room_members_enforce_limits (20260803000001) is kept
-- as it was: 'room_not_found', 'room_expired' and 'room_full' are raised under
-- the same conditions, in the same order, with the same strings.
--
-- Idempotent: safe to re-run.
-- ============================================================================

-- ── 1. server_now() ─────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.server_now()
RETURNS TIMESTAMPTZ
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT now();
$$;

-- Per-role revoke: see 20260705000002 (Supabase default privileges).
REVOKE ALL ON FUNCTION public.server_now() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.server_now() TO authenticated;

-- ── 2. room_member_blocks ───────────────────────────────────────────────────
-- Server-only bookkeeping: RLS on with no policies, and no table grants for
-- the app roles. Only the SECURITY DEFINER triggers below read or write it.
CREATE TABLE IF NOT EXISTS public.room_member_blocks (
  room_id    UUID        NOT NULL REFERENCES public.rooms(id) ON DELETE CASCADE,
  user_id    UUID        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  blocked_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (room_id, user_id)
);

ALTER TABLE public.room_member_blocks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.room_member_blocks FROM PUBLIC, anon, authenticated;

-- Members already blocked when this runs keep their block across a rejoin.
INSERT INTO public.room_member_blocks (room_id, user_id)
SELECT m.room_id, m.user_id
FROM public.room_members m
WHERE m.can_share IS FALSE
ON CONFLICT (room_id, user_id) DO NOTHING;

-- The host's switch is the only writer of blocks.
CREATE OR REPLACE FUNCTION public.room_members_track_blocks()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.can_share IS FALSE THEN
    INSERT INTO public.room_member_blocks (room_id, user_id)
    VALUES (NEW.room_id, NEW.user_id)
    ON CONFLICT (room_id, user_id) DO NOTHING;
  ELSE
    DELETE FROM public.room_member_blocks b
    WHERE b.room_id = NEW.room_id
      AND b.user_id = NEW.user_id;
  END IF;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS room_members_track_blocks ON public.room_members;
CREATE TRIGGER room_members_track_blocks
  AFTER UPDATE OF can_share ON public.room_members
  FOR EACH ROW
  WHEN (OLD.can_share IS DISTINCT FROM NEW.can_share)
  EXECUTE FUNCTION public.room_members_track_blocks();

REVOKE ALL ON FUNCTION public.room_members_track_blocks()
  FROM PUBLIC, anon, authenticated;

-- ── 3 + 5. room_members UPDATE guard ────────────────────────────────────────
-- A move to NULL is let through on purpose: if a foreign key on either column
-- is ON DELETE SET NULL, that referential action is a real UPDATE that fires
-- this trigger, and refusing it would make deleting the parent row fail (the
-- same reason 20260803000004 leaves transfers.room_id unfrozen).
CREATE OR REPLACE FUNCTION public.room_members_guard_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF (NEW.room_id IS DISTINCT FROM OLD.room_id AND NEW.room_id IS NOT NULL)
     OR (NEW.user_id IS DISTINCT FROM OLD.user_id AND NEW.user_id IS NOT NULL)
  THEN
    RAISE EXCEPTION 'room membership cannot be moved';
  END IF;

  -- Only the switch is gated on expiry, so identity re-derivation
  -- (room_members_derive_identity) and referential actions still work on an
  -- expired room until the sweep deletes it.
  IF NEW.can_share IS DISTINCT FROM OLD.can_share AND NOT EXISTS (
    SELECT 1 FROM public.rooms r
    WHERE r.id = NEW.room_id
      AND r.expires_at > now()
  ) THEN
    RAISE EXCEPTION 'room_expired';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS room_members_guard_update ON public.room_members;
CREATE TRIGGER room_members_guard_update
  BEFORE UPDATE ON public.room_members
  FOR EACH ROW EXECUTE FUNCTION public.room_members_guard_update();

REVOKE ALL ON FUNCTION public.room_members_guard_update()
  FROM PUBLIC, anon, authenticated;

-- ── 4 + 2. join trigger: rejoin, cap, blocks ────────────────────────────────
-- Same trigger name and timing as 20260803000001 (BEFORE INSERT, SECURITY
-- DEFINER so it sees every member past RLS); only the body changes.
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
  -- Row lock serialises joins to one room, so two joins can't both count 9
  -- and land an 11th member. NO KEY UPDATE doesn't block the KEY SHARE lock
  -- that inserting a transfer for this room takes.
  SELECT r.expires_at INTO v_expires
  FROM public.rooms r WHERE r.id = NEW.room_id
  FOR NO KEY UPDATE;

  IF v_expires IS NULL THEN
    RAISE EXCEPTION 'room_not_found';
  END IF;
  IF v_expires <= now() THEN
    RAISE EXCEPTION 'room_expired';
  END IF;

  -- The caller is already in this room: report it the way the primary key
  -- would, before the cap can call a full room a refusal. Scoped to the
  -- caller's own identity so it can't be used to probe who else is a member.
  IF EXISTS (
    SELECT 1
    FROM public.room_members m
    JOIN public.users u ON u.id = m.user_id
    WHERE m.room_id = NEW.room_id
      AND m.user_id = NEW.user_id
      AND u.auth_uid = auth.uid()
  ) THEN
    RAISE EXCEPTION 'already_member' USING ERRCODE = 'unique_violation';
  END IF;

  SELECT count(*) INTO v_count
  FROM public.room_members m WHERE m.room_id = NEW.room_id;

  -- Mirrors AppConstants.maxRoomMembers.
  IF v_count >= 10 THEN
    RAISE EXCEPTION 'room_full';
  END IF;

  -- Sharing permission is the server's call, not the joiner's: a member the
  -- host blocked comes back blocked.
  NEW.can_share := NOT EXISTS (
    SELECT 1 FROM public.room_member_blocks b
    WHERE b.room_id = NEW.room_id
      AND b.user_id = NEW.user_id
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS room_members_enforce_limits ON public.room_members;
CREATE TRIGGER room_members_enforce_limits
  BEFORE INSERT ON public.room_members
  FOR EACH ROW EXECUTE FUNCTION public.room_members_enforce_limits();

REVOKE ALL ON FUNCTION public.room_members_enforce_limits()
  FROM PUBLIC, anon, authenticated;
