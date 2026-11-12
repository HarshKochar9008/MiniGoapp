import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../Minigo/theme/mini_icons.dart';
import '../../Minigo/theme/mini_theme.dart';
import '../../core/analytics/analytics.dart';
import '../identity/identity_service.dart';
import 'onboarding_content.dart';
import 'onboarding_services.dart';
import 'screens/onb_card_screen.dart';
import 'screens/onb_intro_screens.dart';
import 'screens/onb_paywall_screen.dart';
import 'screens/onb_setup_screens.dart';
import 'screens/onb_share_screen.dart';
import 'screens/onb_solution_screen.dart';
import 'screens/onb_swipe_screen.dart';
import 'widgets/onb_motion.dart';
import 'widgets/onb_widgets.dart';

enum OnbStep {
  welcome,
  swipe,
  solution,
  nickname,
  generate,
  card,
  share,
  paywall,
}

/// The questionnaire onboarding (variant B of the onboarding experiment).
///
/// welcome → swipe → solution → nickname → generate (pull the lever to craft
/// the code; it is revealed on the same screen) → card → share → (paywall,
/// debug only).
///
/// The goal and pain-point questions were removed after user feedback; the
/// swipe deck is now the only question, and its answers drive the solution
/// rows. Rooms are no longer set up here either: the app's Rooms tab covers
/// them.
///
/// The notification priming screen was removed too: the system prompt shows
/// once onboarding completes.
class OnboardingFlowV2 extends StatefulWidget {
  final VoidCallback onComplete;
  final OnbServices services;

  /// The placeholder Pro paywall is only reachable in debug builds until it
  /// is wired to real in-app purchases.
  final bool showProPaywall;

  /// Replayed from Settings: the system back gesture may leave the flow from
  /// steps that can't go back.
  final bool isReplay;

  const OnboardingFlowV2({
    super.key,
    required this.onComplete,
    this.services = const OnbServices(),
    this.showProPaywall = kDebugMode,
    this.isReplay = false,
  });

  @override
  State<OnboardingFlowV2> createState() => _OnboardingFlowV2State();
}

class _OnboardingFlowV2State extends State<OnboardingFlowV2> {
  final _stopwatch = Stopwatch()..start();
  final _nickname = TextEditingController(
    text: IdentityService.identityNotifier.value?.nickname,
  );

  OnbStep _step = OnbStep.welcome;
  bool _forward = true;
  bool _finishing = false;

  // Answers.
  final Set<OnbPain> _relates = {};
  int _tone = 0;
  int _line = 0;

  // Setup results.
  UserIdentity? _identity;

  List<OnbStep> get _path => [
        OnbStep.welcome,
        OnbStep.swipe,
        OnbStep.solution,
        OnbStep.nickname,
        OnbStep.generate,
        OnbStep.card,
        OnbStep.share,
        if (widget.showProPaywall) OnbStep.paywall,
      ];

  int get _index => _path.indexOf(_step).clamp(0, _path.length - 1);

  @override
  void initState() {
    super.initState();
    _logStep();
    unawaited(widget.services.preloadSounds());
  }

  @override
  void dispose() {
    _nickname.dispose();
    unawaited(widget.services.disposeSounds());
    super.dispose();
  }

  // ── navigation ──────────────────────────────────────────────────────────

  void _goTo(OnbStep step, {bool forward = true}) {
    if (!mounted || step == _step) return;
    setState(() {
      _forward = forward;
      _step = step;
      // The deck starts over on every visit, so its answers do too —
      // otherwise a card rejected on the second pass would still count.
      if (step == OnbStep.swipe) _relates.clear();
    });
    _logStep();
  }

  void _next() {
    final path = _path;
    final i = path.indexOf(_step);
    if (i < 0 || i + 1 >= path.length) {
      _finish();
      return;
    }
    _goTo(path[i + 1]);
  }

  /// No going back from code creation (the identity exists by then). Later
  /// steps can return to it — it shows the code already crafted.
  bool get _canGoBack {
    final i = _path.indexOf(_step);
    return i > 0 && _step != OnbStep.generate;
  }

  void _back() {
    if (!_canGoBack) return;
    final path = _path;
    _goTo(path[path.indexOf(_step) - 1], forward: false);
  }

  void _logStep() {
    Analytics.instance.logEvent(AnalyticsEvents.onbStepViewed, {
      'step': _step.name,
      'index': _index,
    });
    if (_step == OnbStep.paywall) {
      Analytics.instance.logEvent(AnalyticsEvents.onbPaywallViewed);
    }
  }

  // ── completion ──────────────────────────────────────────────────────────

  Future<void> _skip() async {
    Analytics.instance
        .logEvent(AnalyticsEvents.onbSkipped, {'step': _step.name});
    await _complete();
  }

  Future<void> _finish() async {
    Analytics.instance.logEvent(AnalyticsEvents.onbCompleted, {
      'duration_ms': _stopwatch.elapsedMilliseconds,
    });
    await _complete();
  }

  Future<void> _complete() async {
    if (_finishing) return;
    _finishing = true;
    try {
      final nick = _nickname.text.trim();
      if (_identity != null && nick.isNotEmpty && nick != _identity!.nickname) {
        try {
          await widget.services.saveNickname(nick);
        } catch (e) {
          // Not worth blocking onboarding over; it can be set in Settings.
          if (kDebugMode) debugPrint('onboarding: nickname save failed: $e');
        }
      }
      await widget.services.saveAnswers(relates: _relates);
      await widget.services.markComplete();
      // There is no priming screen: the system prompt (and push setup, which
      // main.dart leaves to onboarding on first launch) comes once they land
      // in the app.
      unawaited(_requestNotifications());
      if (mounted) widget.onComplete();
    } finally {
      _finishing = false;
    }
  }

  // ── step handlers ───────────────────────────────────────────────────────

  void _swipeAnswer(OnbStatement s, bool relates) {
    if (relates) _relates.add(s.pain);
    Analytics.instance.logEvent(AnalyticsEvents.onbSwipeAnswered, {
      'pain': s.pain.name,
      'relates': relates,
    });
  }

  /// Three rows: the cards they agreed with first, then topped up in the
  /// default order.
  List<OnbPain> get _solutionRows {
    const order = onbPainOrder;
    final rows = [
      for (final p in order)
        if (_relates.contains(p)) p
    ];
    for (final p in order) {
      if (rows.length >= 3) break;
      if (!rows.contains(p)) rows.add(p);
    }
    return rows.take(3).toList();
  }

  /// Not awaited: on iOS the system prompt holds the future until it is
  /// answered, and the app shouldn't wait on it.
  Future<void> _requestNotifications() async {
    try {
      final granted = await widget.services.requestNotifications();
      Analytics.instance.logEvent(AnalyticsEvents.onbNotificationPrompt,
          {'result': granted ? 'granted' : 'denied'});
    } catch (e) {
      if (kDebugMode) debugPrint('onboarding: notification setup failed: $e');
    }
  }

  void _copyCode() {
    final code = _identity?.shortCode;
    if (code == null) return;
    Clipboard.setData(ClipboardData(text: code));
    onbTick();
    Analytics.instance
        .logEvent(AnalyticsEvents.onbCodeCopied, {'step': _step.name});
  }

  Future<bool> _shareCard(
      Uint8List? png, String text, String fileStem, Rect? origin) async {
    var shared = false;
    try {
      shared = await widget.services.shareCard(
        png: png,
        text: text,
        fileStem: fileStem,
        origin: origin,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('onboarding: share failed: $e');
    }
    Analytics.instance.logEvent(AnalyticsEvents.onbCardShared, {
      'tone': onbCardTones[_tone].name,
      'line': _line,
      'with_image': png != null,
      'completed': shared,
    });
    return shared;
  }

  // ── build ───────────────────────────────────────────────────────────────

  Widget _screen() {
    switch (_step) {
      case OnbStep.welcome:
        return OnbWelcomeScreen(onNext: _next);
      case OnbStep.swipe:
        return OnbSwipeScreen(onAnswer: _swipeAnswer, onDone: _next);
      case OnbStep.solution:
        return OnbSolutionScreen(rows: _solutionRows, onNext: _next);
      case OnbStep.nickname:
        return OnbNicknameScreen(
          controller: _nickname,
          tone: onbCardTones[_tone],
          line: onbCardLines[_line],
          onNext: _next,
          onSkip: () {
            _nickname.clear();
            _next();
          },
        );
      case OnbStep.generate:
        return OnbCraftScreen(
          create: widget.services.createIdentity,
          initialIdentity: _identity,
          onCrafted: (identity) => setState(() => _identity = identity),
          onPulled: () =>
              Analytics.instance.logEvent(AnalyticsEvents.onbLeverPulled),
          onSound: (cue) => unawaited(widget.services.playSound(cue)),
          onNext: _next,
          onSkip: _skip,
        );
      case OnbStep.card:
        return OnbCardScreen(
          code: _identity!.shortCode,
          nickname: _nicknameOrNull,
          toneIndex: _tone,
          lineIndex: _line,
          onTone: (i) => setState(() => _tone = i),
          onLine: (i) => setState(() => _line = i),
          onUseCard: () {
            Analytics.instance.logEvent(AnalyticsEvents.onbCardStyled, {
              'tone': onbCardTones[_tone].name,
              'line': _line,
            });
            unawaited(
                widget.services.saveCardStyle((tone: _tone, line: _line)));
            _next();
          },
        );
      case OnbStep.share:
        return OnbShareScreen(
          tone: onbCardTones[_tone],
          line: onbCardLines[_line],
          code: _identity!.shortCode,
          nickname: _nicknameOrNull,
          share: _shareCard,
          onCopy: _copyCode,
          onContinue: _next,
        );
      case OnbStep.paywall:
        return OnbPaywallScreen(
          onContinueFree: _finish,
          onCta: (plan) => Analytics.instance
              .logEvent(AnalyticsEvents.onbPaywallCta, {'plan': plan}),
        );
    }
  }

  String? get _nicknameOrNull {
    final n = _nickname.text.trim();
    return n.isEmpty ? null : n;
  }

  @override
  Widget build(BuildContext context) {
    final path = _path;
    final progress = path.length <= 1 ? 0.0 : _index / (path.length - 1);
    final reduce = onbReduceMotion(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_canGoBack) {
          _back();
        } else if (widget.isReplay) {
          widget.onComplete();
        }
      },
      child: Scaffold(
        backgroundColor: context.mini.paper,
        resizeToAvoidBottomInset: true,
        body: OnbSpaceBackground(
          progress: progress,
          child: SafeArea(
            child: Column(
              children: [
                _Header(
                  progress: progress,
                  step: _index + 1,
                  total: path.length,
                  canGoBack: _canGoBack,
                  onBack: _back,
                  onSkip: _step == OnbStep.welcome ? _skip : null,
                ),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: Duration(milliseconds: reduce ? 0 : 560),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    layoutBuilder: (current, previous) => Stack(
                      fit: StackFit.expand,
                      children: [...previous, if (current != null) current],
                    ),
                    transitionBuilder: (child, anim) {
                      final incoming = child.key == ValueKey(_step);
                      final dir = _forward ? 1.0 : -1.0;
                      final slide = Tween<Offset>(
                        begin: Offset((incoming ? 0.18 : -0.18) * dir, 0),
                        end: Offset.zero,
                      ).animate(anim);
                      final scale =
                          Tween<double>(begin: incoming ? 0.94 : 1.04, end: 1)
                              .animate(anim);
                      return FadeTransition(
                        opacity: anim,
                        child: SlideTransition(
                          position: slide,
                          child: ScaleTransition(scale: scale, child: child),
                        ),
                      );
                    },
                    child: KeyedSubtree(
                      key: ValueKey(_step),
                      child: _screen(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final double progress;
  final int step;
  final int total;
  final bool canGoBack;
  final VoidCallback onBack;
  final VoidCallback? onSkip;

  const _Header({
    required this.progress,
    required this.step,
    required this.total,
    required this.canGoBack,
    required this.onBack,
    required this.onSkip,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 16, 4),
      child: Row(
        children: [
          AnimatedOpacity(
            opacity: canGoBack ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            child: IconButton(
              onPressed: canGoBack ? onBack : null,
              tooltip: 'Back',
              icon: Icon(MiniIcons.back, color: c.ink, size: 22),
            ),
          ),
          Expanded(
            child: OnbProgressBar(
              value: progress,
              semanticsLabel: 'Step $step of $total',
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 44,
            child: AnimatedOpacity(
              opacity: onSkip != null ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: TextButton(
                onPressed: onSkip,
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  foregroundColor: c.inkSoft,
                ),
                child: const Text('Skip'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
