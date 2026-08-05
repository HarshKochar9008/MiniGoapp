import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/mini_theme.dart';

/// Animated MiniGo saucer built from `assets/minigo_ufo.png`.
///
/// The artwork already carries baked-in speed trails, so the motion design
/// leans on that instead of fighting it:
///  * **Arrival** — the saucer warps in from the lower left while warp streaks
///    rush past it and a shockwave ring expands from the landing point.
///  * **Hover** — it settles into a slow sine bob with a matching tilt, a
///    breathing glow underneath, and sparks orbiting on two axes.
///
/// Honours the platform "reduce motion" setting: when animations are disabled
/// the saucer is drawn in its resting pose with the glow, no movement.
class MiniUfo extends StatefulWidget {
  /// Width of the saucer artwork. The widget lays out as a square of
  /// `size * 1.25` so the glow and orbiting sparks have room.
  final double size;

  /// Play the warp-in before settling into the hover loop.
  final bool arrive;

  /// Keep bobbing/orbiting after arrival. Set false for a static hero.
  final bool hover;

  /// Accent used for the glow, streaks and sparks. Defaults to the theme
  /// accent so the animation reads correctly in light and dark mode.
  final Color? tint;

  /// Fired once the arrival leg finishes (never fired when reduce-motion is on
  /// or [arrive] is false — call sites must not depend on it for logic).
  final VoidCallback? onArrived;

  const MiniUfo({
    super.key,
    this.size = 150,
    this.arrive = true,
    this.hover = true,
    this.tint,
    this.onArrived,
  });

  @override
  State<MiniUfo> createState() => _MiniUfoState();
}

class _MiniUfoState extends State<MiniUfo> with TickerProviderStateMixin {
  static const _arrivalDuration = Duration(milliseconds: 1250);
  static const _hoverDuration = Duration(milliseconds: 4200);

  late final AnimationController _arrival;
  late final AnimationController _hover;

  /// Eased arrival progress: 0 = off-screen lower left, 1 = resting pose.
  late final Animation<double> _flight;

  /// Streaks and the shockwave live on their own slices of the arrival.
  late final Animation<double> _streaks;
  late final Animation<double> _shockwave;

  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _arrival = AnimationController(vsync: this, duration: _arrivalDuration);
    _hover = AnimationController(vsync: this, duration: _hoverDuration);

    _flight = CurvedAnimation(parent: _arrival, curve: Curves.easeOutCubic);
    _streaks = CurvedAnimation(
      parent: _arrival,
      curve: const Interval(0, 0.72, curve: Curves.easeOutQuart),
    );
    _shockwave = CurvedAnimation(
      parent: _arrival,
      curve: const Interval(0.52, 1, curve: Curves.easeOutCubic),
    );

    _arrival.addStatusListener((status) {
      if (status == AnimationStatus.completed) widget.onArrived?.call();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // MediaQuery is only safe from here down, and the flag can change while
    // the widget is alive (system setting toggled), so re-evaluate each time.
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduce != _reduceMotion || !_arrival.isAnimating) {
      _reduceMotion = reduce;
      _applyMotion();
    }
  }

  @override
  void didUpdateWidget(MiniUfo old) {
    super.didUpdateWidget(old);
    if (old.arrive != widget.arrive || old.hover != widget.hover) {
      _applyMotion();
    }
  }

  void _applyMotion() {
    if (_reduceMotion) {
      _arrival.value = 1;
      _hover
        ..stop()
        ..value = 0;
      return;
    }
    if (widget.arrive) {
      if (!_arrival.isAnimating && _arrival.value < 1) _arrival.forward();
    } else {
      _arrival.value = 1;
    }
    if (widget.hover) {
      if (!_hover.isAnimating) _hover.repeat();
    } else {
      _hover
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _arrival.dispose();
    _hover.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tint = widget.tint ?? context.mini.accent;
    final box = widget.size * 1.25;

    return SizedBox(
      width: box,
      height: box,
      // One rebuild per frame drives every layer, so the bob, glow and sparks
      // stay locked to the same phase.
      child: AnimatedBuilder(
        animation: Listenable.merge([_arrival, _hover]),
        builder: (context, _) {
          final t = _hover.value; // 0..1, loops
          final flight = _flight.value; // 0..1, one-shot
          final wave = math.sin(t * 2 * math.pi);

          // Warp-in path: the saucer keeps the artwork's own travel axis
          // (lower left → upper right) so the baked trails read as real speed.
          final travel = widget.size * 0.9 * (1 - flight);
          final dx = -travel;
          final dy = travel * 0.42;

          // Hover: gentle vertical bob plus a matched tilt, both faded in with
          // the arrival so the settle looks like one motion.
          final bob = wave * widget.size * 0.035 * flight;
          final tilt = wave * 0.022 * flight;
          final settleScale = 0.82 + 0.18 * flight;

          return Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              // Breathing ground glow.
              Transform.translate(
                offset: Offset(0, widget.size * 0.30 + bob * 0.5),
                child: Opacity(
                  opacity: (0.55 + 0.45 * wave).clamp(0.0, 1.0) * flight,
                  child: Container(
                    width: widget.size * (0.62 + 0.06 * wave),
                    height: widget.size * 0.20,
                    decoration: BoxDecoration(
                      borderRadius:
                          BorderRadius.all(Radius.elliptical(box, box)),
                      gradient: RadialGradient(
                        colors: [
                          tint.withValues(alpha: 0.34),
                          tint.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              // Halo behind the hull.
              Opacity(
                opacity: 0.5 + 0.25 * wave,
                child: Container(
                  width: box,
                  height: box,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: miniGlow(tint, strength: 0.20),
                  ),
                ),
              ),

              // Warp streaks — only during the approach.
              if (_streaks.value > 0 && _streaks.value < 1)
                CustomPaint(
                  size: Size.square(box),
                  painter: _WarpStreakPainter(
                    progress: _streaks.value,
                    tint: tint,
                  ),
                ),

              // Shockwave ring at touchdown.
              if (_shockwave.value > 0)
                CustomPaint(
                  size: Size.square(box),
                  painter: _ShockwavePainter(
                    progress: _shockwave.value,
                    tint: tint,
                  ),
                ),

              // Orbiting sparks.
              CustomPaint(
                size: Size.square(box),
                painter: _SparkPainter(
                  phase: t,
                  fade: flight,
                  tint: tint,
                ),
              ),

              // The saucer itself.
              Transform.translate(
                offset: Offset(dx, dy + bob),
                child: Transform.rotate(
                  angle: tilt,
                  child: Transform.scale(
                    scale: settleScale,
                    child: Image.asset(
                      'assets/minigo_ufo.png',
                      width: widget.size,
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.medium,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Thin streaks rushing along the saucer's travel axis during the warp-in.
class _WarpStreakPainter extends CustomPainter {
  final double progress;
  final Color tint;

  const _WarpStreakPainter({required this.progress, required this.tint});

  // Perpendicular offsets and relative speeds, hand-tuned so the streaks read
  // as a loose bundle rather than a comb.
  static const _lanes = [-0.30, -0.14, 0.02, 0.17, 0.33];
  static const _speeds = [1.00, 0.78, 1.18, 0.86, 1.06];

  @override
  void paint(Canvas canvas, Size size) {
    // Travel axis of the artwork: up and to the right at ~24°.
    const angle = -0.42;
    final dir = Offset(math.cos(angle), math.sin(angle));
    final perp = Offset(-dir.dy, dir.dx);
    final center = size.center(Offset.zero);
    final span = size.width * 1.15;

    // Streaks are brightest mid-approach and gone by the time it settles.
    final fade = math.sin(progress * math.pi);

    for (var i = 0; i < _lanes.length; i++) {
      final p = (progress * _speeds[i]).clamp(0.0, 1.0);
      final length = span * 0.42 * (1 - p * 0.65);
      final head =
          center + dir * (span * (p - 0.5)) + perp * (size.width * _lanes[i]);
      final tail = head - dir * length;

      final paint = Paint()
        ..strokeCap = StrokeCap.round
        ..strokeWidth = size.width * (0.008 + 0.006 * (1 - p))
        ..shader = LinearGradient(
          begin: Alignment.centerRight,
          end: Alignment.centerLeft,
          colors: [
            tint.withValues(alpha: 0.55 * fade),
            tint.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromPoints(head, tail));
      canvas.drawLine(head, tail, paint);
    }
  }

  @override
  bool shouldRepaint(_WarpStreakPainter old) =>
      old.progress != progress || old.tint != tint;
}

/// Expanding ring that lands with the saucer.
class _ShockwavePainter extends CustomPainter {
  final double progress;
  final Color tint;

  const _ShockwavePainter({required this.progress, required this.tint});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    for (final delay in const [0.0, 0.22]) {
      final p = ((progress - delay) / (1 - delay)).clamp(0.0, 1.0);
      if (p <= 0) continue;
      final radius = size.width * (0.16 + 0.34 * p);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.width * 0.012 * (1 - p)
        ..color = tint.withValues(alpha: 0.42 * (1 - p));
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(_ShockwavePainter old) =>
      old.progress != progress || old.tint != tint;
}

/// Small sparks orbiting the saucer on two tilted rings.
class _SparkPainter extends CustomPainter {
  final double phase;
  final double fade;
  final Color tint;

  const _SparkPainter({
    required this.phase,
    required this.fade,
    required this.tint,
  });

  // radiusFactor, flattening, angular offset, direction
  static const _orbits = [
    (0.44, 0.34, 0.0, 1.0),
    (0.36, 0.52, 2.1, -1.0),
    (0.48, 0.26, 4.0, 1.0),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (fade <= 0) return;
    final center = size.center(Offset.zero);
    for (var i = 0; i < _orbits.length; i++) {
      final (rf, flat, offset, dir) = _orbits[i];
      final a = (phase * 2 * math.pi * dir) + offset;
      final pos = center +
          Offset(
            math.cos(a) * size.width * rf,
            math.sin(a) * size.width * rf * flat,
          );
      // Sparks on the far side of the orbit read dimmer.
      final depth = (math.sin(a) + 1) / 2;
      final alpha = (0.22 + 0.55 * depth) * fade;
      final r = size.width * (0.010 + 0.006 * depth);

      canvas.drawCircle(
        pos,
        r * 2.6,
        Paint()..color = tint.withValues(alpha: alpha * 0.22),
      );
      canvas.drawCircle(pos, r, Paint()..color = tint.withValues(alpha: alpha));
    }
  }

  @override
  bool shouldRepaint(_SparkPainter old) =>
      old.phase != phase || old.fade != fade || old.tint != tint;
}
