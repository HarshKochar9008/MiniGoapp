-- Enable Postgres CDC (realtime) for the tables the app live-updates from:
--   rooms / room_members   → rooms list + room detail
--   transfers / transfer_files → receive, history, and transfer-detail screens
-- Events are still scoped by RLS: clients only receive changes for rows
-- they are allowed to SELECT.
--
-- Idempotent: skips tables already in the publication.

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['rooms', 'room_members', 'transfers', 'transfer_files']
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime'
        AND schemaname = 'public'
        AND tablename = t
    ) THEN
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
    END IF;
  END LOOP;
END $$;
