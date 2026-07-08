# Cloudflare R2 hybrid storage setup

MiniGo can store file bytes on Cloudflare R2 instead of Supabase Storage,
keeping Supabase for auth, metadata, realtime and push. Why: R2's free tier
gives 10 GB storage and **zero egress fees**, removing the two hardest
Supabase free-tier limits (1 GB storage, 5 GB egress/month) for a
file-sharing app.

## How it works

- Object keys are identical to `transfer_files.storage_path`
  (`<transferId>/<fileName>`), so **no schema change** is needed.
- The Flutter app never holds R2 credentials. Two Supabase edge functions
  mint short-lived presigned URLs after enforcing the same rules as the
  `storage.objects` RLS policies:
  - `r2-sign-upload` — caller must be the **sender** of a non-completed,
    non-expired transfer.
  - `r2-sign-download` — caller must be the **receiver or sender** of a
    non-expired transfer.
- The client is flag-gated (`USE_R2_STORAGE`) and falls back to Supabase
  Storage per file when signing fails (function not deployed, secrets
  missing) or when a download 404s on R2 (object uploaded before the
  cutover). It is safe to ship with the flag on before R2 is configured.
- Files are E2E-encrypted client-side before upload, so R2 only ever stores
  ciphertext.

## Setup steps

### 1. Create the bucket

Cloudflare Dashboard → R2 → Create bucket, name `transfers`
(or set `R2_BUCKET` to your name in step 3).

### 2. Add a lifecycle rule (replaces most storage cleanup)

Bucket → Settings → Object lifecycle rules → Add rule:
**delete objects 1 day after upload**. This enforces the 24 h transfer TTL
at the storage layer even if the cron job ever stops running.

Also under Settings → CORS policy, no rule is required for the Flutter app
(it is not a browser), but if you later add a web client you will need one.

### 3. Create an API token

R2 → Manage R2 API Tokens → Create API token:

- Permissions: **Object Read & Write**, scoped to the `transfers` bucket only.
- Note the **Access Key ID**, **Secret Access Key**, and your
  **Account ID** (shown on the R2 overview page).

### 4. Set edge function secrets

```sh
npx supabase secrets set \
  R2_ACCOUNT_ID=<account id> \
  R2_ACCESS_KEY_ID=<access key id> \
  R2_SECRET_ACCESS_KEY=<secret access key> \
  R2_BUCKET=transfers
```

### 5. Deploy the functions

```sh
npx supabase functions deploy r2-sign-upload
npx supabase functions deploy r2-sign-download
# picks up the new R2 cleanup block:
npx supabase functions deploy expire-transfers --no-verify-jwt
```

Do NOT pass `--no-verify-jwt` to the two signing functions —
`config.toml` sets `verify_jwt = true` for them deliberately.

### 6. Enable the flag in the app

In `.env` (or via `--dart-define=USE_R2_STORAGE=true`):

```
USE_R2_STORAGE=true
```

## Rollout / rollback

- **Mixed period**: for up to 24 h after enabling, receivers may download
  files that were uploaded to Supabase Storage. The client handles this:
  an R2 404 automatically retries against Supabase. No data migration is
  needed — old objects expire on their own.
- **Rollback**: set `USE_R2_STORAGE=false` and ship; the Supabase path is
  untouched. In-flight R2 objects stay downloadable only if the flag is on,
  so flip it only between releases, not mid-day, if transfers are active.

## Cleanup semantics

- The bucket lifecycle rule (step 2) deletes every object at ~24 h.
- `expire-transfers` additionally deletes R2 objects for expired transfers
  when the R2 secrets are set. This matters mainly for **room** transfers,
  whose files must disappear at room expiry (1 hour) — well before the
  lifecycle rule fires. S3 DeleteObject calls are free on R2 (they count
  against neither Class A nor Class B operation quotas).

## Free-tier budget after the move

| Quota | Supabase Storage | R2 |
|---|---|---|
| Storage | 1 GB | 10 GB |
| Egress | 5 GB/month (shared with API) | unlimited, $0 |
| Writes | shared | 1M Class A ops/month |
| Reads | shared | 10M Class B ops/month |

Each file upload ≈ 1 Class A op, each download ≈ 1 Class B op, so quota
exhaustion would require ~1M uploaded files/month — not a realistic limit
for this app.
