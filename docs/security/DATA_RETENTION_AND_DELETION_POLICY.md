# MiniGo — Data Retention and Deletion Policy

Version 0.1 (draft) · 2026-11-15 · describes what the source code implements. Items marked **unconfirmed** depend on deployed configuration that the audit could not inspect. Review with counsel before publishing any of this to users.

## Schedule

| Data | Location | Retention | Mechanism | Confirmed |
|---|---|---|---|---|
| File contents | R2 or Supabase Storage | 24 hours from creation; for room transfers, until the room expires (30, 60 or 120 minutes) | `expire-transfers` function every 15 minutes: marks expired, deletes objects, records `files_purged_at`; retries failures next run | Code yes; schedule **unconfirmed** (MG-07) |
| File contents, backstop | R2 | 1 day | Bucket lifecycle rule (manual setup, `docs/R2_SETUP.md`) | **Unconfirmed** |
| Transfer and file records (names, sizes, hashes, sender, receiver, status) | Postgres | Marked expired at 24 hours; deleted 7 days after creation, once files are purged | Same function, step 4 | Code yes; schedule **unconfirmed** |
| Rooms and memberships | Postgres | Until room expiry, then deleted once its transfers are purged | Same function, step 3 | As above |
| Account row (id, code, public key) | Postgres | Kept indefinitely, including after deletion, so a code is never reissued | By design | Yes |
| Nickname, push token | Postgres | Until changed, account deletion, or identity retirement | Trigger clears both on retirement | Yes |
| Anonymous auth user | Supabase Auth | 90 days without session activity | Daily sweep `cleanup_stale_anonymous_identities` | Code yes; schedule **unconfirmed** |
| Rate-limit counters | Postgres | 1 day | Daily prune | Code yes; schedule **unconfirmed** |
| Crash reports | Google Crashlytics | Google's retention (90 days at the time of writing; verify) | Provider | Not verified |
| Security telemetry | Talsec | Provider's retention | Provider | Not verified |
| Request logs, IP addresses | Supabase, Cloudflare, Google | Provider's retention | Provider | Not verified |
| Database backups | Supabase | Plan-dependent | Provider | **Not documented** — record the plan's backup retention here |
| On device: received files | Downloads / Gallery / Files | Until the user deletes them | User | — |
| On device: cache and temporary copies | App cache | Until cleared in Settings, by reset, or by the OS | `LocalCache.clear()` | Yes (MG-19 notes copies that linger) |
| On device: key, session, settings | Keystore/Keychain, preferences | Until reset, deletion or uninstall | `app_reset.dart` | Yes |

A deleted record can persist in provider backups until those backups age out. State the backup period to users once it is known.

## Deletion

### By the user

- **Delete account** (Privacy & Security): the server clears the nickname and push token and marks the identity deleted, so the code stops working. The device signs out and removes its key, history, contacts and cache.
- **Not removed by this action today** (MG-23): the account row with its code and public key; the anonymous auth user (removed by the 90-day sweep); files the user sent that are still within their 24 hours; transfer records for up to 7 days; crash data held by Google; files already saved to the device's shared storage.
- **Reset app**: same as above but proceeds offline and completes the server step later.

### By request

There is no web form or address for deletion requests yet (MG-05). Once one exists: verify the requester controls the identity (they supply the code from the device), then retire the identity and remove its live transfers and stored objects. Target: within 30 days.

### By the operator

Abuse or legal removal: retire the identity, delete the stored objects, keep the minimum record of the action (`INCIDENT_RESPONSE_PLAN.md`).

## Verification

Monthly, and before each release, run the retention queries in `PRODUCTION_SECURITY_CHECKLIST.md` and record the result here.

| Date | Expiry job healthy | Rows past retention | Objects without a live transfer | Checked by |
|---|---|---|---|---|
| — | not yet verified | — | — | — |

## Open items

1. Confirm the three scheduled jobs and the R2 lifecycle rule exist (MG-07).
2. Close the gaps that let objects outlive their transfer (MG-08).
3. Extend account deletion and document exactly what it removes (MG-23, MG-14).
4. Record backup retention and provider log retention.
5. Publish the user-facing version at a stable URL (MG-05).
