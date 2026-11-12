import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../Minigo/theme/mini_theme.dart';
import '../../../Minigo/widgets/mini_ufo.dart';
import '../../../Minigo/widgets/mini_widgets.dart';
import '../../../core/constants.dart';
import '../widgets/onb_motion.dart';
import '../widgets/onb_painters.dart';
import '../widgets/onb_slot_machine.dart';

// ---------------------------------------------------------------------------
// Screen 1 — Welcome
// ---------------------------------------------------------------------------

class OnbWelcomeScreen extends StatefulWidget {
  final VoidCallback onNext;
  const OnbWelcomeScreen({super.key, required this.onNext});

  @override
  State<OnbWelcomeScreen> createState() => _OnbWelcomeScreenState();
}

class _OnbWelcomeScreenState extends State<OnbWelcomeScreen> {
  static final _rng = math.Random();
  String _code = 'A4X9K2';
  Timer? _cycle;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _cycle?.cancel();
    if (onbReduceMotion(context)) return;
    // A fresh code every few seconds: "any code, any phone".
    _cycle = Timer.periodic(const Duration(milliseconds: 4600), (_) {
      if (!mounted) return;
      setState(() => _code = String.fromCharCodes(List.generate(
            6,
            (_) => AppConstants.codeAlphabet
                .codeUnitAt(_rng.nextInt(AppConstants.codeAlphabet.length)),
          )));
    });
  }

  @override
  void dispose() {
    _cycle?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return OnbStagger(
      duration: const Duration(milliseconds: 1600),
      delay: const Duration(milliseconds: 500),
      child: OnbPage(
        body: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              // The saucer hovers over the machine like a cabinet topper;
              // shorter on small phones so the headline stays in view.
              height: math.min(200, MediaQuery.sizeOf(context).height * 0.24),
              child: Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: const [
                  OnbOrbits(size: 280),
                  MiniUfo(size: 150),
                ],
              ),
            ),
            OnbReveal(
              index: 2,
              child: LayoutBuilder(
                builder: (context, constraints) => OnbSlotMachine(
                  code: _code,
                  width: math.min(constraints.maxWidth * 0.54, 186),
                ),
              ),
            ),
            const SizedBox(height: 26),
            OnbReveal(
              index: 3,
              child: Text('Send anything.',
                  style: MiniText.display, textAlign: TextAlign.center),
            ),
            const SizedBox(height: 4),
            OnbReveal(
              index: 4,
              child: Text(
                'To any phone.',
                style: MiniText.display.copyWith(color: c.accent),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 16),
            OnbReveal(
              index: 5,
              child: Text(
                'iPhone or Android. No number, no account — just a '
                'six-character code.',
                textAlign: TextAlign.center,
                style: MiniText.bodySoft,
              ),
            ),
          ],
        ),
        bottom: OnbReveal(
          index: 7,
          child: OnbSheen(
            borderRadius: BorderRadius.circular(MiniRadius.pill),
            child: MiniButton(label: 'Get started', onPressed: widget.onNext),
          ),
        ),
      ),
    );
  }
}
