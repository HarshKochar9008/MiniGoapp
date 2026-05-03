import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'incoming_transfer_notification_style.dart';

/// Runs in a separate isolate when a message arrives while the app is backgrounded or terminated.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp();
  } catch (_) {}

  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const iosInit = DarwinInitializationSettings();
  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(
    settings: const InitializationSettings(
      android: androidInit,
      iOS: iosInit,
    ),
  );

  final androidPlugin = plugin.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  await androidPlugin?.createNotificationChannel(
    IncomingTransferLocalNotifications.androidChannel,
  );

  // Prefer one local notification per transfer (logo + stable id/tag). Server should send
  // Android as data-only (see send-transfer-fcm) so we always hit this path on Android.
  final data = Map<String, dynamic>.from(message.data);
  final title = message.notification?.title ??
      (data['title'] as String?)?.trim() ??
      'Incoming transfer';
  final body = message.notification?.body ??
      (data['body'] as String?)?.trim() ??
      'Tap to view and download your files.';

  final notificationId =
      IncomingTransferLocalNotifications.stableNotificationId(
    data,
    messageId: message.messageId,
  );
  final androidTag =
      IncomingTransferLocalNotifications.androidTagForTransfer(data);

  await plugin.show(
    id: notificationId,
    title: title,
    body: body,
    notificationDetails: IncomingTransferLocalNotifications.notificationDetails(
      body,
      androidTag: androidTag,
    ),
    payload: jsonEncode(data),
  );
}
