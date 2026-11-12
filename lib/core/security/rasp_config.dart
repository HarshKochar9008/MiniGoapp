import 'package:flutter/foundation.dart';
import 'package:freerasp/freerasp.dart';

import '../constants.dart';

/// What freeRASP checks a running copy of MiniGo against. A copy that doesn't
/// match — re-signed, renamed, or installed from elsewhere — reports a threat.
///
/// A wrong value here locks genuine users out (see `AppSecurity`), so each one
/// is the real identifier and nothing is filled in speculatively.
abstract final class RaspConfig {
  /// `applicationId` in android/app/build.gradle.kts.
  static const androidPackageName = 'com.Zen.app';

  /// Base64 SHA-256 of each certificate a genuine Android build is signed
  /// with. For a keystore:
  /// `keytool -exportcert -alias ALIAS -keystore FILE.jks |
  /// openssl dgst -sha256 -binary | base64`
  static const androidSigningCertHashes = [
    // Upload key (minigo-upload.jks, CN=MiniGo, SHA-256 29:CE:C0:…:BF:F9).
    // Signs every APK built here, including App Distribution builds.
    'Kc7AipIQbtelZKj1tc0fLorA1X8UKORuDq4LwDbiv/k=',
    // TODO(launch): Google Play re-signs uploads with its own app-signing
    // key. Add that certificate's hash (Play Console → Test and release →
    // App integrity → App signing key certificate → SHA-256, converted to
    // Base64) before the first Play release, or every Play install reports
    // appIntegrity and locks itself.
  ];

  /// Installers that count as official besides Google Play and Huawei
  /// AppGallery, which freeRASP trusts already. Testers install through
  /// Firebase App Distribution (tool/distribute_android.sh).
  static const androidSupportedStores = ['dev.firebase.appdistribution'];

  /// `PRODUCT_BUNDLE_IDENTIFIER` of the Runner target.
  static const iosBundleIds = ['com.zen.app'];

  /// Apple Developer Team ID (10 characters, developer.apple.com →
  /// Membership). Null until MiniGo has an Apple Developer account: freeRASP
  /// stays off on iOS rather than run against a guessed team, which it would
  /// report as tampering on every genuine install.
  static const String? appleTeamId = null;

  /// Receives Talsec's security reports, and is the Talsec Portal login.
  static const watcherMail = AppConstants.supportEmail;

  /// Release builds run the full checks. Debug and profile builds use
  /// freeRASP's dev mode, which skips the emulator, debugger, signature,
  /// install-source, obfuscation, developer-mode and ADB checks.
  static const isProd = kReleaseMode;

  /// The config for this platform, or null when this platform isn't set up
  /// yet (iOS without [appleTeamId]).
  static TalsecConfig? build() {
    final teamId = appleTeamId;
    if (defaultTargetPlatform == TargetPlatform.iOS && teamId == null) {
      return null;
    }
    return TalsecConfig(
      // Each platform verifies only its own section, so both can be built
      // everywhere.
      androidConfig: AndroidConfig(
        packageName: androidPackageName,
        signingCertHashes: androidSigningCertHashes,
        supportedStores: androidSupportedStores,
      ),
      iosConfig: teamId == null
          ? null
          : IOSConfig(bundleIds: iosBundleIds, teamId: teamId),
      watcherMail: watcherMail,
      isProd: isProd,
      // Kill the app if the callback channel itself is tampered with. Off in
      // dev mode, where hot restart re-attaches callbacks on purpose.
      killOnBypass: isProd,
    );
  }
}
