-- ============================================================================
-- 20261115000001_transfer_size_limits
-- ----------------------------------------------------------------------------
-- The send limits (100 MB per file, 20 files per transfer) lived only in the
-- app: AppConstants.maxFileSizeBytes / maxFilesPerTransfer. Nothing on the
-- server looked at size or count, and sign-in is anonymous, so a modified
-- client could store arbitrary amounts for the 24 h TTL. `enc_chunk_size` was
-- likewise sender-chosen and unchecked, and the receiver reads one chunk into
-- memory at a time.
--
--   1. transfer_files.file_size is present and within the limit.
--   2. transfer_files.enc_chunk_size is within what the app will decrypt
--      (E2ECrypto.maxChunkSize).
--   3. At most 20 file rows per transfer.
--   4. The `transfers` Storage bucket refuses objects over the limit.
--
-- NOT covered here: Cloudflare R2. A presigned PUT accepts any body size
-- unless Content-Length is part of the signature, which r2-sign-upload does
-- not do yet. Until it does, the declared file_size is checked (1) but the
-- R2 object itself is not bounded by the server; current app builds refuse to
-- download more than the limit.
--
-- NOT VALID, like the other constraints in this repo: enforced for every
-- write from now on without re-scanning old rows, which age out on the TTL.
--
-- Idempotent: safe to re-run.
-- ============================================================================

-- ── 1. declared size ────────────────────────────────────────────────────────
-- 104857600 = 100 MiB, AppConstants.maxFileSizeBytes.
ALTER TABLE public.transfer_files
  DROP CONSTRAINT IF EXISTS transfer_files_file_size_limit;

ALTER TABLE public.transfer_files
  ADD CONSTRAINT transfer_files_file_size_limit
  CHECK (
    file_size IS NOT NULL
    AND file_size BETWEEN 0 AND 104857600
  )
  NOT VALID;

-- ── 2. chunk size ───────────────────────────────────────────────────────────
-- 4194304 = 4 MiB, E2ECrypto.maxChunkSize. The app writes 1 MiB.
ALTER TABLE public.transfer_files
  DROP CONSTRAINT IF EXISTS transfer_files_enc_chunk_size_limit;

ALTER TABLE public.transfer_files
  ADD CONSTRAINT transfer_files_enc_chunk_size_limit
  CHECK (
    enc_chunk_size IS NULL
    OR enc_chunk_size BETWEEN 1 AND 4194304
  )
  NOT VALID;

-- ── 3. files per transfer ───────────────────────────────────────────────────
-- Not SECURITY DEFINER: current_user must stay the caller's role for the
-- check below, and the only role that can insert here — the transfer's
-- sender — already sees every row of its own transfer
-- (transfer_files_select_participant), so the count is the real one.
-- Only app roles are limited; the service role and migrations are trusted.
-- The sender uploads one file at a time, so no lock is taken.
CREATE OR REPLACE FUNCTION public.transfer_files_enforce_count()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_count INTEGER;
BEGIN
  IF current_user NOT IN ('anon', 'authenticated') THEN
    RETURN NEW;
  END IF;

  SELECT count(*) INTO v_count
  FROM public.transfer_files f
  WHERE f.transfer_id = NEW.transfer_id;

  -- Mirrors AppConstants.maxFilesPerTransfer.
  IF v_count >= 20 THEN
    RAISE EXCEPTION 'transfer_file_limit'
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS transfer_files_enforce_count ON public.transfer_files;
CREATE TRIGGER transfer_files_enforce_count
  BEFORE INSERT ON public.transfer_files
  FOR EACH ROW EXECUTE FUNCTION public.transfer_files_enforce_count();

REVOKE ALL ON FUNCTION public.transfer_files_enforce_count()
  FROM PUBLIC, anon, authenticated;

-- ── 4. Storage bucket ───────────────────────────────────────────────────────
-- 101 MiB: the limit plus the cipher's 16-byte tag per 1 MiB chunk. The
-- project-wide upload limit still applies if it is lower.
UPDATE storage.buckets
SET file_size_limit = 105906176
WHERE id = 'transfers';
