import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../Minigo/theme/mini_theme.dart';

/// Motion primitives for the questionnaire onboarding.
///
/// Every animated piece honours the platform "reduce motion" setting the same
/// way MiniUfo and MiniCodeReel do: when animations are disabled, things are
/// drawn in their final state and nothing moves.

bool onbReduceMotion(BuildContext context) =>
    MediaQuery.maybeDisableAnimationsOf(context) ?? false;

/// Maps [t] into the sub-range [start, end] and eases it.
double onbSegment(double t, double start, double end,
    [Curve curve = Curves.easeOutCubic]) {
  if (end <= start) return t >= end ? 1 : 0;
  return curve.transform(((t - start) / (end - start)).clamp(0.0, 1.0));
}

// ---------------------------------------------------------------------------
// Staggered entrances
// ---------------------------------------------------------------------------

/// Drives the entrance of every [OnbReveal] beneath it from one controller.
class OnbStagger extends StatefulWidget {
  final Widget child;
  final Duration duration;
  final Duration delay;

  const OnbStagger({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 1200),
    this.delay = const Duration(milliseconds: 120),
  });

  static Animation<double> of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_OnbStaggerScope>()
          ?.animation ??
      kAlwaysCompleteAnimation;

  @override
  State<OnbStagger> createState() => _OnbStaggerState();
}

class _OnbStaggerState extends State<OnbStagger>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: widget.duration);
  Timer? _start;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (onbReduceMotion(context)) {
      _ctrl.value = 1;
    } else {
      _start = Timer(widget.delay, () {
        if (mounted) _ctrl.forward();
      });
    }
  }

  @override
  void dispose() {
    _start?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _OnbStaggerScope(animation: _ctrl, child: widget.child);
}

class _OnbStaggerScope extends InheritedWidget {
  final Animation<double> animation;
  const _OnbStaggerScope({required this.animation, required super.child});

  @override
  bool updateShouldNotify(_OnbStaggerScope old) => old.animation != animation;
}

/// Fades, lifts and un-shrinks [child] in its slot of the surrounding
/// [OnbStagger]. Higher [index] = later.
class OnbReveal extends StatelessWidget {
  final int index;
  final Widget child;
  final double dy;
  final double step;
  final double span;

  const OnbReveal({
    super.key,
    required this.index,
    required this.child,
    this.dy = 26,
    this.step = 0.075,
    this.span = 0.42,
  });

  @override
  Widget build(BuildContext context) {
    final anim = OnbStagger.of(context);
    final start = (index * step).clamp(0.0, 1.0 - span);
    final end = (start + span).clamp(0.0, 1.0);
    return AnimatedBuilder(
      animation: anim,
      child: child,
      builder: (context, child) {
        final t = onbSegment(anim.value, start, end);
        final pop = onbSegment(anim.value, start, end, Curves.easeOutBack);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, dy * (1 - pop)),
            child: Transform.scale(scale: 0.94 + 0.06 * pop, child: child),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Ambient background — drifting stars and slow glows, parallax on progress
// ---------------------------------------------------------------------------

class OnbSpaceBackground extends StatefulWidget {
  /// 0..1 through the flow. Stars slide with it, so moving forward feels
  /// like flying forward.
  final double progress;
  final Widget child;

  const OnbSpaceBackground({
    super.key,
    required this.progress,
    required this.child,
  });

  @override
  State<OnbSpaceBackground> createState() => _OnbSpaceBackgroundState();
}

class _OnbSpaceBackgroundState extends State<OnbSpaceBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 40),
  );
  static final List<_Star> _stars = _Star.field(70);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (onbReduceMotion(context)) {
      _ctrl.stop();
    } else if (!_ctrl.isAnimating) {
      _ctrl.repeat();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: c.paper),
        RepaintBoundary(
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: widget.progress),
            duration: const Duration(milliseconds: 900),
            curve: Curves.easeInOutCubic,
            builder: (context, progress, _) => CustomPaint(
              painter: _SpacePainter(
                clock: _ctrl,
                progress: progress,
                stars: _stars,
                accent: c.accent,
                dot: context.isDarkMini ? Colors.white : c.ink,
                dark: context.isDarkMini,
              ),
            ),
          ),
        ),
        widget.child,
      ],
    );
  }
}

class _Star {
  final double x, y, r, depth, phase;
  const _Star(this.x, this.y, this.r, this.depth, this.phase);

  static List<_Star> field(int n) {
    final rng = math.Random(7);
    return List.generate(n, (_) {
      final depth = 0.25 + rng.nextDouble() * 0.75;
      return _Star(
        rng.nextDouble(),
        rng.nextDouble(),
        0.5 + depth * 1.4,
        depth,
        rng.nextDouble() * math.pi * 2,
      );
    });
  }
}

class _SpacePainter extends CustomPainter {
  final Animation<double> clock;
  final double progress;
  final List<_Star> stars;
  final Color accent;
  final Color dot;
  final bool dark;

  _SpacePainter({
    required this.clock,
    required this.progress,
    required this.stars,
    required this.accent,
    required this.dot,
    required this.dark,
  }) : super(repaint: clock);

  @override
  void paint(Canvas canvas, Size size) {
    final t = clock.value * math.pi * 2;

    // Two slow glows on lissajous paths.
    void glow(double cx, double cy, double radius, double alpha) {
      final center = Offset(cx * size.width, cy * size.height);
      final rect = Rect.fromCircle(center: center, radius: radius);
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(colors: [
            accent.withValues(alpha: alpha),
            accent.withValues(alpha: 0),
          ]).createShader(rect),
      );
    }

    glow(0.18 + 0.10 * math.sin(t), 0.14 + 0.06 * math.cos(t * 2),
        size.width * 0.75, dark ? 0.16 : 0.10);
    glow(0.86 + 0.08 * math.cos(t), 0.82 + 0.05 * math.sin(t * 3),
        size.width * 0.65, dark ? 0.12 : 0.07);

    // Stars drift down-left slowly; progress slides them sideways by depth.
    final paint = Paint();
    for (final s in stars) {
      final x =
          (s.x - progress * 0.45 * s.depth - clock.value * 0.05 * s.depth) %
              1.0 *
              size.width;
      final y = (s.y + clock.value * 0.12 * s.depth) % 1.0 * size.height;
      final twinkle = 0.55 + 0.45 * math.sin(t * 6 + s.phase);
      paint.color =
          dot.withValues(alpha: (dark ? 0.55 : 0.16) * s.depth * twinkle);
      canvas.drawCircle(Offset(x, y), s.r, paint);
    }
  }

  @override
  bool shouldRepaint(_SpacePainter old) =>
      old.progress != progress ||
      old.accent != accent ||
      old.dot != dot ||
      old.dark != dark;
}

// ---------------------------------------------------------------------------
// Press feedback
// ---------------------------------------------------------------------------

/// Squashes [child] while pressed and springs it back on release.
class OnbPressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double pressedScale;
  final String? semanticLabel;
  final bool? selected;

  const OnbPressable({
    super.key,
    required this.child,
    this.onTap,
    this.pressedScale = 0.96,
    this.semanticLabel,
    this.selected,
  });

  @override
  State<OnbPressable> createState() => _OnbPressableState();
}

class _OnbPressableState extends State<OnbPressable> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      selected: widget.selected,
      label: widget.semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => _set(true) : null,
        onTapUp: enabled ? (_) => _set(false) : null,
        onTapCancel: enabled ? () => _set(false) : null,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _down ? widget.pressedScale : 1,
          duration: Duration(milliseconds: _down ? 90 : 260),
          curve: _down ? Curves.easeOut : Curves.elasticOut,
          child: widget.child,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Particle burst
// ---------------------------------------------------------------------------

/// A one-shot burst of confetti-like sparks, replayed whenever [trigger]
/// changes. Paints over [child] without taking hits.
class OnbBurst extends StatefulWidget {
  final int trigger;
  final Widget child;
  final List<Color>? colors;
  final int count;
  final double spread;

  const OnbBurst({
    super.key,
    required this.trigger,
    required this.child,
    this.colors,
    this.count = 34,
    this.spread = 170,
  });

  @override
  State<OnbBurst> createState() => _OnbBurstState();
}

class _OnbBurstState extends State<OnbBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );
  List<_Spark> _sparks = const [];

  @override
  void didUpdateWidget(OnbBurst old) {
    super.didUpdateWidget(old);
    if (old.trigger != widget.trigger && widget.trigger > 0) _fire();
  }

  void _fire() {
    if (onbReduceMotion(context)) return;
    final rng = math.Random();
    _sparks = List.generate(widget.count, (_) {
      final a = rng.nextDouble() * math.pi * 2;
      return _Spark(
        angle: a,
        speed: 0.45 + rng.nextDouble() * 0.55,
        size: 3 + rng.nextDouble() * 4,
        spin: (rng.nextDouble() - 0.5) * 10,
        colorIndex: rng.nextInt(64),
        square: rng.nextBool(),
      );
    });
    _ctrl.forward(from: 0);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    final colors = widget.colors ??
        [c.accent, MiniColors.blue200, MiniColors.blue500, c.ink];
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _BurstPainter(
                anim: _ctrl,
                sparks: _sparks,
                colors: colors,
                spread: widget.spread,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Spark {
  final double angle, speed, size, spin;
  final int colorIndex;
  final bool square;
  const _Spark({
    required this.angle,
    required this.speed,
    required this.size,
    required this.spin,
    required this.colorIndex,
    required this.square,
  });
}

class _BurstPainter extends CustomPainter {
  final Animation<double> anim;
  final List<_Spark> sparks;
  final List<Color> colors;
  final double spread;

  _BurstPainter({
    required this.anim,
    required this.sparks,
    required this.colors,
    required this.spread,
  }) : super(repaint: anim);

  @override
  void paint(Canvas canvas, Size size) {
    final t = anim.value;
    if (t == 0 || t == 1 || sparks.isEmpty) return;
    final center = size.center(Offset.zero);
    final travel = Curves.easeOutCubic.transform(t);
    final fade = 1 - Curves.easeInQuad.transform(t);
    final paint = Paint();
    for (final s in sparks) {
      final d = spread * s.speed * travel;
      final gravity = 90 * t * t;
      final p = center +
          Offset(math.cos(s.angle) * d, math.sin(s.angle) * d + gravity);
      paint.color = colors[s.colorIndex % colors.length]
          .withValues(alpha: fade.clamp(0.0, 1.0));
      canvas.save();
      canvas.translate(p.dx, p.dy);
      canvas.rotate(s.spin * t);
      if (s.square) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: Offset.zero, width: s.size, height: s.size * 0.6),
            const Radius.circular(1.2),
          ),
          paint,
        );
      } else {
        canvas.drawCircle(Offset.zero, s.size / 2, paint);
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_BurstPainter old) =>
      old.sparks != sparks || old.colors != colors;
}

// ---------------------------------------------------------------------------
// Sheen — a diagonal highlight that sweeps across [child] on a loop
// ---------------------------------------------------------------------------

class OnbSheen extends StatefulWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final Duration period;
  final double strength;
  final bool enabled;

  const OnbSheen({
    super.key,
    required this.child,
    this.borderRadius = BorderRadius.zero,
    this.period = const Duration(milliseconds: 3600),
    this.strength = 0.22,
    this.enabled = true,
  });

  @override
  State<OnbSheen> createState() => _OnbSheenState();
}

class _OnbSheenState extends State<OnbSheen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: widget.period);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!widget.enabled || onbReduceMotion(context)) {
      _ctrl.stop();
    } else if (!_ctrl.isAnimating) {
      _ctrl.repeat();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || onbReduceMotion(context)) return widget.child;
    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: ClipRRect(
              borderRadius: widget.borderRadius,
              child: AnimatedBuilder(
                animation: _ctrl,
                builder: (context, _) {
                  // Sweep during the first 40% of the period, rest after.
                  final t = onbSegment(_ctrl.value, 0, 0.4, Curves.easeInOut);
                  final x = -2.2 + 4.4 * t;
                  return DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment(x - 0.6, -1),
                        end: Alignment(x + 0.6, 1),
                        colors: [
                          Colors.white.withValues(alpha: 0),
                          Colors.white.withValues(alpha: widget.strength),
                          Colors.white.withValues(alpha: 0),
                        ],
                        stops: const [0.35, 0.5, 0.65],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Bottom call-to-action area
// ---------------------------------------------------------------------------

/// Slides its buttons up into place when [visible] turns true.
class OnbCtaArea extends StatelessWidget {
  final bool visible;
  final List<Widget> children;

  const OnbCtaArea({super.key, this.visible = true, required this.children});

  @override
  Widget build(BuildContext context) {
    return AnimatedSlide(
      offset: visible ? Offset.zero : const Offset(0, 0.6),
      duration: const Duration(milliseconds: 420),
      curve: visible ? Curves.easeOutBack : Curves.easeIn,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 260),
        child: IgnorePointer(
          ignoring: !visible,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    );
  }
}

/// Standard page layout: scrollable content above, pinned buttons below.
class OnbPage extends StatelessWidget {
  final Widget body;
  final Widget? bottom;
  final EdgeInsets padding;

  /// Give [body] exactly the height above [bottom], so it can share it out
  /// with [Expanded]. It scrolls only when its intrinsic height is taller,
  /// so everything in it must report one: put a LayoutBuilder in a Stack
  /// (Positioned.fill) beside a SizedBox that stands in for it.
  final bool fillBody;

  const OnbPage({
    super.key,
    required this.body,
    this.bottom,
    this.padding = const EdgeInsets.fromLTRB(24, 8, 24, 20),
    this.fillBody = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: fillBody
                ? CustomScrollView(
                    physics: const BouncingScrollPhysics(),
                    slivers: [
                      SliverFillRemaining(hasScrollBody: false, child: body),
                    ],
                  )
                : LayoutBuilder(
                    builder: (context, constraints) => SingleChildScrollView(
                      physics: const BouncingScrollPhysics(),
                      child: ConstrainedBox(
                        constraints:
                            BoxConstraints(minHeight: constraints.maxHeight),
                        child: body,
                      ),
                    ),
                  ),
          ),
          if (bottom != null) ...[const SizedBox(height: 12), bottom!],
        ],
      ),
    );
  }
}

/// Light haptic tick, swallowed where the platform has none.
void onbTick() => HapticFeedback.selectionClick();
void onbThump() => HapticFeedback.mediumImpact();
