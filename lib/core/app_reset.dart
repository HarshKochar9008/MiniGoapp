import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app.dart';
import '../features/identity/identity_service.dart';
import 'notifications/notification_service.dart';
import 'notifications/pending_push.dart';
import 'supabase_config.dart';
import 'theme.dart';

/// Clears all local app persistence and Supabase session on this device, then
/// rebuilds the widget tree (same as a fresh process for UI/state).
///
/// Server data is not touched — run `scripts/reset_supabase_data.sql` separately.
class AppReset {
  AppReset._();

  static Future<void> clearLocalDataAndRelaunchUi() async {
    PendingIncomingTransfer.clear();
    NotificationService.setUserId(null);

    try {
      await SupabaseConfig.client.auth.signOut();
    } catch (_) {}

    IdentityService.clearCache();

    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();

    await ThemeController.load();

    runApp(const WhooshApp());
  }
}
