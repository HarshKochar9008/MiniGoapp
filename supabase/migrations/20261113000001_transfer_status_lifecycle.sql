-- ============================================================================
-- 20261113000001_transfer_status_lifecycle
-- ----------------------------------------------------------------------------
-- `transfers.status` had no server-side model at all: no CHECK on its values,
-- no rule about which changes are allowed, and `transfers_update_sender`
-- (20260704000004) plus the freeze trigger (20260803000004) deliberately left
-- it writable by the sender. Two holes followed from that:
--
--   * An expired transfer could be revived. When a room expired mid-send, the
--     sweep deleted the files and stamped `expired`; the sender's app, refused
--     by r2-sign-upload, fell back to Supabase Storage (whose policies never
--     looked at status), finished the upload, and wrote `completed` over
--     `expired`. The receiver saw "Ready to download" for deleted files.
--   * A completed transfer could be flipped to `failed` by a resumed or
--     discarded saved send, in front of a receiver who already had the files.
--
-- The app now models the lifecycle explicitly (lib/features/transfer/
-- transfer_status.dart) and only ever writes status with a conditional
-- update. This migration makes the server agree, so an old or modified
-- client can't do otherwise:
--
--   1. CHECK: status is one of the known values.
--   2. Trigger: expired is terminal; completed may only become expired; only
--      the server (service role / database owner — the expire sweep) may set
--      expired; a client-inserted row always starts pending.
--   3. transfer_files INSERT and the transfers-bucket upload policies also
--      require the parent transfer to still accept uploads (not completed,
--      not expired). Every condition of the policies they replace is kept.
--
-- The base table predates this repo's migrations, and `status` may be a
-- VARCHAR (README) or a legacy Postgres enum. Every comparison goes through
-- `status::text`, which is safe on both.
--
-- Interplay with 20261113000002 (expire-transfers schedule): the sweep runs as
-- the service role and may set expired from ANY status, then stamps
-- files_purged_at on rows that are already expired. Nothing here blocks
-- either: the trigger fires only when `status` is in the SET list, and an
-- expired → expired write is a no-op.
--
-- Idempotent: safe to re-run.
-- ============================================================================

-- ── 1. Known values only ────────────────────────────────────────────────────
-- 'uploading' is legacy (never written by current clients) but still valid.
-- NOT VALID: enforced for every write from now on, without re-scanning old
-- rows, like the other constraints in this repo. They age out on the TTL.
ALTER TABLE public.transfers
  DROP CONSTRAINT IF EXISTS transfers_status_known;

ALTER TABLE public.transfers
  ADD CONSTRAINT transfers_status_known
  CHECK (
    status::text IN (
      'pending', 'uploading', 'completed', 'partial', 'failed', 'expired'
    )
  )
  NOT VALID;

-- ── 2. Allowed transitions ──────────────────────────────────────────────────
-- "Client" = a request running as anon/authenticated (PostgREST user JWT).
-- The service role (edge functions) and the database owner (pg_cron jobs,
-- migrations) are the server. A trigger function that is not SECURITY
-- DEFINER sees the session role in current_user.
CREATE OR REPLACE FUNCTION public.transfers_status_transition()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_client BOOLEAN := current_user IN ('anon', 'authenticated');
  v_old    TEXT;
  v_new    TEXT := NEW.status::text;
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- A transfer's outcome is earned by uploading, never declared up front.
    IF v_client AND v_new IS DISTINCT FROM 'pending' THEN
      NEW.status := 'pending';
    END IF;
    RETURN NEW;
  END IF;

  v_old := OLD.status::text;
  IF v_new IS NOT DISTINCT FROM v_old THEN
    RETURN NEW;
  END IF;

  IF v_old = 'expired' THEN
    RAISE EXCEPTION 'transfer_status_expired_is_final'
      USING ERRCODE = 'check_violation',
            DETAIL = format('transfer %s: expired -> %s', OLD.id, v_new);
  END IF;

  IF v_new = 'expired' THEN
    IF v_client THEN
      RAISE EXCEPTION 'transfer_status_expired_is_server_only'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN NEW; -- the sweep may expire a transfer from any status
  END IF;

  IF v_old = 'completed' THEN
    RAISE EXCEPTION 'transfer_status_completed_is_final'
      USING ERRCODE = 'check_violation',
            DETAIL = format('transfer %s: completed -> %s', OLD.id, v_new);
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS transfers_status_transition ON public.transfers;
CREATE TRIGGER transfers_status_transition
  BEFORE INSERT OR UPDATE OF status ON public.transfers
  FOR EACH ROW EXECUTE FUNCTION public.transfers_status_transition();

REVOKE ALL ON FUNCTION public.transfers_status_transition()
  FROM PUBLIC, anon, authenticated;

-- ── 3a. transfer_files: rows only for a transfer that still accepts them ────
-- Replaces transfer_files_insert_sender (20260704000004), keeping its sender
-- condition. Every INSERT policy on the table is dropped first, name-
-- agnostically: policies are permissive (OR'ed), so any leftover one would
-- let a row in without the status condition.
DO $$
DECLARE p RECORD;
BEGIN
  FOR p IN
    SELECT policyname FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'transfer_files'
      AND cmd = 'INSERT'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.transfer_files',
                   p.policyname);
  END LOOP;
END $$;

CREATE POLICY transfer_files_insert_sender ON public.transfer_files
  FOR INSERT
  WITH CHECK (
    transfer_id IN (
      SELECT t.id FROM public.transfers t
      WHERE t.sender_id IN (SELECT id FROM public.users WHERE auth_uid = auth.uid())
        -- NULL reads as the column default, pending.
        AND COALESCE(t.status::text, 'pending') NOT IN ('completed', 'expired')
    )
  );

-- ── 3b. transfers bucket: uploads only into a transfer that accepts them ────
-- Replaces transfers_obj_insert / transfers_obj_update (20260704000002),
-- keeping the bucket, folder and sender conditions. SELECT and DELETE are
-- unchanged: participants may still read, and the sender may still clean up.
-- Only these two names are dropped — storage.objects carries other buckets'
-- policies (releases), which must survive.
DROP POLICY IF EXISTS transfers_obj_insert ON storage.objects;
CREATE POLICY transfers_obj_insert ON storage.objects
  FOR INSERT
  WITH CHECK (
    bucket_id = 'transfers'
    AND (storage.foldername(name))[1] IN (
      SELECT t.id::text FROM public.transfers t
      WHERE t.sender_id IN (SELECT id FROM public.users WHERE auth_uid = auth.uid())
        AND COALESCE(t.status::text, 'pending') NOT IN ('completed', 'expired')
    )
  );

-- UPDATE is the upsert/retry path (x-upsert): same rule on both sides.
DROP POLICY IF EXISTS transfers_obj_update ON storage.objects;
CREATE POLICY transfers_obj_update ON storage.objects
  FOR UPDATE
  USING (
    bucket_id = 'transfers'
    AND (storage.foldername(name))[1] IN (
      SELECT t.id::text FROM public.transfers t
      WHERE t.sender_id IN (SELECT id FROM public.users WHERE auth_uid = auth.uid())
        AND COALESCE(t.status::text, 'pending') NOT IN ('completed', 'expired')
    )
  )
  WITH CHECK (
    bucket_id = 'transfers'
    AND (storage.foldername(name))[1] IN (
      SELECT t.id::text FROM public.transfers t
      WHERE t.sender_id IN (SELECT id FROM public.users WHERE auth_uid = auth.uid())
        AND COALESCE(t.status::text, 'pending') NOT IN ('completed', 'expired')
    )
  );
