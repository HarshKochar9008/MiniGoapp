import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../Minigo/theme/mini_theme.dart';
import '../../../Minigo/widgets/mini_widgets.dart';
import '../onboarding_content.dart';
import '../widgets/onb_motion.dart';
import '../widgets/onb_widgets.dart';

// ---------------------------------------------------------------------------
// Screen 8 — Placeholder "MiniGo Pro" paywall.
//
// DEBUG BUILDS ONLY (see OnboardingFlowV2.showProPaywall). Nothing here is
// connected to the App Store or Google Play: shipping a purchase button that
// doesn't work gets an app rejected. Every bracketed value is a placeholder.
// ---------------------------------------------------------------------------

class OnbPaywallScreen extends StatefulWidget {
  final VoidCallback onContinueFree;
  final ValueChanged<String> onCta;

  const OnbPaywallScreen({
    super.key,
    required this.onContinueFree,
    required this.onCta,
  });

  @override
  State<OnbPaywallScreen> createState() => _OnbPaywallScreenState();
}

class _OnbPaywallScreenState extends State<OnbPaywallScreen> {
  bool _yearly = true;

  void _todo(String what) {
    widget.onCta(what);
    // TODO(pro): start the store purchase / restore flow here.
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Placeholder paywall — purchases aren’t connected yet.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return OnbStagger(
      child: OnbPage(
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            OnbReveal(
              index: 0,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: MiniColors.warn.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(MiniRadius.pill),
                  ),
                  child: Text(
                    'PLACEHOLDER · DEBUG BUILDS ONLY',
                    style: MiniText.label.copyWith(color: MiniColors.warn),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const OnbTitle(
              title: 'Go further with MiniGo Pro',
              subtitle: 'MiniGo stays free. Pro is for when you need more.',
              revealIndex: 1,
            ),
            const SizedBox(height: 20),
            for (var i = 0; i < onbProPerks.length; i++)
              OnbReveal(
                index: 3 + i,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    children: [
                      MiniIconPlate(
                        icon: onbProPerks[i].icon,
                        tint: c.accent,
                        size: 40,
                        iconSize: 19,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              onbProPerks[i].pro,
                              style: MiniText.body
                                  .copyWith(fontWeight: FontWeight.w600),
                            ),
                            Text(onbProPerks[i].free, style: MiniText.small),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 6),
            OnbReveal(
              index: 7,
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final f in const [
                    'End-to-end encrypted',
                    'No account needed',
                    'Cancel any time',
                  ])
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: c.sand,
                        borderRadius: BorderRadius.circular(MiniRadius.pill),
                      ),
                      child: Text(f,
                          style: MiniText.small
                              .copyWith(fontWeight: FontWeight.w500)),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            OnbReveal(
              index: 8,
              child: _PlanCard(
                selected: _yearly,
                title: 'Yearly',
                price: onbProYearlyPrice,
                detail: onbProYearlyPerMonth,
                badge: '$onbProTrialLabel free trial',
                onTap: () {
                  onbTick();
                  setState(() => _yearly = true);
                },
              ),
            ),
            const SizedBox(height: 10),
            OnbReveal(
              index: 9,
              child: _PlanCard(
                selected: !_yearly,
                title: 'Monthly',
                price: onbProMonthlyPrice,
                onTap: () {
                  onbTick();
                  setState(() => _yearly = false);
                },
              ),
            ),
          ],
        ),
        bottom: OnbReveal(
          index: 10,
          step: 0.06,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OnbSheen(
                borderRadius: BorderRadius.circular(MiniRadius.pill),
                child: MiniButton(
                  label: _yearly
                      ? 'Start my free $onbProTrialLabel trial'
                      : 'Subscribe — $onbProMonthlyPrice',
                  onPressed: () => _todo(_yearly ? 'yearly' : 'monthly'),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _yearly
                    ? 'Then $onbProYearlyRenewal/year. Renews automatically. '
                        'Cancel any time in your App Store or Google Play '
                        'settings.'
                    : 'Renews monthly. Cancel any time in your App Store or '
                        'Google Play settings.',
                style: MiniText.small.copyWith(fontSize: 11.5),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              MiniButton(
                label: 'Continue with free',
                style: MiniBtnStyle.secondary,
                onPressed: widget.onContinueFree,
              ),
              TextButton(
                onPressed: () => _todo('restore'),
                child: const Text('Restore purchases'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlanCard extends StatefulWidget {
  final bool selected;
  final String title;
  final String price;
  final String? detail;
  final String? badge;
  final VoidCallback onTap;

  const _PlanCard({
    required this.selected,
    required this.title,
    required this.price,
    required this.onTap,
    this.detail,
    this.badge,
  });

  @override
  State<_PlanCard> createState() => _PlanCardState();
}

class _PlanCardState extends State<_PlanCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2800),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (onbReduceMotion(context)) {
      _spin.stop();
    } else if (!_spin.isAnimating) {
      _spin.repeat();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return OnbPressable(
      onTap: widget.onTap,
      selected: widget.selected,
      semanticLabel: '${widget.title}, ${widget.price}'
          '${widget.badge != null ? ', ${widget.badge}' : ''}',
      child: CustomPaint(
        foregroundPainter: widget.selected
            ? _SpinBorderPainter(clock: _spin, accent: c.accent)
            : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 260),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: BoxDecoration(
            color: widget.selected
                ? Color.alphaBlend(c.accentSoft, c.paperDeep)
                : c.paperDeep,
            borderRadius: BorderRadius.circular(MiniRadius.card),
            border: Border.all(
              color: widget.selected ? Colors.transparent : c.divider,
            ),
            boxShadow: miniCardShadow(context, strong: widget.selected),
          ),
          child: Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: widget.selected ? c.accent : c.sandDeep,
                    width: widget.selected ? 7 : 2,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.title, style: MiniText.heading),
                    if (widget.detail != null)
                      Text(widget.detail!, style: MiniText.small),
                    // Own line: beside the title it ran out of room on
                    // 320-pt-wide phones once the price took its share.
                    if (widget.badge != null) ...[
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: MiniColors.blue600,
                          borderRadius: BorderRadius.circular(MiniRadius.pill),
                        ),
                        child: Text(
                          widget.badge!,
                          style: GoogleFonts.outfit(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Text(
                widget.price,
                style: MiniText.heading.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A rotating sweep-gradient outline around the selected plan.
class _SpinBorderPainter extends CustomPainter {
  final Animation<double> clock;
  final Color accent;
  _SpinBorderPainter({required this.clock, required this.accent})
      : super(repaint: clock);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(1);
    final rrect =
        RRect.fromRectAndRadius(rect, const Radius.circular(MiniRadius.card));
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..shader = SweepGradient(
          colors: [
            accent,
            MiniColors.blue200,
            accent.withValues(alpha: 0.4),
            accent,
          ],
          stops: const [0, 0.35, 0.7, 1],
          transform: GradientRotation(clock.value * math.pi * 2),
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_SpinBorderPainter old) => old.accent != accent;
}
