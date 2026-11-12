# MiniGo Command Guide

Quick command reference for local development, debugging, cleaning, building, and dependency management.

***

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

***

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

***

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

***

## 4) Hot reload / restart (from running terminal)

While `flutter run` is active:

- `r` -> hot reload
- `R` -> hot restart
- `q` -> quit app run

***

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

***

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

***

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

***

## 8) Build commands

Every release build needs `android/key.properties` pointing at the upload keystore (`~/keystores/minigo-upload.jks`). Without it the build stops with an error instead of signing with the debug key, because freeRASP would treat a debug-signed release as tampered and lock it (see section 13). Debug and profile builds don't need it.

Release builds are obfuscated. `--split-debug-info` writes the symbol files that turn obfuscated stack traces back into readable ones. Upload them to Crashlytics after every release build (commands below), and keep them for `flutter symbolize`. `flutter clean` deletes `build/`.

Android APK (debug):

```bash
flutter build apk --debug
```

Android APK (release, for direct install/sideload — one APK per CPU architecture, roughly half the size of a fat APK):

```bash
flutter build apk --release --split-per-abi -Psplit-per-abi \
  --obfuscate --split-debug-info=build/symbols/android
```

Install `app-arm64-v8a-release.apk` on modern phones (2017+); `app-armeabi-v7a-release.apk` covers older 32-bit devices.

Android APK (release, single fat APK — only when you need one file that works everywhere; contains both ARM ABIs, x86_64 is stripped automatically):

```bash
flutter build apk --release --target-platform android-arm,android-arm64 \
  --obfuscate --split-debug-info=build/symbols/android
```

(`--target-platform` also skips compiling the unused x86_64 Dart snapshot, so the build is faster.)

Latest release APK: run the command above, then install or copy it from `build\app\outputs\flutter-apk`. On Windows, build and open that folder in one step:

```powershell
flutter build apk --release --split-per-abi -Psplit-per-abi; explorer build\app\outputs\flutter-apk
```

Android App Bundle (Play Store) — before the first Play upload, add Play's app-signing hash (section 13):

```bash
flutter build appbundle --release --obfuscate --split-debug-info=build/symbols/android
firebase crashlytics:symbols:upload --app=1:454168249027:android:1a50dcafc57eaf2a055876 build/symbols/android
```

The bundle is at `build/app/outputs/bundle/release/app-release.aab`.

Tester build to phones through Firebase App Distribution (builds an obfuscated release APK, uploads it, then uploads its symbols):

```bash
tool/distribute_android.sh "what changed"
```

iOS archive for App Store / TestFlight — needs the Apple Team ID set (section 13) and signing configured in Xcode:

```bash
flutter build ipa --release --obfuscate --split-debug-info=build/symbols/ios
firebase crashlytics:symbols:upload --app=1:454168249027:ios:44ccd27ada64874d055876 build/symbols/ios
```

The archive is at `build/ios/archive/Runner.xcarchive`, and the `.ipa` to upload is in `build/ios/ipa/`.

iOS release build without signing (checks that it compiles, can't be installed):

```bash
flutter build ios --release --no-codesign
```

***

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

***

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

***

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

***

## 12) Windows command notes

- Use `rd /s /q <folder>` to delete directories.
- Use `copy` for file duplication.
- Run terminal as normal user (admin not required for Flutter commands).

***

## 13) App security (freeRASP)

freeRASP checks at runtime that the app is a genuine, unmodified MiniGo. All of its settings live in `lib/core/security/rasp_config.dart`. Release builds run the full checks, and if a copy has been re-signed or hooked (Frida etc.) it stops transfers and asks the user to reinstall. Debug and profile builds skip the emulator, debugger, signing and install-source checks and never lock.

### Required before launch

**1. Add Google Play's app-signing hash.** Play re-signs every bundle with its own key, so Play installs carry a different certificate from the upload key. Without its hash, every Play install locks itself. In Play Console go to Test and release → App integrity → App signing key certificate and copy the SHA-256. Convert it to Base64:

```bash
echo -n "AB:CD:EF:...:12" | tr -d ':' | xxd -r -p | base64
```

Add the result to `androidSigningCertHashes` in `rasp_config.dart`.

**2. Set the Apple Team ID.** Copy it from developer.apple.com → Membership (10 characters) into `appleTeamId` in `rasp_config.dart`. Until then freeRASP doesn't run on iOS.

### Signing hashes

Base64 SHA-256 of a keystore's certificate (prompts for the keystore password):

```bash
keytool -exportcert -alias upload -keystore ~/keystores/minigo-upload.jks | openssl dgst -sha256 -binary | base64
```

The upload key gives `Kc7AipIQbtelZKj1tc0fLorA1X8UKORuDq4LwDbiv/k=`, which is already in `rasp_config.dart`. If the upload key is ever replaced, add the new hash before shipping builds signed with it.

Check which certificate a built APK carries:

```bash
~/Library/Android/sdk/build-tools/36.0.0/apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk
```

It prints the SHA-256 as hex. Convert it with the `xxd | base64` command above, and it must match a hash in `rasp_config.dart`.

### Verify

Security tests (config matches the build files, every threat is handled, critical threats block transfers, the lock screen shows):

```bash
flutter test test/app_security_test.dart
```

freeRASP running in a debug build on an Android device or emulator:

```bash
~/Library/Android/sdk/platform-tools/adb logcat -s flutter | grep security_
```

Expect `security_rasp_started {prod: false}` and then `security_checks_finished`. On iOS, `security_rasp_unavailable {reason: not_configured}` means the Team ID isn't set.

Tamper response: re-sign a release APK with a different key, install it, and the app should open on "Reinstall MiniGo". Installing it means uninstalling MiniGo first, which deletes that device's identity, so use a throwaway emulator, never a phone or emulator you use for testing.

```bash
~/Library/Android/sdk/build-tools/36.0.0/apksigner sign --ks ~/.android/debug.keystore \
  --ks-pass pass:android --ks-key-alias androiddebugkey \
  --out /tmp/tampered.apk build/app/outputs/flutter-apk/app-release.apk
~/Library/Android/sdk/platform-tools/adb install /tmp/tampered.apk
```

