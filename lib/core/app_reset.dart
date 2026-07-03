import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app.dart';
import '../features/identity/identity_service.dart';
import 'navigation/root_navigator.dart';
import 'notifications/notification_service.dart';
import 'notifications/pending_push.dart';
import 'supabase_config.dart';
import 'theme.dart';

/// Clears all local app persistence and Supabase session on this device, then
/// rebuilds the widget tree (same as a fresh process for UI/state).
///
/// The server-side `users` row is soft-retired (nickname/fcm_token cleared,
/// `deleted_at` stamped) rather than deleted, so shared history other people
/// have with this identity isn't touched — only what identifies it is scrubbed.
class AppReset {
  AppReset._();

  static Future<void> clearLocalDataAndRelaunchUi({
    required String userId,
  }) async {
    PendingIncomingTransfer.clear();
    NotificationService.setUserId(null);

    // Best-effort, same as signOut() below: must run first, while the
    // session is still valid enough to pass the row's RLS check.
    try {
      await SupabaseConfig.client
          .from('users')
          .update({
            'nickname': null,
            'fcm_token': null,
            'deleted_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', userId)
          .timeout(const Duration(seconds: 10));
    } catch (_) {}

    // Timeout guard: on a slow/stuck network, signOut()'s server round-trip
    // must not block the rest of the reset — the local wipe below still has
    // to happen either way.
    try {
      await SupabaseConfig.client.auth
          .signOut()
          .timeout(const Duration(seconds: 10));
    } catch (_) {}

    IdentityService.clearCache();

    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();

    await ThemeController.load();

    // Replacing the navigator key is the part that actually matters: it's a
    // stable GlobalKey, so without this, Flutter reparents the *existing*
    // Navigator (and everything mounted in its route stack — MainShell,
    // its cached identity, etc.) onto the relaunched tree intact instead of
    // rebuilding it, no matter what key MiniGoApp itself gets below.
    rootNavigatorKey = GlobalKey<NavigatorState>();
    runApp(MiniGoApp(key: UniqueKey()));
  }
}
