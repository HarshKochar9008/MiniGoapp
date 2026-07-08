import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/constants.dart';
import '../../features/identity/identity_service.dart';
import '../../Minigo/theme/mini_theme.dart';
import '../../Minigo/widgets/mini_widgets.dart';

class OnboardingScreen extends StatefulWidget {
  final VoidCallback onComplete;
  const OnboardingScreen({super.key, required this.onComplete});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  int _step = 0;
  String? _nickname;
  final _nicknameController = TextEditingController();

  Future<void> _finish() async {
    final trimmedNick = _nickname?.trim();
    if (trimmedNick != null && trimmedNick.isNotEmpty) {
      await IdentityService.setNickname(trimmedNick);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarding_complete', true);
    widget.onComplete();
  }

  void _next() => setState(() => _step++);

  @override
  void dispose() {
    _nicknameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    switch (_step) {
      case 0:
        return _OnbWelcome(onNext: _next, onSkip: _finish);
      case 1:
        return _OnbGenerate(onNext: _next);
      case 2:
        return _OnbCode(onNext: _next);
      case 3:
        return _OnbNickname(
          onNext: _next,
          onSkip: _next,
          onNicknameChanged: (nick) => _nickname = nick,
          controller: _nicknameController,
        );
      case 4:
        return _OnbPermissions(onNext: _next);
      case 5:
        return _OnbReady(onDone: _finish);
      default:
        return _OnbReady(onDone: _finish);
    }
  }
}

// ---------------------------------------------------------------------------
// Shuffling code animation – chars cycle randomly, then optionally settle
// ---------------------------------------------------------------------------
class _CodeShuffler extends StatefulWidget {
  /// Target code to settle on; null keeps cycling forever.
  final String? settle;
  final TextStyle style;
  final VoidCallback? onSettled;
  /// Delay before locking chars (ignored when settle is null).
  final Duration shuffleDuration;
  /// Gap between each char locking in.
  final Duration lockInterval;

  const _CodeShuffler({
    this.settle,
    required this.style,
  }) : onSettled = null, shuffleDuration = const Duration(seconds: 2), lockInterval = const Duration(milliseconds: 80);

  @override
  State<_CodeShuffler> createState() => _CodeShufflerState();
}

class _CodeShufflerState extends State<_CodeShuffler> {
  static const _alpha = AppConstants.codeAlphabet;
  final _rng = Random();

  late List<String> _display;
  late List<bool> _locked;
  Timer? _tick;
  int _lockIdx = 0;

  @override
  void initState() {
    super.initState();
    _display = List.generate(6, (_) => _rand());
    _locked = List.filled(6, false);
    _tick = Timer.periodic(const Duration(milliseconds: 55), _onTick);
    if (widget.settle != null) {
      Future.delayed(widget.shuffleDuration, _beginSettle);
    }
  }

  void _onTick(Timer _) {
    if (!mounted) return;
    setState(() {
      for (int i = 0; i < 6; i++) {
        if (!_locked[i]) _display[i] = _rand();
      }
    });
  }

  void _beginSettle() {
    if (!mounted) return;
    _lockNext();
  }

  void _lockNext() {
    if (!mounted) return;
    if (_lockIdx >= 6) {
      _tick?.cancel();
      widget.onSettled?.call();
      return;
    }
    final i = _lockIdx++;
    setState(() {
      _locked[i] = true;
      _display[i] = widget.settle![i];
    });
    Future.delayed(widget.lockInterval, _lockNext);
  }

  String _rand() => _alpha[_rng.nextInt(_alpha.length)];

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return RichText(
      textAlign: TextAlign.center,
      text: TextSpan(
        children: [
          ..._buildChars(0, 3),
          TextSpan(
            text: ' · ',
            style: widget.style.copyWith(color: c.inkFaint),
          ),
          ..._buildChars(3, 6),
        ],
      ),
    );
  }

  List<TextSpan> _buildChars(int start, int end) {
    final c = context.mini;
    return List.generate(end - start, (j) {
      final i = start + j;
      return TextSpan(
        text: _display[i],
        style: widget.style.copyWith(
          color: _locked[i] ? c.ink : c.accent,
        ),
      );
    });
  }
}

// ---------------------------------------------------------------------------
// Step 0 – Welcome
// ---------------------------------------------------------------------------
class _OnbWelcome extends StatelessWidget {
  final VoidCallback onNext;
  final VoidCallback onSkip;
  const _OnbWelcome({required this.onNext, required this.onSkip});

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Scaffold(
      backgroundColor: c.paper,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 60, 28, 32),
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: GestureDetector(
                  onTap: onSkip,
                  child: Text('Skip', style: MiniText.bodySoft),
                ),
              ),
              const Spacer(),
              Image.asset(
                'assets/logo.png',
                width: 96,
                height: 96,
              ),
              const SizedBox(height: 36),
              Text(
                'Send anything.',
                style: MiniText.display,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                'to anyone, anywhere.',
                style: MiniText.display.copyWith(
                  fontStyle: FontStyle.italic,
                  color: c.accent,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 18),
              Text(
                'No accounts. No phone numbers. Just a six-character code that lives only on your device.',
                textAlign: TextAlign.center,
                style: MiniText.bodySoft,
              ),
              const Spacer(),
              MiniButton(label: 'Begin', onPressed: onNext),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Step 1 – Generating (shuffling animation, auto-advances)
// ---------------------------------------------------------------------------
class _OnbGenerate extends StatefulWidget {
  final VoidCallback onNext;
  const _OnbGenerate({required this.onNext});
  @override
  State<_OnbGenerate> createState() => _OnbGenerateState();
}

class _OnbGenerateState extends State<_OnbGenerate> {
  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 2600), () {
      if (mounted) widget.onNext();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Scaffold(
      backgroundColor: c.paper,
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _CodeShuffler(style: MiniText.codeLarge),
              const SizedBox(height: 40),
              Text(
                'Crafting your code',
                style: MiniText.title,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text('a few quiet moments…', style: MiniText.bodySoft),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Step 2 – Code reveal (settles on demo code)
// ---------------------------------------------------------------------------
class _OnbCode extends StatelessWidget {
  final VoidCallback onNext;
  const _OnbCode({required this.onNext});

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Scaffold(
      backgroundColor: c.paper,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 60, 28, 32),
          child: Column(
            children: [
              const SizedBox(height: 24),
              Text('How it works', style: MiniText.label),
              const SizedBox(height: 24),
              _CodeShuffler(
                settle: 'A4X9K2',
                style: MiniText.codeLarge,
              ),
              const SizedBox(height: 28),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                decoration: BoxDecoration(
                  color: c.paperDeep,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  'Your unique 6-character code is your address. Share it to receive files, or ask for someone else\'s to send. '
                  'You can rotate it anytime from Settings.',
                  textAlign: TextAlign.center,
                  style: MiniText.bodySoft,
                ),
              ),
              const Spacer(),
              MiniButton(label: 'Continue', onPressed: onNext),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Step 3 – Permissions
// ---------------------------------------------------------------------------
class _OnbPermissions extends StatelessWidget {
  final VoidCallback onNext;
  const _OnbPermissions({required this.onNext});

  @override
  Widget build(BuildContext context) {
    final items = const [
      ['Notifications', 'so files arrive when you\'re away'],
      ['Files & photos', 'to pick what to send or save what you receive'],
      ['Camera', 'for scanning QR codes'],
    ];
    final c = context.mini;
    return Scaffold(
      backgroundColor: c.paper,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 60, 28, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('A few quiet permissions', style: MiniText.title),
              const SizedBox(height: 28),
              for (final r in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: c.paperDeep,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: c.accent,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                r[0],
                                style: GoogleFonts.outfit(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: c.ink,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(r[1], style: MiniText.small),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              const Spacer(),
              MiniButton(label: 'Continue', onPressed: onNext),
              const SizedBox(height: 8),
              MiniButton(
                label: 'Skip for now',
                onPressed: onNext,
                style: MiniBtnStyle.ghost,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Step 3 – Nickname
// ---------------------------------------------------------------------------
class _OnbNickname extends StatelessWidget {
  final VoidCallback onNext;
  final VoidCallback onSkip;
  final ValueChanged<String?> onNicknameChanged;
  final TextEditingController controller;

  const _OnbNickname({
    required this.onNext,
    required this.onSkip,
    required this.onNicknameChanged,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Scaffold(
      backgroundColor: c.paper,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 60, 28, 32),
          child: Column(
            children: [
              const SizedBox(height: 24),
              Text('Pick a nickname', style: MiniText.title),
              const SizedBox(height: 8),
              Text(
                'This helps others recognize you. Totally optional.',
                textAlign: TextAlign.center,
                style: MiniText.bodySoft,
              ),
              const SizedBox(height: 40),
              TextField(
                controller: controller,
                onChanged: onNicknameChanged,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                style: MiniText.body.copyWith(fontSize: 18),
                decoration: InputDecoration(
                  hintText: 'e.g., Alex, BlueBunny, ...',
                  filled: true,
                  fillColor: c.paperDeep,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: c.accent, width: 2),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 16,
                  ),
                ),
              ),
              const Spacer(),
              MiniButton(label: 'Continue', onPressed: onNext),
              const SizedBox(height: 8),
              MiniButton(
                label: 'Skip for now',
                onPressed: onSkip,
                style: MiniBtnStyle.ghost,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Step 5 – Ready
// ---------------------------------------------------------------------------
class _OnbReady extends StatelessWidget {
  final VoidCallback onDone;
  const _OnbReady({required this.onDone});

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Scaffold(
      backgroundColor: c.paper,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 60, 28, 32),
          child: Column(
            children: [
              const Spacer(),
              const Icon(
                Icons.check_circle_outline_rounded,
                size: 56,
                color: MiniColors.success,
              ),
              const SizedBox(height: 24),
              Text(
                'You\'re ready.',
                style: MiniText.display,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                'Send and receive files with anyone, anywhere — no sign-up needed.',
                textAlign: TextAlign.center,
                style: MiniText.bodySoft,
              ),
              const Spacer(),
              MiniButton(label: 'Open MiniGo', onPressed: onDone),
            ],
          ),
        ),
      ),
    );
  }
}
