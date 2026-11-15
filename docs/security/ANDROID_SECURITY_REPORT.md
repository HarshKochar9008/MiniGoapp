# MiniGo — Android Security Report

Audit date 2026-11-15 · app 1.0.0+1 · package `com.Zen.app` · internal engineering evidence.

Sources: `android/app/src/main/AndroidManifest.xml`, Gradle files, Kotlin sources, `res/xml`, and the existing merged release manifest in `build/` (built 2026-11-15, not regenerated). Nothing was run on a device.

## Build configuration

| Item | Value | Assessment |
|---|---|---|
| compileSdk / targetSdk / minSdk | 37 / 36 / 24 | Meets current Play target-API requirements. |
| `debuggable` | not set; absent from release manifest | OK |
| Minify / shrink | R8 on, resources shrunk | OK. Keep rules are broad (`io.flutter.**`, `com.google.firebase.**`). |
| Dart obfuscation | `--obfuscate --split-debug-info` in `tool/distribute_android.sh` | OK. Symbols are uploaded to Crashlytics. |
| Signing | `android/key.properties` (ignored, never committed) → keystore outside the repo | OK. A release variant can be debug-signed when built through a task name without "Release" (MG-25). |
| Cleartext | no `usesCleartextTraffic`, no network security config | Platform default: cleartext off, user CAs untrusted. |
| Backup | `allowBackup=false`; data-extraction rules exclude everything for cloud and device transfer | OK |
| Secrets | none in the project. `google-services.json` is tracked: Firebase client config, not a server secret. | Confirm the API key is restricted in Google Cloud (not tested). |

## Components

| Component | Exported | Notes |
|---|---|---|
| `MainActivity` | yes | Launcher; `minigo://send` (BROWSABLE); `SEND` and `SEND_MULTIPLE` for `*/*`. `singleTask`, empty `taskAffinity`. |
| `MinigoWidgetProvider` | yes (required for widgets) | Handles a copy action from any sender (MG-24). |
| Firebase messaging receivers | yes, permission-guarded | Standard. |
| Services, providers | not exported | `share_plus` FileProvider limited to `cache/share_plus/`. |

No WebView in app code.

## Intent and deep-link handling

- **Deep link.** Custom scheme only; no verified App Links. Dart validates scheme, host and code format, then opens the Send screen with the recipient prefilled. Nothing is sent without the user choosing files and swiping. Another app could register the same scheme (low impact).
- **Share intake.** Only `content://` URIs are accepted and the app's own providers are rejected, which blocks an attacker pointing the app at its own private files. Names are sanitised and prefixed. **The copy is unbounded** and starts without confirmation (MG-19). A URI on a third-party provider that MiniGo can read and the caller cannot would be accepted; the user must still pick a recipient.
- **Native method channels.** `saveToMediaStore` and `openFile` rely on the Dart caller for validation (MG-24). The single caller sanitises today.

## Permissions

| Permission | Needed | Action |
|---|---|---|
| INTERNET | yes | — |
| CAMERA | yes (QR scanning) | Declare in Data safety; feature marked not required. |
| POST_NOTIFICATIONS | yes | — |
| WRITE_EXTERNAL_STORAGE (≤ API 29) | yes, legacy save path | — |
| READ_MEDIA_IMAGES, READ_MEDIA_VIDEO | **no** | Remove (MG-13). Restricted by Play's photo and video permissions policy. |
| READ_EXTERNAL_STORAGE (≤ API 32) | **no** | Remove (MG-13). |
| Added by plugins | ACCESS_NETWORK_STATE, WAKE_LOCK, VIBRATE, USE_BIOMETRIC, RECEIVE_BOOT_COMPLETED, others | Normal-level. `<queries>` from the runtime-protection SDK include a bare `MAIN` intent and SMS/call intents, giving broad package visibility; be ready to explain it in review. |

Absent: MANAGE_EXTERNAL_STORAGE, QUERY_ALL_PACKAGES, REQUEST_INSTALL_PACKAGES, exact alarms, full-screen intent, foreground services.

## Runtime protection

freeRASP runs in release builds. Tampering and hooking restrict the app; root, emulator, debugger and sideloading are logged only.

**Launch blocker (MG-03):** only the upload certificate is pinned. Play-signed installs will be treated as tampered and locked until the Play app-signing certificate hash is added.

## Screen and local data

- No `FLAG_SECURE`; the app can be screenshotted and appears in recents except while paused under the lock (MG-20).
- The home-screen widget shows the user's code, read from SharedPreferences.
- Session tokens are in SharedPreferences (MG-11); the private key is in the Keystore.

## Findings affecting Android

MG-03 (P1), MG-06 (P1), MG-11, MG-13 (P2), MG-19, MG-20, MG-24 (P3), MG-25, MG-30 (P4). Details and fixes: `VULNERABILITY_REMEDIATION_LOG.md`.

## Not tested

Device behaviour; a freshly merged manifest; the keystore itself and whether its hash matches the pinned value; Firebase key restrictions; binary analysis of the built APK (MobSF not installed).
