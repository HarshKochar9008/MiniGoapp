import 'dart:convert';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

import '../constants.dart';
import '../network/network_errors.dart';
import '../offline/pending_backend_jobs.dart';
import '../supabase_config.dart';
import 'incoming_transfer_notification_style.dart';
import 'pending_push.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  static bool _available = false;
  static String? _userId;
  static bool _initializing = false;
  static Future<void>? _initializeFuture;

  static void setUserId(String? id) => _userId = id;

  static Future<void> initialize() async {
    if (_available) return;
    if (_initializeFuture != null) return _initializeFuture!;
    _initializing = true;
    _initializeFuture = _initializeInternal();
    await _initializeFuture;
    _initializing = false;
    _initializeFuture = null;
  }

  static Future<void> _initializeInternal() async {
    try {
      if (!kIsWeb && Platform.isAndroid) {
        final status = await Permission.notification.request();
        if (status.isDenied && kDebugMode) {
          debugPrint('Notification permission denied');
        }
      }

      await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
        announcement: false,
        carPlay: false,
        criticalAlert: false,
      );

      await FirebaseMessaging.instance
          .setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );

      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      const iosInit = DarwinInitializationSettings();
      await _localNotifications.initialize(
        const InitializationSettings(
          android: androidInit,
          iOS: iosInit,
        ),
        onDidReceiveNotificationResponse: (details) {
          PendingIncomingTransfer.applyPayload(details.payload);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            PendingIncomingTransfer.tryNavigateToReceive();
          });
        },
      );

      final androidPlugin = _localNotifications
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      await androidPlugin?.createNotificationChannel(
        IncomingTransferLocalNotifications.androidChannel,
      );

      FirebaseMessaging.onMessage.listen((message) async {
        final data = Map<String, dynamic>.from(message.data);
        final title = message.notification?.title ??
            (data['title'] as String?) ??
            'Incoming transfer';
        final body = message.notification?.body ??
            (data['body'] as String?) ??
            'A new transfer is available.';
        final notificationId = IncomingTransferLocalNotifications.stableNotificationId(
          data,
          messageId: message.messageId,
        );
        final androidTag =
            IncomingTransferLocalNotifications.androidTagForTransfer(data);
        await _localNotifications.show(
          notificationId,
          title,
          body,
          IncomingTransferLocalNotifications.notificationDetails(
            body,
            androidTag: androidTag,
          ),
          payload: jsonEncode(data),
        );
      });

      FirebaseMessaging.onMessageOpenedApp.listen((message) {
        PendingIncomingTransfer.setFromRemoteMessage(message.data);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          PendingIncomingTransfer.tryNavigateToReceive();
        });
      });

      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) {
        PendingIncomingTransfer.setFromRemoteMessage(initial.data);
      }

      FirebaseMessaging.instance.onTokenRefresh.listen((token) async {
        final uid = _userId;
        if (uid == null || uid.isEmpty) return;
        try {
          await SupabaseConfig.client
              .from('users')
              .update({'fcm_token': token}).eq('id', uid);
          await PendingBackendJobs.clearFcmTokenSyncPending();
        } catch (e) {
          if (NetworkErrors.isRetryableFailure(e)) {
            await PendingBackendJobs.markFcmTokenSyncPending(uid);
          }
          if (kDebugMode) {
            debugPrint('FCM token refresh sync failed: $e');
          }
        }
      });

      final launchDetails =
          await _localNotifications.getNotificationAppLaunchDetails();
      if (launchDetails?.didNotificationLaunchApp == true) {
        final payload = launchDetails!.notificationResponse?.payload;
        PendingIncomingTransfer.applyPayload(payload);
      }

      _available = true;
    } catch (e) {
      _available = false;
      if (kDebugMode) {
        debugPrint('Notifications disabled: $e');
      }
    }
  }

  static Future<void> syncFcmToken(String userId) async {
    // Ensure initialization is started, but do not fail token sync if local
    // notification setup had issues. FCM token can still be available.
    if (!_available && !_initializing) {
      await initialize();
    }
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null || token.isEmpty) return;
      try {
        await SupabaseConfig.ensureValidSession();
      } catch (_) {
        // Session refresh can fail offline; DB update may still work briefly or fail clearly below.
      }
      await SupabaseConfig.client
          .from('users')
          .update({'fcm_token': token}).eq('id', userId);
      await PendingBackendJobs.clearFcmTokenSyncPending();
    } catch (e) {
      if (NetworkErrors.isRetryableFailure(e)) {
        await PendingBackendJobs.markFcmTokenSyncPending(userId);
      }
      if (kDebugMode) {
        if (NetworkErrors.isRetryableFailure(e)) {
          final host = Uri.tryParse(AppConstants.supabaseUrl)?.host ?? 'Supabase';
          debugPrint(
            'FCM: device token from Firebase is fine; saving it to your backend failed '
            'because $host could not be reached (JWT refresh / REST timed out). '
            'Fix network, VPN, or firewall blocking HTTPS to Supabase. ($e)',
          );
        } else {
          debugPrint('FCM token sync failed: $e');
        }
      }
    }
  }

  /// After the first frame when [rootNavigatorKey] is attached.
  static void handleLaunchAndPendingNavigation() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      PendingIncomingTransfer.tryNavigateToReceive();
    });
  }
}
