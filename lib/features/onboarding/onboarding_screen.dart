import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../zensend/theme/zen_theme.dart';
import '../../zensend/widgets/zen_widgets.dart';

class OnboardingScreen extends StatefulWidget {
  final VoidCallback onComplete;
  const OnboardingScreen({super.key, required this.onComplete});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  int _step = 0;

  Future<void> _finish() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarding_complete', true);
    widget.onComplete();
  }

  void _next() => setState(() => _step++);

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
        return _OnbPermissions(onNext: _next);
      case 4:
        return _OnbReady(onDone: _finish);
      default:
        return _OnbReady(onDone: _finish);
    }
  }
}

class _OnbWelcome extends StatelessWidget {
  final VoidCallback onNext;
  final VoidCallback onSkip;
  const _OnbWelcome({required this.onNext, required this.onSkip});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZenColors.paper,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 60, 28, 32),
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: GestureDetector(
                  onTap: onSkip,
                  child: Text('Skip', style: ZenText.bodySoft),
                ),
              ),
              const Spacer(),
              Container(
                width: 96,
                height: 96,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [ZenColors.blue200, ZenColors.paperDeep],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
              ),
              const SizedBox(height: 36),
              Text(
                'Send anything.',
                style: ZenText.display,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                'to anyone, anywhere.',
                style: ZenText.display.copyWith(
                  fontStyle: FontStyle.italic,
                  color: ZenColors.blue600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 18),
              Text(
                'No accounts. No phone numbers. Just a six-character code that lives only on your device.',
                textAlign: TextAlign.center,
                style: ZenText.bodySoft,
              ),
              const Spacer(),
              ZenButton(label: 'Begin', onPressed: onNext),
            ],
          ),
        ),
      ),
    );
  }
}

class _OnbGenerate extends StatefulWidget {
  final VoidCallback onNext;
  const _OnbGenerate({required this.onNext});
  @override
  State<_OnbGenerate> createState() => _OnbGenerateState();
}

class _OnbGenerateState extends State<_OnbGenerate>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1600))
      ..repeat();
    Future.delayed(const Duration(milliseconds: 2000), () {
      if (mounted) widget.onNext();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZenColors.paper,
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 140,
                height: 140,
                child: AnimatedBuilder(
                  animation: _c,
                  builder: (_, __) => Stack(
                    alignment: Alignment.center,
                    children: [
                      ...List.generate(3, (i) {
                        final t = ((_c.value + i / 3) % 1);
                        return Opacity(
                          opacity: (1 - t),
                          child: Container(
                            width: 140 * t,
                            height: 140 * t,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                  color: ZenColors.blue500, width: 1),
                            ),
                          ),
                        );
                      }),
                      Container(
                        width: 28,
                        height: 28,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: ZenColors.ink,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 36),
              Text('Crafting your code',
                  style: ZenText.title, textAlign: TextAlign.center),
              const SizedBox(height: 6),
              Text('a few quiet moments…', style: ZenText.bodySoft),
            ],
          ),
        ),
      ),
    );
  }
}

class _OnbCode extends StatelessWidget {
  final VoidCallback onNext;
  const _OnbCode({required this.onNext});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZenColors.paper,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 60, 28, 32),
          child: Column(
            children: [
              const SizedBox(height: 24),
              Text('How it works', style: ZenText.label),
              const SizedBox(height: 24),
              Text(
                fmtCode('A4X9K2'),
                style: ZenText.codeLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 28),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                decoration: BoxDecoration(
                  color: ZenColors.paperDeep,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  'Your unique 6-character code is your address. Share it to receive files, or ask for someone else\'s to send. '
                  'You can rotate it anytime from Settings.',
                  textAlign: TextAlign.center,
                  style: ZenText.bodySoft,
                ),
              ),
              const Spacer(),
              ZenButton(label: 'Continue', onPressed: onNext),
            ],
          ),
        ),
      ),
    );
  }
}

class _OnbPermissions extends StatelessWidget {
  final VoidCallback onNext;
  const _OnbPermissions({required this.onNext});

  @override
  Widget build(BuildContext context) {
    final items = const [
      ['Notifications', 'so files arrive when you\'re away'],
      ['Files & photos', 'to pick what to send or save what you receive'],
      ['Camera', 'for scanning QR codes (optional)'],
    ];
    return Scaffold(
      backgroundColor: ZenColors.paper,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 60, 28, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('A few quiet permissions', style: ZenText.title),
              const SizedBox(height: 28),
              for (final r in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: ZenColors.paperDeep,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: ZenColors.blue500,
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
                                style: GoogleFonts.inter(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: ZenColors.ink,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(r[1], style: ZenText.small),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              const Spacer(),
              ZenButton(label: 'Continue', onPressed: onNext),
              const SizedBox(height: 8),
              ZenButton(
                label: 'Skip for now',
                onPressed: onNext,
                style: ZenBtnStyle.ghost,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OnbReady extends StatelessWidget {
  final VoidCallback onDone;
  const _OnbReady({required this.onDone});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZenColors.paper,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 60, 28, 32),
          child: Column(
            children: [
              const Spacer(),
              const Icon(
                Icons.check_circle_outline_rounded,
                size: 56,
                color: ZenColors.success,
              ),
              const SizedBox(height: 24),
              Text(
                'You\'re ready.',
                style: ZenText.display,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                'Send and receive files with anyone, anywhere — no sign-up needed.',
                textAlign: TextAlign.center,
                style: ZenText.bodySoft,
              ),
              const Spacer(),
              ZenButton(label: 'Open ZenSend', onPressed: onDone),
            ],
          ),
        ),
      ),
    );
  }
}
