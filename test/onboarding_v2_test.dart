import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:minigo/Minigo/theme/mini_theme.dart';
import 'package:minigo/core/constants.dart';
import 'package:minigo/features/identity/identity_service.dart';
import 'package:minigo/features/onboarding_v2/onboarding_content.dart';
import 'package:minigo/features/onboarding_v2/onboarding_experiment.dart';
import 'package:minigo/features/onboarding_v2/onboarding_flow.dart';
import 'package:minigo/features/onboarding_v2/onboarding_services.dart';
import 'package:minigo/features/onboarding_v2/onboarding_sounds.dart';
import 'package:minigo/features/onboarding_v2/screens/onb_share_screen.dart';
import 'package:minigo/features/onboarding_v2/widgets/onb_slot_machine.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records what the flow asked for instead of touching Supabase/Firebase.
class FakeServices extends OnbServices {
  FakeServices({this.failures = 0});

  /// How many identity calls fail before one succeeds.
  int failures;
  int identityCalls = 0;
  int notificationRequests = 0;
  final sounds = <OnbSoundCue>[];
  String? savedNickname;
  bool completed = false;
  Set<OnbPain>? savedRelates;

  @override
  Future<UserIdentity> createIdentity() async {
    identityCalls++;
    if (failures > 0) {
      failures--;
      throw Exception('offline');
    }
    return const UserIdentity(id: 'user-1', shortCode: 'A4X9K2');
  }

  @override
  Future<bool> requestNotifications() async {
    notificationRequests++;
    return true;
  }

  @override
  Future<void> preloadSounds() async {}

  @override
  Future<void> playSound(OnbSoundCue cue) async => sounds.add(cue);

  @override
  Future<void> disposeSounds() async {}

  @override
  Future<void> saveNickname(String nickname) async => savedNickname = nickname;

  @override
  Future<void> markComplete() async => completed = true;

  @override
  Future<void> saveAnswers({required Set<OnbPain> relates}) async =>
      savedRelates = {...relates};

  @override
  Future<bool> shareCard({
    required Uint8List? png,
    required String text,
    required String fileStem,
    Rect? origin,
  }) async =>
      true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;
  // main() loads .env in the app; the share card's QR link reads it.
  dotenv.loadFromString(envString: 'SUPABASE_URL=https://example.supabase.co');

  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// Steps the clock in frame-sized slices so timers and animations run.
  Future<void> advance(WidgetTester t, int ms) async {
    for (var i = 0; i < ms ~/ 50; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> tapText(WidgetTester t, String text, {int settle = 700}) async {
    final finder = find.text(text);
    expect(finder, findsWidgets, reason: 'looking for "$text"');
    await t.ensureVisible(finder.last);
    await t.pump();
    await t.tap(finder.last);
    await advance(t, settle);
  }

  final lever = find.byKey(OnbSlotMachine.leverKey);

  /// Pulls the lever on the craft screen and waits for the code to land.
  Future<void> pullLever(WidgetTester t,
      {bool drag = false, int settle = 3200}) async {
    expect(find.text('Pull the lever'), findsOneWidget);
    if (drag) {
      await t.drag(lever, const Offset(0, 240));
    } else {
      await t.tap(lever);
    }
    await advance(t, settle);
  }

  Future<void> pumpFlow(
    WidgetTester tester,
    FakeServices services, {
    required VoidCallback onComplete,
    bool paywall = false,
    ThemeData? theme,
    Size size = const Size(360, 740),
    bool reduceMotion = true,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? buildMiniTheme(),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: reduceMotion,
              textScaler: TextScaler.linear(textScale),
            ),
            child: OnboardingFlowV2(
              onComplete: onComplete,
              services: services,
              showProPaywall: paywall,
            ),
          ),
        ),
      ),
    );
    await advance(tester, 600);
  }

  /// Welcome → swipe deck (answered per [agree]) → solution, stopping on the
  /// nickname step.
  Future<void> answerQuestions(WidgetTester t, List<bool> agree) async {
    await tapText(t, 'Get started');
    expect(find.text('Sound familiar?'), findsOneWidget);
    for (final yes in agree) {
      await tapText(t, yes ? 'That’s me' : 'Not me', settle: 200);
    }
    await advance(t, 900);
    expect(find.text('A simpler way\nto send files'), findsOneWidget);
    await tapText(t, 'Set me up');
    expect(find.text('What should we call you?'), findsOneWidget);
  }

  /// Text taller than its box. Flutter clips it without reporting an
  /// overflow, so this measures each paragraph instead.
  List<String> clippedText(WidgetTester t) => [
        for (final p in t.allRenderObjects.whereType<RenderParagraph>())
          if (p.hasSize &&
              (TextPainter(
                    text: p.text,
                    textScaler: p.textScaler,
                    textDirection: p.textDirection,
                    maxLines: p.maxLines,
                  )..layout(maxWidth: p.size.width + 1))
                      .height >
                  p.size.height + 1)
            p.text.toPlainText(),
      ];

  /// Agree with cards 1 and 3 (swap numbers, group chat).
  const agreeOddCards = [true, false, true, false];
  const agreeNone = [false, false, false, false];

  group('experiment', () {
    test('draws a variant once and keeps it', () async {
      final first = await OnboardingExperiment.assign(random: Random(1));
      final again = await OnboardingExperiment.assign(random: Random(2));
      expect(again, first);
      expect(await OnboardingExperiment.current(), first);
    });

    test('installs without a draw replay the classic flow', () async {
      expect(await OnboardingExperiment.current(), OnboardingVariant.classic);
    });
  });

  group('slot machine reels', () {
    const len = AppConstants.codeAlphabet.length;

    test('every reel lands exactly on its target symbol', () {
      final rng = Random(4);
      for (var n = 0; n < 200; n++) {
        final from = rng.nextInt(len);
        final target = rng.nextInt(len);
        final turns = 2 + rng.nextInt(5);
        final travel = slotTravel(
            from: from, target: target, turns: turns, alphabetLength: len);
        expect(travel, greaterThanOrEqualTo(turns * len));
        final landed = (from + slotReelOffset(1, travel.toDouble())).round();
        expect(landed % len, target);
      }
    });

    test('a rolling reel lands on its target from any fractional position', () {
      final rng = Random(9);
      for (var n = 0; n < 200; n++) {
        final position = rng.nextDouble() * 500;
        final target = rng.nextInt(len);
        final travel = slotTravelNear(
          position: position,
          target: target,
          desired: rng.nextDouble() * 40,
          alphabetLength: len,
        );
        expect(travel, greaterThanOrEqualTo(2));
        final end = position + slotReelOffset(1, travel, windUp: false);
        expect((end - end.roundToDouble()).abs(), lessThan(1e-9));
        expect(end.round() % len, target);
      }
    });

    test('a spin winds up, overshoots, then snaps back onto the target', () {
      const travel = 93.0;
      expect(slotReelOffset(0, travel), 0);
      expect(slotReelOffset(0.035, travel), lessThan(0)); // wind-up
      expect(slotReelOffset(0.88, travel), greaterThan(travel)); // overshoot
      expect(slotReelOffset(1, travel), travel);
      // Already rolling: no wind-up.
      expect(slotReelOffset(0.035, travel, windUp: false), greaterThan(0));
      // Never runs backwards during the main run.
      var last = slotReelOffset(0.07, travel);
      for (var t = 0.08; t < 0.88; t += 0.01) {
        final now = slotReelOffset(t, travel);
        expect(now, greaterThanOrEqualTo(last));
        last = now;
      }
    });
  });

  group('copy stays honest', () {
    test('expiry is described as expiring until deletion is verified', () {
      expect(kExpiryDeletesFiles, isFalse);
      expect(onbPainOption(OnbPain.staysOnline).fix, contains('expire'));
    });
  });

  testWidgets(
      'welcome goes straight to the swipe deck — no goal or pain '
      'questions', (tester) async {
    await pumpFlow(tester, FakeServices(), onComplete: () {});
    await tapText(tester, 'Get started');
    expect(find.text('Sound familiar?'), findsOneWidget);
    expect(find.text('What brings you to MiniGo?'), findsNothing);
    expect(find.text('Pick as many as you like.'), findsNothing);
  });

  testWidgets('main path runs end to end and saves what was answered',
      (tester) async {
    final services = FakeServices();
    var done = false;
    await pumpFlow(tester, services, onComplete: () => done = true);

    await answerQuestions(tester, agreeOddCards);
    await tester.enterText(find.byType(TextField), 'Alex');
    await tapText(tester, 'Looks good');

    // Pull the lever: the code is crafted and revealed on the same screen.
    expect(find.text('This is you.'), findsNothing);
    await pullLever(tester, drag: true);
    expect(services.sounds, [OnbSoundCue.leverPull, OnbSoundCue.codeReveal]);
    expect(services.identityCalls, 1);
    expect(find.text('This is you.'), findsOneWidget);
    // The big code row is read out character by character.
    expect(find.bySemanticsLabel('Your code: A 4 X 9 K 2'), findsOneWidget);
    await tapText(tester, 'Make my share card');

    expect(find.text('Make your share card'), findsOneWidget);
    await tapText(tester, 'Drop files here');
    await tapText(tester, 'Use this card');

    expect(find.text('Your card is ready'), findsOneWidget);
    expect(find.text('Drop files here'), findsOneWidget);
    // Kept for Settings' My card.
    expect(await services.loadCardStyle(), (tone: 0, line: 1));
    await tapText(tester, 'Continue');

    expect(done, isTrue);
    expect(services.completed, isTrue);
    expect(services.notificationRequests, 1);
    expect(services.savedNickname, 'Alex');
    expect(services.savedRelates, {OnbPain.swapNumbers, OnbPain.groupChat});
    expect(tester.takeException(), isNull);
  });

  testWidgets('a short tug on the lever springs back without crafting',
      (tester) async {
    final services = FakeServices();
    await pumpFlow(tester, services, onComplete: () {});
    await answerQuestions(tester, agreeNone);
    await tapText(tester, 'Skip for now');

    expect(find.text('Pull the lever'), findsOneWidget);
    await tester.drag(lever, const Offset(0, 20));
    await advance(tester, 1500);
    expect(find.text('Pull the lever'), findsOneWidget);
    expect(find.text('This is you.'), findsNothing);
    expect(services.sounds, isEmpty);

    await pullLever(tester, drag: true);
    expect(find.text('This is you.'), findsOneWidget);
    expect(services.sounds, [OnbSoundCue.leverPull, OnbSoundCue.codeReveal]);
  });

  testWidgets('a failed craft asks for another pull, which then works',
      (tester) async {
    // Fails the background attempt and the first pull.
    final services = FakeServices(failures: 2);
    await pumpFlow(tester, services, onComplete: () {});
    await answerQuestions(tester, agreeNone);
    await tapText(tester, 'Skip for now');

    await pullLever(tester);
    expect(find.text('Couldn\'t craft your code'), findsOneWidget);
    expect(find.text('This is you.'), findsNothing);

    await tester.tap(lever);
    await advance(tester, 3200);
    expect(find.text('This is you.'), findsOneWidget);
    expect(services.identityCalls, 3);
    expect(services.sounds, [
      OnbSoundCue.leverPull,
      OnbSoundCue.leverPull,
      OnbSoundCue.codeReveal,
    ]);
  });

  testWidgets('a failed craft can be left, to get the code once online',
      (tester) async {
    final services = FakeServices(failures: 99);
    var done = false;
    await pumpFlow(tester, services, onComplete: () => done = true);
    await answerQuestions(tester, agreeNone);
    await tapText(tester, 'Skip for now');

    final leave = find.text('Continue without a code');
    expect(leave.hitTestable(), findsNothing);
    await pullLever(tester);
    expect(find.text('Couldn\'t craft your code'), findsOneWidget);

    await tapText(tester, 'Continue without a code');
    expect(done, isTrue);
    expect(services.completed, isTrue);
    expect(services.notificationRequests, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no swipe statement is cut off at large text sizes',
      (tester) async {
    await pumpFlow(tester, FakeServices(),
        onComplete: () {}, size: const Size(320, 568), textScale: 2);
    await tapText(tester, 'Get started');
    for (var i = 0; i < onbStatements.length; i++) {
      expect(clippedText(tester), isEmpty, reason: 'card ${i + 1}');
      await tapText(tester, 'Not me', settle: 200);
    }
    await advance(tester, 900);
    expect(tester.takeException(), isNull);
  });

  testWidgets('with motion on, the reels sound as they roll, stop and land',
      (tester) async {
    final services = FakeServices(failures: 2);
    await pumpFlow(tester, services, onComplete: () {}, reduceMotion: false);
    await advance(tester, 1800);
    await tapText(tester, 'Get started', settle: 1400);
    for (var i = 0; i < onbStatements.length; i++) {
      await tapText(tester, 'Not me', settle: 500);
    }
    await advance(tester, 1600);
    await tapText(tester, 'Set me up', settle: 1400);
    await tapText(tester, 'Skip for now', settle: 1400);

    await pullLever(tester, settle: 1500);
    expect(find.text('Couldn\'t craft your code'), findsOneWidget);
    expect(services.sounds, [
      OnbSoundCue.leverPull,
      OnbSoundCue.reelsSpin,
      OnbSoundCue.reelsStop,
    ]);

    services.sounds.clear();
    await tester.tap(lever);
    await advance(tester, 4500);
    expect(find.text('This is you.'), findsOneWidget);
    expect(services.sounds, [
      OnbSoundCue.leverPull,
      OnbSoundCue.reelsSpin,
      OnbSoundCue.reelsLand,
      OnbSoundCue.codeReveal,
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('coming back from the card shows the code already crafted',
      (tester) async {
    final services = FakeServices();
    await pumpFlow(tester, services, onComplete: () {});
    await answerQuestions(tester, agreeNone);
    await tapText(tester, 'Skip for now');
    await pullLever(tester);
    await tapText(tester, 'Make my share card');

    await tester.tap(find.byTooltip('Back'));
    await advance(tester, 900);
    expect(find.text('This is you.'), findsOneWidget);
    expect(find.text('Pull the lever'), findsNothing);
    expect(services.identityCalls, 1);
  });

  testWidgets('solution rows lead with the cards they agreed with',
      (tester) async {
    await pumpFlow(tester, FakeServices(), onComplete: () {});
    await tapText(tester, 'Get started');
    // Only "My friend has an Android, so AirDrop is useless."
    for (final yes in [false, true, false, false]) {
      await tapText(tester, yes ? 'That’s me' : 'Not me', settle: 200);
    }
    await advance(tester, 900);

    final airdrop = tester.getTopLeft(
        find.text(onbPainOption(OnbPain.airdrop).fix, skipOffstage: false));
    final swap = tester.getTopLeft(
        find.text(onbPainOption(OnbPain.swapNumbers).fix, skipOffstage: false));
    expect(airdrop.dy, lessThan(swap.dy));
    // Three rows: topped up with swap numbers and email links, no further.
    expect(find.text(onbPainOption(OnbPain.groupChat).fix, skipOffstage: false),
        findsNothing);
  });

  testWidgets(
      'no notification screen — the system prompt comes once onboarding '
      'finishes', (tester) async {
    final services = FakeServices();
    var done = false;
    await pumpFlow(tester, services, onComplete: () => done = true);

    await answerQuestions(tester, agreeNone);
    await tapText(tester, 'Skip for now');
    expect(find.text('Pull the lever'), findsOneWidget);
    expect(services.notificationRequests, 0);

    await pullLever(tester);
    await tapText(tester, 'Make my share card');
    await tapText(tester, 'Use this card');
    expect(services.notificationRequests, 0);
    await tapText(tester, 'Continue');
    expect(done, isTrue);
    expect(services.notificationRequests, 1);
  });

  testWidgets('skipping from the welcome screen still sets up notifications',
      (tester) async {
    final services = FakeServices();
    var done = false;
    await pumpFlow(tester, services, onComplete: () => done = true);
    await tapText(tester, 'Skip');
    expect(done, isTrue);
    expect(services.notificationRequests, 1);
  });

  testWidgets('the share-card step offers no Room, even to group sharers',
      (tester) async {
    final services = FakeServices();
    await pumpFlow(tester, services, onComplete: () {});

    await answerQuestions(tester, agreeOddCards); // includes the group card
    await tapText(tester, 'Skip for now');
    await pullLever(tester);
    await tapText(tester, 'Make my share card');
    expect(find.text('Make your share card'), findsOneWidget);
    expect(find.text('Start a Room'), findsNothing);
    expect(find.text('My card'), findsNothing);

    await tapText(tester, 'Use this card');
    expect(find.text('Your card is ready'), findsOneWidget);
    expect(find.text('Share my card'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the share step keeps its text in view above the buttons',
      (tester) async {
    await pumpFlow(tester, FakeServices(), onComplete: () {});
    await answerQuestions(tester, agreeNone);
    await tapText(tester, 'Skip for now');
    await pullLever(tester);
    await tapText(tester, 'Make my share card');
    await tapText(tester, 'Use this card');

    // The card shrinks to fit rather than pushing the text below the fold.
    final viewport = tester.getRect(find.descendant(
        of: find.byType(OnbShareScreen), matching: find.byType(Scrollable)));
    final subtitle = tester.getRect(find.textContaining('Send it to whoever'));
    expect(subtitle.bottom, lessThanOrEqualTo(viewport.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('going back to the swipe deck forgets the earlier answers',
      (tester) async {
    final services = FakeServices();
    await pumpFlow(tester, services, onComplete: () {});

    await answerQuestions(tester, agreeOddCards);
    // Nickname → back to solution → back to the deck.
    await tester.tap(find.byTooltip('Back'));
    await advance(tester, 700);
    await tester.tap(find.byTooltip('Back'));
    await advance(tester, 700);
    expect(find.text('Sound familiar?'), findsOneWidget);
    for (final yes in agreeNone) {
      await tapText(tester, yes ? 'That’s me' : 'Not me', settle: 200);
    }
    await advance(tester, 900);
    await tapText(tester, 'Set me up');
    await tapText(tester, 'Skip for now');
    await pullLever(tester);
    await tapText(tester, 'Make my share card');
    await tapText(tester, 'Use this card');
    await tapText(tester, 'Continue');
    expect(services.savedRelates, isEmpty);
  });

  testWidgets('debug paywall follows the share step and lets people leave',
      (tester) async {
    final services = FakeServices();
    var done = false;
    await pumpFlow(tester, services,
        onComplete: () => done = true, paywall: true);

    await answerQuestions(tester, agreeNone);
    await tapText(tester, 'Skip for now');
    await pullLever(tester);
    await tapText(tester, 'Make my share card');
    await tapText(tester, 'Use this card');
    await tapText(tester, 'Continue');

    expect(find.text('Go further with MiniGo Pro'), findsOneWidget);
    expect(find.text('PLACEHOLDER · DEBUG BUILDS ONLY'), findsOneWidget);
    await tapText(tester, 'Continue with free');
    expect(done, isTrue);
  });

  for (final dark in [false, true]) {
    testWidgets(
        'every screen lays out on a small phone with motion on '
        '(${dark ? 'dark' : 'light'})', (tester) async {
      final services = FakeServices();
      await pumpFlow(
        tester,
        services,
        onComplete: () {},
        paywall: true,
        theme: dark ? buildMiniDarkTheme() : buildMiniTheme(),
        size: const Size(320, 600),
        reduceMotion: false,
      );
      await advance(tester, 1800);
      await tapText(tester, 'Get started', settle: 1400);
      for (var i = 0; i < onbStatements.length; i++) {
        await tapText(tester, 'That’s me', settle: 500);
      }
      await advance(tester, 1600);
      await advance(tester, 3500); // solution rows play out
      await tapText(tester, 'Set me up', settle: 1400);
      await tapText(tester, 'Looks good', settle: 1400);
      await pullLever(tester, drag: true, settle: 4500);
      expect(find.text('This is you.'), findsOneWidget);
      await tapText(tester, 'Make my share card', settle: 1400);
      expect(find.text('Start a Room'), findsNothing);
      // Swipe the line selector on one, then tap the neighbour it reveals.
      final selector = find.text('Send me files').last;
      await tester.ensureVisible(selector);
      await tester.pump();
      await tester.drag(selector, const Offset(-140, 0));
      await advance(tester, 900);
      await tapText(tester, 'Beam me something 🛸', settle: 900);
      await tapText(tester, 'Use this card', settle: 2200);
      await tapText(tester, 'Continue', settle: 1400);
      expect(find.text('Go further with MiniGo Pro'), findsOneWidget);
      await advance(tester, 1500);
      expect(tester.takeException(), isNull);
    });
  }
}
