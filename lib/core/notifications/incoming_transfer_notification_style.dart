import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Shared look for FCM-triggered local notifications (foreground + background isolate).
///
/// Android: [largeIcon] shows the Whoosh logo in the expanded notification header.
/// The bitmap lives at `android/app/src/main/res/drawable/whoosh_notif_logo.png`
/// (kept in sync with `assets/logo.png`).
///
/// Use [stableNotificationId] + [androidTagForTransfer] so multiple FCM deliveries for the
/// same transfer (e.g. webhook + client invoke) **replace** a single tray slot instead of
/// stacking 3–5 notifications.
class IncomingTransferLocalNotifications {
  IncomingTransferLocalNotifications._();

  static const String androidChannelId = 'incoming_transfers';
  static const String androidChannelName = 'Incoming Transfers';
  static const String androidChannelDescription =
      'Alerts when a new transfer arrives';

  static const AndroidNotificationChannel androidChannel =
      AndroidNotificationChannel(
    androidChannelId,
    androidChannelName,
    description: androidChannelDescription,
    importance: Importance.max,
  );

  static const DrawableResourceAndroidBitmap androidLargeIcon =
      DrawableResourceAndroidBitmap('@drawable/whoosh_notif_logo');

  /// One notification id per transfer so [FlutterLocalNotificationsPlugin.show] updates in place.
  static int stableNotificationId(
    Map<String, dynamic> data, {
    String? messageId,
  }) {
    final tid = (data['transfer_id'] ?? data['transferId'] ?? '').toString().trim();
    if (tid.isNotEmpty) {
      return tid.hashCode.abs() % 2000000000;
    }
    final mid = messageId?.trim();
    if (mid != null && mid.isNotEmpty) {
      return mid.hashCode.abs() % 2000000000;
    }
    var h = 17;
    for (final e in data.entries) {
      h = 37 * h + e.key.hashCode;
      h = 37 * h + '${e.value}'.hashCode;
    }
    return h.abs() % 2000000000;
  }

  /// Android tag groups replacements; must stay stable per transfer.
  static String? androidTagForTransfer(Map<String, dynamic> data) {
    final tid = (data['transfer_id'] ?? data['transferId'] ?? '').toString().trim();
    if (tid.isEmpty) return 'whoosh_incoming_unknown';
    return 'whoosh_incoming_$tid';
  }

  static NotificationDetails notificationDetails(
    String expandedBody, {
    String? androidTag,
  }) {
    return NotificationDetails(
      android: AndroidNotificationDetails(
        androidChannel.id,
        androidChannel.name,
        channelDescription: androidChannel.description,
        importance: Importance.max,
        priority: Priority.high,
        tag: androidTag,
        largeIcon: androidLargeIcon,
        styleInformation: BigTextStyleInformation(expandedBody),
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
    );
  }
}
