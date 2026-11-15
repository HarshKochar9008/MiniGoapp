# MiniGo — Privacy Compliance Report

Audit date 2026-11-15 · app 1.0.0+1 · internal engineering evidence. Not legal advice; have counsel review the published policy and terms.

## What is collected (from source)

| Data | Where it goes | Linked to identity | Purpose |
|---|---|---|---|
| Anonymous account id, six-character code | Supabase | yes (pseudonymous) | Addressing |
| Public encryption key | Supabase | yes | Encryption |
| Nickname (optional) | Supabase; returned to anyone who looks up the code; shown to room members | yes | Display |
| Push token | Supabase, Google FCM | yes | Notifications |
| File contents | R2 or Supabase Storage, as ciphertext (plaintext only when the recipient has no key and the sender confirms) | yes | Delivery |
| File name, size, MIME type, SHA-256 of the plaintext, timestamps, sender and receiver | Supabase, unencrypted | yes | Delivery, integrity |
| Room name, membership, member nicknames | Supabase | yes | Rooms |
| Crash reports with account id, code and an activity trail | Google Crashlytics | yes | Diagnostics |
| Security telemetry (device and app state) | Talsec | device-level | Tamper detection |
| IP address, request logs | Supabase, Cloudflare, Google (provider logs) | provider-side | Operation |
| Bundle id, country (iOS update check, user-initiated) | Apple | no | Update check |

Not collected: name, email, phone number, contacts, location, advertising identifier, analytics SDK events. Recent recipients and contact aliases stay on the device.

## Policy versus behaviour

| # | Policy or in-app statement | Actual | Fix |
|---|---|---|---|
| 1 | Processors: Supabase, Cloudflare, Firebase, Google Fonts | Talsec also receives data; Google Fonts receives nothing (fonts are bundled, runtime fetching disabled) | Add Talsec; remove or correct the fonts line |
| 2 | "Your code reveals nothing about you" / nickname "shown on your home screen" | Nickname is returned to anyone who enters the code | Say so, or stop returning it from the lookup |
| 3 | Unencrypted metadata: names, sizes, times | Also MIME type and a SHA-256 of the original file, which lets the operator confirm a known file | Disclose, or change what is stored (MG-22) |
| 4 | "Server cleanup deletes expired files" | Depends on a scheduled job and a storage rule that have not been confirmed to exist | Confirm (MG-07), then keep the statement |
| 5 | "Only the person you send to can open it" (onboarding) | True only for encrypted sends | Qualify |
| 6 | Account deletion removes code, nickname, token | Soft retire: the row, public key and auth user remain; files you sent stay for up to 24 h; crash data is not deleted | Describe precisely, and delete more (MG-23) |
| 7 | Retention list | Omits the 90-day inactive-identity sweep and room data | Add |
| 8 | — | No controller identity, effective date, age statement, legal basis, international-transfer statement, or provider-log mention | Add |
| 9 | Contact | A personal Gmail address | Role address on a project domain |

## Requirements

| Requirement | Result | Note |
|---|---|---|
| Privacy policy available in-app | PASS | Settings → About → Legal. |
| Privacy policy at a public URL | FAIL | URLs are null (MG-05). Required by both stores. |
| Policy accurate and complete | FAIL | Table above (MG-14). |
| Data minimisation | PARTIAL | Strong overall. Crash reports carry a stable id and the code (MG-21); plaintext hash stored (MG-22). |
| Consent | PARTIAL | Camera, notifications and photos use OS prompts at the point of use. No acceptance of terms or policy before use (MG-01). Crash reporting has no opt-out. |
| Retention defined | PASS | 24 h files, 7 days records, 90 days inactive identities. See `DATA_RETENTION_AND_DELETION_POLICY.md`. |
| Retention enforced | NOT TESTED | MG-07. |
| In-app account deletion | PARTIAL | Present and easy to find; soft retire only (MG-23). |
| Deletion request outside the app | FAIL | No web path (MG-05). Required by Google Play. |
| Third-party sharing disclosed | FAIL | Talsec missing. |
| Children | NOT ADDRESSED | No age statement or gate. Decide the audience and say so. |
| Tracking / advertising | PASS | None. |

## Store declarations (draft, to be confirmed against the shipped build)

**Google Play Data safety**
- Collected: Files and docs (user files; encrypted in transit; processed for app functionality), App activity / other user-generated content (file names), Personal info → User IDs (account id, code), Device or other IDs (push token, installation id), App info and performance → Crash logs and diagnostics. Optional: Name (nickname).
- Shared: none sold; processors are service providers.
- Encrypted in transit: yes. Deletion request: in-app, plus the URL once it exists.

**Apple App Privacy**
- Data linked to the user: Identifiers (User ID, Device ID), User Content (files; file names as other user content), Diagnostics (crash data).
- Tracking: no.
- Purposes: App Functionality; Diagnostics → Analytics.

Both forms must match what the build actually does. Re-check after any change to crash reporting or metadata handling.
