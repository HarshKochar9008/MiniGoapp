import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../Minigo/theme/mini_theme.dart';
import '../../../Minigo/widgets/mini_ufo.dart';
import '../../../Minigo/widgets/mini_widgets.dart';
import '../onboarding_content.dart';
import '../widgets/onb_motion.dart';
import '../widgets/onb_painters.dart';

// ---------------------------------------------------------------------------
// Screen 3 — "A simpler way to send files"
//
// The payoff for the swipe deck: a short list of what MiniGo does instead,
// led by the cards they agreed with. One bold line and one soft line per row.
// ---------------------------------------------------------------------------

class OnbSolutionScreen extends StatelessWidget {
  final List<OnbPain> rows;
  final VoidCallback onNext;

  const OnbSolutionScreen({
    super.key,
    required this.rows,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    final heading = MiniText.display.copyWith(fontSize: 32);
    // Smaller on short phones so all three rows fit above the button.
    final hero = math.min(130.0, MediaQuery.sizeOf(context).height * 0.13);
    return OnbStagger(
      child: OnbPage(
        body: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            OnbReveal(
              index: 0,
              child: SizedBox(
                height: hero,
                child: Stack(
                  alignment: Alignment.center,
                  clipBehavior: Clip.none,
                  children: [
                    OnbOrbits(size: hero * 1.6),
                    MiniUfo(size: hero * 0.74),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            OnbReveal(
              index: 1,
              child: Text.rich(
                TextSpan(children: [
                  const TextSpan(text: 'A simpler way\n'),
                  TextSpan(
                    text: 'to send files',
                    style: TextStyle(color: c.accent),
                  ),
                ]),
                textAlign: TextAlign.center,
                style: heading,
              ),
            ),
            const SizedBox(height: 22),
            Container(
              decoration: miniCard(context, strong: true),
              child: Column(
                children: [
                  for (var i = 0; i < rows.length; i++) ...[
                    if (i > 0)
                      Divider(
                        height: 1,
                        thickness: 1,
                        indent: 70,
                        color: c.dividerSoft,
                      ),
                    OnbReveal(
                      index: 2 + i,
                      dy: 14,
                      child: _SolutionRow(option: onbPainOption(rows[i])),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        bottom: OnbReveal(
          index: 3 + rows.length,
          child: OnbSheen(
            borderRadius: BorderRadius.circular(MiniRadius.pill),
            child: MiniButton(label: 'Set me up', onPressed: onNext),
          ),
        ),
      ),
    );
  }
}

class _SolutionRow extends StatelessWidget {
  final OnbPainOption option;
  const _SolutionRow({required this.option});

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Semantics(
      label: '${option.headline}. ${option.fix}',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 18, 14),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: c.accentSoft,
                borderRadius: BorderRadius.circular(MiniRadius.control),
              ),
              child: Icon(option.icon, size: 20, color: c.accent),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(option.headline, style: MiniText.heading),
                  const SizedBox(height: 3),
                  Text(option.fix, style: MiniText.small),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
