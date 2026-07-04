-- ============================================================================
-- 20260704000002_storage_lockdown
-- ----------------------------------------------------------------------------
-- Scopes the `transfers` storage bucket to the PARTICIPANTS of each transfer
-- (object path = `{transfer_id}/{filename}`). Name-agnostic: drops every
-- existing policy on storage.objects that targets this bucket (any name),
-- including the insecure `transfers_authenticated_*` / "Auth users can *"
-- policies that gated on role only.
--
-- Idempotent: safe to re-run. Only touches policies related to the `transfers`
-- bucket — policies for other buckets are left alone.
-- ============================================================================

INSERT INTO storage.buckets (id, name, public)
VALUES ('transfers', 'transfers', false)
ON CONFLICT (id) DO UPDATE SET public = false;

-- Drop every existing policy on storage.objects that belongs to this bucket,
-- regardless of its current name.
DO $$
DECLARE p RECORD;
BEGIN
  FOR p IN
    SELECT policyname FROM pg_policies
    WHERE schemaname = 'storage' AND tablename = 'objects'
      AND (
        policyname LIKE 'transfers%'
        OR policyname IN (
          'Auth users can upload',
          'Auth users can read',
          'Auth users can update'
        )
      )
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON storage.objects', p.policyname);
  END LOOP;
END $$;

-- READ: sender OR receiver of the transfer may download.
CREATE POLICY transfers_obj_select ON storage.objects
  FOR SELECT
  USING (
    bucket_id = 'transfers'
    AND (storage.foldername(name))[1] IN (
      SELECT t.id::text FROM public.transfers t
      WHERE t.sender_id   IN (SELECT id FROM public.users WHERE auth_uid = auth.uid())
         OR t.receiver_id IN (SELECT id FROM public.users WHERE auth_uid = auth.uid())
    )
  );

-- WRITE: only the SENDER of the transfer may upload into its folder.
CREATE POLICY transfers_obj_insert ON storage.objects
  FOR INSERT
  WITH CHECK (
    bucket_id = 'transfers'
    AND (storage.foldername(name))[1] IN (
      SELECT t.id::text FROM public.transfers t
      WHERE t.sender_id IN (SELECT id FROM public.users WHERE auth_uid = auth.uid())
    )
  );

-- UPDATE (upsert / retry): only the sender may overwrite their own objects.
CREATE POLICY transfers_obj_update ON storage.objects
  FOR UPDATE
  USING (
    bucket_id = 'transfers'
    AND (storage.foldername(name))[1] IN (
      SELECT t.id::text FROM public.transfers t
      WHERE t.sender_id IN (SELECT id FROM public.users WHERE auth_uid = auth.uid())
    )
  )
  WITH CHECK (
    bucket_id = 'transfers'
    AND (storage.foldername(name))[1] IN (
      SELECT t.id::text FROM public.transfers t
      WHERE t.sender_id IN (SELECT id FROM public.users WHERE auth_uid = auth.uid())
    )
  );

-- DELETE: sender may clean up their own objects (expiry / cancel).
CREATE POLICY transfers_obj_delete ON storage.objects
  FOR DELETE
  USING (
    bucket_id = 'transfers'
    AND (storage.foldername(name))[1] IN (
      SELECT t.id::text FROM public.transfers t
      WHERE t.sender_id IN (SELECT id FROM public.users WHERE auth_uid = auth.uid())
    )
  );
