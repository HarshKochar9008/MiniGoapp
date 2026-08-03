-- ============================================================================
-- 20260803000004_freeze_participants
-- ----------------------------------------------------------------------------
-- `transfers_update_sender` (20260704000004) re-asserts only `sender_id` in its
-- WITH CHECK, so the sender could rewrite every other column of a transfer they
-- own — including, after the files were already uploaded:
--
--   * receiver_id   — re-target a completed transfer at a different person
--   * sender_code   — impersonate another user in the receiver's UI
--   * created_at    — push the row forward and evade the 24h TTL sweep
--
-- `sender_code` / `receiver_code` matter more than they look: since the users
-- lockdown made the `users` join return null for a counterparty, these
-- denormalized columns are what History (history_screen.dart:159) and the
-- Received tab (received_tab_screen.dart:282) actually display. A
-- client-supplied value was being shown as the other party's identity.
--
-- `room_members.short_code` / `.nickname` are the same pattern: the client
-- sends them on join (room_service.dart:147,194) and listMembers() prefers them
-- over the users join, so a member could join a room under someone else's code.
--
-- Fix, in both cases: derive the identity columns server-side from `users` on
-- write, and freeze the participant columns afterwards. SECURITY DEFINER is
-- required because owner-only RLS on `users` means the writer cannot read the
-- counterparty's row themselves.
--
-- Idempotent: safe to re-run.
-- ============================================================================

-- ── transfers: codes are derived, never accepted from the client ────────────
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
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS transfers_derive_codes ON public.transfers;
CREATE TRIGGER transfers_derive_codes
  BEFORE INSERT ON public.transfers
  FOR EACH ROW EXECUTE FUNCTION public.transfers_derive_codes();

REVOKE ALL ON FUNCTION public.transfers_derive_codes()
  FROM PUBLIC, anon, authenticated;

-- ── transfers: participants and creation time are immutable ─────────────────
-- Deliberately NOT frozen:
--   status, upload_progress  — the sender legitimately updates both.
--   room_id                  — rooms.id is referenced ON DELETE SET NULL, and
--                              that referential action performs a real UPDATE
--                              that fires this trigger. Freezing it would make
--                              deleting an expired room fail.
CREATE OR REPLACE FUNCTION public.transfers_freeze_participants()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.id            IS DISTINCT FROM OLD.id
     OR NEW.sender_id     IS DISTINCT FROM OLD.sender_id
     OR NEW.receiver_id   IS DISTINCT FROM OLD.receiver_id
     OR NEW.sender_code   IS DISTINCT FROM OLD.sender_code
     OR NEW.receiver_code IS DISTINCT FROM OLD.receiver_code
     OR NEW.room_name     IS DISTINCT FROM OLD.room_name
     OR NEW.created_at    IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION
      'transfer participants and creation time cannot be changed';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS transfers_freeze_participants ON public.transfers;
CREATE TRIGGER transfers_freeze_participants
  BEFORE UPDATE ON public.transfers
  FOR EACH ROW EXECUTE FUNCTION public.transfers_freeze_participants();

REVOKE ALL ON FUNCTION public.transfers_freeze_participants()
  FROM PUBLIC, anon, authenticated;

-- ── room_members: displayed identity is derived, not client-supplied ────────
-- Covers UPDATE too: only the host may update a member row
-- (room_members_update_host), and nothing stops them rewriting another
-- member's displayed code while flipping can_share.
CREATE OR REPLACE FUNCTION public.room_members_derive_identity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  SELECT u.short_code, u.nickname
    INTO NEW.short_code, NEW.nickname
  FROM public.users u
  WHERE u.id = NEW.user_id;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS room_members_derive_identity ON public.room_members;
CREATE TRIGGER room_members_derive_identity
  BEFORE INSERT OR UPDATE ON public.room_members
  FOR EACH ROW EXECUTE FUNCTION public.room_members_derive_identity();

REVOKE ALL ON FUNCTION public.room_members_derive_identity()
  FROM PUBLIC, anon, authenticated;
