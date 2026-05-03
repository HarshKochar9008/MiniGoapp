# Whoosh Command Guide

Quick command reference for local development, debugging, cleaning, building, and dependency management.

Run all commands from the project root:

`D:\Snapit\neosapien_share`

---

## 1) First-time setup

```bash
flutter --version
flutter doctor -v
flutter pub get
```

Create local env file (if missing):

```bash
copy .env.example .env
```

---

## 2) Run the app

Run normally:

```bash
flutter run
```

Run with explicit Supabase defines:

```bash
flutter run --dart-define=SUPABASE_URL=https://<project-ref>.supabase.co --dart-define=SUPABASE_ANON_KEY=<anon-key>
```

Run in release mode (faster runtime profiling):

```bash
flutter run --release
```

Run on a specific device:

```bash
flutter run -d <device-id>
```

---

## 3) Devices and emulators

List connected devices:

```bash
flutter devices
```

List available emulators:

```bash
flutter emulators
```

Launch an emulator:

```bash
flutter emulators --launch <emulator-id>
```

---

## 4) Hot reload / restart (from running terminal)

While `flutter run` is active:

- `r` -> hot reload
- `R` -> hot restart
- `q` -> quit app run

---

## 5) Clean cache and rebuild

Standard clean:

```bash
flutter clean
flutter pub get
```

Deep clean (safe, rebuilds generated files):

```bash
flutter clean
rd /s /q .dart_tool
rd /s /q build
flutter pub get
```

Repair global pub cache (if package cache is corrupted):

```bash
flutter pub cache repair
```

---

## 6) Dependency commands

Get dependencies:

```bash
flutter pub get
```

Show outdated packages:

```bash
flutter pub outdated
```

Upgrade dependencies within constraints:

```bash
flutter pub upgrade
```

Upgrade to latest resolvable versions:

```bash
flutter pub upgrade --major-versions
```

---

## 7) Code quality and tests

Static analysis:

```bash
flutter analyze
```

Run tests:

```bash
flutter test
```

Run a specific test file:

```bash
flutter test test/<file_name>_test.dart
```

---

## 8) Build commands

Android APK (debug):

```bash
flutter build apk --debug
```

Android APK (release):

```bash
flutter build apk --release
```

Latest release APK: run the command above, then install or copy `build\app\outputs\flutter-apk\app-release.apk`. On Windows, build and open that folder in one step:

```powershell
flutter build apk --release; explorer build\app\outputs\flutter-apk
```

Android App Bundle (Play Store):

```bash
flutter build appbundle --release
```

iOS release build:

```bash
flutter build ios --release
```

---

## 9) Firebase / notifications helpers

If Android build fails after Firebase config changes:

```bash
flutter clean
flutter pub get
flutter run
```

Confirm required Firebase files exist:

- `android/app/google-services.json`
- `ios/Runner/GoogleService-Info.plist`

---

## 10) Supabase quick commands (SQL via dashboard)

This project uses Supabase for auth, DB, and storage. Common checks:

1. Auth -> enable **Anonymous sign-ins**
2. Storage -> bucket `transfers` exists
3. Database -> RLS policies exist for `users`, `transfers`, `transfer_files`

If transfer uploads fail due to bucket/policies, run:

```bash
scripts/recreate_transfers_bucket.sql
```

Use that file content in Supabase SQL Editor.

---

## 11) Useful troubleshooting sequence

```bash
flutter clean
flutter pub get
flutter analyze
flutter test
flutter run -d <device-id>
```

If startup still hangs:

1. Open app -> **Run diagnostics**
2. Verify DNS + Auth health result
3. Test on Wi-Fi and mobile data both
4. Re-check `.env` and `--dart-define` values

---

## 12) Windows command notes

- Use `rd /s /q <folder>` to delete directories.
- Use `copy` for file duplication.
- Run terminal as normal user (admin not required for Flutter commands).

