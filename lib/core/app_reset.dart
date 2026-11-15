import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app.dart';
import '../features/identity/identity_service.dart';
import '../features/onboarding_v2/onboarding_experiment.dart';
import 'analytics/analytics.dart';
import 'constants.dart';
import 'contacts/contact_aliases.dart';
import 'contacts/recent_recipients.dart';
import 'crypto/e2e_crypto.dart';
import 'errors/service_health.dart';
import 'errors/service_unavailable_sheet.dart';
import 'navigation/root_navigator.dart';
import 'network/network_errors.dart';
import 'notifications/notification_service.dart';
import 'notifications/pending_push.dart';
import 'offline/offline_sync_coordinator.dart';
import 'offline/pending_backend_jobs.dart';
import 'storage/local_cache.dart';
import 'supabase_config.dart';
import 'theme.dart';
import 'widget_bridge.dart';

/// Clears all local app persistence and Supabase session on this device, then
/// rebuilds the widget tree (same as a fresh process for UI/state).
///
/// The server-side `users` row is soft-retired (nickname/fcm_token cleared,
/// `deleted_at` stamped) rather than deleted, so shared history other people
/// have with this identity isn't touched — only what identifies it is scrubbed.
///
/// Steps, in order:
/// 1. Detach: no token write, offline drain or push for this identity runs
///    while it's being retired.
/// 2. Retire the row on the server. A lost reply is checked before it's
///    called a failure.
/// 3. Point of no return (account deletion only gets here if 2 succeeded).
///    An unconfirmed retirement is queued, and the queue survives the wipe:
///    the next identity on this device retires the old row.
/// 4. Sign out, wipe storage (keeping the onboarding A/B arm and the
///    retirement queue), keys and caches.
/// 5. Reset process-wide state and relaunch the UI.
class AppReset {
  AppReset._();

  static bool _running = false;

  /// Preferences that outlive a reset: the onboarding experiment arm (a
  /// reset user must not be re-drawn into the other arm) and old identities
  /// still waiting to be retired.
  static const _keysSurvivingReset = [
    OnboardingExperiment.prefKey,
    IdentityService.pendingRetirementsKey,
  ];

  /// With [requireServerRetirement] the server scrub becomes a precondition:
  /// if it can't be confirmed this throws [AccountRetirementException] and
  /// nothing on the device is touched. Account deletion sets it, because
  /// wiping the device while the code stays live would leave senders
  /// targeting an identity nobody holds. Otherwise the scrub is best-effort,
  /// so an offline device can still be reset; the retirement is then queued
  /// for the next identity to finish.
  static Future<void> clearLocalDataAndRelaunchUi({
    required String userId,
    bool requireServerRetirement = false,
  }) async {
    if (_running) return;
    _running = true;
    var pastPointOfNoReturn = false;
    var relaunched = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final authUid = prefs.getString(AppConstants.prefAuthUid) ??
          (SupabaseConfig.isInitialized
              ? SupabaseConfig.client.auth.currentUser?.id
              : null);

      // 1. Detach first, so nothing writes fcm_token back after the scrub:
      // not a token refresh, a resume-time sync, nor a queued drain.
      NotificationService.detachForReset();
      OfflineSyncCoordinator.instance.stop();

      // 2.
      final retired = await _retireOnServer(userId);
      if (!retired && requireServerRetirement) {
        NotificationService.reattachAfterAbortedReset(userId);
        if (IdentityService.isVerified &&
            IdentityService.identityNotifier.value?.id == userId) {
          OfflineSyncCoordinator.instance.start(userId: userId);
        }
        throw const AccountRetirementException();
      }

      // 3.
      pastPointOfNoReturn = true;
      IdentityService.beginReset();
      if (!retired && authUid != null) {
        await IdentityService.queueRetirement(authUid);
      }
      PendingIncomingTransfer.clear();

      // 4. Timeout guard: on a slow/stuck network, signOut()'s server
      // round-trip must not block the rest of the reset. It drops the local
      // session before that round-trip, so the wipe below is safe either way.
      try {
        await SupabaseConfig.client.auth
            .signOut()
            .timeout(const Duration(seconds: 10));
      } catch (_) {}

      await _clearPreferencesKeeping(prefs, _keysSurvivingReset);
      // These keep in-memory copies that would otherwise outlive the relaunch
      // and be written straight back to the prefs just cleared.
      await ContactAliases.clear();
      await RecentRecipients.clear();

      // Keys and files last, and best-effort: a cache file the OS won't let
      // go of mustn't strand the reset half-done.
      if (authUid != null) {
        try {
          await E2ECrypto.clearLocalKey(authUid);
        } catch (_) {}
      }
      try {
        await LocalCache.clear();
        await LocalCache.clearUploadResumeState();
      } catch (_) {}

      try {
        await ThemeController.load();
      } catch (_) {}

      // 5.
      _resetProcessState();
      _relaunch();
      relaunched = true;
    } finally {
      if (pastPointOfNoReturn && !relaunched) {
        // Something above threw after the identity was dropped. Relaunch
        // anyway: the old tree holds an identity that no longer exists.
        _resetProcessState();
        _relaunch();
      }
      _running = false;
    }
  }

  /// Retires the row; true once the server confirms it's retired. A
  /// network failure or 5xx means the reply was lost, not necessarily the
  /// update — it may have committed before the connection dropped — so the
  /// row is checked before calling it a failure.
  static Future<bool> _retireOnServer(String userId) async {
    try {
      // The select makes an RLS no-op visible: it comes back empty instead
      // of failing.
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
      return retired.isNotEmpty;
    } catch (e) {
      if (!NetworkErrors.isTransient(e)) return false;
      return _isRetiredOnServer(userId);
    }
  }

  static Future<bool> _isRetiredOnServer(String userId) async {
    try {
      final row = await SupabaseConfig.client
          .from('users')
          .select('deleted_at')
          .eq('id', userId)
          .maybeSingle()
          .timeout(const Duration(seconds: 8));
      return row != null && row['deleted_at'] != null;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _clearPreferencesKeeping(
    SharedPreferences prefs,
    List<String> keys,
  ) async {
    final kept = <String, Object>{
      for (final key in keys)
        if (prefs.get(key) != null) key: prefs.get(key)!,
    };
    await prefs.clear();
    for (final entry in kept.entries) {
      final value = entry.value;
      if (value is String) {
        await prefs.setString(entry.key, value);
      } else if (value is bool) {
        await prefs.setBool(entry.key, value);
      } else if (value is int) {
        await prefs.setInt(entry.key, value);
      } else if (value is double) {
        await prefs.setDouble(entry.key, value);
      } else if (value is List) {
        await prefs.setStringList(entry.key, value.cast<String>());
      }
    }
  }

  /// Process-wide state that the "fresh process" promise above relies on.
  static void _resetProcessState() {
    try {
      ServiceHealth.instance.resetForNewSession();
      ServiceUnavailableSheet.resetVisibility();
      Analytics.instance.clearIdentity();
      unawaited(PendingBackendJobs.refreshPendingCount());
      // The home-screen widget reads the code from the prefs just cleared.
      unawaited(WidgetBridge.refresh());
    } catch (_) {}
    NotificationService.resumeAfterReset();
    IdentityService.endReset();
  }

  static void _relaunch() {
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
