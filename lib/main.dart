import 'dart:async';

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
  } catch (_) {
    // Optional fallback only; --dart-define still works without this file.
  }

  try {
    await Firebase.initializeApp();
  } catch (_) {
    // Firebase is optional during local/dev setup without google-services files.
  }

  // Supabase is required by identity/session bootstrap on first screen.
  try {
    await initSupabase();
  } catch (e) {
    if (kDebugMode) {
      debugPrint('Supabase init failed during startup: $e');
    }
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
    if (kDebugMode) {
      debugPrint('Background service initialization failed: $e');
    }
  }
}
