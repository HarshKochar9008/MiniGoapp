# MiniGo — Security Test Results

Internal engineering evidence, not a third-party test report.

| | |
|---|---|
| Date | 2026-11-15 |
| App version | 1.0.0+1 |
| Source | `feat/onboarding-v2` at `649e333` plus uncommitted working-tree changes |
| Environment | Developer workstation, macOS (Darwin 25.6.0). No device, emulator or backend used. |
| Flutter / Dart | 3.47.7 stable / 3.13.5 |

## Executed

| Check | Tool | Result |
|---|---|---|
| Static analysis | `flutter analyze --no-pub` | 0 errors, 0 warnings, 2 info (`deprecated_member_use` at `notification_service.dart:214,252`). No security-relevant lints. Lint set is stock `flutter_lints`; `android/` and `ios/` are excluded. |
| Unit and widget tests | `flutter test --no-pub` | **258 passed, 0 failed.** |
| Outdated dependencies | `flutter pub outdated` | 9 direct dependencies behind latest; notable: `freerasp` 8.2.4 → 9.0.0, `flutter_secure_storage` 10.3.4 → 11.2.0 (held deliberately), `gal` 2.3.3 → 3.0.1. No vulnerability lookup performed. |
| Secret sweep, tracked files | manual `grep` for JWT, Google API key, PEM, provider-token and password patterns | No secrets. Hits were a truncated placeholder in the README, Firebase client config files, and a PEM-header regex in an edge function. |
| Secret sweep, history | `git log --all --diff-filter=A --name-only` filtered for env, keystore, key and certificate files | Only `.env.example` and Firebase client config files were ever added. Historical blob contents were not scanned. |
| `.env` contents | key names only | `SUPABASE_URL`, `SUPABASE_ANON_KEY` (publishable-format key), `USE_R2_STORAGE`. No service-role or storage secret. |
| Manual source review | — | All migrations and edge functions; crypto, identity, transfer, storage, notification, lock and reset code; Android and iOS native projects; build scripts. |

### Security-relevant tests in the suite

| File | Tests | Covers |
|---|---|---|
| `e2e_crypto_test.dart` | 16 | truncation and extension detection, format tagging |
| `safe_file_name_test.dart` | 10 | traversal, control and URL characters, length |
| `app_security_test.dart` | 12 | tamper config matches build files, threat handling, log redaction, lock screen |
| `app_lock_test.dart` | 6 | lock state and gate |
| `identity_lifecycle_test.dart` | 16 | saved identity, retirement queue, reset |
| `transfer_status_test.dart` | 19 | status parsing, client TTL, transitions |
| `save_file_test.dart` | 8 | saving received files |
| `room_lifecycle_test.dart` | 23 | room expiry, share permission |

There are no tests for the SQL policies, triggers or edge functions.

## Not run

| Check | Reason |
|---|---|
| osv-scanner, gitleaks, semgrep, trivy | Not installed on the workstation. |
| MobSF (static or dynamic) | Not installed; no built artefact analysed. |
| OWASP ZAP, Burp Suite, any API request | No staging backend or test accounts. The only linked project is production. |
| SQL policy tests (pgTAP or `supabase test db`) | None exist; no local database was started. |
| Device tests (Android, iOS) | Not in scope of a read-only source audit. |
| MASTG dynamic test cases | As above. |

## Limitations

- Findings are derived from source. The deployed database, storage buckets, scheduled jobs, function secrets and dashboard settings were not inspected and may differ.
- Two findings (MG-10 URL leakage, MG-15 Photos access) are inferred from code and library behaviour and were not reproduced.
- A clean result from the checks above is not evidence of security; most of the findings in this audit are design and configuration gaps that no scanner here would report.

## To reproduce

```
flutter analyze --no-pub
flutter test --no-pub
flutter pub outdated
```

The staging test cases T1–T17 are listed in `API_SECURITY_REPORT.md` §5.
