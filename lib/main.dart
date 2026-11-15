import 'dart:async';

import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/analytics/analytics.dart';
import 'core/notifications/fcm_background.dart';
import 'core/notifications/notification_service.dart';
import 'core/security/app_lock.dart';
import 'core/security/app_security.dart';
import 'core/supabase_config.dart';
import 'core/theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  // Every screen is laid out for an upright phone, and several cannot be
  // used on their side (the onboarding lever, the bottom nav). The manifest
  // and Info.plist say the same; this covers whatever they don't. Not
  // awaited: the first frame must not wait on a platform round trip.
  unawaited(
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]),
  );

  // The fonts ship in assets/google_fonts/: never download them, so first
  // launch costs no data and text renders offline or where Google is blocked.
  GoogleFonts.config.allowRuntimeFetching = false;
  LicenseRegistry.addLicense(_fontLicenses);

  try {
    await dotenv.load(fileName: '.env');
  } catch (_) {}

  try {
    await Firebase.initializeApp();
    // Disable collection in debug so dev noise doesn't pollute the dashboard.
    await FirebaseCrashlytics.instance
        .setCrashlyticsCollectionEnabled(!kDebugMode);
    FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;
    PlatformDispatcher.instance.onError = (error, stack) {
      FirebaseCrashlytics.instance
          .recordError(redactForReport(error), stack, fatal: true);
      return true;
    };
  } catch (_) {
    // Firebase is optional during local/dev setup without google-services files.
  }

  Analytics.instance.init();
  Analytics.instance.logEvent(AnalyticsEvents.appOpened);

  // After Firebase and Analytics so findings reach Crashlytics; before
  // runApp so a tampered or hooked copy never shows the app (see
  // AppSecurity).
  await AppSecurity.instance.start();

  try {
    await initSupabase();
  } catch (e) {
    if (kDebugMode) debugPrint('Supabase init failed during startup: $e');
  }

  // Load the saved theme before the first frame — otherwise dark-mode users
  // get a flash of the light theme on every cold start.
  try {
    await ThemeController.load();
  } catch (_) {}

  // Before the first frame, so an app with the lock on never shows behind it.
  await AppLock.initialize();

  runApp(const MiniGoApp());
  unawaited(_initializeServices());
}

Future<void> _initializeServices() async {
  try {
    // First run: the onboarding permissions step asks, with context, instead
    // of an OS prompt landing on top of the welcome screen. A first run that
    // finishes onboarding sets notifications up from there (see _AppEntry).
    // The auth listener is not waited on here: initSupabase() starts it.
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('onboarding_complete') ?? false) {
      await NotificationService.initialize();
    }
  } catch (e) {
    if (kDebugMode) debugPrint('Background service initialization failed: $e');
  }
}

/// The bundled fonts' SIL Open Font Licenses, for Settings → About → Licenses.
Stream<LicenseEntry> _fontLicenses() async* {
  for (final (family, file) in const [
    ('Outfit', 'Outfit'),
    ('JetBrains Mono', 'JetBrainsMono'),
  ]) {
    final text =
        await rootBundle.loadString('assets/google_fonts/$file-OFL.txt');
    yield LicenseEntryWithLineBreaks([family], text);
  }
}
