# MiniGo — Third-Party SDK and Processor Inventory

Audit date 2026-11-15 · app 1.0.0+1 · from `pubspec.yaml` / `pubspec.lock` (176 hosted packages, all from pub.dev; no git or path dependencies, no overrides).

No vulnerability scan was run against these versions (see `SECURITY_TEST_RESULTS.md`).

## Data processors

| Processor | Via | Data received | In the privacy policy |
|---|---|---|---|
| Supabase | `supabase_flutter` 2.18.3; edge functions | Account id, code, public key, nickname, push token, transfer and room records, file metadata, stored objects, IP and request logs | Yes (hash, MIME type, rooms and logs not itemised) |
| Cloudflare R2 | presigned URLs, when `USE_R2_STORAGE=true` | Encrypted file bytes, object keys containing the file name, IP | Yes |
| Google — Firebase Cloud Messaging | `firebase_messaging` 17.0.1; `send-transfer-fcm` | Push token, installation id, transfer id, sender code, generic text | Yes |
| Google — Crashlytics | `firebase_crashlytics` 6.0.1 | Crash data, device and app info, account id, code, activity trail. Off in debug builds. | Yes |
| Talsec | `freerasp` 8.2.4 (closed-source runtime) | Security telemetry, device and app identifiers; reports go to the configured watcher mailbox | **No** — add (MG-14) |
| Apple | iTunes lookup, iOS, user-initiated | Bundle id, country, IP | No |
| Google — Firebase App Distribution | tester builds only | Tester accounts | Not applicable to store builds |

## Direct dependencies

| Package | Version | Purpose | Native code | Sends data off device |
|---|---|---|---|---|
| supabase_flutter | 2.18.3 | Auth, database, storage, realtime | via plugins | Yes |
| http | 1.6.0 | HTTP client | no | — |
| tus_client_dart | 2.5.0 | Resumable uploads | no | Yes (to storage) |
| cryptography | 2.9.0 | X25519, HKDF, AES-GCM | no | No |
| crypto | 3.0.8 | SHA-256 | no | No |
| flutter_secure_storage | 10.3.4 | Private key in Keystore / Keychain | yes | No |
| shared_preferences | 2.5.6 | Local settings and session | yes | No |
| firebase_core | 5.1.0 | Firebase initialisation | yes | Yes |
| firebase_crashlytics | 6.0.1 | Crash reporting | yes | Yes |
| firebase_messaging | 17.0.1 | Push | yes | Yes |
| flutter_local_notifications | 22.3.3 | Local notifications | yes | No |
| freerasp | 8.2.4 | Runtime protection | yes (vendor binary) | Yes |
| local_auth | 3.0.2 | App lock | yes | No |
| file_picker | 13.3.2 | Choosing files | yes | No |
| gal | 2.3.3 | Save to gallery (iOS path) | yes | No |
| permission_handler | 13.0.2 | Runtime permissions | yes | No |
| mobile_scanner | 7.5.0 | QR scanning (ML Kit on Android) | yes | Not verified |
| qr_flutter | 4.1.0 | QR rendering | no | No |
| share_plus | 13.3.1 | Share sheet | yes | No |
| url_launcher | 6.3.3 | Links, mailto | yes | No |
| path_provider | 2.1.6 | Directories | yes | No |
| connectivity_plus | 7.3.1 | Network state | yes | No |
| battery_plus | 7.1.2 | Battery state | yes | No |
| disk_space_plus | 0.2.8 | Free space | yes | No |
| package_info_plus | 10.2.2 | Version info | yes | No |
| audioplayers | 6.8.1 | Onboarding sounds | yes | No |
| google_fonts | 9.0.0 | Fonts (bundled; runtime fetching off) | no | No |
| lucide_icons_flutter | 4.0.2 | Icons | no | No |
| glossy | 0.0.5 | Frosted-glass widget | no | No |
| flutter_dotenv | 6.0.1 | Loads bundled `.env` | no | No |
| mime, cross_file | 2.1.0, 0.3.5+5 | Helpers | no | No |

## Backend dependencies

Edge functions import `@supabase/supabase-js@2.49.1` and `aws4fetch@1.0.20` from `esm.sh`. Versions are pinned but there is no lockfile or integrity hash, so transitive resolution happens at deploy time (MG-16).

## Notes for review

- `glossy` 0.0.5 and `disk_space_plus` 0.2.8 are small single-maintainer packages. `glossy` is one pure-Dart file and could be vendored.
- `freerasp` is a closed binary from the vendor's own Maven repository and is one major version behind.
- `flutter_secure_storage` is held at 10.x on purpose; 11.x cannot read keys written by 9.x installs.
- iOS plugins resolve through Swift Package Manager; the Podfile is not the iOS inventory.
- Android `<queries>` added by the runtime-protection SDK give broad package visibility; the app logs only a count of suspicious apps, never which.
