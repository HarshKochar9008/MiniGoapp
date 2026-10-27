import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app.dart';
import '../features/identity/identity_service.dart';
import 'constants.dart';
import 'contacts/contact_aliases.dart';
import 'contacts/recent_recipients.dart';
import 'crypto/e2e_crypto.dart';
import 'navigation/root_navigator.dart';
import 'notifications/notification_service.dart';
import 'notifications/pending_push.dart';
import 'storage/local_cache.dart';
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

  /// With [requireServerRetirement] the server scrub becomes a precondition:
  /// if it can't be confirmed this throws [AccountRetirementException] and
  /// nothing on the device is touched. Account deletion sets it, because
  /// wiping the device while the code stays live would leave senders
  /// targeting an identity nobody holds. Otherwise the scrub is best-effort,
  /// so an offline device can still be reset.
  static Future<void> clearLocalDataAndRelaunchUi({
    required String userId,
    bool requireServerRetirement = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final authUid = prefs.getString(AppConstants.prefAuthUid) ??
        (SupabaseConfig.isInitialized
            ? SupabaseConfig.client.auth.currentUser?.id
            : null);

    // Detach first so a token refresh can't write fcm_token back after the
    // scrub below clears it.
    NotificationService.setUserId(null);

    // Best-effort, same as signOut() below: must run first, while the
    // session is still valid enough to pass the row's RLS check. The select
    // makes an RLS no-op visible — it comes back empty instead of failing.
    try {
      final retired = await SupabaseConfig.client
          .from('users')
          .update({
            'nickname': null,
            'fcm_token': null,
            'deleted_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', userId)
          .select('id')
          .timeout(const Duration(seconds: 10));
      if (requireServerRetirement && retired.isEmpty) {
        throw const AccountRetirementException();
      }
    } catch (_) {
      if (requireServerRetirement) {
        NotificationService.setUserId(userId);
        throw const AccountRetirementException();
      }
    }

    PendingIncomingTransfer.clear();

    // Timeout guard: on a slow/stuck network, signOut()'s server round-trip
    // must not block the rest of the reset — the local wipe below still has
    // to happen either way.
    try {
      await SupabaseConfig.client.auth
          .signOut()
          .timeout(const Duration(seconds: 10));
    } catch (_) {}

    IdentityService.clearCache();

    await prefs.clear();
    // These keep in-memory copies that would otherwise outlive the relaunch
    // and be written straight back to the prefs just cleared.
    await ContactAliases.clear();
    await RecentRecipients.clear();

    // Keys and files last, and best-effort: a cache file the OS won't let go
    // of mustn't strand the reset half-done.
    if (authUid != null) {
      try {
        await E2ECrypto.clearLocalKey(authUid);
      } catch (_) {}
    }
    try {
      await LocalCache.clear();
      await LocalCache.clearUploadResumeState();
    } catch (_) {}

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

/// The server didn't confirm the identity was retired, so the reset stopped
/// before touching anything.
class AccountRetirementException implements Exception {
  const AccountRetirementException();

  @override
  String toString() =>
      'Couldn’t reach MiniGo to deactivate your code, so nothing was '
      'deleted. Check your connection and try again.';
}
