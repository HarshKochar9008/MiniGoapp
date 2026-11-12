import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freerasp/freerasp.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:minigo/Minigo/theme/mini_theme.dart';
import 'package:minigo/core/analytics/analytics.dart';
import 'package:minigo/core/constants.dart';
import 'package:minigo/core/security/app_security.dart';
import 'package:minigo/core/security/rasp_config.dart';
import 'package:minigo/core/security/security_gate.dart';
import 'package:minigo/features/transfer/transfer_service.dart';

/// The code freeRASP's native side sends for each threat (see
/// `ThreatX.fromInt` in package:freerasp).
const _threatCodes = {
  Threat.hooks: 209533833,
  Threat.debug: 1268968002,
  Threat.passcode: 1293399086,
  Threat.deviceId: 1514211414,
  Threat.simulator: 477190884,
  Threat.appIntegrity: 1115787534,
  Threat.obfuscationIssues: 1001443554,
  Threat.deviceBinding: 1806586319,
  Threat.unofficialStore: 629780916,
  Threat.privilegedAccess: 44506749,
  Threat.secureHardwareNotAvailable: 1564314755,
  Threat.systemVPN: 659382561,
  Threat.devMode: 45291047,
  Threat.adbEnabled: 379769839,
  Threat.screenshot: 705651459,
  Threat.screenRecording: 64690214,
  Threat.multiInstance: 859307284,
  Threat.unsecureWiFi: 363588890,
  Threat.timeSpoofing: 189105221,
  Threat.locationSpoofing: 653273273,
  Threat.automation: 298453120,
  Threat.bootloader: 1651076936,
};

/// SHA-256 of the upload certificate, as `keytool -list -v` prints it.
const _uploadCertSha256 = '29:CE:C0:8A:92:10:6E:D7:A5:64:A8:F5:B5:CD:1F:2E:'
    '8A:C0:D5:7F:14:28:E4:6E:0E:AE:0B:C0:36:E2:BF:F9';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = MethodChannel('talsec.app/freerasp/methods');
  const threatEvents = EventChannel('talsec.app/freerasp/events');
  const stateEvents = EventChannel('talsec.app/freerasp/execution_state');

  late List<MethodCall> calls;
  MockStreamHandlerEventSink? threatSink;

  setUp(() {
    AppSecurity.instance.resetForTest();
    calls = [];
    threatSink = null;
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return null;
    });
    messenger.setMockStreamHandler(
      threatEvents,
      MockStreamHandler.inline(onListen: (_, sink) => threatSink = sink),
    );
    messenger.setMockStreamHandler(
      stateEvents,
      MockStreamHandler.inline(onListen: (_, __) {}),
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockStreamHandler(threatEvents, null);
    messenger.setMockStreamHandler(stateEvents, null);
    debugDefaultTargetPlatformOverride = null;
    AppSecurity.instance.resetForTest();
  });

  Future<void> emit(Threat threat) async {
    threatSink!.success(_threatCodes[threat]);
    await pumpEventQueue();
  }

  group('RaspConfig', () {
    test('matches the identifiers the builds actually use', () {
      final gradle = File('android/app/build.gradle.kts').readAsStringSync();
      expect(gradle,
          contains('applicationId = "${RaspConfig.androidPackageName}"'));

      final pbxproj = File('ios/Runner.xcodeproj/project.pbxproj')
          .readAsStringSync();
      for (final id in RaspConfig.iosBundleIds) {
        expect(pbxproj, contains('PRODUCT_BUNDLE_IDENTIFIER = $id;'));
      }
    });

    test('Android pins the upload certificate and trusts App Distribution',
        () {
      // Constructing the config runs freeRASP's own format checks.
      final android = RaspConfig.build()!.androidConfig!;
      expect(android.packageName, 'com.Zen.app');
      expect(android.signingCertHashes,
          contains(hashConverter.fromSha256toBase64(_uploadCertSha256)));
      expect(android.supportedStores, ['dev.firebase.appdistribution']);
    });

    test('runs the full checks only in release builds', () {
      final config = RaspConfig.build()!;
      expect(config.isProd, kReleaseMode);
      expect(config.killOnBypass, kReleaseMode);
      expect(config.watcherMail, AppConstants.supportEmail);
    });

    test('iOS stays off until the Apple Team ID is set', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final teamId = RaspConfig.appleTeamId;
      if (teamId == null) {
        expect(RaspConfig.build(), isNull);
      } else {
        final ios = RaspConfig.build()!.iosConfig!;
        expect(ios.teamId, teamId);
        expect(ios.bundleIds, RaspConfig.iosBundleIds);
      }
    });
  });

  group('AppSecurity', () {
    test('only tampering and hooking are critical', () {
      final critical = Threat.values
          .where((t) => AppSecurity.severityOf(t) == ThreatSeverity.critical);
      expect(critical.toSet(), {Threat.appIntegrity, Threat.hooks});
    });

    test('starts freeRASP and handles every threat it can report', () async {
      expect(_threatCodes.keys.toSet(), Threat.values.toSet());
      for (final MapEntry(key: threat, value: code) in _threatCodes.entries) {
        expect(ThreatX.fromInt(code), threat);
      }

      await AppSecurity.instance.start();

      expect(AppSecurity.instance.status, RaspStatus.running);
      final start = calls.singleWhere((c) => c.method == 'start');
      final sent = jsonDecode((start.arguments as Map)['config'] as String)
          as Map<String, dynamic>;
      expect(sent['androidConfig']['packageName'], 'com.Zen.app');

      for (final threat in Threat.values) {
        await emit(threat);
      }
      expect(AppSecurity.instance.detected, Threat.values.toSet());
      // Tests run as a debug build, which never restricts.
      expect(AppSecurity.instance.restricted.value, isFalse);
    });

    test('a critical threat restricts an enforcing build; warnings do not',
        () async {
      AppSecurity.instance.enforce = true;
      await AppSecurity.instance.start();

      for (final threat in [
        Threat.privilegedAccess,
        Threat.debug,
        Threat.simulator,
        Threat.devMode,
        Threat.unofficialStore,
      ]) {
        await emit(threat);
      }
      expect(AppSecurity.instance.restricted.value, isFalse);
      AppSecurity.instance.ensureTransfersAllowed();

      await emit(Threat.hooks);
      expect(AppSecurity.instance.restricted.value, isTrue);
      expect(AppSecurity.instance.ensureTransfersAllowed,
          throwsA(isA<SecurityRestrictedException>()));
    });

    test('fails open when the SDK will not start', () async {
      messenger.setMockMethodCallHandler(methods, (call) async {
        throw PlatformException(code: 'error', message: 'refused');
      });

      await AppSecurity.instance.start();

      expect(AppSecurity.instance.status, RaspStatus.failed);
      expect(AppSecurity.instance.restricted.value, isFalse);
    });

    test('transfers refuse to start once restricted', () async {
      AppSecurity.instance.enforce = true;
      AppSecurity.instance.handleThreat(Threat.appIntegrity);

      await expectLater(
        TransferService.sendFiles(
          senderId: 'sender',
          receiverId: 'receiver',
          files: const [],
          onProgress: (_) {},
          allowUnencrypted: true,
        ),
        throwsA(isA<SecurityRestrictedException>()),
      );
      await expectLater(
        TransferService.downloadToFile(
          storagePath: 'transfer/0_file.bin',
          fileName: 'file.bin',
          onProgress: (_, __) {},
        ),
        throwsA(isA<SecurityRestrictedException>()),
      );
    });
  });

  group('Log redaction', () {
    test('file names stay out of logs but not out of the UI', () {
      final tooLarge = FileTooLargeException('passport.pdf', 200 << 20);
      expect(tooLarge.toString(), contains('passport.pdf'));
      expect(describeForLogs(tooLarge), isNot(contains('passport')));
      expect(redactForReport(tooLarge).toString(), isNot(contains('passport')));

      const fsError = FileSystemException(
        'Cannot open file',
        '/data/cache/1730_123_passport.pdf',
        OSError('No such file or directory', 2),
      );
      expect(describeForLogs(fsError), contains('Cannot open file'));
      expect(describeForLogs(fsError), isNot(contains('passport')));
    });

    test('other errors are reported unchanged', () {
      final error = StateError('backend unreachable');
      expect(redactForReport(error), same(error));
      expect(describeForLogs(error), error.toString());
    });
  });

  group('SecurityGate', () {
    testWidgets('replaces the app with the reinstall notice', (tester) async {
      tester.view.physicalSize = const Size(320 * 3, 640 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        theme: buildMiniTheme(),
        builder: (context, child) => SecurityGate(child: child!),
        home: const Scaffold(body: Text('home')),
      ));
      expect(find.text('home'), findsOneWidget);
      expect(find.byType(SecurityLockScreen), findsNothing);

      AppSecurity.instance.restricted.value = true;
      await tester.pump();

      expect(find.text('home'), findsNothing);
      expect(find.text('Reinstall MiniGo'), findsOneWidget);
      expect(find.textContaining('Google Play'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
