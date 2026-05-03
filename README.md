# Whoosh

**Frictionless file sharing across any network — no accounts, no friction, just a 6-character code.**

Whoosh is a production-grade Flutter mobile application that enables secure, real-time file transfers between devices using a simple short-code system. No email, no password, no sign-up — recipients are identified by a unique 6-character code, and files are transferred instantly over a cloud-relay with full SHA-256 integrity verification.

---

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Architecture](#architecture)
- [Tech Stack](#tech-stack)
- [Project Structure](#project-structure)
- [Getting Started](#getting-started)
- [Supabase Setup](#supabase-setup)
- [Firebase & Push Notifications](#firebase--push-notifications)
- [Configuration Reference](#configuration-reference)
- [Permissions](#permissions)
- [Security](#security)
- [Offline Resilience](#offline-resilience)
- [Error Handling](#error-handling)
- [Testing](#testing)
- [License](#license)

---

## Overview

Whoosh solves the classic problem of sending files between people on different networks without requiring any account setup or contact exchange.

**Core user flows:**

| Role | Steps |
|------|-------|
| **Sender** | Enter recipient's 6-character code → Select files → Hash + Upload → Done |
| **Receiver** | Receive push notification → Download + Verify SHA-256 → Saved to device |

Every file transfer uses TUS resumable uploads, streaming SHA-256 integrity verification, and Supabase Realtime for live per-file progress. Transfers expire after 24 hours.

---

## Features

### Identity & Onboarding
- **Zero-friction anonymous auth** — Supabase anonymous sign-in; no email, password, or phone ever required
- **6-character short code** — generated on first launch from a disambiguated alphabet (no `O`, `0`, `I`, `1`, `L`) and cached locally; survives app restarts
- **Collision-safe provisioning** — unique DB constraint retry loop (up to 10 attempts)
- **Animated onboarding** — Welcome → code reveal → permission requests → ready in one linear flow

### File Transfers
- Share up to **20 files** per transfer (max **100 MB** per file)
- **All file types supported** — images, videos, documents, archives, binaries
- **TUS resumable uploads** — fingerprint + byte-offset persisted locally; resumes from exact interruption point after connectivity loss
- **Streaming SHA-256** — hash computed during upload, independently verified during download; no full-file RAM buffering at any stage
- **Live progress** — per-file and aggregate progress visible to both sender and receiver via Postgres CDC subscriptions
- **Transfer history** — paginated log of all sent and received transfers with status badges and 24-hour TTL expiry indicators

### Notifications & Real-Time
- **FCM push notifications** — delivered via a Supabase Edge Function (TypeScript + FCM HTTP v1) when upload completes
- **Background isolate handler** — receives and displays notifications even when the app is fully closed
- **Deep-link navigation** — tapping a notification opens directly to the Receive screen for that transfer (`transfer_id` + `sender_code` payload)
- **Duplicate prevention** — stable notification IDs per transfer; downloaded file IDs persisted to `SharedPreferences`

### Offline Resilience
- **Persistent job queue** — failed backend operations (FCM token sync, push triggers) queued to `SharedPreferences` and retried on reconnect
- **Offline sync coordinator** — triggers on connectivity recovery (debounced 450 ms), app lifecycle resume, and coordinator startup
- **Connectivity-aware UI** — live online/offline badge on Home; send operations blocked gracefully when offline

### Settings & Diagnostics
- **Theme toggle** — Light / Dark / System
- **Push readiness check** — verifies FCM token is synced and notification permission is granted
- **Startup diagnostics** — DNS resolution, auth health probe, session refresh validation, IP lookup
- **App reset** — wipes local state + anonymous session for a completely clean slate

---

## Architecture

Whoosh uses a **client-driven cloud-relay** model — the Flutter app orchestrates all transfer logic; Supabase provides identity, storage, real-time messaging, and push delivery.

```
┌──────────────────────────────────────────────────────────────┐
│                       Flutter Client                          │
│                                                              │
│   Identity      Transfer      Notifications    Offline Sync  │
│   Service       Service       Service          Coordinator   │
└─────┬──────────────┬──────────────┬────────────────┬─────────┘
      │              │              │                │
 ┌────▼──────────────▼──────────────▼────────────────▼────────┐
 │                        Supabase                             │
 │                                                             │
 │  Postgres DB (RLS)    Storage (private bucket)              │
 │  Anonymous Auth       Realtime (Postgres CDC)               │
 │  Edge Functions       Row Level Security                    │
 └──────────────────────────────┬──────────────────────────────┘
                                │
                   ┌────────────▼────────────┐
                   │   Firebase (FCM v1)      │
                   │   Push Notifications     │
                   └─────────────────────────┘
```

**Transfer data flow:**

```
[Sender]                              [Supabase]                        [Receiver]
   │                                      │                                  │
   ├─ Connectivity pre-check              │                                  │
   ├─ Pick files (path only, no RAM)      │                                  │
   ├─ Validate sizes / count / dupes      │                                  │
   ├─ Stream SHA-256 hash                 │                                  │
   ├─ TUS stream upload ────────────────► │ Storage (transfers bucket)       │
   ├─ Insert transfer + files rows ──────►│ Postgres                        │
   ├─ Invoke Edge Function ──────────────►│ FCM push ──────────────────────►│
   │                                      ├─ Realtime CDC ─────────────────►│
   │                                      │◄──────────── Stream download ───┤
   │                                      │             Verify SHA-256      │
   │                                      │             Save to device      │
```

**Key design principles:**

- **Stateless resume** — TUS fingerprint + byte offset stored locally; uploads resume from the last confirmed offset after any interruption
- **Streaming I/O** — all file operations (hash, upload, download, save) use streams; no full-file heap allocation
- **Persistent job queues** — failed backend calls queued to `SharedPreferences` and replayed automatically on recovery
- **Connectivity-aware** — preflight checks gate major operations; recovery is automatic and silent
- **Data isolation** — Postgres Row Level Security ensures users only access their own transfers

---

## Tech Stack

| Category | Technology | Version | Purpose |
|----------|-----------|---------|---------|
| **Framework** | Flutter | 3.x | Cross-platform mobile (Android + iOS) |
| **Language** | Dart | 3.0+ | Client-side logic |
| **Backend** | Supabase (`supabase_flutter`) | ^2.3.4 | Auth, Postgres DB, Storage, Realtime |
| **Resumable Upload** | `tus_client_dart` | ^2.5.0 | TUS protocol with resume support |
| **File I/O** | `file_picker` | ^11.0.2 | Device file selection |
| | `gal` | ^2.3.0 | Save to gallery (Android MediaStore / iOS Photos) |
| | `path_provider` | ^2.1.3 | App storage paths |
| | `cross_file` | ^0.3.5+2 | Cross-platform file abstraction |
| **Integrity** | `crypto` | ^3.0.3 | Streaming SHA-256 hashing |
| **Networking** | `connectivity_plus` | ^7.1.1 | Network path detection |
| **Local Storage** | `shared_preferences` | ^2.2.3 | Code cache, offline queues, settings |
| | `disk_space_plus` | ^0.2.4 | Free disk space preflight check |
| **Notifications** | `firebase_core` | ^4.7.0 | Firebase initialization |
| | `firebase_messaging` | ^16.2.0 | FCM push token + background isolate handler |
| | `flutter_local_notifications` | ^21.0.0 | In-app and system tray alerts |
| **Permissions** | `permission_handler` | ^12.0.1 | Android/iOS runtime permissions |
| **Device** | `battery_plus` | ^7.0.0 | Battery level + power-save mode detection |
| **Config** | `flutter_dotenv` | ^5.2.1 | `.env` file loading |
| **UI** | `google_fonts` | ^6.2.1 | Inter, Instrument Serif, JetBrains Mono |
| **Edge Functions** | Deno / TypeScript | — | FCM v1 push delivery via Supabase Edge |

---

## Project Structure

```
lib/
├── main.dart                               # App entry point, Supabase init, FCM background handler
├── app.dart                                # MaterialApp, theming, bottom nav shell
│
├── core/
│   ├── constants.dart                      # App limits, code alphabet, validation rules
│   ├── supabase_config.dart                # Supabase client singleton, session management
│   ├── theme.dart                          # AppColors, ZenColors palette, ThemeController
│   ├── app_reset.dart                      # Full device reset (local data + anonymous session)
│   ├── network/
│   │   ├── connection_status.dart          # Connectivity notifier (coarse online/offline)
│   │   └── network_errors.dart             # Retryable error classification (DNS, timeouts, TLS)
│   ├── offline/
│   │   ├── offline_sync_coordinator.dart   # Orchestrates retry of queued jobs on reconnect
│   │   └── pending_backend_jobs.dart       # SharedPreferences queue (FCM sync, push retries)
│   ├── navigation/
│   │   └── root_navigator.dart             # Global navigator key for deep-link routing
│   ├── notifications/
│   │   ├── notification_service.dart       # FCM token, local notifications, token sync
│   │   ├── fcm_background.dart             # Background isolate handler (closed app)
│   │   ├── incoming_transfer_notification_style.dart
│   │   └── pending_push.dart               # Deep-link payload management
│   └── utils/
│       └── short_code_generator.dart       # Collision-safe 6-character code generation
│
├── features/
│   ├── identity/
│   │   └── identity_service.dart           # Anonymous auth bootstrap, session refresh, code provisioning
│   ├── home/
│   │   └── home_screen.dart                # Code display, copy/share, online badge, send button
│   ├── send/
│   │   └── send_screen.dart                # Code validation, file picker, upload pipeline + progress
│   ├── receive/
│   │   ├── receive_screen.dart             # Realtime subscriber, download, SHA-256 verify, save
│   │   ├── received_tab_screen.dart        # Paginated list of incoming transfers
│   │   └── save_file.dart                  # Platform-specific file save (Android / iOS)
│   ├── transfer/
│   │   ├── transfer_service.dart           # Core: SHA-256, TUS upload, stream download, Realtime
│   │   └── transfer_progress_widgets.dart  # Progress bars, per-file status cards
│   ├── history/
│   │   └── history_screen.dart             # All transfers, filters, pagination, TTL expiry UI
│   ├── settings/
│   │   └── settings_screen.dart            # Theme toggle, push readiness, diagnostics, app reset
│   └── onboarding/
│       └── onboarding_screen.dart          # Welcome → code animation → permissions → ready
│
└── Whoosh/
    ├── theme/
    │   └── zen_theme.dart                  # ZenColors (paper, ink, blue600, sand, etc.)
    └── widgets/
        └── zen_widgets.dart                # Shared UI components (buttons, cards, dialogs)

supabase/
└── functions/
    └── send-transfer-fcm/
        └── index.ts                        # Edge Function: FCM v1 push on transfer completion
```

---

## Getting Started

### Prerequisites

- Flutter SDK `>= 3.0.0` / Dart SDK `>= 3.0.0`
- A [Supabase](https://supabase.com) project (free tier works)
- A [Firebase](https://console.firebase.google.com) project with Cloud Messaging enabled
- Android Studio / Xcode for platform builds

### 1. Clone the repository

```bash
git clone https://github.com/your-org/Whoosh.git
cd Whoosh
```

### 2. Install dependencies

```bash
flutter pub get
```

### 3. Configure environment

```bash
cp .env.example .env
```

Fill in your Supabase credentials:

```dotenv
SUPABASE_URL=https://your-project-id.supabase.co
SUPABASE_ANON_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
```

### 4. Run the app

```bash
# Pass credentials at compile time (recommended)
flutter run \
  --dart-define=SUPABASE_URL=https://your-project-id.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=eyJ...

# Or rely on the .env file (development only)
flutter run
```

---

## Supabase Setup

### 1. Enable Anonymous Auth

Supabase Dashboard → **Authentication → Settings** → enable **"Allow anonymous sign-ins"**

### 2. Create Tables

```sql
-- Identity: one anonymous user per device + short recipient code
CREATE TABLE users (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_uid   UUID NOT NULL UNIQUE,
  short_code VARCHAR(8) NOT NULL UNIQUE,
  fcm_token  TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Transfer session: status + live progress JSON
CREATE TABLE transfers (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  sender_id       UUID REFERENCES users(id),
  receiver_id     UUID REFERENCES users(id),
  status          VARCHAR(20) DEFAULT 'pending',
  upload_progress TEXT,
  created_at      TIMESTAMPTZ DEFAULT now()
);

-- Per-file metadata and integrity record
CREATE TABLE transfer_files (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transfer_id  UUID REFERENCES transfers(id),
  file_name    VARCHAR(255) NOT NULL,
  file_size    BIGINT NOT NULL,
  mime_type    VARCHAR(100),
  storage_path VARCHAR(500) NOT NULL,
  sha256_hash  VARCHAR(64),
  created_at   TIMESTAMPTZ DEFAULT now()
);
```

> **Note:** If `transfers.status` was created as a Postgres ENUM, convert it to `VARCHAR(20)`:
> ```sql
> ALTER TABLE transfers ALTER COLUMN status TYPE VARCHAR(20) USING status::VARCHAR(20);
> DROP TYPE IF EXISTS transfer_status;
> ```

### 3. Enable Realtime

Supabase Dashboard → **Database → Replication** → enable Realtime for the `transfers` table.

### 4. Create Storage Bucket

Supabase Dashboard → **Storage → New Bucket** → name it `transfers` → set as **private** (not public).

### 5. Row Level Security — Database Tables

```sql
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE transfers ENABLE ROW LEVEL SECURITY;
ALTER TABLE transfer_files ENABLE ROW LEVEL SECURITY;

-- Users: anyone can look up by code; auth users can insert themselves
CREATE POLICY "Anyone can look up users" ON users FOR SELECT USING (true);
CREATE POLICY "Auth users can insert themselves" ON users FOR INSERT
  WITH CHECK (auth_uid = auth.uid());

-- Transfers: participants can read; sender can insert and update
CREATE POLICY "Participants can view transfers" ON transfers FOR SELECT
  USING (
    sender_id   IN (SELECT id FROM users WHERE auth_uid = auth.uid())
    OR receiver_id IN (SELECT id FROM users WHERE auth_uid = auth.uid())
  );
CREATE POLICY "Auth users can create transfers" ON transfers FOR INSERT
  WITH CHECK (sender_id IN (SELECT id FROM users WHERE auth_uid = auth.uid()));
CREATE POLICY "Sender can update transfer status" ON transfers FOR UPDATE
  USING (sender_id IN (SELECT id FROM users WHERE auth_uid = auth.uid()));

-- Transfer files: scoped to transfers the user can see
CREATE POLICY "Participants can view files" ON transfer_files FOR SELECT
  USING (transfer_id IN (
    SELECT id FROM transfers WHERE
      sender_id   IN (SELECT id FROM users WHERE auth_uid = auth.uid())
      OR receiver_id IN (SELECT id FROM users WHERE auth_uid = auth.uid())
  ));
CREATE POLICY "Sender can insert files" ON transfer_files FOR INSERT
  WITH CHECK (transfer_id IN (
    SELECT id FROM transfers WHERE
      sender_id IN (SELECT id FROM users WHERE auth_uid = auth.uid())
  ));
```

### 6. Row Level Security — Storage Bucket

Run in the **SQL Editor** (the Storage UI does not expose these policies):

```sql
CREATE POLICY "Auth users can upload"
  ON storage.objects FOR INSERT
  WITH CHECK (bucket_id = 'transfers' AND (SELECT auth.role()) = 'authenticated');

CREATE POLICY "Auth users can read"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'transfers' AND (SELECT auth.role()) = 'authenticated');

CREATE POLICY "Auth users can update"
  ON storage.objects FOR UPDATE
  USING (bucket_id = 'transfers' AND (SELECT auth.role()) = 'authenticated');
```

---

## Firebase & Push Notifications

### 1. Android

1. Firebase Console → **Project settings → Your apps → Android**
2. The package name must match `applicationId` in `android/app/build.gradle.kts` (e.g. `com.zen.app`)
3. Download `google-services.json` → place at `android/app/google-services.json`

### 2. iOS

1. Firebase Console → add an iOS app with the correct bundle ID
2. Download `GoogleService-Info.plist` → place at `ios/Runner/GoogleService-Info.plist`
3. In Xcode: enable **Push Notifications** capability and **Background Modes → Remote notifications**

### 3. Deploy the Edge Function

```bash
supabase functions deploy send-transfer-fcm
```

Set the required secrets in Supabase Dashboard → **Edge Functions → Secrets**:

| Secret | Value |
|--------|-------|
| `FCM_PROJECT_ID` | Firebase project ID |
| `FCM_SERVICE_ACCOUNT_JSON` | Full Firebase service account JSON (with FCM Admin role) |

> **Important:** The Flutter client invokes this Edge Function directly after upload completes. Do **not** add a Database Webhook on `transfers` INSERT — that would cause duplicate notifications per transfer.

### 4. FCM Payload Contract

| Field | Value | Purpose |
|-------|-------|---------|
| `data.transfer_id` | UUID | Deep-link to the specific transfer |
| `data.sender_code` | String | Display sender identity |
| `notification.title` | String | System tray title |
| `notification.body` | String | System tray body |

---

## Configuration Reference

### App Constants

| Constant | Value | Description |
|----------|-------|-------------|
| Code alphabet | `ABCDEFGHJKMNPQRSTUVWXYZ23456789` | 32 characters — ambiguous chars excluded |
| Code length | `6` | Recipient short code length |
| Max file size | `100 MB` | Per-file upload limit |
| Max files per transfer | `20` | Files per send operation |
| Transfer TTL | `24 hours` | Transfers expire and are purged after this |
| Large upload threshold | `10 MB` (Wi-Fi) / `5 MB` (cellular) | Warns before uploading on metered connections |

### Design System (ZenColors)

| Token | Hex | Usage |
|-------|-----|-------|
| `paper` | `#FBFAF7` | Light mode background |
| `ink` | `#1A2230` | Primary text |
| `blue600` | `#1558D6` | Primary CTA buttons |
| `sand` | earthy tones | Dividers, secondary surfaces |

**Typography:** Instrument Serif (display) · Inter (body) · JetBrains Mono (short codes)

---

## Permissions

### Android

| Permission | API Level | Reason |
|-----------|-----------|--------|
| `POST_NOTIFICATIONS` | 13+ | Display incoming transfer alerts |
| `READ_MEDIA_IMAGES`, `READ_MEDIA_VIDEO`, `READ_MEDIA_AUDIO` | 33+ | Save received files to gallery |
| `WRITE_EXTERNAL_STORAGE` | < 33 | Save received files to Downloads |

### iOS

| Permission | Reason |
|-----------|--------|
| `NSPhotoLibraryAddUsageDescription` | Save images/videos to Photos |
| Local notifications | Display incoming transfer alerts (Info.plist) |

Permissions are requested contextually — never upfront — with explanatory dialogs before each prompt.

### File Save Destinations

| Platform | File Type | Destination |
|----------|-----------|-------------|
| Android | Image / Video | Device gallery (via `gal`, Whoosh album) |
| Android | Other | `/Download/` folder |
| iOS | Image / Video | Photos app (via `gal`) |
| iOS | Other | App Documents (`Whoosh/` directory) |

Existing files are never overwritten — a `_(1)`, `_(2)` suffix is appended automatically.

---

## Security

| Concern | Implementation |
|---------|---------------|
| **Transport** | TLS 1.2+ enforced for all connections. No plaintext communication. |
| **Authentication** | Supabase Anonymous Auth + JWT tokens. Auto-refreshed 60 seconds before expiry. Graceful fallback to cached identity on transient failures. |
| **Storage access** | Private bucket. Clients receive 1-hour signed download URLs — no public access. |
| **File integrity** | SHA-256 computed streaming during upload; independently verified streaming during download. Mismatches surfaced as hard errors in the UI. |
| **Data isolation** | Postgres Row Level Security on all tables. Users can only read and write their own transfers. |
| **Path traversal** | File names sanitized before storage path construction — `..`, `<>`, pipes, wildcards, and control characters stripped. |
| **API keys** | Only the Supabase anonymous key (a public, RLS-scoped key) is bundled in the app. The service role key never leaves the server. |
| **Duplicate delivery** | Downloaded file IDs persisted to `SharedPreferences`. Survives app restarts; prevents re-delivery on notification re-tap. |

---

## Offline Resilience

Whoosh recovers gracefully from connectivity interruptions at every stage of a transfer.

### Upload Interruption
- TUS protocol persists a **fingerprint and byte offset** locally
- If the connection drops mid-upload, the next attempt resumes from the last confirmed byte
- A `PendingUploadJob` is persisted to `SharedPreferences` and recovered on app relaunch

### Backend Job Queue

Failed backend operations are queued and retried automatically by the `OfflineSyncCoordinator`:

| Queued Job | Retry Trigger |
|-----------|---------------|
| FCM token sync to `users.fcm_token` | Connectivity recovery, app resume |
| Edge Function invocation (push send) | Connectivity recovery, app resume |

**Trigger conditions:**
1. Connectivity flips from offline → online (debounced 450 ms)
2. App lifecycle transitions to resumed
3. Coordinator startup when already online

Non-network failures (auth errors, bad data) are dropped immediately to prevent queue wedging.

### Retry Strategy

| Operation | Max Attempts | Backoff |
|-----------|-------------|---------|
| Supabase DB calls | 4 | Exponential (400 ms base) |
| TUS upload chunks | Configurable | TUS client retry logic |
| Short code generation | 10 | Immediate (collision retry) |
| FCM token sync | Unlimited | Retried on each reconnect |

---

## Error Handling

| Scenario | User-Facing Behavior |
|----------|----------------------|
| Invalid recipient code | Inline error: `No user found with code "XYZ"` |
| Self-send attempt | Blocked: `You cannot send files to yourself` |
| No internet (pre-flight) | `No internet connection. Please try again.` |
| File exceeds 100 MB | Specific error with file name and limit |
| Too many files (> 20) | Specific error with count and limit |
| Duplicate files selected | Alert dialog listing already-added file names |
| Upload failure | Per-file error state with retry attempt count |
| Download failure | Error state with manual retry button |
| SHA-256 mismatch | `Integrity check failed — file may be corrupted` |
| Gallery permission denied | `Gallery access denied. Enable in Settings.` |
| Anonymous auth failure | `Ensure anonymous auth is enabled in Supabase` |
| Short code collision | Transparent retry (up to 10 attempts, then exception) |
| FCM token not saved (offline) | Queued silently; retried when device is online |
| Push Edge Function failed | Job queued; retried on connectivity recovery |
| Transfer expired | Visual dimming with "Expired" status badge |

---

## Testing

```bash
flutter test
```

| Suite | What is tested |
|-------|---------------|
| `ShortCodeGenerator` | Code length, alphabet constraints, ambiguous character exclusion, statistical uniqueness |
| `TransferService.sanitizeFileName` | Path traversal sequences, XSS payloads, control characters, Unicode edge cases |
| `TransferService.formatFileSize` | Bytes → KB / MB / GB formatting at boundary values |
| `AppConstants` | Validation rules: file size limits, code format, transfer limits |

---

## License

Proprietary — All rights reserved. © 2025 Whoosh / Neosapien.

