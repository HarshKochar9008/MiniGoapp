import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minigo/core/security/app_lock.dart';
import 'package:minigo/core/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

// path_provider is deliberately not mocked here: answering it makes
// google_fonts throw (see widget-test gotchas), so these tests stay on the
// SharedPreferences and local_auth seams only.
void main() {
  setUp(() {
    AppLock.locked.value = false;
    AppLock.authenticateOverride = null;
    AppLock.clock = DateTime.now;
  });

  tearDown(() {
    AppLock.authenticateOverride = null;
    AppLock.clock = DateTime.now;
  });

  group('AppLock state', () {
    test('is off by default and does not lock on start', () async {
      SharedPreferences.setMockInitialValues({});
      await AppLock.initialize();
      expect(AppLock.isEnabled, isFalse);
      expect(AppLock.locked.value, isFalse);
    });

    test('a saved "on" locks before the first frame', () async {
      SharedPreferences.setMockInitialValues({AppLock.prefKey: true});
      await AppLock.initialize();
      expect(AppLock.isEnabled, isTrue);
      expect(AppLock.locked.value, isTrue);
    });

    test('lockIfEnabled does nothing while the lock is off', () async {
      SharedPreferences.setMockInitialValues({});
      await AppLock.initialize();
      AppLock.lockIfEnabled();
      expect(AppLock.locked.value, isFalse);
    });

    test('setEnabled(false) clears a lock and persists the choice', () async {
      SharedPreferences.setMockInitialValues({AppLock.prefKey: true});
      await AppLock.initialize();
      await AppLock.setEnabled(false);
      expect(AppLock.locked.value, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(AppLock.prefKey), isFalse);
    });
  });

  group('AppLockGate', () {
    testWidgets('covers content until the user passes the check',
        (tester) async {
      SharedPreferences.setMockInitialValues({AppLock.prefKey: true});
      await AppLock.initialize();

      var prompts = 0;
      AppLock.authenticateOverride = (_) async {
        prompts++;
        return false;
      };

      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: const AppLockGate(child: Text('inside the app')),
      ));
      await tester.pump();

      // The first frame asks once on its own.
      expect(prompts, 1);
      expect(AppLock.locked.value, isTrue);
      expect(find.text('MiniGo is locked'), findsOneWidget);

      // A failed or cancelled check leaves the lock on, with a manual retry.
      await tester.tap(find.text('Unlock'));
      await tester.pump();
      expect(prompts, 2);
      expect(AppLock.locked.value, isTrue);

      AppLock.authenticateOverride = (_) async {
        prompts++;
        return true;
      };
      await tester.tap(find.text('Unlock'));
      await tester.pump();
      await tester.pump();
      expect(AppLock.locked.value, isFalse);
      expect(find.text('MiniGo is locked'), findsNothing);
    });

    testWidgets('locks again after a long background, not a short one',
        (tester) async {
      SharedPreferences.setMockInitialValues({AppLock.prefKey: true});
      await AppLock.initialize();
      // Declines any prompt, so the lock stays on once it applies.
      AppLock.authenticateOverride = (_) async => false;
      AppLock.unlock();

      var now = DateTime(2026, 11, 15, 10);
      AppLock.clock = () => now;

      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: const AppLockGate(child: Text('inside the app')),
      ));
      await tester.pump();
      expect(AppLock.locked.value, isFalse);

      final binding = tester.binding;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();

      // Back within the grace period: still unlocked.
      now = now.add(const Duration(seconds: 20));
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(AppLock.locked.value, isFalse);

      // Away past the grace period: locked again.
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      now = now.add(AppLock.graceperiod + const Duration(seconds: 1));
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(AppLock.locked.value, isTrue);
    });
  });
}
