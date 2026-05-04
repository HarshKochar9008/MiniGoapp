import 'dart:async';

import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'app.dart';
import 'core/notifications/fcm_background.dart';
import 'core/notifications/notification_service.dart';
import 'core/supabase_config.dart';
import 'core/theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  try {
    await dotenv.load(fileName: '.env');
  } catch (_) {}

  try {
    await Firebase.initializeApp();
    // Disable collection in debug so dev noise doesn't pollute the dashboard.
    await FirebaseCrashlytics.instance
        .setCrashlyticsCollectionEnabled(!kDebugMode);
    FlutterError.onError =
        FirebaseCrashlytics.instance.recordFlutterFatalError;
    PlatformDispatcher.instance.onError = (error, stack) {
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      return true;
    };
  } catch (_) {
    // Firebase is optional during local/dev setup without google-services files.
  }

  try {
    await initSupabase();
  } catch (e) {
    if (kDebugMode) debugPrint('Supabase init failed during startup: $e');
  }

  runApp(const WhooshApp());
  unawaited(_initializeServices());
}

Future<void> _initializeServices() async {
  try {
    await ThemeController.load();
    await NotificationService.initialize();
    SupabaseConfig.startAuthListener();
  } catch (e) {
    if (kDebugMode) debugPrint('Background service initialization failed: $e');
  }
}
