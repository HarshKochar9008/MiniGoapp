import 'dart:io';

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
      'error': describeForLogs(error),
    });
    try {
      FirebaseCrashlytics.instance
          .recordError(redactForReport(error), stack, fatal: false);
    } catch (_) {}
  }

  /// Attached to every later crash report from this process.
  void setCustomKey(String key, Object value) {
    try {
      FirebaseCrashlytics.instance.setCustomKey(key, value);
    } catch (_) {}
  }
}

/// An error whose message names a user's file. The UI shows `toString()`;
/// logs and crash reports get [logDescription] instead.
abstract interface class NamesUserFile {
  String get logDescription;
}

/// [error] as it may appear in logs and crash reports, which leave the
/// device: without the path a [FileSystemException] carries (temp paths embed
/// the file name) or the file name in a [NamesUserFile] error.
String describeForLogs(Object error) => switch (error) {
      NamesUserFile e => e.logDescription,
      // Not runtimeType: release builds obfuscate type names.
      FileSystemException e => 'FileSystemException: ${e.message}'
          '${e.osError == null ? '' : ' (${e.osError})'}',
      _ => error.toString(),
    };

/// [error] itself when its message is safe to report, otherwise a stand-in
/// carrying [describeForLogs].
Object redactForReport(Object error) =>
    error is NamesUserFile || error is FileSystemException
        ? _RedactedError(describeForLogs(error))
        : error;

class _RedactedError implements Exception {
  const _RedactedError(this.description);
  final String description;

  @override
  String toString() => description;
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

  // Runtime self-protection (freeRASP, see AppSecurity). Props name the
  // threat and its severity, nothing about the device or the user.
  static const securityRaspStarted = 'security_rasp_started';
  static const securityRaspUnavailable = 'security_rasp_unavailable';
  static const securityChecksFinished = 'security_checks_finished';
  static const securityThreat = 'security_threat';
  static const securityRestricted = 'security_restricted';

  // Onboarding A/B experiment (classic flow vs questionnaire flow).
  static const onboardingVariantAssigned = 'onboarding_variant_assigned';
  static const onbStepViewed = 'onb_step_viewed';
  static const onbSwipeAnswered = 'onb_swipe_answered';
  static const onbNotificationPrompt = 'onb_notification_prompt';
  static const onbLeverPulled = 'onb_lever_pulled';
  static const onbCardStyled = 'onb_card_styled';
  static const onbCardShared = 'onb_card_shared';
  static const onbCodeCopied = 'onb_code_copied';
  static const onbPaywallViewed = 'onb_paywall_viewed';
  static const onbPaywallCta = 'onb_paywall_cta';
  static const onbSkipped = 'onb_skipped';
  static const onbCompleted = 'onb_completed';
}
