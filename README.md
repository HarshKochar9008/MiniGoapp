# ZenSend

ZenSend is a real-time, cross-internet mobile file sharing app (Android/iOS) built with Flutter + Supabase.

It focuses on:
- simple recipient-code based sharing (no account setup friction),
- reliable large-file transfer using resumable uploads,
- end-to-end transfer integrity checks with SHA-256,
- and resilient behavior across poor or intermittent connectivity.

## Overview

### What the app does

ZenSend lets a sender transfer one or more files to a receiver using a short recipient code.  
Files are uploaded to Supabase Storage, transfer metadata is stored in Postgres, and the receiver is updated through Supabase Realtime and push notifications.

### Key product behavior

- No email/password onboarding (anonymous auth).
- Sender and receiver can be on different networks (internet-based relay model).
- Receiver can download later if offline during send.
- Transfers are treated as time-bound (24-hour TTL).

## Architecture

### High-level system design

ZenSend uses a **client-driven architecture** where Flutter handles user flows, transfer orchestration, and integrity checks, while Supabase provides identity, storage, metadata, and real-time signaling.

Core building blocks:
- **Identity layer**: Supabase Anonymous Auth + short code provisioning.
- **Transfer layer**: streaming hash, resumable upload, metadata persistence, download + verify.
- **Notification layer**: Realtime subscriptions + FCM notifications for closed-app delivery.
- **Resilience layer**: connectivity monitoring, persisted retry queues, deferred backend jobs.

### Tech stack

| Layer | Technology |
|-------|-----------|
| Frontend | Flutter 3.x (Dart, Android/iOS targets only) |
| Auth | Supabase Anonymous Auth (no email/password/phone) |
| Database | Supabase Postgres (users, transfers, transfer_files) |
| Storage | Supabase Storage (bucket: `transfers`) |
| Real-time | Supabase Realtime (Postgres CDC on `transfers` table) |
| Integrity | SHA-256 via `package:crypto` (streaming, constant memory) |
| Connectivity | `connectivity_plus` for network awareness |
| Transport | TLS 1.2+ via Supabase HTTPS endpoints (all traffic encrypted) |

### Codebase structure

```
lib/
├── main.dart                              # Entry point, Supabase init, auth listener
├── app.dart                               # MaterialApp + theme
├── core/
│   ├── constants.dart                     # App-wide config (limits, keys, pagination)
│   ├── supabase_config.dart               # Supabase singleton + auth state management
│   ├── network/
│   │   ├── connection_status.dart         # Shared connectivity notifier (connectivity_plus)
│   │   └── network_errors.dart            # Retryable transport/DNS classification
│   ├── offline/
│   │   ├── offline_sync_coordinator.dart  # When-online drain: FCM DB sync, push invoke queue
│   │   └── pending_backend_jobs.dart      # SharedPreferences queue for deferred backend calls
│   └── utils/
│       └── short_code_generator.dart      # Safe-alphabet code generation
└── features/
    ├── identity/
    │   └── identity_service.dart          # Anonymous auth + short code provisioning + session refresh
    ├── home/
    │   └── home_screen.dart               # Code display, navigation, sent history, connectivity
    ├── send/
    │   └── send_screen.dart               # File pick → hash → stream upload → progress
    ├── receive/
    │   ├── receive_screen.dart            # Realtime subscription, download + verify, TTL, pagination
    │   └── save_file.dart                 # Platform-specific native file saving + permissions
    └── transfer/
        └── transfer_service.dart          # Core: streaming I/O, SHA-256, retry, Realtime, pagination
```

### Transfer data flow

```
[Sender]                              [Supabase]                           [Receiver]
   │                                      │                                    │
   ├─ Connectivity pre-check              │                                    │
   ├─ Pick files (path only, no RAM)      │                                    │
   ├─ Validate sizes / count / dupes      │                                    │
   ├─ Compute SHA-256 (streaming)         │                                    │
   ├─ Stream upload (with retry) ────────►│ Storage (transfers bucket)         │
   ├─ Insert transfer_files row ─────────►│ Postgres                          │
   │                                      ├─ Realtime CDC ────────────────────►│
   │                                      │                     Auto-refresh   │
   │                                      │◄──────────────── Stream download ──┤
   │                                      │                  Verify SHA-256    │
   │                                      │                  Save to device    │
```

## Features

### 1) User and identity

- **Anonymous onboarding**: no email/password/phone; device gets an anonymous Supabase auth identity.
- **Safe short recipient code**: 6-character code from a disambiguated alphabet (`DFG5HR`).
- **Collision-safe code creation**: unique-constraint retries up to 10 attempts for code generation.
- **Session continuity**: token refresh + session recovery logic prevent most auth interruptions.

### 2) Sending and receiving files

- **Recipient-code based send flow** with validation and self-send blocking.
- **All file types supported** (`FileType.any`) with multi-file transfers (up to 20 files).
- **Cross-network sharing** via Supabase cloud (not restricted to local Wi-Fi/LAN).
- **Transfer history and status** for both sent and received flows.

### 3) Transfer engine and reliability

- **Resumable uploads (TUS)** with persistent fingerprint/offset resume semantics.
- **Streaming I/O** for uploads/downloads to avoid loading whole files into memory.
- **SHA-256 verification** before upload and after download for integrity guarantees.
- **Progress visibility** per file plus aggregate transfer progress.
- **Automatic retries** for transient failures with bounded outer retry attempts.
- **Safety checks** for file-size limits, duplicate additions, and filename sanitization.

### 4) Real-time and notifications

- **Realtime transfer updates** through Postgres CDC subscription on `transfers`.
- **Push notifications (FCM)** for incoming transfer awareness while app is backgrounded/closed.
- **Deep-link-ready payload contract** using transfer metadata (`transfer_id`, `sender_code`).

### 5) Offline behavior and resilience

- **Connectivity awareness** with pre-flight network checks and online/offline status indicators.
- **Deferred backend job queue** for operations that fail while offline.
- **When-online sync coordinator** to replay pending jobs (FCM sync + edge function retries).
- **Persistent duplicate-delivery prevention** for already downloaded file records.

### 6) Error handling and UX safety

- Domain-specific exceptions and user-facing actionable messages.
- Defensive handling for auth failures, network drops, integrity mismatches, and permission issues.
- Expiration-aware rendering for stale/expired transfers.

### Error handling matrix

| Scenario | Behavior |
|----------|----------|
| Invalid recipient code | Immediate inline error: `No user found with code "XYZ"` |
| Self-send attempt | Blocked: `You cannot send files to yourself` |
| No internet | Pre-flight check: `No internet connection. Please try again.` |
| File too large | Specific error with file name and size limit |
| Too many files | Specific error with count and limit |
| Duplicate files | Alert dialog listing already-added file names |
| Upload failure | Per-file error state with retry attempt count |
| Download failure | Error state with retry button |
| SHA-256 mismatch | `Integrity check failed — file may be corrupted` |
| Permission denied | Descriptive message (e.g., `Gallery access denied. Please enable in Settings.`) |
| Network error | Descriptive message, retry available; lists auto-refresh when back online if the last load failed |
| FCM token not saved (offline) | Pending flag; retried when device is online (`OfflineSyncCoordinator`) |
| Push edge function failed after upload | Job queued; retried when online (non-network errors dropped) |
| Anonymous auth failure | `Ensure anonymous auth is enabled in Supabase` |
| Short code collision | Transparent retry (up to 10 attempts) |
| Code validation failure | `Could not validate code. Check your connection.` |
| Transfer expired | Visual dimming with "Expired" status badge |

### File Saving

- **Images / videos** → saved to device gallery via `Gal` (ZenSend album)
- **Other files (Android)** → saved to `/Download/` or external storage with unique naming
- **Other files (iOS)** → saved to app Documents (`ZenSend/` directory)
- **Unique file names** — existing files are not overwritten; a `_(1)`, `_(2)` suffix is appended
- **Permissions** — Android: `permission_handler` resolves the correct permission level automatically based on the device's SDK version (granular media for API 33+, storage for older). iOS: `photosAddOnly` with Info.plist descriptions.

### Transfer History

- **Sent transfers** — home screen displays recent sent transfers with recipient code, status, and timestamp
- **Received transfers** — paginated list with infinite scroll, expired transfers shown with visual dimming
- **TTL enforcement** — transfers older than 24 hours are marked as expired client-side

## Setup

### Prerequisites

- Flutter SDK >= 3.0.0
- A Supabase project ([supabase.com](https://supabase.com))

### Environment

1. Copy `.env.example` to `.env`
2. Fill in your Supabase project URL and anon key
3. Run with compile-time defines:
   - `flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...`
4. Do not commit secrets. `lib/core/constants.dart` now reads from `--dart-define`.

### Supabase Configuration

#### 1. Enable Anonymous Auth

Supabase Dashboard → Authentication → Settings → Enable "Allow anonymous sign-ins"

#### 2. Create Tables

```sql
-- Users table
CREATE TABLE users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_uid UUID NOT NULL UNIQUE,
  short_code VARCHAR(8) NOT NULL UNIQUE,
  fcm_token TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Transfers table
CREATE TABLE transfers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  sender_id UUID REFERENCES users(id),
  receiver_id UUID REFERENCES users(id),
  status VARCHAR(20) DEFAULT 'pending',
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Transfer files table
CREATE TABLE transfer_files (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transfer_id UUID REFERENCES transfers(id),
  file_name VARCHAR(255) NOT NULL,
  file_size BIGINT NOT NULL,
  mime_type VARCHAR(100),
  storage_path VARCHAR(500) NOT NULL,
  sha256_hash VARCHAR(64),
  created_at TIMESTAMPTZ DEFAULT now()
);
```

#### 3. Fix ENUM (if you used an ENUM for status)

If you created `transfers.status` as a Postgres ENUM type (e.g. `transfer_status`), it must include all values the app uses. Run this in the SQL Editor:

```sql
-- Option A (recommended): Convert ENUM to VARCHAR for flexibility
ALTER TABLE transfers ALTER COLUMN status TYPE VARCHAR(20) USING status::VARCHAR(20);
DROP TYPE IF EXISTS transfer_status;
```

Or if you want to keep the ENUM, add the missing values:

```sql
-- Option B: Add missing ENUM values
ALTER TYPE transfer_status ADD VALUE IF NOT EXISTS 'failed';
ALTER TYPE transfer_status ADD VALUE IF NOT EXISTS 'partial';
ALTER TYPE transfer_status ADD VALUE IF NOT EXISTS 'uploading';
```

#### 4. Create Storage Bucket

Supabase Dashboard → Storage → New Bucket → Name: `transfers` (set as **private**, NOT public)

#### 5. Enable Realtime

Supabase Dashboard → Database → Replication → Enable Realtime for the `transfers` table.

#### 5b. Push Notifications (Incoming while app closed)

1. **Replace** the checked-in Android placeholder with your real Firebase Android app file:
   - Firebase Console → Project settings → Your apps → Android — the app **package name must match** `applicationId` in `android/app/build.gradle.kts` (currently `com.Zen.app`). Download `google-services.json` → `android/app/google-services.json`.
   - iOS: add `ios/Runner/GoogleService-Info.plist` from the same console (enable Push Notifications + Background Modes → Remote notifications in Xcode).
2. Ensure `users.fcm_token` exists (see schema above). The app registers `FirebaseMessaging.onBackgroundMessage` **before** `Firebase.initializeApp()`, requests Android 13+ notification permission, creates the `incoming_transfers` channel, shows **data-only** pushes in the background isolate, and merges **notification + data** payloads for deep-linking (`transfer_id`, `sender_code`).
3. **Deploy the included Edge Function** `supabase/functions/send-transfer-fcm/` (FCM HTTP v1). Set secrets `FCM_PROJECT_ID` and `FCM_SERVICE_ACCOUNT_JSON` (Firebase service account JSON with *Firebase Cloud Messaging API Admin*). The **app invokes this after upload** — do **not** add a duplicate **Database Webhook** on `transfers` INSERT (that caused multiple notifications per transfer). See `index.ts` header comments.
4. **FCM payload contract** (what the function already sends): `data.transfer_id`, `data.sender_code`, plus `notification.title/body` for system tray display on Android/iOS.

#### 6. RLS Policies (Database Tables)

```sql
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE transfers ENABLE ROW LEVEL SECURITY;
ALTER TABLE transfer_files ENABLE ROW LEVEL SECURITY;

-- Users: anyone can read (for code lookup), auth users can insert their own
CREATE POLICY "Anyone can look up users" ON users FOR SELECT USING (true);
CREATE POLICY "Auth users can insert themselves" ON users FOR INSERT
  WITH CHECK (auth_uid = auth.uid());

-- Transfers: participants can read, auth users can insert
CREATE POLICY "Participants can view transfers" ON transfers FOR SELECT
  USING (
    sender_id IN (SELECT id FROM users WHERE auth_uid = auth.uid())
    OR receiver_id IN (SELECT id FROM users WHERE auth_uid = auth.uid())
  );
CREATE POLICY "Auth users can create transfers" ON transfers FOR INSERT
  WITH CHECK (sender_id IN (SELECT id FROM users WHERE auth_uid = auth.uid()));
CREATE POLICY "Sender can update transfer status" ON transfers FOR UPDATE
  USING (sender_id IN (SELECT id FROM users WHERE auth_uid = auth.uid()));

-- Transfer files: linked to transfers the user can see
CREATE POLICY "Participants can view files" ON transfer_files FOR SELECT
  USING (transfer_id IN (SELECT id FROM transfers WHERE
    sender_id IN (SELECT id FROM users WHERE auth_uid = auth.uid())
    OR receiver_id IN (SELECT id FROM users WHERE auth_uid = auth.uid())
  ));
CREATE POLICY "Sender can insert files" ON transfer_files FOR INSERT
  WITH CHECK (transfer_id IN (SELECT id FROM transfers WHERE
    sender_id IN (SELECT id FROM users WHERE auth_uid = auth.uid())
  ));
```

#### 7. Storage Policies (REQUIRED — upload will fail with 403 without these)

Run this in the **SQL Editor** (not the Storage UI):

```sql
-- Allow authenticated users to upload to the transfers bucket
CREATE POLICY "Auth users can upload"
  ON storage.objects FOR INSERT
  WITH CHECK (bucket_id = 'transfers' AND (SELECT auth.role()) = 'authenticated');

-- Allow authenticated users to read/download from the transfers bucket
CREATE POLICY "Auth users can read"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'transfers' AND (SELECT auth.role()) = 'authenticated');

-- Allow authenticated users to update (upsert) files in the transfers bucket
CREATE POLICY "Auth users can update"
  ON storage.objects FOR UPDATE
  USING (bucket_id = 'transfers' AND (SELECT auth.role()) = 'authenticated');
```

### Run

```bash
flutter pub get
flutter run
```

### Run Tests

```bash
flutter test
```

## Security

| Concern | Implementation |
|---------|---------------|
| Transport encryption | All Supabase endpoints use **TLS 1.2+** (HTTPS). No plaintext communication. `HttpClient` used for streaming communicates exclusively over HTTPS. |
| Authentication | Supabase Anonymous Auth with **JWT tokens**. Each device gets a unique auth identity. Tokens auto-refreshed before expiry. |
| Storage access | Download URLs are **signed** with 1-hour expiry. No public bucket access. |
| File integrity | **SHA-256** hash computed before upload (streaming) and verified after download. Failures shown in UI. |
| Data isolation | **Row Level Security** policies ensure users can only access their own transfers. |
| Path traversal | File names sanitized — `..`, `<>`, pipes, wildcards stripped before storage path construction. |
| API keys | The `supabase_anon_key` is a **public/anonymous key** (not a service role key). Data security is enforced via RLS on the server. |
| Duplicate delivery | Transfer file IDs persisted to `SharedPreferences` — survives app restarts. |


## Testing

Unit tests cover:
- `ShortCodeGenerator` — correct length, safe alphabet, ambiguous char exclusion, statistical uniqueness
- `TransferService.sanitizeFileName` — path traversal, XSS, control chars, normal names, empty input
- `TransferService.formatFileSize` — bytes, KB, MB, GB formatting
- `AppConstants` — alphabet exclusions, code length, file size limits, TTL

## License

MIT
