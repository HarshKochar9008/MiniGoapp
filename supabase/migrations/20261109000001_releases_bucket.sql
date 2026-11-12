-- ============================================================================
-- 20261109000001_releases_bucket
-- ----------------------------------------------------------------------------
-- Public bucket for the Android APK. Someone without MiniGo who scans a
-- MiniGo QR code with their camera downloads it from here (see
-- supabase/functions/qr). Anyone with the link can download it.
--
-- Reads need no policy (public bucket). There is no write policy, so only
-- the service role uploads: `tool/distribute_android.sh --public`.
-- ============================================================================

INSERT INTO storage.buckets (id, name, public, allowed_mime_types)
VALUES (
  'releases',
  'releases',
  true,
  ARRAY['application/vnd.android.package-archive']
)
ON CONFLICT (id) DO UPDATE
SET public = true,
    allowed_mime_types = EXCLUDED.allowed_mime_types;
