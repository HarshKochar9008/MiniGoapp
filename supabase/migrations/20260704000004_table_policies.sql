-- ============================================================================
-- 20260704000004_table_policies
-- ----------------------------------------------------------------------------
-- Resets `transfers` and `transfer_files` RLS to participant-scoped access.
-- The deployed policies were role-gated (e.g. `*_authenticated_*`), which — in
-- an app where `authenticated` is obtained by credential-free anonymous
-- sign-in — is effectively public. Name-agnostic: drops EVERY existing policy
-- on each table, then recreates only the secure set.
--
-- Idempotent: safe to re-run.
-- ============================================================================

ALTER TABLE public.transfers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.transfer_files ENABLE ROW LEVEL SECURITY;

-- ── transfers ───────────────────────────────────────────────────────────────
DO $$
DECLARE p RECORD;
BEGIN
  FOR p IN
    SELECT policyname FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'transfers'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.transfers', p.policyname);
  END LOOP;
END $$;

-- Participants (sender or receiver) may read a transfer.
CREATE POLICY transfers_select_participant ON public.transfers
  FOR SELECT
  USING (
    sender_id   IN (SELECT id FROM public.users WHERE auth_uid = auth.uid())
    OR receiver_id IN (SELECT id FROM public.users WHERE auth_uid = auth.uid())
  );

-- Only the sender may create a transfer (bound to their own user id).
CREATE POLICY transfers_insert_sender ON public.transfers
  FOR INSERT
  WITH CHECK (
    sender_id IN (SELECT id FROM public.users WHERE auth_uid = auth.uid())
  );

-- Only the sender may update a transfer (status / progress).
CREATE POLICY transfers_update_sender ON public.transfers
  FOR UPDATE
  USING (
    sender_id IN (SELECT id FROM public.users WHERE auth_uid = auth.uid())
  )
  WITH CHECK (
    sender_id IN (SELECT id FROM public.users WHERE auth_uid = auth.uid())
  );

-- ── transfer_files ────────────────────────────────────────────────────────
DO $$
DECLARE p RECORD;
BEGIN
  FOR p IN
    SELECT policyname FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'transfer_files'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.transfer_files', p.policyname);
  END LOOP;
END $$;

-- Files are visible only to participants of the parent transfer.
CREATE POLICY transfer_files_select_participant ON public.transfer_files
  FOR SELECT
  USING (
    transfer_id IN (
      SELECT t.id FROM public.transfers t
      WHERE t.sender_id   IN (SELECT id FROM public.users WHERE auth_uid = auth.uid())
         OR t.receiver_id IN (SELECT id FROM public.users WHERE auth_uid = auth.uid())
    )
  );

-- Only the sender of the parent transfer may add file rows.
CREATE POLICY transfer_files_insert_sender ON public.transfer_files
  FOR INSERT
  WITH CHECK (
    transfer_id IN (
      SELECT t.id FROM public.transfers t
      WHERE t.sender_id IN (SELECT id FROM public.users WHERE auth_uid = auth.uid())
    )
  );

-- No UPDATE/DELETE policies: denied by default.
