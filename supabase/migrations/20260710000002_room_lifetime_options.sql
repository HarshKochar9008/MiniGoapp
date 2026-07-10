-- ============================================================================
-- 20260710000002_room_lifetime_options
-- ----------------------------------------------------------------------------
-- Rooms get a user-chosen lifetime: 30 min, 1 hour, or 2 hours.
--
-- The client sends `lifetime_minutes` (30 | 60 | 120) on insert; a BEFORE
-- INSERT trigger computes `expires_at` server-side from the DB clock, so a
-- client can neither pick an arbitrary expiry nor exploit clock skew. A
-- BEFORE UPDATE trigger freezes both columns so a room's life can't be
-- extended after creation. The expire-transfers edge function deletes rooms
-- past `expires_at` (cascade removes members, storage files are cleaned).
--
-- Idempotent: safe to re-run.
-- ============================================================================

ALTER TABLE public.rooms
  ADD COLUMN IF NOT EXISTS lifetime_minutes smallint NOT NULL DEFAULT 60;

ALTER TABLE public.rooms
  DROP CONSTRAINT IF EXISTS rooms_lifetime_minutes_allowed;
ALTER TABLE public.rooms
  ADD CONSTRAINT rooms_lifetime_minutes_allowed
  CHECK (lifetime_minutes IN (30, 60, 120));

-- ── expires_at is derived server-side, never taken from the client ──────────
CREATE OR REPLACE FUNCTION public.rooms_set_expiry()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  NEW.expires_at := now() + make_interval(mins => NEW.lifetime_minutes);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS rooms_set_expiry ON public.rooms;
CREATE TRIGGER rooms_set_expiry
  BEFORE INSERT ON public.rooms
  FOR EACH ROW EXECUTE FUNCTION public.rooms_set_expiry();

-- ── a room's lifetime is immutable after creation ───────────────────────────
CREATE OR REPLACE FUNCTION public.rooms_freeze_expiry()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.expires_at IS DISTINCT FROM OLD.expires_at
     OR NEW.lifetime_minutes IS DISTINCT FROM OLD.lifetime_minutes THEN
    RAISE EXCEPTION 'room expiry cannot be changed';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS rooms_freeze_expiry ON public.rooms;
CREATE TRIGGER rooms_freeze_expiry
  BEFORE UPDATE ON public.rooms
  FOR EACH ROW EXECUTE FUNCTION public.rooms_freeze_expiry();

-- New public functions are auto-EXECUTE for anon/authenticated via default
-- privileges; trigger functions can't be called over RPC, but revoke anyway
-- to keep the surface explicit.
REVOKE ALL ON FUNCTION public.rooms_set_expiry() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rooms_freeze_expiry() FROM PUBLIC, anon, authenticated;
