import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../Minigo/theme/mini_theme.dart';
import '../../../Minigo/widgets/mini_ufo.dart';
import 'onb_motion.dart';
import 'onb_slot_machine.dart';

/// The craft screen's stage: the slot machine under a resting saucer and,
/// once the code has landed, the reveal —
///
///  * a shockwave and sparks burst from the reels;
///  * the six tiles flip up out of the machine one after another, turning
///    from paper to glowing blue, and lock into a big `ABC DEF` row;
///  * the empty machine drops away;
///  * the saucer loops once around the new code, trailing light, and settles
///    hovering above it;
///  * a sheen sweeps across the tiles as they lock in.
///
/// Everything runs off one [revealDuration] clock. With reduce motion — or
/// when [revealed] is already true on first build (coming back to the
/// screen) — it shows the final frame.
///
/// `tool/make_onb_sounds.py` times `code_reveal.wav` to the constants below;
/// regenerate it after changing them.
class OnbCodeStage extends StatefulWidget {
  final String? code;
  final bool rolling;

  /// The code has landed: play the reveal.
  final bool revealed;
  final VoidCallback onPull;
  final VoidCallback onLanded;

  const OnbCodeStage({
    super.key,
    required this.code,
    required this.rolling,
    required this.revealed,
    required this.onPull,
    required this.onLanded,
  });

  static const revealDuration = Duration(milliseconds: 1800);

  /// When the tiles have locked in, so the caption and button can follow.
  static const settleDelay = Duration(milliseconds: 1000);

  @override
  State<OnbCodeStage> createState() => _OnbCodeStageState();
}

// Timeline, in seconds from the moment the code lands.
const _burstEnd = 0.8;
const _tileLaunch = 0.06;
const _tileStagger = 0.055;
const _tileFlight = 0.62;
const _machineDrop = (0.08, 0.5);
const _ufoLoop = (0.12, 1.32);
const _trailLength = 0.16; // of the loop
const _sheen = (1.0, 1.45);
const _glowPulse = (0.85, 1.6);

class _OnbCodeStageState extends State<OnbCodeStage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    duration: OnbCodeStage.revealDuration,
  );
  final _glyphs = _Glyphs();
  late final List<_Spark> _sparks = _Spark.scatter(math.Random(7), 36);

  @override
  void initState() {
    super.initState();
    if (widget.revealed) _reveal.value = 1;
  }

  @override
  void didUpdateWidget(OnbCodeStage old) {
    super.didUpdateWidget(old);
    if (widget.revealed && !old.revealed) {
      if (onbReduceMotion(context)) {
        _reveal.value = 1;
      } else {
        _reveal.forward(from: 0);
      }
    } else if (!widget.revealed && old.revealed) {
      _reveal.value = 0;
    }
  }

  @override
  void dispose() {
    _reveal.dispose();
    _glyphs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return LayoutBuilder(builder: (context, constraints) {
      final g = _Stage(constraints.maxWidth);
      final machine = OnbSlotMachine(
        code: widget.code,
        width: g.machineW,
        rolling: widget.rolling,
        tilesOut: widget.revealed,
        onPull: widget.onPull,
        onLanded: widget.onLanded,
      );
      final code = widget.code;
      final stage = SizedBox(
        width: g.w,
        height: g.h,
        child: AnimatedBuilder(
          animation: _reveal,
          child: machine,
          builder: (context, machine) {
            final t = _reveal.value * _seconds;
            final live = widget.revealed && code != null;
            final drop = live
                ? onbSegment(
                    t, _machineDrop.$1, _machineDrop.$2, Curves.easeInCubic)
                : 0.0;
            final ufo = live ? g.ufoAt(t) : g.ufoRest;
            final ufoWidget = Positioned(
              key: const ValueKey('ufo'),
              left: ufo.center.dx - _Stage.ufoBox / 2,
              top: ufo.center.dy - _Stage.ufoBox / 2,
              child: Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 0.0016)
                  ..rotateY(ufo.yaw)
                  ..scaleByDouble(ufo.scale, ufo.scale, 1, 1),
                child: const MiniUfo(size: _Stage.ufo),
              ),
            );
            return Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: g.machineLeft,
                  top: g.machineTop,
                  child: IgnorePointer(
                    ignoring: drop > 0,
                    child: Opacity(
                      opacity: 1 - drop,
                      child: Transform.translate(
                        offset: Offset(0, 34 * drop),
                        child: Transform.scale(
                          scale: 1 - 0.08 * drop,
                          child: machine,
                        ),
                      ),
                    ),
                  ),
                ),
                if (live)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _BackPainter(
                          t: t,
                          stage: g,
                          sparks: _sparks,
                          accent: c.accent,
                          sparkColors: [
                            c.accent,
                            MiniColors.blue500,
                            context.isDarkMini
                                ? Colors.white
                                : MiniColors.blue200,
                          ],
                        ),
                      ),
                    ),
                  ),
                if (ufo.behind) ufoWidget,
                if (live)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _TilesPainter(
                          t: t,
                          stage: g,
                          code: code,
                          glyphs: _glyphs,
                          paper: c.sand,
                          ink: c.ink,
                        ),
                      ),
                    ),
                  ),
                if (!ufo.behind) ufoWidget,
              ],
            );
          },
        ),
      );
      if (!widget.revealed || code == null) return stage;
      return Semantics(
        label: 'Your code: ${code.split('').join(' ')}',
        child: ExcludeSemantics(child: stage),
      );
    });
  }
}

final _seconds = OnbCodeStage.revealDuration.inMilliseconds / 1000;

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------

/// Where everything sits on a stage [w] wide.
class _Stage {
  static const ufo = 120.0; // MiniUfo lays out as ufo × 1.25 square
  static const ufoBox = ufo * 1.25;

  final double w;
  late final double machineW = math.min(w * 0.86, 300.0);
  late final double machineH = OnbSlotMachine.heightFor(machineW);
  late final double h = ufoBox + 56 + machineH;
  late final double machineLeft = (w - machineW) / 2;
  late final double machineTop = h - machineH;

  /// The tiles inside the machine, where the reveal lifts them from.
  late final List<Rect> from = [
    for (final r in OnbSlotMachine.tileRects(machineW))
      r.shift(Offset(machineLeft, machineTop)),
  ];
  late final Offset reels = Rect.fromPoints(
    from.first.topLeft,
    from.last.bottomRight,
  ).center;

  /// The big row they lock into: two groups of three.
  late final List<Rect> to = () {
    final rowW = math.min(w * 0.94, 352.0);
    final gap = rowW * 0.028;
    final groupGap = rowW * 0.07;
    final tileW = (rowW - 4 * gap - groupGap) / 6;
    final tileH = tileW * 1.34;
    final top = h - machineH * 0.5 - 16 - tileH / 2;
    var x = (w - rowW) / 2;
    return [
      for (var i = 0; i < 6; i++)
        () {
          final r = Rect.fromLTWH(x, top, tileW, tileH);
          x += tileW + (i == 2 ? groupGap : gap);
          return r;
        }(),
    ];
  }();
  late final Rect row = Rect.fromPoints(to.first.topLeft, to.last.bottomRight);

  _Stage(this.w);

  late final _UfoPose ufoRest = _UfoPose(Offset(w / 2, ufoBox / 2));
  late final Offset _ufoEnd = Offset(w / 2, row.top - ufoBox * 0.24);

  /// The saucer's loop around the new code.
  Offset _loop(double s) {
    final a = math.min(row.width * 0.6, w * 0.52);
    final b = row.height * 1.25;
    final theta =
        -math.pi / 2 + 2 * math.pi * Curves.easeInOutSine.transform(s);
    final top = Offset(row.center.dx, row.center.dy - b);
    // Blend from the resting spot into the loop and out to the hover spot.
    final k = Curves.easeInOut.transform(s);
    final shift = (ufoRest.center - top) * (1 - k) + (_ufoEnd - top) * k;
    return row.center +
        Offset(a * math.cos(theta), b * math.sin(theta)) +
        shift;
  }

  double _loopS(double t) =>
      ((t - _ufoLoop.$1) / (_ufoLoop.$2 - _ufoLoop.$1)).clamp(0.0, 1.0);

  _UfoPose ufoAt(double t) {
    final s = _loopS(t);
    final theta =
        -math.pi / 2 + 2 * math.pi * Curves.easeInOutSine.transform(s);
    final bump = math.sin(math.pi * s);
    final depth = math.sin(theta) * bump; // < 0: behind the tiles
    final settle = Curves.easeInOut.transform(s);
    return _UfoPose(
      _loop(s),
      yaw: theta + math.pi / 2,
      scale: (1 - 0.18 * settle) * (1 + 0.16 * depth),
      behind: depth <= 0,
    );
  }

  /// Points along the saucer's recent path, oldest first.
  List<Offset> trail(double t) {
    final raw = (t - _ufoLoop.$1) / (_ufoLoop.$2 - _ufoLoop.$1);
    final head = raw.clamp(0.0, 1.0);
    final tail = (raw - _trailLength).clamp(0.0, 1.0);
    if (head - tail < 0.002) return const [];
    return [for (var k = 0; k <= 28; k++) _loop(tail + (head - tail) * k / 28)];
  }
}

class _UfoPose {
  final Offset center;
  final double yaw;
  final double scale;
  final bool behind;
  const _UfoPose(this.center,
      {this.yaw = 0, this.scale = 1, this.behind = true});
}

// ---------------------------------------------------------------------------
// Painters
// ---------------------------------------------------------------------------

class _Spark {
  final double angle, distance, size, delay;
  final int color;
  final bool star;
  const _Spark(
      this.angle, this.distance, this.size, this.delay, this.color, this.star);

  static List<_Spark> scatter(math.Random rng, int n) => [
        for (var i = 0; i < n; i++)
          _Spark(
            (i / n) * 2 * math.pi + rng.nextDouble() * 0.4,
            80 + rng.nextDouble() * 120,
            2 + rng.nextDouble() * 2.8,
            rng.nextDouble() * 0.08,
            rng.nextInt(3),
            rng.nextDouble() < 0.35,
          ),
      ];
}

/// Behind the tiles: the shockwave, the sparks, the row's glow and the
/// saucer's trail.
class _BackPainter extends CustomPainter {
  final double t;
  final _Stage stage;
  final List<_Spark> sparks;
  final Color accent;
  final List<Color> sparkColors;

  _BackPainter({
    required this.t,
    required this.stage,
    required this.sparks,
    required this.accent,
    required this.sparkColors,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final o = stage.reels;

    // Flash and shockwave from the reels.
    final flash = 1 - onbSegment(t, 0, 0.28);
    if (flash > 0) {
      canvas.drawCircle(
        o,
        90,
        Paint()
          ..shader = RadialGradient(colors: [
            accent.withValues(alpha: 0.35 * flash),
            accent.withValues(alpha: 0),
          ]).createShader(Rect.fromCircle(center: o, radius: 90)),
      );
    }
    final wave = onbSegment(t, 0, 0.7);
    if (wave < 1) {
      final r = 24 + 190 * wave;
      canvas.drawOval(
        Rect.fromCenter(center: o, width: r * 2, height: r * 0.9),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.6 + 3 * (1 - wave)
          ..color = accent.withValues(alpha: 0.55 * (1 - wave)),
      );
    }

    // Sparks.
    for (final s in sparks) {
      final u = ((t - s.delay) / (_burstEnd - s.delay)).clamp(0.0, 1.0);
      if (u <= 0 || u >= 1) continue;
      final d = s.distance * Curves.easeOutCubic.transform(u);
      final p = o +
          Offset(math.cos(s.angle) * d, math.sin(s.angle) * d * 0.7) +
          Offset(0, 26 * u * u);
      final paint = Paint()
        ..color = sparkColors[s.color]
            .withValues(alpha: math.pow(1 - u, 1.4).toDouble());
      if (s.star) {
        _star(canvas, p, s.size * 2.2 * (1 - 0.4 * u), paint);
      } else {
        canvas.drawCircle(p, s.size * (1 - 0.5 * u), paint);
      }
    }

    // A glow under the locked-in row: a pulse, then a steady halo.
    final pulse = onbSegment(t, _glowPulse.$1, _glowPulse.$2, Curves.linear);
    if (pulse > 0) {
      final strength = 0.18 + 0.14 * math.sin(math.pi * pulse);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            stage.row.inflate(6), Radius.circular(stage.row.height * 0.3)),
        Paint()
          ..color = accent.withValues(alpha: strength)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 24),
      );
    }

    // The saucer's trail: thin and faint at the tail, bright at the head.
    final pts = stage.trail(t);
    for (var k = 1; k < pts.length; k++) {
      final f = k / (pts.length - 1);
      canvas.drawLine(
        pts[k - 1],
        pts[k],
        Paint()
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 1 + 5 * f
          ..color = accent.withValues(alpha: 0.5 * f)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5),
      );
    }
  }

  static void _star(Canvas canvas, Offset c, double r, Paint paint) {
    final path = Path();
    for (var k = 0; k < 8; k++) {
      final rr = k.isEven ? r : r * 0.28;
      final a = k * math.pi / 4 - math.pi / 2;
      final p = c + Offset(math.cos(a) * rr, math.sin(a) * rr);
      k == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path..close(), paint);
  }

  @override
  bool shouldRepaint(_BackPainter old) =>
      old.t != t || old.stage.w != stage.w || old.accent != accent;
}

/// The six tiles: lifting out of the machine, flipping over to their glowing
/// side, and locking into the row.
class _TilesPainter extends CustomPainter {
  final double t;
  final _Stage stage;
  final String code;
  final _Glyphs glyphs;
  final Color paper;
  final Color ink;

  _TilesPainter({
    required this.t,
    required this.stage,
    required this.code,
    required this.glyphs,
    required this.paper,
    required this.ink,
  });

  static const _blueTop = Color(0xFF4D7BFF);

  @override
  void paint(Canvas canvas, Size size) {
    final sheen = onbSegment(t, _sheen.$1, _sheen.$2, Curves.easeInOut);
    final sheenX = stage.row.left - 40 + (stage.row.width + 80) * sheen;
    for (var i = 0; i < 6 && i < code.length; i++) {
      final launch = _tileLaunch + _tileStagger * i;
      final u = ((t - launch) / _tileFlight).clamp(0.0, 1.0);
      final from = stage.from[i];
      final to = stage.to[i];

      // An arc up and over into place.
      final e = Curves.easeInOutCubic.transform(u);
      final p0 = from.center, p2 = to.center;
      final p1 = Offset((p0.dx + p2.dx) / 2, math.min(p0.dy, p2.dy) - 70);
      final pos = p0 * (1 - e) * (1 - e) + p1 * 2 * e * (1 - e) + p2 * e * e;
      final grow = Curves.easeOutBack.transform(u);
      final w = from.width + (to.width - from.width) * grow;
      final h = from.height + (to.height - from.height) * grow;
      final flip = math.pi * Curves.easeInOutCubic.transform(u);
      final roll = 0.14 * math.sin(math.pi * u) * (i.isEven ? 1 : -1);
      final back = flip > math.pi / 2;

      canvas.save();
      canvas.translate(pos.dx, pos.dy);
      canvas.transform((Matrix4.identity()
            ..setEntry(3, 2, 0.0022)
            ..rotateZ(roll)
            ..rotateX(back ? flip - math.pi : flip))
          .storage);
      final rect = Rect.fromCenter(center: Offset.zero, width: w, height: h);
      if (back) {
        _glowingTile(canvas, rect, code[i], sheenX - pos.dx, sheen);
      } else {
        _paperTile(canvas, rect, code[i]);
      }
      canvas.restore();
    }
  }

  void _paperTile(Canvas canvas, Rect rect, String ch) {
    final rrect =
        RRect.fromRectAndRadius(rect, Radius.circular(rect.width * 0.18));
    canvas.drawRRect(rrect, Paint()..color = paper);
    _glyph(
        canvas, rect, ch, math.min(rect.height * 0.46, rect.width * 0.78), ink);
  }

  void _glowingTile(
      Canvas canvas, Rect rect, String ch, double sheenX, double sheen) {
    final rrect =
        RRect.fromRectAndRadius(rect, Radius.circular(rect.width * 0.2));
    canvas.drawRRect(
      rrect.shift(const Offset(0, 4)),
      Paint()
        ..color = MiniColors.blue600.withValues(alpha: 0.45)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_blueTop, MiniColors.blue600],
        ).createShader(rect),
    );
    // A thin lit edge along the top.
    canvas.drawRRect(
      rrect.deflate(0.6),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: 0.5),
            Colors.white.withValues(alpha: 0),
          ],
          stops: const [0, 0.5],
        ).createShader(rect),
    );
    _glyph(canvas, rect, ch, math.min(rect.height * 0.5, rect.width * 0.8),
        Colors.white);
    // The lock-in sheen: a slanted band of light passing over.
    if (sheen > 0 && sheen < 1) {
      canvas.save();
      canvas.clipRRect(rrect);
      final band = Rect.fromCenter(
          center: Offset(sheenX, 0), width: 30, height: rect.height * 2);
      canvas.translate(sheenX, 0);
      canvas.skew(-0.35, 0);
      canvas.translate(-sheenX, 0);
      canvas.drawRect(
        band,
        Paint()
          ..shader = LinearGradient(colors: [
            Colors.white.withValues(alpha: 0),
            Colors.white.withValues(alpha: 0.55),
            Colors.white.withValues(alpha: 0),
          ]).createShader(band),
      );
      canvas.restore();
    }
  }

  void _glyph(Canvas canvas, Rect rect, String ch, double size, Color color) {
    final tp = glyphs.get(ch, size, color);
    tp.paint(canvas, rect.center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_TilesPainter old) =>
      old.t != t ||
      old.code != code ||
      old.stage.w != stage.w ||
      old.paper != paper ||
      old.ink != ink;
}

/// Laid-out glyphs, reused frame to frame.
class _Glyphs {
  final _cache = <(String, int, int), TextPainter>{};
  bool _listening = false;

  TextPainter get(String ch, double size, Color color) {
    if (!_listening) {
      // Google Fonts arrive asynchronously; drop layouts made with the
      // fallback font once the real one is registered.
      PaintingBinding.instance.systemFonts.addListener(_clear);
      _listening = true;
    }
    // Sizes change every frame mid-flight; round so the cache stays small.
    final key = (ch, (size * 2).round(), color.toARGB32());
    return _cache.putIfAbsent(
      key,
      () => TextPainter(
        text: TextSpan(
          text: ch,
          style: GoogleFonts.jetBrainsMono(
            fontSize: key.$2 / 2,
            fontWeight: FontWeight.w600,
            height: 1,
            color: color,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(),
    );
  }

  void _clear() {
    for (final p in _cache.values) {
      p.dispose();
    }
    _cache.clear();
  }

  void dispose() {
    if (_listening) {
      PaintingBinding.instance.systemFonts.removeListener(_clear);
    }
    _clear();
  }
}
