# MiniGo — Security Audit Report

| | |
|---|---|
| Audit date | 2026-11-15 |
| App version | 1.0.0+1 (`pubspec.yaml`) |
| Source state | branch `feat/onboarding-v2` at `649e333`, **plus 83 uncommitted working-tree changes** (audited as on disk) |
| Scope | Flutter client (`lib/`), Android and iOS native projects, Supabase migrations and edge functions (`supabase/`), build scripts, dependencies |
| Method | Manual source review (static). Existing test suite run. No dynamic testing against a backend. |
| Tools | Flutter 3.47.7 / Dart 3.13.5; `flutter analyze` (0 errors, 0 warnings, 2 info); `flutter test` (258 passed); `flutter pub outdated` |
| Status of this document | Internal engineering evidence. **Not** a third-party certification, penetration test, or OWASP compliance attestation. |

## 1. Verdict

**Overall: NOT READY for store submission.**

| Platform | Status | Why |
|---|---|---|
| Google Play | READY AFTER CRITICAL REMEDIATION | No critical (P0) vulnerability found. Six P1 items block release: MG-01 to MG-03, MG-05 and MG-06 apply to Android (MG-04 is iOS-only). |
| Apple App Store | NOT READY | Everything above, plus the iOS project is not submittable as configured (MG-04): no signing team, no push entitlement, no privacy manifest, no URL scheme, an export-compliance flag that needs a decision. |

No approval by Apple or Google is implied or can be guaranteed by this review.

## 2. What the app actually is

The brief for this audit described "six-character file transfer codes". The implementation differs in a way that changes the threat model:

- The six-character code is a **per-user address**, assigned once at first launch and kept. It is not a per-transfer secret and does not grant access to any file.
- A sender looks up a recipient's code, then creates a transfer addressed to that user. Files are **end-to-end encrypted** on the sender's device to the recipient's public key (X25519 + HKDF-SHA256 + AES-256-GCM, chunked).
- Access to transfer rows and stored objects is restricted server-side to the sender and the receiver (Postgres row-level security and signed-URL edge functions).
- "Rooms" are short-lived groups (30/60/120 min, max 10 members) joined by a second kind of six-character code. A room code **is** a capability: knowing it lets you join.
- Sign-in is Supabase anonymous auth. There is no email, phone number or password.

Consequences: guessing a user code does not expose files; it lets a stranger *send* to that user. Guessing a room code lets a stranger join the room. The main risks are therefore abuse (unsolicited content, spam, storage exhaustion), not confidentiality of stored files.

## 3. Architecture

```
┌──────────────── Device (Flutter, Android/iOS) ────────────────┐
│ UI ── TransferService ── E2ECrypto (X25519/AES-GCM, Dart)     │
│  │        │                 │                                 │
│  │        │            private key → Keystore/Keychain        │
│  │        │            (flutter_secure_storage)               │
│  │   SharedPreferences: session tokens, own code, contacts,   │
│  │   pending-upload job, app-lock flag                        │
│  └─ freeRASP (Talsec) · Crashlytics · FCM · local_auth        │
└───────┬───────────────┬──────────────────┬───────────────────┘
        │ HTTPS         │ HTTPS            │ HTTPS
        ▼               ▼                  ▼
┌── Supabase ──────────────────┐   ┌─ Cloudflare R2 (optional) ─┐
│ Auth (anonymous)             │   │ ciphertext objects          │
│ Postgres + RLS + triggers    │   │ <transferId>/<fileName>     │
│   users, transfers,          │◄──┤ presigned PUT/GET, 1 h      │
│   transfer_files, rooms,     │   └─────────────────────────────┘
│   room_members, rate limits  │
│ Storage bucket `transfers`   │   ┌─ Google ────────────────────┐
│   (private, fallback path)   │   │ FCM (push), Crashlytics      │
│ Storage bucket `releases`    │   └─────────────────────────────┘
│   (PUBLIC, Android APK)      │   ┌─ Talsec ────────────────────┐
│ Realtime (RLS-scoped)        │   │ freeRASP security telemetry  │
│ Edge functions:              │   └─────────────────────────────┘
│   r2-sign-upload   (JWT)     │
│   r2-sign-download (JWT)     │
│   send-transfer-fcm (JWT)    │
│   expire-transfers (service key; pg_cron every 15 min)
│   qr (public redirect)       │
└──────────────────────────────┘
```

### Trust boundaries

1. **Device ↔ backend.** The client is untrusted. All authorisation must hold against a modified client using the publishable key that ships in the app.
2. **User ↔ user.** Any authenticated identity can address any other identity whose code it knows.
3. **Backend ↔ file content.** By design the server holds only ciphertext. This holds only if the recipient public key returned by the server is authentic (see MG-09).
4. **Edge functions ↔ database.** Edge functions use the service-role key and bypass RLS; their own checks are the only control.

### Asset inventory

| Asset | Where | Protection |
|---|---|---|
| File contents | R2 / Supabase Storage | E2E ciphertext (when recipient has a key); RLS / signed URLs |
| Content keys | `transfer_files.enc_wrapped_key` | Sealed to recipient public key |
| Device private key | Keystore / Keychain | `flutter_secure_storage` 10.x, default options |
| Session tokens (access + refresh) | SharedPreferences | App sandbox only (MG-11) |
| File names, sizes, MIME types, plaintext SHA-256 | Postgres, object keys | RLS; **plaintext to the operator** |
| User code, nickname, public key | Postgres | Owner-only RLS; returned by code lookup |
| FCM token | Postgres `users.fcm_token` | Owner-only RLS; service role |
| Service-role key, R2 keys, FCM service account | Supabase function secrets / Vault | Not in repo (verified) |
| Android upload keystore | Outside repo, referenced by ignored `android/key.properties` | Not in repo or history (verified) |

### Third-party processors

Supabase, Cloudflare (R2, when enabled), Google (FCM, Crashlytics), Talsec (freeRASP), Apple (iTunes lookup for update check, iOS, user-initiated). Detail in `THIRD_PARTY_SDK_INVENTORY.md`.

## 4. What is already done well

These were verified in source and are worth preserving through any remediation:

- **Authorisation is server-side.** RLS on every table; participant-scoped storage policies; edge functions resolve the caller from the JWT and take sender/receiver from the database, never the request body.
- **Server-derived fields.** `sender_code`, `receiver_code`, `room_name`, `created_at`, room-member identity and `expires_at` are stamped by triggers; participants are frozen after insert.
- **Lifecycle enforced on the server.** `expired` is terminal and server-only; `completed` is final; uploads are refused for completed/expired transfers in both storage paths.
- **Input constraints on the server.** File-name and storage-path safety, SHA-256 format, 100 MiB per file, 20 files per transfer, chunk-size bound, bucket size limit.
- **Cryptography.** Standard primitives from a maintained library, CSPRNG everywhere, unique nonce per chunk, truncation/extension detection in the v2 format, no custom algorithms, unknown formats rejected.
- **Path traversal** closed at three layers (sender sanitiser, DB constraint, receiver sanitiser at the sink), with tests.
- **Privilege hygiene.** Explicit per-role `REVOKE`s on functions (accounting for Supabase default privileges); maintenance functions refuse API callers; the expiry job compares the service key in constant time and refuses to run unconfigured.
- **Android hardening.** `allowBackup=false` with full data-extraction exclusions, cleartext off by default at targetSdk 36, R8 enabled, release builds obfuscated, share-intent intake rejects `file://` and the app's own providers, `singleTask` + empty `taskAffinity`.
- **No secrets in the repo or its history.** `.env` holds only publishable values and was never committed.
- **Logging.** Every `print`/`debugPrint` is debug-only; file names are redacted from crash reports.

## 5. Findings

Severity: P0 critical · P1 high / release blocker · P2 medium · P3 low hardening · P4 informational.
Full detail, root cause, fix and regression test for each: `VULNERABILITY_REMEDIATION_LOG.md`.

### P0 — none found

### P1

| ID | Finding | Evidence |
|---|---|---|
| MG-01 | **No abuse controls.** A receiver cannot block a sender, decline a transfer, or report content. No terms acceptance before use; the Terms are four sentences with no prohibited-content rule. Anyone who knows or guesses a code can push files and notifications to that person. | `lib/features/settings/legal_screens.dart:162-211`; no report/block/decline code in `lib/` (grep); `transfers_insert_sender` policy has no receiver consent |
| MG-02 | **No server-side throttle on sending.** Only code lookups and the push dry-run are rate-limited. Creating transfers, minting upload URLs, sending pushes and creating rooms are unlimited per identity, and identities are free. Enables storage exhaustion and notification harassment. | `rate_limit_hit` is called only in `20260803000003`, `20261029000001` and the dry-run branch of `send-transfer-fcm/index.ts:185` |
| MG-03 | **Play installs will lock themselves.** The runtime-protection config pins only the upload certificate. Google Play re-signs with its own key, which the code treats as tampering (critical → app restricted). | `lib/core/security/rasp_config.dart:19-28` (`TODO(launch)`); `app_security.dart:91` |
| MG-04 | **iOS project is not submittable.** No `DEVELOPMENT_TEAM`, no entitlements file (so no `aps-environment`; push cannot work), no `CFBundleURLTypes` (QR deep links cannot open the app), no app-level `PrivacyInfo.xcprivacy`, freeRASP disabled, and `ITSAppUsesNonExemptEncryption=false` although the app ships its own encryption. | `ios/Runner/Info.plist:79-84`; `ios/Runner.xcodeproj/project.pbxproj`; `rasp_config.dart:42` |
| MG-05 | **No hosted privacy policy, terms or deletion URL**, which both stores require. The only contact for support, privacy, security and abuse is a personal Gmail address. | `lib/core/constants.dart:51,56-58` |
| MG-06 | **Every QR code and share link leads Android users without the app to a sideloaded APK** in a public bucket. This conflicts with distributing the same app on Google Play and bypasses Play's protections. | `supabase/functions/qr/index.ts:26-27,46-51`; `20261109000001_releases_bucket.sql`; `tool/distribute_android.sh:68-70` |

### P2

| ID | Finding | Evidence |
|---|---|---|
| MG-07 | **Deletion at expiry is not confirmed to run.** The 15-minute job is scheduled only if two Vault secrets exist; the R2 lifecycle rule is a manual step. The app's own code treats it as unconfirmed (`kExpiryDeletesFiles = false`) while the Privacy screen states files are deleted. Separately, the Supabase Storage read policy has no expiry check, so objects stay readable to participants until the sweep purges them. | `20261113000002_…schedule.sql:76-80`; `onboarding_content.dart:13-17`; `privacy_screen.dart:558-561`; `20260704000002_storage_lockdown.sql` (`transfers_obj_select`) |
| MG-08 | **Stored bytes are not bounded on every path.** R2 presigned PUTs accept any body size (acknowledged in the migration). On Supabase Storage nothing limits the number of objects per transfer folder, and the sweep lists a folder once (default page size), so excess objects would be orphaned after the transfer is stamped purged. | `20261115000001_transfer_size_limits.sql:14-18`; `r2-sign-upload/index.ts:163`; `expire-transfers/index.ts:176-198` |
| MG-09 | **Encryption depends on trusting the server for keys, and downgrade is silent to the receiver.** The recipient public key comes from the server with no verification, and a transfer with no key is sent in plaintext after a sender-side prompt. The receiver sees no indication that a file arrived unencrypted. | `transfer_service.dart:1087-1091,1482-1485,2365`; `receive_screen.dart:451,602`; `send_destination.dart:112-116` |
| MG-10 | **Signed URLs and local paths can leak through error text.** Upload failure text is written to `transfers.upload_progress`, which the receiver can read; download failure text goes to Crashlytics. `dart:io` exceptions include the request URL, which here is a presigned URL valid for an hour. *Not reproduced at runtime.* | `transfer_service.dart:1578,1611,2402-2404,2432`; `receive_screen.dart:644` |
| MG-11 | **Session tokens are stored in SharedPreferences**, not the keystore. Backup is disabled, so exposure needs root or a compromised device, but a refresh token is long-lived. | `lib/core/supabase_config.dart:44-55` (no `localStorage` passed) |
| MG-12 | **Room codes are guessable at scale.** A room code is a join capability. The lookup allows 180 guesses/hour per identity against 31⁶ ≈ 887 M codes; with many live rooms and many free identities, hits become practical. A joiner then receives files shared to the room. | `20261029000001_…hardening.sql:150-158`; `room_members_insert_self` policy |
| MG-13 | **Unused restricted permissions.** `READ_MEDIA_IMAGES`, `READ_MEDIA_VIDEO` and `READ_EXTERNAL_STORAGE` are declared but nothing requests or uses them. Google Play restricts the media permissions. | `AndroidManifest.xml:14-19`; only `Permission.photosAddOnly` / `Permission.storage` are requested (`save_file.dart:88,149`) |
| MG-14 | **Privacy text does not match behaviour.** Talsec is not disclosed; the policy says fonts are downloaded (they are bundled); copy says the code "reveals nothing about you" while the nickname is returned to anyone who enters it; the plaintext SHA-256 and MIME type are not in the "not encrypted" list; "delete account" is a soft retire and residual data is not described. | `legal_screens.dart:99-105`; `main.dart:36`; `onboarding_content.dart:45`; `app_reset.dart:158-167` |

### P3

| ID | Finding | Evidence |
|---|---|---|
| MG-15 | iOS: decrypted non-media files are saved to `Documents/`, which is exposed in Files/Finder and included in device backups. The album save needs read-write Photos access but only add-only is requested (likely failure or an unexplained prompt). | `Info.plist:75-78`; `save_file.dart:62-64,88,102-113` |
| MG-16 | No automated gate. No CI workflow runs tests, analysis, dependency or secret scanning; the release script ships without running tests. Edge functions import from `esm.sh` with no lockfile. | `codemagic.yaml`; `tool/distribute_android.sh:57-64`; no `deno.lock` |
| MG-17 | User and room codes are generated by the client and inserted as-is; the server enforces uniqueness but not format. A modified client can pick vanity or look-alike codes. The base tables are not defined in the migrations, so their constraints cannot be confirmed from the repo. | `identity_service.dart:287-295`; `room_service.dart:209-237`; `README.md:282-310` |
| MG-18 | User-code enumeration is throttled (1,200/hour per identity) but effectiveness depends on the anonymous sign-up limit and CAPTCHA, which are dashboard settings (not tested). | `20260803000003_lookup_rate_limit.sql:153`; `supabase/config.toml` (local only) |
| MG-19 | Android share-intent intake copies any offered stream into the cache with no size limit before the 100 MB check runs; any app can trigger it. Plaintext source copies persist until the cache is cleared. | `MainActivity.kt:243-272`; `local_cache.dart:24` |
| MG-20 | App lock is a UI overlay controlled by a SharedPreferences flag, with a 60-second grace period and no `FLAG_SECURE`. | `app_lock.dart:21,26,59,141-151` |
| MG-21 | Crash reports carry the user id and code; `recordFlutterFatalError` is not redacted. Disclosed in the policy. | `analytics.dart:31-33`; `main.dart:48` |
| MG-22 | The plaintext SHA-256 of every file is stored server-side (allows confirming a known file); `upload_progress` holds the unsanitised original file name. | `transfer_service.dart:549-564,1439-1440,1565` |
| MG-23 | Account deletion does not remove the user row, public key, auth user, sent files or crash data, and the device FCM token is not deleted. | `app_reset.dart:107-167` |
| MG-24 | Native method-channel handlers trust their Dart caller: the pre-Android-10 save path joins `fileName` without native sanitising, `openFile` accepts any URI with a read grant, and the exported widget receiver lets any app copy the user's code to the clipboard. | `MainActivity.kt:164-181,355`; `MinigoWidgetProvider.kt:27-44` |

### P4

| ID | Finding |
|---|---|
| MG-25 | A release variant can be debug-signed if built with a Gradle task whose name lacks "Release" on a checkout without `key.properties` (`build.gradle.kts:81-95`). |
| MG-26 | Retired identities are not refused by the signers or the transfer insert policy (no `deleted_at` check). |
| MG-27 | The sweep handles 100 transfers per 15-minute run; a backlog under load or abuse delays deletion. |
| MG-28 | Edge functions send `Access-Control-Allow-Origin: *`. Low impact: auth is a bearer token, not a cookie. |
| MG-29 | Constraints added `NOT VALID` were never validated; `apply_security_lockdown.sql` remains in the repo and would undo later hardening if its guard were bypassed. |
| MG-30 | Bundle id case differs between platforms (`com.Zen.app` / `com.zen.app`); template TODO left in `build.gradle.kts:34`; stale Podfile; broad ProGuard keeps; `.env` shipped as an asset (publishable values only today). |
| MG-31 | Low-reputation dependencies (`glossy` 0.0.5, `disk_space_plus` 0.2.8); `freerasp` one major version behind. |

## 6. Is six characters enough?

- **User codes: yes, once MG-01 and MG-02 are fixed.** The code is an address, not a secret. Guessing one yields the ability to send to a stranger plus their nickname and public key. Lengthening the code would hurt usability without removing that risk; receiver-side consent, blocking and sender throttles remove it.
- **Room codes: no, not on their own.** They are bearer capabilities. Recommend 8 or more characters, or host approval of joiners, plus a per-room failed-join signal (MG-12).
- Generation uses `Random.secure()` over a 31-character alphabet (≈ 29.7 bits). Collisions are handled by a unique constraint and client retry (10 attempts for users, 4 for rooms).

## 7. Not tested

| Area | Reason |
|---|---|
| Any dynamic or penetration test of the API | The only linked Supabase project is the live one. No staging environment or test accounts were available, and production must not be probed. |
| Deployed database state (actual policies, grants, triggers, base-table constraints) | Requires database access. Source migrations were reviewed, not the deployed schema. |
| Whether `expire-transfers` and the identity sweep are scheduled; R2 lifecycle rule; bucket privacy; backup retention | Dashboard / cloud-console state. |
| Anonymous sign-in rate limit, CAPTCHA, Firebase API-key restrictions | Dashboard / console state. |
| Dependency CVE scan, secret scan of history blobs, SAST | `osv-scanner`, `gitleaks`, `semgrep`, `trivy`, MobSF not installed. A manual pattern sweep of tracked files and added-file history found no secrets. |
| Runtime behaviour on devices (MG-10 leak, MG-15 Photos prompt, MG-19 disk fill) | Nothing was run on a device. |
| freeRASP network behaviour, binary analysis of the built APK/IPA | Out of reach without MobSF / traffic capture. |

## 8. Next step

A prioritised plan is in `VULNERABILITY_REMEDIATION_LOG.md`. No fix has been implemented; each needs approval, and several need actions only the owner can take (Play Console certificate, Apple Developer account, hosting the policy, deploying migrations).
