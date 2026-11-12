import 'package:flutter/foundation.dart';
import 'package:freerasp/freerasp.dart';

import '../analytics/analytics.dart';
import 'rasp_config.dart';

/// How MiniGo responds to a freeRASP finding.
enum ThreatSeverity {
  /// This copy of the app is modified or being instrumented right now, so
  /// nothing it does with keys or files can be trusted. Release builds stop
  /// transfers and ask for a reinstall.
  critical,

  /// The device or install is riskier than usual (rooted, debuggable,
  /// emulator, sideloaded…). Logged; the user is not interrupted.
  warning,

  /// Device facts that are normal for plenty of genuine users. Logged.
  info,
}

/// Whether freeRASP is watching this process.
enum RaspStatus {
  /// [AppSecurity.start] hasn't run (tests, background isolates).
  notStarted,
  running,

  /// This platform has no [RaspConfig] yet.
  notConfigured,

  /// The SDK refused to start; the app carries on unprotected.
  failed,
}

/// A send, download or decrypt refused because this copy of the app was found
/// tampered with or instrumented. The message is shown to the user as is.
class SecurityRestrictedException implements Exception {
  const SecurityRestrictedException();

  @override
  String toString() =>
      'MiniGo turned off transfers on this copy of the app. Reinstall it, '
      'then try again.';
}

/// Reported to the crash reporter when a critical threat is detected.
class SecurityThreatDetected implements Exception {
  const SecurityThreatDetected(this.threat);

  final Threat threat;

  @override
  String toString() => 'Security threat detected: ${threat.name}';
}

/// Runtime app self-protection (freeRASP), and MiniGo's response to it.
///
/// Each threat is logged once per process, by name and severity only: never
/// device details, file names, codes or the apps installed beside MiniGo.
///
/// In release builds a critical threat puts the app in [restricted] mode for
/// the rest of the process: [ensureTransfersAllowed] refuses to send, download
/// or decrypt, and `SecurityGate` replaces the UI with a reinstall notice.
/// Nothing is persisted and the identity is left alone, so a false positive
/// costs a reinstall, never the user's code, contacts or keys. Signing the
/// anonymous session out would lose them for good, and a hooked process
/// could read the token anyway.
class AppSecurity {
  AppSecurity._();
  static final AppSecurity instance = AppSecurity._();

  /// True once a critical threat has been acted on. Never goes back.
  final ValueNotifier<bool> restricted = ValueNotifier(false);

  final Set<Threat> _detected = {};
  bool _malwareLogged = false;

  /// Threats reported so far in this process.
  Set<Threat> get detected => Set.unmodifiable(_detected);

  RaspStatus _status = RaspStatus.notStarted;
  RaspStatus get status => _status;

  /// Whether critical threats restrict the app. Only release builds do:
  /// debug and profile builds run under debuggers and on emulators, and
  /// testers attach hooking tools on purpose.
  @visibleForTesting
  bool enforce = kReleaseMode;

  static ThreatSeverity severityOf(Threat threat) => switch (threat) {
        Threat.appIntegrity || Threat.hooks => ThreatSeverity.critical,
        Threat.privilegedAccess ||
        Threat.bootloader ||
        Threat.debug ||
        Threat.simulator ||
        Threat.devMode ||
        Threat.adbEnabled ||
        Threat.unofficialStore ||
        Threat.deviceBinding ||
        Threat.multiInstance ||
        Threat.automation ||
        Threat.timeSpoofing ||
        Threat.locationSpoofing ||
        Threat.obfuscationIssues =>
          ThreatSeverity.warning,
        Threat.deviceId ||
        Threat.passcode ||
        Threat.secureHardwareNotAvailable ||
        Threat.systemVPN ||
        Threat.unsecureWiFi ||
        Threat.screenshot ||
        Threat.screenRecording =>
          ThreatSeverity.info,
      };

  /// Starts freeRASP. Call once from `main`, after Firebase (so findings
  /// reach the crash reporter) and before `runApp` (so a compromised copy
  /// never shows the app).
  ///
  /// Fails open: if the SDK can't start, the app runs unprotected and the
  /// failure is reported, rather than every user being locked out by an SDK
  /// fault.
  Future<void> start() async {
    final config = RaspConfig.build();
    if (config == null) {
      _status = RaspStatus.notConfigured;
      Analytics.instance.logEvent(AnalyticsEvents.securityRaspUnavailable, {
        'reason': 'not_configured',
        'platform': defaultTargetPlatform.name,
      });
      return;
    }

    try {
      await Talsec.instance.attachListener(_threatCallback());
      await Talsec.instance.attachExecutionStateListener(
        RaspExecutionStateCallback(
          onAllChecksFinished: () => Analytics.instance
              .logEvent(AnalyticsEvents.securityChecksFinished),
        ),
      );
      await Talsec.instance.start(config);
      _status = RaspStatus.running;
      Analytics.instance.logEvent(
        AnalyticsEvents.securityRaspStarted,
        {'prod': config.isProd},
      );
    } catch (e, stack) {
      _status = RaspStatus.failed;
      Analytics.instance.logError(
        AnalyticsEvents.securityRaspUnavailable,
        e,
        stack: stack,
        props: {'reason': 'start_failed'},
      );
    }
  }

  /// Throws [SecurityRestrictedException] once the app is [restricted].
  /// Called where file bytes or keys are about to be handled.
  void ensureTransfersAllowed() {
    if (restricted.value) throw const SecurityRestrictedException();
  }

  ThreatCallback _threatCallback() {
    // freeRASP exports its own VoidCallback, so spell the type out.
    void Function() on(Threat threat) => () => handleThreat(threat);
    return ThreatCallback(
      onAppIntegrity: on(Threat.appIntegrity),
      onHooks: on(Threat.hooks),
      onPrivilegedAccess: on(Threat.privilegedAccess),
      onBootloader: on(Threat.bootloader),
      onDebug: on(Threat.debug),
      onSimulator: on(Threat.simulator),
      onDevMode: on(Threat.devMode),
      onADBEnabled: on(Threat.adbEnabled),
      onUnofficialStore: on(Threat.unofficialStore),
      onDeviceBinding: on(Threat.deviceBinding),
      onMultiInstance: on(Threat.multiInstance),
      onAutomation: on(Threat.automation),
      onTimeSpoofing: on(Threat.timeSpoofing),
      onLocationSpoofing: on(Threat.locationSpoofing),
      onObfuscationIssues: on(Threat.obfuscationIssues),
      onDeviceID: on(Threat.deviceId),
      onPasscode: on(Threat.passcode),
      onSecureHardwareNotAvailable: on(Threat.secureHardwareNotAvailable),
      onSystemVPN: on(Threat.systemVPN),
      onUnsecureWiFi: on(Threat.unsecureWiFi),
      onScreenshot: on(Threat.screenshot),
      onScreenRecording: on(Threat.screenRecording),
      onMalware: _handleMalware,
    );
  }

  /// Logs [threat] the first time it is seen and, when it is critical in an
  /// enforcing build, restricts the app. freeRASP re-runs its checks while
  /// the app is open, so the same threat can arrive many times.
  @visibleForTesting
  void handleThreat(Threat threat) {
    if (!_detected.add(threat)) return;
    final severity = severityOf(threat);
    final props = {'threat': threat.name, 'severity': severity.name};
    Analytics.instance.setCustomKey(
      'rasp_threats',
      (_detected.map((t) => t.name).toList()..sort()).join(','),
    );

    if (severity != ThreatSeverity.critical) {
      Analytics.instance.logEvent(AnalyticsEvents.securityThreat, props);
      return;
    }
    // A non-fatal report, so critical findings show up as issues rather than
    // only as breadcrumbs on some later crash.
    Analytics.instance.logError(
      AnalyticsEvents.securityThreat,
      SecurityThreatDetected(threat),
      stack: StackTrace.current,
      props: props,
    );
    if (enforce && !restricted.value) {
      restricted.value = true;
      Analytics.instance.logEvent(AnalyticsEvents.securityRestricted, props);
    }
  }

  /// Android only. Logs how many suspicious apps were found, never which:
  /// the list of apps on someone's phone is personal.
  void _handleMalware(List<SuspiciousAppInfo?> apps) {
    if (_malwareLogged || apps.isEmpty) return;
    _malwareLogged = true;
    Analytics.instance.logEvent(AnalyticsEvents.securityThreat, {
      'threat': 'malware',
      'severity': ThreatSeverity.warning.name,
      'count': apps.length,
    });
  }

  @visibleForTesting
  void resetForTest() {
    _detected.clear();
    _malwareLogged = false;
    _status = RaspStatus.notStarted;
    restricted.value = false;
    enforce = kReleaseMode;
  }
}
