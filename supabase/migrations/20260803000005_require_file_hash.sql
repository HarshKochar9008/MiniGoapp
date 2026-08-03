-- ============================================================================
-- 20260803000005_require_file_hash
-- ----------------------------------------------------------------------------
-- `sha256_hash` is the receiver's only integrity signal for an *unencrypted*
-- transfer, and the second one for an encrypted transfer. It was optional in
-- practice from both ends:
--
--   * the client dropped it from the insert on a schema error
--     (TransferService._insertTransferFile) — now fixed there, and
--   * nothing stopped a row being written without it, or with a garbage value.
--
-- With the column guaranteed present and well-formed, TransferService
-- .verifySha256 returning IntegrityCheck.noHashRecorded becomes a legacy-row
-- condition rather than something a current sender can produce.
--
-- NOT VALID, like the file_name constraints in 20260803000002: enforced for
-- every write from now on, without re-scanning rows written before the fix.
-- Those age out on the 24h TTL. Run VALIDATE CONSTRAINT afterwards if you want
-- the guarantee retroactively.
--
-- Idempotent: safe to re-run.
-- ============================================================================

ALTER TABLE public.transfer_files
  DROP CONSTRAINT IF EXISTS transfer_files_sha256_present;

ALTER TABLE public.transfer_files
  ADD CONSTRAINT transfer_files_sha256_present
  CHECK (
    sha256_hash IS NOT NULL
    -- Dart's Digest.toString() is lowercase hex, 64 chars for SHA-256.
    AND sha256_hash ~ '^[0-9a-f]{64}$'
  )
  NOT VALID;

-- Encrypted rows must carry a format tag, so the receiver never has to guess
-- which chunk format the bytes are in. v1 authenticates each chunk with no
-- associated data and cannot detect truncation at a chunk boundary; v2 binds
-- the chunk index and a final-chunk flag into the AAD. Both are accepted here
-- because a sender on an older build still writes v1.
ALTER TABLE public.transfer_files
  DROP CONSTRAINT IF EXISTS transfer_files_enc_algo_known;

ALTER TABLE public.transfer_files
  ADD CONSTRAINT transfer_files_enc_algo_known
  CHECK (
    is_encrypted IS NOT TRUE
    OR enc_algo IN ('x25519-aesgcm-v1', 'x25519-aesgcm-v2')
  )
  NOT VALID;
