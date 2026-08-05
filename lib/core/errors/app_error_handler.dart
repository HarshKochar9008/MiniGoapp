import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../analytics/analytics.dart';
import '../network/network_errors.dart';
import '../theme.dart';
import 'service_health.dart';
import 'service_unavailable_sheet.dart';

/// Single entry point for presenting caught errors to the user.
///
/// Instead of surfacing raw exception strings, it classifies the failure and
/// shows the professional equivalent:
///   * device offline      → "You're offline" snackbar
///   * backend unreachable → [ServiceUnavailableSheet] (retry / contact support)
///   * anything else       → friendly generic snackbar
///
/// Screens that render errors inline (e.g. Send) can keep their inline text
/// and call [maybeShowServiceOutage] instead of [handle] — it only escalates
/// to the outage sheet when a health probe confirms the service is down.
class AppErrorHandler {
  AppErrorHandler._();

  static const String genericMessage =
      'Something went wrong. Please try again.';
  static const String offlineMessage =
      'You\'re offline. Check your connection and try again.';

  /// Logs [error] and shows the appropriate UI for it.
  static Future<void> handle(
    BuildContext context,
    Object error, {
    StackTrace? stack,
    String? friendlyFallback,
    VoidCallback? onRetry,
  }) async {
    Analytics.instance.logError('error_presented', error, stack: stack);

    if (isBackendFailure(error)) {
      final health = await ServiceHealth.instance.check();
      if (!context.mounted) return;
      switch (health) {
        case BackendHealth.offline:
          showErrorSnackBar(context, offlineMessage);
          return;
        case BackendHealth.serviceDown:
          await ServiceUnavailableSheet.show(context, onRetry: onRetry);
          return;
        case BackendHealth.healthy:
        case BackendHealth.unknown:
          // Backend answered the probe — the failure was a transient blip.
          showErrorSnackBar(
            context,
            friendlyFallback ?? 'Connection hiccup. Please try again.',
          );
          return;
      }
    }

    if (!context.mounted) return;
    showErrorSnackBar(context, friendlyFallback ?? genericMessage);
  }

  /// Escalates to the outage sheet only if [error] is a backend failure AND
  /// a health probe confirms the service is down while the device is online.
  /// Safe to fire-and-forget from catch blocks that already show inline errors.
  static Future<void> maybeShowServiceOutage(
    BuildContext context,
    Object error,
  ) async {
    if (!isBackendFailure(error)) return;
    final health = await ServiceHealth.instance.check();
    if (health != BackendHealth.serviceDown || !context.mounted) return;
    await ServiceUnavailableSheet.show(context);
  }

  /// True when [error] points at the network or our backend rather than a
  /// user-fixable or app-level problem.
  static bool isBackendFailure(Object error) {
    if (error is TimeoutException) return true;
    if (NetworkErrors.isRetryableFailure(error)) return true;
    if (error is PostgrestException) {
      return _isServerErrorCode(error.code);
    }
    if (error is StorageException) {
      return _isServerErrorCode(error.statusCode);
    }
    if (error is AuthException) {
      return _isServerErrorCode(error.statusCode);
    }
    return false;
  }

  static bool _isServerErrorCode(String? code) {
    final parsed = int.tryParse(code ?? '');
    return parsed != null && parsed >= 500;
  }

  /// Themed floating error snackbar — the standard way to show a short,
  /// user-friendly failure message.
  static void showErrorSnackBar(BuildContext context, String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final iconColor = Theme.of(context).snackBarTheme.contentTextStyle?.color ??
        context.mini.paper;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(Icons.error_outline_rounded, size: 18, color: iconColor),
              const SizedBox(width: 10),
              Expanded(child: Text(message)),
            ],
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }
}
