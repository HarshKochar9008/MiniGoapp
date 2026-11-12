import 'package:flutter/material.dart';

import '../../../Minigo/theme/mini_icons.dart';
import '../../../Minigo/theme/mini_theme.dart';
import 'onb_motion.dart';

// ---------------------------------------------------------------------------
// Progress bar — glowing fill with the saucer riding its leading edge
// ---------------------------------------------------------------------------

class OnbProgressBar extends StatelessWidget {
  final double value;
  final String semanticsLabel;

  const OnbProgressBar({
    super.key,
    required this.value,
    required this.semanticsLabel,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Semantics(
      label: semanticsLabel,
      child: SizedBox(
        height: 28,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: value.clamp(0.0, 1.0)),
          duration: const Duration(milliseconds: 800),
          curve: Curves.easeOutCubic,
          builder: (context, v, _) => LayoutBuilder(
            builder: (context, constraints) {
              final w = constraints.maxWidth;
              final head = 10 + (w - 20) * v;
              return Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.centerLeft,
                children: [
                  Container(
                    height: 6,
                    decoration: BoxDecoration(
                      color: c.sand,
                      borderRadius: BorderRadius.circular(MiniRadius.pill),
                    ),
                  ),
                  Container(
                    width: head,
                    height: 6,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(MiniRadius.pill),
                      gradient: LinearGradient(colors: [
                        MiniColors.blue600.withValues(alpha: 0.55),
                        MiniColors.blue600,
                        c.accent,
                      ]),
                      boxShadow: [
                        BoxShadow(
                          color: c.accent.withValues(alpha: 0.45),
                          blurRadius: 10,
                        ),
                      ],
                    ),
                  ),
                  Positioned(
                    left: head - 13,
                    child: ExcludeSemantics(
                      child: Image.asset(
                        'assets/minigo_ufo.png',
                        width: 26,
                        filterQuality: FilterQuality.medium,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Titles
// ---------------------------------------------------------------------------

class OnbTitle extends StatelessWidget {
  final String title;
  final String? subtitle;
  final TextAlign align;
  final int revealIndex;

  const OnbTitle({
    super.key,
    required this.title,
    this.subtitle,
    this.align = TextAlign.start,
    this.revealIndex = 0,
  });

  @override
  Widget build(BuildContext context) {
    final cross = align == TextAlign.center
        ? CrossAxisAlignment.center
        : CrossAxisAlignment.start;
    return Column(
      crossAxisAlignment: cross,
      children: [
        OnbReveal(
          index: revealIndex,
          child: Text(
            title,
            textAlign: align,
            style: MiniText.title.copyWith(fontSize: 26, letterSpacing: -0.7),
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 8),
          OnbReveal(
            index: revealIndex + 1,
            child: Text(subtitle!, textAlign: align, style: MiniText.bodySoft),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Round action button (swipe screen)
// ---------------------------------------------------------------------------

class OnbRoundButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool primary;
  final VoidCallback? onTap;

  const OnbRoundButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return OnbPressable(
      onTap: onTap,
      pressedScale: 0.88,
      semanticLabel: label,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: primary ? MiniColors.blue600 : c.paperDeep,
              border: primary ? null : Border.all(color: c.divider),
              boxShadow: [
                ...miniCardShadow(context, strong: true),
                if (primary)
                  BoxShadow(
                    color: MiniColors.blue600.withValues(alpha: 0.35),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
              ],
            ),
            child:
                Icon(icon, size: 26, color: primary ? Colors.white : c.inkSoft),
          ),
          const SizedBox(height: 8),
          ExcludeSemantics(
            child: Text(label,
                textAlign: TextAlign.center,
                style: MiniText.small.copyWith(fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }
}

/// A short animated "Copied" confirmation that swaps in for a label.
class OnbCopiedLabel extends StatelessWidget {
  final bool copied;
  final String idle;
  const OnbCopiedLabel({super.key, required this.copied, required this.idle});

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      transitionBuilder: (child, anim) => ScaleTransition(
        scale: Tween(begin: 0.6, end: 1.0).animate(
          CurvedAnimation(parent: anim, curve: Curves.easeOutBack),
        ),
        child: FadeTransition(opacity: anim, child: child),
      ),
      child: Row(
        key: ValueKey(copied),
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(copied ? MiniIcons.check : MiniIcons.copy,
              size: 18, color: context.mini.ink),
          const SizedBox(width: 8),
          Text(copied ? 'Copied' : idle, style: MiniText.button),
        ],
      ),
    );
  }
}
