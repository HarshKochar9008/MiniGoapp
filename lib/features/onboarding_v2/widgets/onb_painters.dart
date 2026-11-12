import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../Minigo/theme/mini_theme.dart';
import 'onb_motion.dart';

// ---------------------------------------------------------------------------
// Orbits — two tilted rings with satellites, behind the welcome saucer
// ---------------------------------------------------------------------------

class OnbOrbits extends StatefulWidget {
  final double size;
  const OnbOrbits({super.key, required this.size});

  @override
  State<OnbOrbits> createState() => _OnbOrbitsState();
}

class _OnbOrbitsState extends State<OnbOrbits>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 9),
  );

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
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.square(widget.size),
          painter: _OrbitPainter(clock: _ctrl, tint: context.mini.accent),
        ),
      ),
    );
  }
}

class _OrbitPainter extends CustomPainter {
  final Animation<double> clock;
  final Color tint;
  _OrbitPainter({required this.clock, required this.tint})
      : super(repaint: clock);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final t = clock.value * math.pi * 2;
    void ring(double rx, double ry, double tilt, double speed, int sats,
        double alpha) {
      canvas.save();
      canvas.translate(c.dx, c.dy);
      canvas.rotate(tilt);
      final rect =
          Rect.fromCenter(center: Offset.zero, width: rx * 2, height: ry * 2);
      canvas.drawOval(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = tint.withValues(alpha: alpha),
      );
      for (var i = 0; i < sats; i++) {
        final a = t * speed + i * math.pi * 2 / sats;
        final p = Offset(math.cos(a) * rx, math.sin(a) * ry);
        final front = math.sin(a) > 0;
        canvas.drawCircle(
          p,
          front ? 4 : 2.6,
          Paint()..color = tint.withValues(alpha: front ? 0.9 : 0.35),
        );
        canvas.drawCircle(
          p,
          front ? 10 : 6,
          Paint()..color = tint.withValues(alpha: front ? 0.14 : 0.06),
        );
      }
      canvas.restore();
    }

    final r = size.width / 2;
    ring(r * 0.95, r * 0.34, -0.32, 1, 2, 0.22);
    ring(r * 0.78, r * 0.26, 0.45, -1.6, 1, 0.16);
  }

  @override
  bool shouldRepaint(_OrbitPainter old) => old.tint != tint;
}
