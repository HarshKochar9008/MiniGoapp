import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/constants.dart';
import '../../core/supabase_config.dart';
import '../../features/identity/identity_service.dart';
import '../../Minigo/theme/mini_theme.dart';
import '../../Minigo/widgets/mini_ufo.dart';
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
  String? _shortCode;
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
        return _OnbNickname(
          onNext: _next,
          onSkip: _next,
          onNicknameChanged: (nick) => _nickname = nick,
          controller: _nicknameController,
        );
      case 2:
        return _OnbPermissions(onNext: _next);
      case 3:
        return _OnbGenerate(
          onReady: (code) {
            _shortCode = code;
            _next();
          },
        );
      case 4:
        return _OnbCode(code: _shortCode, onNext: _next);
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
    this.onSettled,
  })  : shuffleDuration = const Duration(seconds: 2),
        lockInterval = const Duration(milliseconds: 80);

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
// Page position indicator – small dots, current page shown as a dash
// ---------------------------------------------------------------------------
class _PageDots extends StatelessWidget {
  final int index;
  static const _total = 5;
  const _PageDots({required this.index});

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(_total, (i) {
        final active = i == index;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          margin: const EdgeInsets.symmetric(horizontal: 3),
          height: 5,
          width: active ? 22 : 5,
          decoration: BoxDecoration(
            color: active ? c.accent : c.sandDeep,
            borderRadius: BorderRadius.circular(MiniRadius.pill),
          ),
        );
      }),
    );
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
              const MiniUfo(size: 190),
              const SizedBox(height: 22),
              Text(
                'Send anything.',
                style: MiniText.display,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                'to anyone, anywhere.',
                style: MiniText.display.copyWith(color: c.accent),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 18),
              Text(
                'No accounts. No phone numbers. Just a six-character code that lives only on your device.',
                textAlign: TextAlign.center,
                style: MiniText.bodySoft,
              ),
              const Spacer(),
              const _PageDots(index: 0),
              const SizedBox(height: 16),
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
  /// Called with the real short code once the identity exists server-side.
  final ValueChanged<String> onReady;
  const _OnbGenerate({required this.onReady});
  @override
  State<_OnbGenerate> createState() => _OnbGenerateState();
}

class _OnbGenerateState extends State<_OnbGenerate> {
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _createIdentity();
  }

  Future<void> _createIdentity() async {
    if (_failed) setState(() => _failed = false);
    // Let the shuffle play at least this long so the reveal never feels
    // instant, even on a fast network.
    final minShuffle = Future.delayed(const Duration(milliseconds: 2600));
    try {
      if (!SupabaseConfig.isInitialized) {
        await initSupabase();
        SupabaseConfig.startAuthListener();
      }
      final identity = await IdentityService.initialize()
          .timeout(const Duration(seconds: 20));
      await minShuffle;
      if (mounted) widget.onReady(identity.shortCode);
    } catch (_) {
      await minShuffle;
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Scaffold(
      backgroundColor: c.paper,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _CodeShuffler(style: MiniText.codeLarge),
                const SizedBox(height: 40),
                Text(
                  _failed ? 'Couldn\'t craft your code' : 'Crafting your code',
                  style: MiniText.title,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 6),
                Text(
                  _failed
                      ? 'Check your internet connection and try again.'
                      : 'a few quiet moments…',
                  style: MiniText.bodySoft,
                  textAlign: TextAlign.center,
                ),
                if (_failed) ...[
                  const SizedBox(height: 28),
                  MiniButton(label: 'Retry', onPressed: _createIdentity),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Step 2 – Code reveal (settles on demo code)
// ---------------------------------------------------------------------------
class _OnbCode extends StatefulWidget {
  /// The user's real short code; falls back to a demo code if identity
  /// creation was skipped (e.g. arriving here via a dev shortcut).
  final String? code;
  final VoidCallback onNext;
  const _OnbCode({required this.code, required this.onNext});

  @override
  State<_OnbCode> createState() => _OnbCodeState();
}

class _OnbCodeState extends State<_OnbCode> {
  bool _settled = false;

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
              Text('YOUR UNIQUE CODE', style: MiniText.label),
              const SizedBox(height: 24),
              _CodeShuffler(
                settle: widget.code ?? 'A4X9K2',
                style: MiniText.codeLarge,
                onSettled: () {
                  if (mounted) setState(() => _settled = true);
                },
              ),
              const SizedBox(height: 28),
              AnimatedOpacity(
                opacity: _settled ? 1 : 0,
                duration: const Duration(milliseconds: 600),
                curve: Curves.easeIn,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
                  decoration: miniCard(context, radius: MiniRadius.control),
                  child: Text(
                    'This is you. Anyone can send you files with this code – it never changes and reveals nothing about you.',
                    textAlign: TextAlign.center,
                    style: MiniText.bodySoft,
                  ),
                ),
              ),
              const Spacer(),
              const _PageDots(index: 3),
              const SizedBox(height: 16),
              MiniButton(label: 'Continue', onPressed: widget.onNext),
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
                    padding: const EdgeInsets.all(18),
                    decoration: miniCard(context, radius: MiniRadius.control),
                    child: Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: c.accent,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                r[0],
                                style: GoogleFonts.outfit(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500,
                                  letterSpacing: -0.2,
                                  color: c.ink,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(r[1], style: MiniText.small),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              const Spacer(),
              const Center(child: _PageDots(index: 2)),
              const SizedBox(height: 16),
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
                style: MiniText.body.copyWith(
                  fontSize: 18,
                  fontWeight: FontWeight.w500,
                ),
                decoration: InputDecoration(
                  hintText: 'e.g., Alex, BlueBunny, ...',
                  filled: true,
                  fillColor: c.sand,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(MiniRadius.control),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(MiniRadius.control),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(MiniRadius.control),
                    borderSide: BorderSide(color: c.accent, width: 2),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 18,
                  ),
                ),
              ),
              const Spacer(),
              const _PageDots(index: 1),
              const SizedBox(height: 16),
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
              const MiniUfo(size: 170, tint: MiniColors.success),
              const SizedBox(height: 12),
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
              const _PageDots(index: 4),
              const SizedBox(height: 16),
              MiniButton(label: 'Open MiniGo', onPressed: onDone),
            ],
          ),
        ),
      ),
    );
  }
}
