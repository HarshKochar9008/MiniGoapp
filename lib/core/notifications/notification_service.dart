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

  /// Every listener below is attached and launch taps have been read.
  static bool _listenersReady = false;

  /// The FCM stream subscriptions exist. Attached at most once per process:
  /// a setup retried after a partial failure must not double them (each
  /// foreground message would show twice and each token be written twice).
  static bool _streamsAttached = false;

  /// The OS permission prompt has been asked for in this process.
  static bool _permissionRequested = false;

  static Future<void>? _setupInFlight;
  static String? _userId;

  /// While an app reset retires the identity, no token may be written for
  /// it: a write landing after the scrub would put fcm_token back.
  static bool _tokenSyncSuspended = false;

  static void setUserId(String? id) => _userId = id;

  /// Stops all token writes until [reattachAfterAbortedReset] or
  /// [resumeAfterReset].
  static void detachForReset() {
    _userId = null;
    _tokenSyncSuspended = true;
  }

  /// The reset stopped before touching anything: carry on for [userId].
  static void reattachAfterAbortedReset(String userId) {
    _tokenSyncSuspended = false;
    _userId = userId;
  }

  /// The reset finished; the next identity binds itself via [setUserId].
  static void resumeAfterReset() => _tokenSyncSuspended = false;

  /// Asks for notification permission (once per process), then sets up push
  /// and local notifications. Called at app start once onboarding is done,
  /// and by onboarding's permission step.
  static Future<void> initialize() => _setUp(requestPermission: true);

  /// Sets up push and local notifications without the permission prompt:
  /// foreground messages, taps and token refreshes then work in the session
  /// that finished onboarding, even if the user skipped the prompt.
  static Future<void> initializeWithoutPrompt() =>
      _setUp(requestPermission: false);

  static Future<void> _setUp({required bool requestPermission}) async {
    // One setup at a time; a prompt request arriving during a listener-only
    // setup still gets its prompt once that finishes.
    while (_setupInFlight != null) {
      await _setupInFlight;
    }
    final needsPrompt = requestPermission && !_permissionRequested;
    if (_listenersReady && !needsPrompt) return;
    final run = _setUpInternal(requestPermission: needsPrompt);
    _setupInFlight = run;
    try {
      await run;
    } finally {
      if (identical(_setupInFlight, run)) _setupInFlight = null;
    }
  }

  static Future<void> _setUpInternal({required bool requestPermission}) async {
    if (requestPermission) {
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
        _permissionRequested = true;
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Notification permission request failed: $e');
        }
      }
    }
    if (_listenersReady) return;

    try {
      await FirebaseMessaging.instance
          .setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );

      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      // Never prompt from here: the prompt belongs to [initialize] alone, so
      // the listener-only setup stays silent on iOS.
      const iosInit = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      await _localNotifications.initialize(
        settings: const InitializationSettings(
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

      final androidPlugin =
          _localNotifications.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      await androidPlugin?.createNotificationChannel(
        IncomingTransferLocalNotifications.androidChannel,
      );

      _attachStreamsOnce();

      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) {
        PendingIncomingTransfer.setFromRemoteMessage(initial.data);
      }

      final launchDetails =
          await _localNotifications.getNotificationAppLaunchDetails();
      if (launchDetails?.didNotificationLaunchApp == true) {
        final payload = launchDetails!.notificationResponse?.payload;
        PendingIncomingTransfer.applyPayload(payload);
      }
      // The launch tap only resolves here, well after runApp — the permission
      // prompts above can hold it for seconds. It waits in
      // PendingIncomingTransfer until the shell has an identity.
      handleLaunchAndPendingNavigation();

      _listenersReady = true;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Notifications disabled: $e');
      }
    }
  }

  static void _attachStreamsOnce() {
    if (_streamsAttached) return;
    _streamsAttached = true;

    FirebaseMessaging.onMessage.listen((message) async {
      final data = Map<String, dynamic>.from(message.data);
      final title = message.notification?.title ??
          (data['title'] as String?) ??
          'Incoming transfer';
      final body = message.notification?.body ??
          (data['body'] as String?) ??
          'A new transfer is available.';
      final notificationId =
          IncomingTransferLocalNotifications.stableNotificationId(
        data,
        messageId: message.messageId,
      );
      final androidTag =
          IncomingTransferLocalNotifications.androidTagForTransfer(data);
      await _localNotifications.show(
        id: notificationId,
        title: title,
        body: body,
        notificationDetails:
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

    FirebaseMessaging.instance.onTokenRefresh.listen((token) async {
      final uid = _userId;
      if (_tokenSyncSuspended || uid == null || uid.isEmpty) return;
      try {
        await _writeToken(uid, token);
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
  }

  /// Saves [token] on [userId]'s row unless that row is retired: a retired
  /// identity must never become reachable by push again.
  static Future<void> _writeToken(String userId, String token) async {
    await SupabaseConfig.client
        .from('users')
        .update({'fcm_token': token})
        .eq('id', userId)
        .isFilter('deleted_at', null)
        .timeout(const Duration(seconds: 15));
  }

  /// Does not call [initialize]: that (and its permission prompt) belongs to
  /// app start or the onboarding permissions step, so "Skip for now" holds
  /// until the next launch. The FCM token is available either way. Only call
  /// it for a verified identity (see IdentityService).
  static Future<void> syncFcmToken(String userId) async {
    if (_tokenSyncSuspended) return;
    try {
      // Timeouts: a hung request here wedged the offline drain (its _running
      // flag never cleared). TimeoutException is retryable, so it re-queues.
      final token = await FirebaseMessaging.instance
          .getToken()
          .timeout(const Duration(seconds: 15));
      if (token == null || token.isEmpty) return;
      try {
        await SupabaseConfig.ensureValidSession();
      } catch (_) {
        // Session refresh can fail offline; DB update may still work briefly or fail clearly below.
      }
      if (_tokenSyncSuspended) return;
      await _writeToken(userId, token);
      await PendingBackendJobs.clearFcmTokenSyncPending();
    } catch (e) {
      if (NetworkErrors.isRetryableFailure(e)) {
        await PendingBackendJobs.markFcmTokenSyncPending(userId);
      }
      if (kDebugMode) {
        if (NetworkErrors.isRetryableFailure(e)) {
          final host =
              Uri.tryParse(AppConstants.supabaseUrl)?.host ?? 'Supabase';
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
    // An idle app draws no next frame, and the callback above would wait for one.
    WidgetsBinding.instance.ensureVisualUpdate();
  }
}
