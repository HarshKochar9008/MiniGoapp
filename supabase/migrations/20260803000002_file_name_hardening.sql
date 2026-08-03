-- ============================================================================
-- 20260803000002_file_name_hardening
-- ----------------------------------------------------------------------------
-- `transfer_files.file_name` is written by the sender and read back by the
-- receiver, which passes it straight to saveFileToDevice() -> File.copy() at
-- '<dir>/<file_name>'. The sending *client* sanitizes, but nothing on the
-- server did: transfer_files_insert_sender only checks who owns the parent
-- transfer, never what the column contains. A sender posting directly to
-- PostgREST with file_name = '../../../../data/data/com.Zen.app/...' made the
-- receiving device write outside its Downloads directory.
--
-- The receiver-side fix (lib/core/utils/safe_file_name.dart, applied at the
-- File.copy sink) is the one that protects already-installed clients. This
-- constraint stops the value from being stored in the first place, so the
-- traversal payload never reaches a device.
--
-- NOT VALID on purpose: it is enforced for every INSERT/UPDATE from now on but
-- does not re-scan pre-existing rows, so the migration cannot fail on a row
-- written before the fix. Transfers carry a 24h TTL, so any such rows age out
-- on their own; run VALIDATE CONSTRAINT afterwards if you want the guarantee
-- retroactively.
--
-- Idempotent: safe to re-run.
-- ============================================================================

ALTER TABLE public.transfer_files
  DROP CONSTRAINT IF EXISTS transfer_files_file_name_safe;

ALTER TABLE public.transfer_files
  ADD CONSTRAINT transfer_files_file_name_safe
  CHECK (
    file_name IS NOT NULL
    AND length(file_name) BETWEEN 1 AND 255
    -- no directory component, in either separator style
    AND file_name !~ '[/\\]'
    -- no parent-directory traversal
    AND file_name !~ '\.\.'
    -- no control characters (NUL-splitting, terminal escapes in the UI)
    AND file_name !~ '[[:cntrl:]]'
    -- not a bare directory entry ('.', '..', '   ')
    AND btrim(file_name, '. ') <> ''
  )
  NOT VALID;

-- storage_path is '<transfer_id>/<file_name>'. The R2 signer re-validates it
-- (r2-sign-download splits on the first '/' and re-checks both halves), but a
-- Supabase-Storage-path download builds a signed URL straight from this value.
ALTER TABLE public.transfer_files
  DROP CONSTRAINT IF EXISTS transfer_files_storage_path_safe;

ALTER TABLE public.transfer_files
  ADD CONSTRAINT transfer_files_storage_path_safe
  CHECK (
    storage_path IS NULL
    OR (
      length(storage_path) BETWEEN 1 AND 512
      AND storage_path !~ '\.\.'
      AND storage_path !~ '[[:cntrl:]]'
      AND storage_path !~ '^/'
    )
  )
  NOT VALID;
