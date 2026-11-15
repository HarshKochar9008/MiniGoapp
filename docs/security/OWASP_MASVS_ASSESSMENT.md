# MiniGo — OWASP MASVS Assessment

Audit date 2026-11-15 · app 1.0.0+1 · reference: OWASP MASVS v2 control groups.

**This is a self-assessment by source review. It is not an OWASP certification and makes no claim of formal compliance.** MASTG dynamic test cases were not executed (no device or staging backend); where a control needs runtime evidence the result is PARTIAL or NOT TESTED.

Results: PASS · PARTIAL · FAIL · NOT TESTED. Finding IDs refer to `SECURITY_AUDIT_REPORT.md`.

| Control | Requirement | Current implementation | Verification | Result | Evidence | Remediation |
|---|---|---|---|---|---|---|
| MASVS-STORAGE-1 | Sensitive data stored securely | Private key in Keystore/Keychain. Session tokens, own code, contacts, pending-upload job in SharedPreferences. Android backup disabled. | Source review | PARTIAL | `e2e_crypto.dart:69-95`; `supabase_config.dart:44-55`; `AndroidManifest.xml:27-28` | MG-11 |
| MASVS-STORAGE-2 | No leakage of sensitive data | Debug-only logging; file names redacted from crash reports. Error text may carry signed URLs to the database and Crashlytics; iOS saves decrypted files to a backed-up, shared folder; plaintext source copies linger in cache. | Source review | PARTIAL | `analytics.dart:89-102`; `transfer_service.dart:1578,2432`; `Info.plist:75-78` | MG-10, MG-15, MG-19, MG-21 |
| MASVS-CRYPTO-1 | Strong, standard cryptography | X25519, HKDF-SHA256, AES-256-GCM via `cryptography` 2.9.0; SHA-256 via `crypto`. No custom algorithms. Per-chunk nonce and AAD; truncation detected (v2). Legacy v1 still accepted on decrypt. | Source review; `test/e2e_crypto_test.dart` (16 tests pass) | PASS | `e2e_crypto.dart` | Retire v1 once no in-flight transfers can use it |
| MASVS-CRYPTO-2 | Key management | Random per-file content key sealed to recipient key; private key never leaves the device. Recipient public key is taken from the server unverified; no key-change warning. | Source review | PARTIAL | `send_destination.dart:112-116` | MG-09 |
| MASVS-AUTH-1 | Secure authentication protocol | Supabase anonymous auth (JWT, refresh rotation). No credentials to steal; identity is device-bound. | Source review; server config NOT TESTED | PARTIAL | `identity_service.dart`; `supabase/config.toml` (local values only) | MG-18 |
| MASVS-AUTH-2 | Local authentication | Optional app lock via `local_auth` with passcode fallback; UI overlay, preference-backed flag, 60 s grace. | Source review; `test/app_lock_test.dart` | PARTIAL | `app_lock.dart` | MG-20 |
| MASVS-AUTH-3 | Step-up for sensitive operations | Turning the lock off requires authentication. Account deletion requires confirmation only. | Source review | PARTIAL | `privacy_screen.dart:67-71,344-384` | Optional |
| MASVS-NETWORK-1 | Secure network traffic | HTTPS enforced for the backend URL; no cleartext; no TLS overrides; default trust store. | Source review (grep for `badCertificateCallback`, `http://`) | PASS | `supabase_config.dart:30-42` | — |
| MASVS-NETWORK-2 | Identity pinning | None. Acceptable given E2E encryption of content; metadata relies on the system trust store. | Source review | NOT IMPLEMENTED (optional control) | — | Consider for a later release |
| MASVS-PLATFORM-1 | Secure IPC | Exported launcher activity with validated deep-link and share intake; own providers rejected. Share copy is unbounded; widget receiver accepts a copy action from any app; native handlers trust Dart arguments. | Source review | PARTIAL | `MainActivity.kt:196-272`; `MinigoWidgetProvider.kt:27-44` | MG-19, MG-24 |
| MASVS-PLATFORM-2 | Secure WebViews | No WebView in app code. | Source review | PASS | grep | — |
| MASVS-PLATFORM-3 | Secure UI | No `FLAG_SECURE`; recents blanked only while paused; no tapjacking filter. | Source review | PARTIAL | `app_lock.dart:141-143` | MG-20 |
| MASVS-CODE-1 | Up-to-date platform | compileSdk 37, targetSdk 36, minSdk 24; iOS deployment target 15.5. | Build files, merged manifest | PASS | `build.gradle.kts`; `project.pbxproj` | — |
| MASVS-CODE-2 | Enforced updating | No forced-update mechanism. | Source review | NOT IMPLEMENTED | `update_check.dart` | Consider a minimum-version check |
| MASVS-CODE-3 | No known-vulnerable components | 176 hosted packages, no git/path dependencies. No vulnerability scan was run. | `flutter pub outdated` only | NOT TESTED | `pubspec.lock` | MG-16 |
| MASVS-CODE-4 | Validate untrusted input | File names sanitised at sender, database and receiver; download size capped while streaming; chunk size bounded; deep-link code validated; push payload used only for navigation. | Source review; `safe_file_name_test.dart`, `save_file_test.dart` | PASS | `safe_file_name.dart`; `transfer_service.dart:2333-2353` | MG-24 (defence in depth) |
| MASVS-RESILIENCE-1 | Platform integrity checks | freeRASP on Android (root, emulator, hooks). Disabled on iOS. | Source review; `app_security_test.dart` | PARTIAL | `rasp_config.dart:42` | MG-04 |
| MASVS-RESILIENCE-2 | Anti-tampering | Signing-certificate pinning; Play certificate missing, which will lock genuine Play installs. | Source review | FAIL | `rasp_config.dart:19-28` | MG-03 |
| MASVS-RESILIENCE-3 | Anti-static-analysis | R8 with resource shrinking; Dart `--obfuscate --split-debug-info` in the release script. Broad keep rules. | Build files | PASS | `build.gradle.kts:96-101`; `distribute_android.sh:57-58` | — |
| MASVS-RESILIENCE-4 | Anti-dynamic-analysis | Hook/debugger detection restricts the app in release builds (Android). | Source review | PARTIAL | `app_security.dart:90-114` | MG-04 for iOS |
| MASVS-PRIVACY-1 | Data minimisation | No name, email, phone, contacts, location or advertising id. Collects code, optional nickname, push token, file metadata, crash data with user id. | Source review | PARTIAL | `legal_screens.dart:41-67` | MG-21, MG-22 |
| MASVS-PRIVACY-2 | Unlinkability | Stable user id and code attached to every crash report. | Source review | PARTIAL | `analytics.dart:31-33` | MG-21 |
| MASVS-PRIVACY-3 | Transparency | In-app policy exists but omits a processor and misstates several behaviours; no hosted copy. | Source review | FAIL | `legal_screens.dart` | MG-05, MG-14 |
| MASVS-PRIVACY-4 | User control | In-app deletion exists but is a soft retire; no way to remove received transfers or block senders. | Source review | PARTIAL | `app_reset.dart:158-167` | MG-01, MG-23 |

## Summary

PASS 7 · PARTIAL 12 · FAIL 2 · NOT TESTED 1 · optional control not implemented 2.

The two FAIL results (anti-tampering configuration and privacy transparency) are release blockers. The PARTIAL results are mostly hardening, with MG-11 and MG-10 the most worthwhile.
