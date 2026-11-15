-- Expiry sweep: purge tracking + schedule.
--
-- 1. transfers.files_purged_at — expire-transfers stamps it once every storage
--    object of an expired transfer has been deleted (Supabase Storage and R2).
--    Until then the sweep retries the delete, the transfer's room is not
--    deleted, and the row is not hard-deleted. Previously a transfer was
--    marked expired even when deleting its files failed, and the next run
--    skipped every expired row, so those bytes were never cleaned up.
--    Only the sweep (service role) may set it; a sender forging it would keep
--    their files out of the cleanup.
--
-- 2. The 15-minute pg_cron job that calls the function. It used to exist only
--    as a comment in the function header, so a fresh project never expired
--    anything until someone scheduled it by hand.

-- ── 1. purge tracking ───────────────────────────────────────────────────────
ALTER TABLE public.transfers
  ADD COLUMN IF NOT EXISTS files_purged_at TIMESTAMPTZ;

CREATE OR REPLACE FUNCTION public.transfers_guard_files_purged_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  -- PostgREST runs a request as its role (SET ROLE), so current_user is the
  -- caller's: 'service_role' for the sweep, 'authenticated' for the app.
  IF current_user IN ('service_role', 'postgres', 'supabase_admin') THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'INSERT' THEN
    NEW.files_purged_at := NULL;
  ELSIF NEW.files_purged_at IS DISTINCT FROM OLD.files_purged_at THEN
    RAISE EXCEPTION 'files_purged_at is maintained by the expiry sweep';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS transfers_guard_files_purged_at ON public.transfers;
CREATE TRIGGER transfers_guard_files_purged_at
  BEFORE INSERT OR UPDATE OF files_purged_at ON public.transfers
  FOR EACH ROW EXECUTE FUNCTION public.transfers_guard_files_purged_at();

REVOKE ALL ON FUNCTION public.transfers_guard_files_purged_at()
  FROM PUBLIC, anon, authenticated;

-- ── 2. schedule (pg_cron + pg_net + Vault, when available) ──────────────────
-- The job reads the project URL and the service-role key from Vault at run
-- time, so no secret is written into this file or into cron.job. Create them
-- once (SQL editor), then re-run this DO block:
--
--   select vault.create_secret('https://<ref>.supabase.co', 'minigo_project_url');
--   select vault.create_secret('<service-role key>', 'minigo_service_role_key');
--
-- Without both secrets nothing is scheduled. That way a job someone already
-- registered by hand under the same name is left alone instead of being
-- replaced by one that cannot authenticate.
DO $$
DECLARE
  v_secrets INTEGER;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron')
     OR NOT EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_net')
  THEN
    RAISE NOTICE 'pg_cron/pg_net unavailable — call expire-transfers every '
      '15 minutes from an external scheduler.';
    RETURN;
  END IF;

  CREATE EXTENSION IF NOT EXISTS pg_cron;
  CREATE EXTENSION IF NOT EXISTS pg_net;

  SELECT count(DISTINCT name) INTO v_secrets
  FROM vault.decrypted_secrets
  WHERE name IN ('minigo_project_url', 'minigo_service_role_key');

  IF v_secrets < 2 THEN
    RAISE NOTICE 'expire-transfers not scheduled: create the Vault secrets '
      'minigo_project_url and minigo_service_role_key, then re-run this block.';
    RETURN;
  END IF;

  -- cron.schedule() upserts by job name, so re-running stays idempotent.
  PERFORM cron.schedule(
    'expire-transfers-15min',
    '0,15,30,45 * * * *',
    $job$
      SELECT net.http_post(
        url := (SELECT decrypted_secret FROM vault.decrypted_secrets
                WHERE name = 'minigo_project_url')
               || '/functions/v1/expire-transfers',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer ' || (
            SELECT decrypted_secret FROM vault.decrypted_secrets
            WHERE name = 'minigo_service_role_key')
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 120000
      );
    $job$
  );
EXCEPTION WHEN OTHERS THEN
  -- Never fail the migration over scheduling; the column and guard above are
  -- what the function needs. Surface the reason for whoever reads the logs.
  RAISE NOTICE 'expire-transfers scheduling skipped: %', SQLERRM;
END $$;
