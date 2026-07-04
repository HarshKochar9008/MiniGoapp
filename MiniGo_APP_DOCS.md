# MiniGo — App Documentation

> Real-time mobile file sharing for Android & iOS

---

## Overview

**MiniGo** is a mobile-first file sharing app that lets users send files to each other instantly using a unique 6-character short code. No accounts, no sign-in friction — just share your code and start receiving files. Built with Flutter, powered by Supabase (Postgres + Realtime + Storage) and Firebase (push notifications + crash reporting).

---

## Core Concept

Every user gets a permanent **short code** (e.g. `WH3-X9Z`) generated on first launch. To send someone a file, you enter their code. To receive files, you share your code. No usernames, no email — just the code.

---

## Screens & Features

### 1. Onboarding (First Launch)

A 5-step animated walkthrough shown only on first install:

| Step | What it does |
|------|-------------|
| Welcome | Introduces MiniGo |
| Generate | Animated code-shuffler reveals your unique short code |
| Code | Explains how to share/use your code |
| Permissions | Requests notification and storage permissions |
| Ready | Confirms setup complete |

- Skippable at any step
- Completion state persisted in SharedPreferences
- Never shown again after first completion

---

### 2. Home Screen

The main hub after onboarding. Shows:

- **Your short code** — large, formatted display (e.g. `WH3-X9Z`)
- **Online / Offline indicator** — live connectivity dot (green/red)
- **Code actions:**
  - Copy to clipboard (with haptic feedback)
  - Show QR code (bottom sheet with scannable QR)
  - Share via native share sheet (e.g. iMessage, WhatsApp)
- **Send FAB** — floating button to open the Send screen
- **Info card** — contextual tip explaining how codes work

---

### 3. Send Screen

Initiates an outbound file transfer:

**Step 1 — Enter recipient code**
- Manual text input (uppercase, 6-char validation)
- QR scanner — tap to scan recipient's QR code instead of typing
- Code validation against Supabase before proceeding

**Step 2 — Pick files**
- Multi-file picker (up to 20 files per transfer)
- Max 100 MB per file
- Metered network warnings:
  - Wi-Fi: warn if total > 10 MB
  - Cellular: warn if total > 5 MB
- Battery + power-save mode awareness

**Step 3 — Upload**
- Per-file progress bars with real-time updates
- SHA-256 checksum computed before upload (integrity verification)
- TUS resumable upload protocol — interrupted uploads can be resumed
- Cancellable mid-upload
- Interrupted upload recovery — if app closes mid-send, resumes automatically on relaunch

**Transfer limits:**
- 20 files per transfer
- 100 MB per file
- Transfers expire after 24 hours

---

### 4. Receive Screen

Opened automatically when a push notification arrives or when tapping a pending transfer in history.

**Features:**
- Shows all files in the transfer with sender's code
- Live sender upload progress (via Supabase Realtime subscription)
- Per-file download with progress bars
- Disk space check before downloading (50 MB safety buffer)
- Download cancellation support
- Save to device gallery (photos/videos via `gal` package)
- Tracks which files have already been downloaded (persisted across app restarts)
- Transfer status display: `pending`, `uploading`, `completed`, `partial`, `failed`, `expired`

---

### 5. History Screen

Lists all past incoming transfers:

- Shows sender code, file count, transfer status, timestamp
- Paginated (50 per page)
- Tap any transfer to re-open the Receive screen and re-download files
- Expired transfers are clearly labeled
- Pull-to-refresh

---

### 6. QR Code

- Tap **QR** on the Home screen to show your personal QR code as a bottom sheet
- On the Send screen, tap the QR scanner icon to scan another user's code
- Uses `qr_flutter` for rendering, `mobile_scanner` for scanning

---

### 7. Settings Screen

| Setting | Description |
|---------|-------------|
| Dark Mode toggle | Switches between light/dark theme, persisted |
| Push notification status | Shows whether closed-app delivery is ready (FCM token synced) |
| Reset all local data | Wipes short code, onboarding state, pending uploads, signs out of Supabase |

---

### 8. About Screen

- App name, version
- Brief description of MiniGo
- Legal/attribution info

---

### 9. Privacy Screen

- Privacy policy content displayed in-app

---

## Technical Architecture

### Backend: Supabase

| Resource | Purpose |
|----------|---------|
| `users` table | Stores user records with `auth_uid` and `short_code` |
| `transfers` table | Tracks each transfer: sender, receiver, status, upload_progress |
| Supabase Storage | File storage with TUS resumable upload support |
| Supabase Realtime | Live transfer status and upload progress subscriptions |
| Edge Functions | `send-transfer-fcm` — triggers push notification to recipient |

### Authentication

- Supabase anonymous auth (no email/password required)
- Auth UID tied to device; persisted in SharedPreferences
- If auth identity changes, stale local data is cleared

### Identity System

- On first launch: generates a unique 6-char short code using a custom alphabet (`ABCDEFGHJKMNPQRSTUVWXYZ23456789` — no ambiguous chars like O/0/I/1/L)
- Retries up to 10 times if a collision occurs
- Code + user DB ID cached locally for offline resilience

### Push Notifications: Firebase

- FCM (Firebase Cloud Messaging) for background/closed-app delivery
- Flutter Local Notifications for foreground display
- Rich incoming transfer notification style (file names, sender info)
- FCM token synced to Supabase so the edge function can target the right device

### File Transfer Pipeline

```
Sender                          Supabase                        Receiver
  │                               │                                │
  ├─ SHA-256 hash each file        │                                │
  ├─ Create transfer row ─────────►│                                │
  ├─ TUS upload (resumable) ──────►│                                │
  ├─ Update upload_progress ──────►│──── Realtime broadcast ───────►│
  ├─ Mark transfer complete ──────►│                                │
  │                               ├─ Edge fn: send-transfer-fcm ──►│ (push)
  │                               │                                ├─ Download files
  │                               │                                ├─ Verify integrity
  │                               │                                └─ Save to device
```

### Offline / Resilience

- **Connection monitoring** via `connectivity_plus` with live UI indicator
- **Interrupted upload recovery** — `PendingUploadJob` persisted before upload starts; resumed on next launch
- **Offline queue** via `OfflineSyncCoordinator`:
  - FCM token sync retried when back online
  - Push edge function retried if it failed after upload completed
- **Cached identity** — short code served from SharedPreferences when Supabase is unreachable

### Theme

- Light and dark mode
- Custom "Zen" design system (`MiniColors`, `ZenText`, `ZenTheme`)
- Google Fonts (Inter)
- Minimal, clean aesthetic

### Analytics

- Custom `Analytics` service wrapping event logging
- Events: code copied, code shared, QR shown, send initiated, transfer completed, etc.

### Crash Reporting

- Firebase Crashlytics for automatic crash capture

---

## Package Summary

| Package | Role |
|---------|------|
| `supabase_flutter` | Backend (auth, database, storage, realtime) |
| `firebase_messaging` | Push notifications |
| `firebase_crashlytics` | Crash reporting |
| `flutter_local_notifications` | In-app notification display |
| `file_picker` | Native file picker (multi-select) |
| `tus_client_dart` | Resumable file uploads |
| `qr_flutter` | QR code display |
| `mobile_scanner` | QR code scanning |
| `gal` | Save files to device gallery |
| `permission_handler` | Runtime permissions |
| `connectivity_plus` | Network connectivity detection |
| `battery_plus` | Battery level + power save mode |
| `disk_space_plus` | Available storage check |
| `crypto` | SHA-256 checksums |
| `shared_preferences` | Local key-value persistence |
| `google_fonts` | Inter typeface |
| `flutter_dotenv` | Environment variable loading |

---

## Key Constraints

- Android & iOS only (no web support)
- Max **20 files** per transfer
- Max **100 MB** per file
- Transfers expire after **24 hours**
- Files require app to be open during upload (no OS-level background uploader)
- Disk space checked before download (50 MB safety buffer reserved)

---

## Navigation Structure

```
App Launch
  └── Onboarding (first launch only)
  └── Main Shell
        ├── Tab: Home (your code, send FAB)
        ├── Tab: History (incoming transfers)
        └── Tab: Settings
              ├── About
              └── Privacy
        
        Modal / Push:
        ├── Send Screen
        │     └── QR Scanner
        ├── Receive Screen (from notification or history tap)
        └── QR Code Bottom Sheet
```
