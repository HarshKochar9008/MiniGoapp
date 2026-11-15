# MiniGo — API and Backend Security Report

Audit date 2026-11-15 · app 1.0.0+1 · internal engineering evidence, not a penetration test.

## Scope and method

Static review of all 23 migrations in `supabase/migrations/`, `supabase/apply_security_lockdown.sql` (header and guard), `supabase/config.toml`, and the five edge functions.

**No request was sent to any backend.** The only Supabase project linked to this checkout is the live one; there is no staging environment and no test accounts, and production must not be probed. Every "dynamic" row below is therefore NOT TESTED, and the test cases in §5 are written to be run against a staging project once one exists.

The base tables (`users`, `transfers`, `transfer_files`, `rooms`, `room_members`) are not created by any migration. Their definitions are known only from `README.md:282-310`, so column types, foreign keys and default constraints on the deployed database are unverified.

## 1. Endpoint inventory

### PostgREST tables (role `authenticated` via anonymous sign-in)

| Table | SELECT | INSERT | UPDATE | DELETE |
|---|---|---|---|---|
| `users` | own row | own `auth_uid` | own row; id/auth_uid/short_code frozen; retirement final | none |
| `transfers` | sender or receiver | as sender; codes, room name, `created_at`, status stamped by triggers; room membership checked | sender; participants frozen; status transitions enforced | none |
| `transfer_files` | participants | sender, while transfer accepts uploads; ≤20 rows; name/path/hash/size constraints | none | none |
| `rooms` | member or owner | as owner; expiry computed server-side | owner; expiry frozen | owner |
| `room_members` | members | self, into a live room; cap 10; block list re-applied | host; row cannot be moved; identity re-derived | self (non-owner) or host (others) |
| `rate_limit_counters`, `room_member_blocks` | none | none | none | none |

### RPCs

| Function | Caller | Notes |
|---|---|---|
| `lookup_user_by_code` | authenticated | 200 / 10 min per identity; returns id, code, public key, nickname |
| `lookup_room_by_code` | authenticated | 30 / 10 min per identity; returns expired rooms too |
| `create_room` | authenticated | security invoker; **not metered** |
| `retire_previous_identity` | authenticated | proof is knowledge of the old auth uid; anonymous identities only |
| `room_presence`, `list_room_blocks`, `unblock_room_user`, `room_member_public_keys`, `server_now` | authenticated | relationship-scoped |
| `is_room_member`, `is_room_owner`, `room_is_joinable` | anon, authenticated | answer only about the caller; `room_is_joinable` confirms existence of a room id (a random UUID) |
| `cleanup_stale_anonymous_identities`, `prune_rate_limit_counters`, `rate_limit_hit` | none / service role | refuse or are revoked for app roles |

### Edge functions

| Function | Auth | Authorisation | Notes |
|---|---|---|---|
| `r2-sign-upload` | JWT | caller is sender; transfer not completed/expired/past TTL | presigned PUT, 1 h; size not bound; **not metered** |
| `r2-sign-download` | JWT | caller is sender or receiver; not expired | presigned GET, 1 h |
| `send-transfer-fcm` | JWT | caller is sender (real send); dry-run metered 60 / 10 min | real send **not metered**, repeatable per transfer |
| `expire-transfers` | service-role key, constant-time compare | — | two-phase expiry and purge, batch 100 |
| `qr` | public | — | validates a 6-char code, 302 to app / APK / store link |

### Storage

| Bucket | Access |
|---|---|
| `transfers` (private) | read: participants (no expiry condition); write/update: sender while transfer accepts uploads; delete: sender; 101 MiB object limit |
| `releases` (**public**) | anyone reads; service role writes; APK MIME type only |

## 2. Assessment by risk class

| Class | Result | Basis |
|---|---|---|
| Broken authentication | PASS (static) | All data functions require a verified JWT; `expire-transfers` requires the service key and refuses to run unconfigured. |
| Broken authorisation / IDOR / BOLA | PASS (static) | Row and object access is scoped to participants by policy; signers resolve the caller from the JWT and re-check ownership; "not found" and "not yours" return the same response. |
| Injection | PASS (static) | No dynamic SQL built from user input; `format()` is used only with catalog names in migrations; object keys are built from a validated UUID and an encoded, validated file name. |
| Request tampering | PASS (static) | Identity, room, time and status fields are derived or frozen by triggers. Residual: codes are client-generated (MG-17). |
| Replay | PARTIAL | A push can be re-sent for the same transfer without limit (MG-02). Presigned URLs are reusable for one hour by design. |
| Rate-limit bypass / brute force | FAIL | Limits are per identity and identities are free; writes are not limited at all (MG-02, MG-12, MG-18). |
| Information disclosure | PARTIAL | Lookup returns nickname and public key; `room_is_joinable` callable by `anon`; error text may store signed URLs in a receiver-readable column (MG-10). |
| Insecure error messages | PARTIAL | `send-transfer-fcm` returns raw FCM error text and a database error message to the caller (`index.ts:268,327`). |
| Session handling | NOT TESTED | JWT expiry and refresh rotation are dashboard settings. |
| Race conditions | PASS (static) | Room joins are serialised with a row lock; status changes are conditional; counters use a single upsert. Residual: file-count trigger takes no lock (a sender racing itself could exceed 20 rows). |
| Resource exhaustion | FAIL | Unlimited transfers and uploads; unbounded R2 object size; unbounded objects per Supabase folder (MG-02, MG-08). |
| CORS | INFO | `*` on three functions; bearer auth, no cookies (MG-28). |

## 3. Transfer lifecycle

| Check | Result | Evidence |
|---|---|---|
| Expiry enforced server-side | PASS (static) | Signers compare `created_at` to the server clock; `created_at` is stamped by trigger. |
| Expired transfers cannot be revived | PASS (static) | `transfers_status_transition`. |
| Expired files cannot be downloaded | PARTIAL | R2 path: refused with 410. Supabase Storage path: read policy has no expiry condition (MG-07). |
| Objects actually deleted | NOT TESTED | Depends on the scheduled job and R2 lifecycle rule existing (MG-07). |
| Failed cleanup retried | PASS (static) | `files_purged_at` stays unset on any failure. |
| Orphans detected | PARTIAL | R2 orphans rely on the lifecycle rule; Supabase orphans beyond one list page are missed (MG-08). |
| DB and storage consistent | PASS (static) | Rows are hard-deleted only after `files_purged_at` is set. |
| Backup retention | NOT TESTED | Supabase backup settings are not in the repo. See `DATA_RETENTION_AND_DELETION_POLICY.md`. |

## 4. Upload and download controls

| Control | Result | Note |
|---|---|---|
| 100 MB enforced server-side | PARTIAL | Declared size and Supabase bucket: yes. R2 object: no (MG-08). |
| File signature / MIME / extension validation | NOT APPLICABLE by design | Content is ciphertext; the server cannot inspect it. Risk is handled on the receiving device and through abuse controls (MG-01). |
| Malware scanning / quarantine | NOT APPLICABLE by design | Same reason. The client could warn before opening executable types. |
| Archive-bomb protection | NOT APPLICABLE | The app never unpacks archives. |
| File-name sanitising, path traversal | PASS | Three layers plus tests. |
| Storage isolation | PASS (static) | One folder per transfer id; policies key on the folder. |
| File integrity | PASS | AEAD per chunk plus plaintext SHA-256 verified after decrypt. |
| Private storage | PASS (static) for `transfers`; deployed state NOT TESTED | Migration forces `public = false`. |
| Signed URL lifetime | PASS | 1 hour. |
| Cache-control on downloads | NOT TESTED | Not set by the signer; needs a response capture. |

## 5. Reproducible test cases (for a staging project)

Run with two anonymous identities A and B and a third, C. Expected results follow from the reviewed source.

| # | Case | Expected |
|---|---|---|
| T1 | C selects `transfers` / `transfer_files` for an A→B transfer id | zero rows |
| T2 | C calls `r2-sign-download` with A→B `storage_path` | 403 |
| T3 | C calls `r2-sign-upload` for an A→B transfer | 403 |
| T4 | A inserts a transfer with `sender_id` = B's id | RLS violation |
| T5 | A inserts with `sender_code`, `created_at` (future), `status='completed'` set | row stored with derived code, `now()`, `pending` |
| T6 | A updates `receiver_id` or `created_at` | exception |
| T7 | A sets `status='expired'`; A changes `completed` → `failed` | both refused |
| T8 | A inserts `transfer_files` with `file_name='../x'`, `file_size=104857601`, a 21st row, a non-hex hash | each refused |
| T9 | 201 lookups in 10 minutes | 201st raises |
| T10 | A updates own `short_code` / clears own `deleted_at` | refused / absorbed |
| T11 | `anon` (no session) calls `lookup_user_by_code` | permission denied |
| T12 | POST `expire-transfers` without the service key | 401 |
| T13 | Download a transfer older than 24 h via both storage paths | R2: 410. Supabase Storage: **currently succeeds until purged** (MG-07) |
| T14 | A creates 1,000 transfers / calls real push 100 times for one transfer | **currently succeeds** (MG-02) |
| T15 | PUT 1 GB to an R2 presigned URL | **currently succeeds** (MG-08) |
| T16 | Non-member inserts a transfer naming a room id | `room_share_denied` |
| T17 | Blocked member leaves and rejoins a room | `can_share` stays false |

T13–T15 are the cases expected to fail today; they become the regression tests for the corresponding fixes.
