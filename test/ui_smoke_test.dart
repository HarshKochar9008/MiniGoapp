import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:minigo/Minigo/theme/mini_theme.dart';
import 'package:minigo/Minigo/widgets/mini_code_reel.dart';
import 'package:minigo/Minigo/widgets/mini_ufo.dart';
import 'package:minigo/Minigo/widgets/mini_widgets.dart';

/// Layout smoke tests for the shared design system: every reusable surface has
/// to build without overflow or paint errors in both themes, on a small screen.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Themes and MiniText resolve Google Fonts eagerly; keep the test offline and
  // let it fall back to the bundled default font.
  GoogleFonts.config.allowRuntimeFetching = false;

  Widget host(ThemeData theme, Widget child) => MaterialApp(
        theme: theme,
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: child,
          ),
        ),
      );

  Widget gallery() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionHeader(title: 'Section', counter: '3'),
          MiniCard(
            child: Column(
              children: const [
                MiniFileRow(
                    name: 'holiday-photo.jpg',
                    size: '2.4 MB',
                    mimeCategory: 'Image'),
                HairLine(),
                MiniFileRow(
                    name: 'contract.pdf', size: '188 KB', mimeCategory: 'PDF'),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const CodeChip(code: 'A4X9K2'),
          const SizedBox(height: 12),
          MiniButton(label: 'Primary', onPressed: () {}),
          const SizedBox(height: 8),
          MiniButton(
            label: 'Secondary',
            style: MiniBtnStyle.secondary,
            onPressed: () {},
          ),
          const SizedBox(height: 8),
          const MiniButton(label: 'Disabled'),
          const SizedBox(height: 8),
          MiniButton(label: 'Loading', loading: true, onPressed: () {}),
          const SizedBox(height: 8),
          MiniButton(
            label: 'Danger',
            style: MiniBtnStyle.danger,
            onPressed: () {},
          ),
          const SizedBox(height: 12),
          const StatusBanner(
            icon: Icons.wifi_off_rounded,
            text: 'You are offline',
            tint: MiniColors.warn,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: MiniTabPill(label: 'All', active: true, onTap: () {}),
              ),
              Expanded(
                child: MiniTabPill(label: 'Sent', active: false, onTap: () {}),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Center(child: ProgressArc(progress: 0.42, label: 'Uploading')),
          const SizedBox(height: 12),
          const TransferTileSkeleton(),
          const SizedBox(height: 12),
          const MiniIconPlate(
              icon: Icons.bolt_rounded, tint: MiniColors.blue600),
        ],
      );

  for (final name in ['light', 'dark']) {
    testWidgets('design system builds in $name theme', (tester) async {
      // Narrow phone width — the size most likely to overflow.
      tester.view.physicalSize = const Size(320 * 3, 900 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      final theme = name == 'light' ? buildMiniTheme() : buildMiniDarkTheme();
      await tester.pumpWidget(host(theme, gallery()));
      await tester.pump(const Duration(milliseconds: 400));

      expect(tester.takeException(), isNull);
      expect(find.text('Primary'), findsOneWidget);
      expect(find.text('A4X · 9K2'), findsOneWidget);
      expect(find.text('42%'), findsOneWidget);
    });
  }

  testWidgets('progress arc clamps out-of-range values', (tester) async {
    await tester.pumpWidget(
      host(buildMiniTheme(), const ProgressArc(progress: 1.8)),
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(
      host(buildMiniTheme(), const ProgressArc(progress: -0.5)),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('animated logo runs its arrival and hover loop', (tester) async {
    await tester.pumpWidget(host(buildMiniTheme(), const MiniUfo(size: 160)));

    // Mid-arrival: warp streaks and the flight transform are live.
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);

    // Past arrival, into the hover loop.
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump(const Duration(milliseconds: 1200));
    expect(tester.takeException(), isNull);
    expect(find.byType(MiniUfo), findsOneWidget);
  });

  testWidgets('animated logo settles when reduce-motion is on', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildMiniTheme(),
        home: const MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: Scaffold(body: Center(child: MiniUfo(size: 140))),
        ),
      ),
    );
    // No pending frames should remain — nothing is animating.
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  group('code reel', () {
    Widget reel(String code, {bool reduceMotion = false}) => MaterialApp(
          theme: buildMiniTheme(),
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduceMotion),
            child: Scaffold(
              body: Center(
                child: MiniCodeReel(
                  code: code,
                  style: MiniText.codeLarge,
                  haptics: false,
                ),
              ),
            ),
          ),
        );

    testWidgets('spins, then lands on every character of the code',
        (tester) async {
      await tester.pumpWidget(reel('A4X9K2'));

      // Still spinning partway in — the code is not just drawn statically.
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.hasRunningAnimations, isTrue);
      expect(tester.takeException(), isNull);

      await tester.pumpAndSettle();
      // One reel per character, each settled on its target glyph.
      for (final glyph in 'A4X9K2'.split('')) {
        expect(find.text(glyph), findsWidgets, reason: 'reel missing $glyph');
      }
      expect(find.text(' · '), findsOneWidget);
    });

    testWidgets('lands immediately when reduce-motion is on', (tester) async {
      await tester.pumpWidget(reel('B7MZ35', reduceMotion: true));
      // Settled on the first frame — nothing spins at all.
      expect(tester.hasRunningAnimations, isFalse);
      expect(tester.takeException(), isNull);
      for (final glyph in 'B7MZ35'.split('')) {
        expect(find.text(glyph), findsWidgets, reason: 'reel missing $glyph');
      }
    });

    testWidgets('re-rolls when the code changes', (tester) async {
      await tester.pumpWidget(reel('A4X9K2'));
      await tester.pumpAndSettle();

      await tester.pumpWidget(reel('Z9P2WD'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (final glyph in 'Z9P2WD'.split('')) {
        expect(find.text(glyph), findsWidgets, reason: 'reel missing $glyph');
      }
    });

    testWidgets('shows a glyph outside the pool without spinning',
        (tester) async {
      // 'O' and '1' are excluded from the code alphabet on purpose.
      await tester.pumpWidget(reel('O1'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('O'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
    });
  });
}
