# MiniGo — iOS Security Report

Audit date 2026-11-15 · app 1.0.0+1 · bundle id `com.zen.app` · internal engineering evidence.

Sources: `ios/Runner/Info.plist`, `AppDelegate.swift`, `project.pbxproj`, `Podfile`, and the Swift Package Manager plugin packages on disk. Nothing was built or run.

## Status: not submittable as configured (MG-04)

| Gap | Evidence | Effect |
|---|---|---|
| No signing team | no `DEVELOPMENT_TEAM` in `project.pbxproj` | Cannot archive for distribution. |
| No entitlements file | none under `ios/Runner` | No `aps-environment`: push registration fails, although `remote-notification` background mode is declared. |
| No URL scheme | no `CFBundleURLTypes`; no URL handling in `AppDelegate.swift` | QR codes and share links cannot open the iOS app. |
| No app-level privacy manifest | no `PrivacyInfo.xcprivacy`, no reference in the project | Required-reason APIs used from app code are undeclared. |
| Runtime protection off | `appleTeamId = null` in `rasp_config.dart` | No tamper or jailbreak detection on iOS. |
| Export-compliance flag | `ITSAppUsesNonExemptEncryption = false` | The app performs its own X25519/AES-GCM encryption with a Dart library, outside the OS. The flag needs a deliberate decision before upload. |
| Share-sheet intake, widget | not implemented on iOS | Feature gap versus Android, not a vulnerability. |

## Info.plist

| Key | Value | Assessment |
|---|---|---|
| NSFaceIDUsageDescription | "MiniGo uses Face ID to unlock the app when App lock is on." | Accurate. |
| NSCameraUsageDescription | "MiniGo uses the camera to scan recipient QR codes." | Accurate. |
| NSPhotoLibraryAddUsageDescription | saving received images and videos | Accurate. |
| NSPhotoLibraryUsageDescription | "…to save received media files." | The code requests add-only access, but saving into a named album needs read-write access. Either the save fails or a full-library prompt appears whose stated reason does not explain reading (MG-15). |
| NSAppTransportSecurity | absent | Defaults apply; no exceptions. Good. |
| UIFileSharingEnabled, LSSupportsOpeningDocumentsInPlace | true | Received non-media files in `Documents/MiniGo` are visible in Files and Finder and included in iCloud and local backups (MG-15). |
| UIBackgroundModes | `remote-notification` | Justified by push, once the entitlement exists. |
| Supported devices | iPhone and iPad; iPad in all orientations | Confirm iPad support is intended; the app is designed for portrait phones. |

No microphone, location, contacts, Bluetooth, local-network or tracking keys, and no code requesting them.

## Data protection

- Private key: Keychain through `flutter_secure_storage` with default accessibility (plugin defaults not verified).
- Session tokens: `UserDefaults` (MG-11).
- Files: default protection class; no backup exclusion.
- Decrypted images and videos remain in the temp directory after saving so Quick Look can preview them.

## Native code

`AppDelegate.swift` implements a text share sheet and `openFile` (Quick Look on a path supplied by Dart, with no containment check; the single caller passes paths it created).

## Dependencies

Plugins are integrated with Swift Package Manager; `Podfile.lock` lists only Flutter and SDWebImage, and the Podfile's Firebase pin and permission macros no longer have any effect. Most plugins ship a privacy manifest. `audioplayers_darwin`, `firebase_core` and `firebase_crashlytics` wrappers do not (the upstream Firebase SDK manifests were not checked). `disk_space_plus` ships a manifest that declares no disk-space reason.

## Release build settings

Optimised Swift, assertions off, dSYMs on, bitcode off, deployment target 15.5. No debug-only flags in Release.

## Not tested

Anything on a device or simulator; Keychain accessibility defaults; upstream Firebase privacy manifests and SDK signatures; the export-compliance outcome (a compliance decision for the owner).
