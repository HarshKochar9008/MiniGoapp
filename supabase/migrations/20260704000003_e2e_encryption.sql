-- ============================================================================
-- 20260704000003_e2e_encryption
-- ----------------------------------------------------------------------------
-- Adds per-file end-to-end encryption metadata. File BYTES are encrypted on the
-- sender's device with a random per-file content key (AES-256-GCM). That
-- content key is then sealed to the recipient's X25519 public key and stored
-- here as `enc_wrapped_key`. The server/database only ever sees ciphertext and
-- a key it cannot open — it CANNOT read file contents.
--
-- `sha256_hash` remains the hash of the PLAINTEXT (verified after decryption),
-- so integrity is preserved end-to-end.
--
-- Idempotent: safe to re-run.
-- ============================================================================

-- true once the object bytes in storage are ciphertext.
ALTER TABLE public.transfer_files
  ADD COLUMN IF NOT EXISTS is_encrypted BOOLEAN NOT NULL DEFAULT false;

-- Algorithm tag, e.g. 'x25519-aesgcm-v1'. NULL when not encrypted.
ALTER TABLE public.transfer_files
  ADD COLUMN IF NOT EXISTS enc_algo TEXT;

-- Content key sealed to the recipient's public key (base64url):
-- ephemeral_pub(32) || wrap_nonce(12) || wrapped_content_key_ciphertext || gcm_tag(16)
ALTER TABLE public.transfer_files
  ADD COLUMN IF NOT EXISTS enc_wrapped_key TEXT;

-- Base nonce (base64url, 8 bytes) for the chunked file stream; per-chunk nonce
-- is base_nonce || uint32(chunk_index).
ALTER TABLE public.transfer_files
  ADD COLUMN IF NOT EXISTS enc_nonce TEXT;

-- Plaintext chunk size in bytes used by the streaming cipher.
ALTER TABLE public.transfer_files
  ADD COLUMN IF NOT EXISTS enc_chunk_size INTEGER;
