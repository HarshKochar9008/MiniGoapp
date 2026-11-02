-- ============================================================================
-- 20261029000001_transfer_insert_hardening
-- ----------------------------------------------------------------------------
-- Three holes on the INSERT side that the earlier lockdowns left open:
--
--  1. created_at was accepted from the client. 20260803000004 freezes it on
--     UPDATE "to evade the 24h TTL sweep", but a sender could simply create
--     the row with a far-future created_at. expire-transfers selects on
--     `created_at < now() - 24h`, so that row and its files were never
--     expired, and r2-sign-download — which only refuses status 'expired' —
--     kept signing links for it. transfers_derive_codes now stamps it, and
--     rows already planted in the future are pulled back to now().
--
--  2. Nothing on the server read room_members.can_share: the host's switch
--     was enforced only by the blocked member's own app. Any user could also
--     insert a transfer naming any room_id, with any room_name, which the
--     receiver's History then labels as coming from that room. A BEFORE
--     INSERT trigger now requires a live room, a sender who is a member
--     allowed to share, and a receiver who is a member, and derives room_name
--     from the room. Its error strings are the ones room_send_screen.dart
--     matches on ('room_share_denied' was already expected there).
--
--  3. lookup_room_by_code was unmetered, and a room's id is all
--     room_members_insert_self asks for. Metered like lookup_user_by_code
--     (20260803000003).
--
-- Idempotent: safe to re-run.
-- ============================================================================

-- ── 1. created_at is the server's clock ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public.transfers_derive_codes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  NEW.sender_code := (
    SELECT u.short_code FROM public.users u WHERE u.id = NEW.sender_id
  );
  IF NEW.receiver_id IS NULL THEN
    NEW.receiver_code := NULL;
  ELSE
    NEW.receiver_code := (
      SELECT u.short_code FROM public.users u WHERE u.id = NEW.receiver_id
    );
  END IF;
  -- The TTL sweep keys on this. The app never sends it.
  NEW.created_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS transfers_derive_codes ON public.transfers;
CREATE TRIGGER transfers_derive_codes
  BEFORE INSERT ON public.transfers
  FOR EACH ROW EXECUTE FUNCTION public.transfers_derive_codes();

REVOKE ALL ON FUNCTION public.transfers_derive_codes()
  FROM PUBLIC, anon, authenticated;

-- No legitimate row has a future created_at (the column defaulted to now()),
-- so any that exist were planted. Pulling them back to now() hands them to the
-- next sweep after 24h. The freeze trigger forbids exactly this edit; one DO
-- block keeps lifting it, the UPDATE and restoring it a single statement, so
-- a failure can't leave the trigger disabled.
DO $$
BEGIN
  ALTER TABLE public.transfers DISABLE TRIGGER transfers_freeze_participants;
  UPDATE public.transfers SET created_at = now() WHERE created_at > now();
  ALTER TABLE public.transfers ENABLE TRIGGER transfers_freeze_participants;
END $$;

-- ── 2. room transfers: the room, the sender's permission, the receiver ──────
-- SECURITY DEFINER: the sender may not be able to see the room or its members
-- through RLS — that is the case this has to refuse.
CREATE OR REPLACE FUNCTION public.transfers_check_room()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_room_name TEXT;
BEGIN
  IF NEW.room_id IS NULL THEN
    -- A direct transfer is never labelled as coming from a room.
    NEW.room_name := NULL;
    RETURN NEW;
  END IF;

  SELECT r.name INTO v_room_name
  FROM public.rooms r
  WHERE r.id = NEW.room_id
    AND r.expires_at > now();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'room_expired';
  END IF;

  -- `IS NOT FALSE`: the app treats a missing can_share as allowed.
  IF NOT EXISTS (
    SELECT 1 FROM public.room_members m
    WHERE m.room_id = NEW.room_id
      AND m.user_id = NEW.sender_id
      AND m.can_share IS NOT FALSE
  ) THEN
    RAISE EXCEPTION 'room_share_denied';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.room_members m
    WHERE m.room_id = NEW.room_id
      AND m.user_id = NEW.receiver_id
  ) THEN
    RAISE EXCEPTION 'room_recipient_not_member';
  END IF;

  NEW.room_name := v_room_name;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS transfers_check_room ON public.transfers;
CREATE TRIGGER transfers_check_room
  BEFORE INSERT ON public.transfers
  FOR EACH ROW EXECUTE FUNCTION public.transfers_check_room();

REVOKE ALL ON FUNCTION public.transfers_check_room()
  FROM PUBLIC, anon, authenticated;

-- ── 3. lookup_room_by_code: metered ─────────────────────────────────────────
-- Was `language sql STABLE`; metering writes, so it becomes plpgsql. Same
-- columns, and still no expiry filter, so RoomService.joinRoom keeps its
-- distinct "expired" vs "not found" errors.
DROP FUNCTION IF EXISTS public.lookup_room_by_code(TEXT);
CREATE FUNCTION public.lookup_room_by_code(p_code TEXT)
RETURNS TABLE (
  id UUID,
  code TEXT,
  name TEXT,
  owner_id UUID,
  expires_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'lookup_room_by_code: authentication required';
  END IF;

  -- Joining is rare: 30 codes per 10 minutes leaves room for typos, and
  -- turns a scan of the 31^6 code space into years per identity.
  IF NOT public.rate_limit_hit(
        'lookup_room_by_code', auth.uid(), 30, INTERVAL '10 minutes') THEN
    RAISE EXCEPTION
      'lookup_room_by_code: too many lookups, please try again shortly';
  END IF;

  RETURN QUERY
    SELECT r.id, r.code, r.name, r.owner_id, r.expires_at
    FROM public.rooms r
    WHERE r.code = upper(trim(p_code))
    LIMIT 1;
END;
$$;

REVOKE ALL ON FUNCTION public.lookup_room_by_code(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lookup_room_by_code(TEXT) TO authenticated;
