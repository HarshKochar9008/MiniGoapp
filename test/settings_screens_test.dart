import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:minigo/Minigo/theme/mini_theme.dart';
import 'package:minigo/core/constants.dart';
import 'package:minigo/core/contacts/contact_aliases.dart';
import 'package:minigo/core/contacts/recent_recipients.dart';
import 'package:minigo/core/theme.dart';
import 'package:minigo/features/identity/identity_service.dart';
import 'package:minigo/features/settings/about_screen.dart';
import 'package:minigo/features/settings/app_facts.dart';
import 'package:minigo/features/settings/privacy_screen.dart';
import 'package:minigo/features/settings/release_notes.dart';
import 'package:minigo/features/settings/update_check.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// About and Privacy & Security have to lay out on a small phone in both
/// themes, and destructive actions may only run once their sheet is confirmed.
/// Platform plugins (path_provider, secure storage, Supabase) are absent here,
/// which also exercises the screens' "unavailable" states.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  const identity = UserIdentity(id: 'user-1', shortCode: 'A4X9K2');

  setUp(() {
    // Unanswered platform calls never complete under fake async. Answer the
    // temp-directory lookup with null so path_provider throws and the cache
    // row settles on "Unavailable". Leave every other lookup pending, as it
    // is without a mock: google_fonts reads the support directory and, with
    // fetching off, throws for each font as soon as that call is answered.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) => call.method == 'getTemporaryDirectory'
          ? Future<Object?>.value()
          : Completer<Object?>().future,
    );
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'MiniGo',
      packageName: 'com.zen.app',
      version: '1.0.0',
      buildNumber: '7',
      buildSignature: '',
    );
    ThemeController.themeMode.value = ThemeController.defaultMode;
  });

  Future<void> pumpScreen(
    WidgetTester tester,
    Widget screen, {
    bool dark = false,
  }) async {
    // Narrow phone width — the size most likely to overflow.
    tester.view.physicalSize = const Size(320 * 3, 900 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: dark ? buildMiniDarkTheme() : buildMiniTheme(),
      home: screen,
    ));
    await tester.pumpAndSettle();
  }

  Finder page() => find.byType(Scrollable).first;

  Future<void> openRow(WidgetTester tester, String title) async {
    await tester.scrollUntilVisible(find.text(title), 250, scrollable: page());
    // ensureVisible jumps without a frame; lay out before hit-testing.
    await tester.pumpAndSettle();
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
  }

  group('About', () {
    for (final dark in [false, true]) {
      testWidgets('builds on a small phone (${dark ? 'dark' : 'light'})',
          (tester) async {
        await pumpScreen(tester, const AboutScreen(), dark: dark);

        expect(find.text('Share simply. Stay in control.'), findsOneWidget);
        expect(find.text('Version 1.0.0 (7)'), findsOneWidget);

        await tester.scrollUntilVisible(
          find.text('Made with care by the MiniGo team.'),
          300,
          scrollable: page(),
        );
        expect(find.text('Version 1.0.0 · Build 7'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('What’s New shows the running version’s notes', (tester) async {
      await pumpScreen(tester, const AboutScreen());
      await openRow(tester, 'What’s New');

      expect(find.text('What’s new in 1.0.0'), findsOneWidget);
      expect(find.text('Rooms'), findsOneWidget);
    });

    testWidgets('legal rows open the in-app terms and privacy policy',
        (tester) async {
      await pumpScreen(tester, const AboutScreen());

      await openRow(tester, 'Terms of Service');
      expect(find.text('Provided as-is'.toUpperCase()), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await openRow(tester, 'Privacy Policy');
      expect(find.text('What MiniGo collects'.toUpperCase()), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Privacy & Security', () {
    for (final dark in [false, true]) {
      testWidgets('builds on a small phone (${dark ? 'dark' : 'light'})',
          (tester) async {
        await pumpScreen(
          tester,
          const PrivacyScreen(identity: identity),
          dark: dark,
        );

        expect(find.textContaining('Your privacy matters.'), findsOneWidget);
        expect(find.text('Anonymous'), findsOneWidget);
        expect(find.text('This device'), findsOneWidget);

        await tester.scrollUntilVisible(
          find.text('No expiry'),
          250,
          scrollable: page(),
        );
        expect(
          find.text('Files can be downloaded for '
              '${AppFacts.transferLifetime} after they’re sent.'),
          findsOneWidget,
        );

        await tester.scrollUntilVisible(
          find.text('Report a security issue'),
          250,
          scrollable: page(),
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('reset preferences waits for confirmation', (tester) async {
      await ThemeController.setThemeMode(ThemeMode.dark);
      await pumpScreen(tester, const PrivacyScreen(identity: identity));
      await openRow(tester, 'Reset app preferences');

      expect(find.text('Reset app preferences?'), findsOneWidget);
      expect(find.text('Appearance: Dark → Light'), findsOneWidget);
      expect(ThemeController.themeMode.value, ThemeMode.dark);

      await tester.tap(find.text('Reset preferences'));
      await tester.pumpAndSettle();

      expect(ThemeController.themeMode.value, ThemeController.defaultMode);
      expect(find.text('Reset app preferences?'), findsNothing);
      expect(find.text('Preferences reset'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('theme_mode'), isNull);
    });

    testWidgets('cancelling a destructive sheet changes nothing',
        (tester) async {
      await ThemeController.setThemeMode(ThemeMode.dark);
      await pumpScreen(tester, const PrivacyScreen(identity: identity));
      await openRow(tester, 'Reset app preferences');

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Reset app preferences?'), findsNothing);
      expect(ThemeController.themeMode.value, ThemeMode.dark);
    });

    testWidgets(
        'account deletion stops before touching the device when the server '
        'can’t confirm it', (tester) async {
      SharedPreferences.setMockInitialValues({
        AppConstants.prefShortCode: identity.shortCode,
        AppConstants.prefUserDbId: identity.id,
      });
      await pumpScreen(tester, const PrivacyScreen(identity: identity));
      await openRow(tester, 'Sign out and delete account');

      expect(find.text('ON MINIGO’S SERVERS'), findsOneWidget);
      expect(find.text('REMOVED FROM THIS DEVICE'), findsOneWidget);
      expect(find.textContaining('A4X · 9K2'), findsOneWidget);

      // No backend in tests, so the server retirement can't be confirmed.
      await tester.ensureVisible(find.text('Sign out and delete'));
      await tester.tap(find.text('Sign out and delete'));
      await tester.pumpAndSettle();

      expect(find.textContaining('nothing was deleted'), findsOneWidget);
      expect(find.text('Sign out and delete account?'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AppConstants.prefShortCode), identity.shortCode);
      expect(tester.takeException(), isNull);
    });
  });

  group('supporting logic', () {
    test('versions compare numerically', () {
      expect(isNewerVersion('1.10.0', '1.9.2'), isTrue);
      expect(isNewerVersion('2.0.0', '1.99.99'), isTrue);
      expect(isNewerVersion('1.0.0', '1.0.0'), isFalse);
      expect(isNewerVersion('1.0', '1.0.1'), isFalse);
      expect(isNewerVersion('1.0.0+9', '1.0.0'), isFalse);
    });

    test('release notes fall back to the newest earlier release', () {
      expect(ReleaseNotes.forVersion('1.0.0')?.version, '1.0.0');
      expect(ReleaseNotes.forVersion('1.0.4')?.version, '1.0.0');
      expect(ReleaseNotes.forVersion('0.9.0'), isNull);
    });

    test('configured limits read naturally', () {
      expect(
        AppFacts.transferLifetime,
        '${AppConstants.transferTtlHours} hours',
      );
      expect(AppFacts.maxFileSize, '100 MB');
      // Mirrors AppConstants.roomLifetimeMinutesOptions.
      expect(AppFacts.roomLifetimes, '30 minutes, 1 hour, or 2 hours');
    });

    test('clearing local lists forgets the in-memory copies too', () async {
      await RecentRecipients.record('A4X9K2');
      await ContactAliases.setAlias('user-2', 'Alex');

      await RecentRecipients.clear();
      await ContactAliases.clear();

      expect(RecentRecipients.all, isEmpty);
      expect(ContactAliases.aliasFor('user-2'), isNull);

      // A later write must not resurrect what was cleared.
      await RecentRecipients.record('B7Y3M4');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('recent_recipients'), isNot(contains('A4X9K2')));
    });
  });
}
