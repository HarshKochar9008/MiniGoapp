import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

/// Lightweight analytics facade.
///
/// Events are dispatched to every registered [AnalyticsSink]. The default
/// sinks log to debug console and tag a Crashlytics breadcrumb so that any
/// crash report carries the recent user journey.
///
/// Add Firebase Analytics / Mixpanel / PostHog later by registering a new
/// sink in [Analytics.init] — call sites do not change.
class Analytics {
  Analytics._();
  static final Analytics instance = Analytics._();

  final List<AnalyticsSink> _sinks = [];
  String? _userId;

  void init() {
    _sinks
      ..clear()
      ..add(_DebugLogSink())
      ..add(_CrashlyticsBreadcrumbSink());
  }

  void identify(String userId, {String? shortCode}) {
    _userId = userId;
    try {
      FirebaseCrashlytics.instance.setUserIdentifier(userId);
      if (shortCode != null) {
        FirebaseCrashlytics.instance.setCustomKey('short_code', shortCode);
      }
    } catch (_) {}
  }

  void logEvent(String name, [Map<String, Object?> props = const {}]) {
    final enriched = <String, Object?>{
      if (_userId != null) 'uid': _userId,
      ...props,
    };
    for (final sink in _sinks) {
      try {
        sink.log(name, enriched);
      } catch (_) {}
    }
  }

  void logError(String name, Object error,
      {StackTrace? stack, Map<String, Object?> props = const {}}) {
    logEvent(name, {
      ...props,
      'error': error.toString(),
    });
    try {
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: false);
    } catch (_) {}
  }
}

abstract class AnalyticsSink {
  void log(String name, Map<String, Object?> props);
}

class _DebugLogSink implements AnalyticsSink {
  @override
  void log(String name, Map<String, Object?> props) {
    if (!kDebugMode) return;
    debugPrint('[analytics] $name ${props.isEmpty ? '' : props}');
  }
}

class _CrashlyticsBreadcrumbSink implements AnalyticsSink {
  @override
  void log(String name, Map<String, Object?> props) {
    try {
      FirebaseCrashlytics.instance.log('$name ${props.isEmpty ? '' : props}');
    } catch (_) {}
  }
}

/// Canonical event names — keep in one place so they cannot drift.
class AnalyticsEvents {
  static const appOpened = 'app_opened';
  static const identityReady = 'identity_ready';

  static const sendCodeEntered = 'send_code_entered';
  static const sendCodeInvalid = 'send_code_invalid';
  static const sendCodeValidated = 'send_code_validated';
  static const sendFilesPicked = 'send_files_picked';
  static const sendStarted = 'send_started';
  static const sendCompleted = 'send_completed';
  static const sendFailed = 'send_failed';
  static const sendCancelled = 'send_cancelled';

  static const downloadStarted = 'download_started';
  static const downloadCompleted = 'download_completed';
  static const downloadFailed = 'download_failed';
  static const downloadCancelled = 'download_cancelled';
  static const downloadAllRequested = 'download_all_requested';

  static const codeCopied = 'code_copied';
  static const codeShared = 'code_shared';
  static const qrShown = 'qr_shown';
  static const qrScanned = 'qr_scanned';

  static const offlineQueued = 'offline_queued';
  static const offlineDrained = 'offline_drained';
}
