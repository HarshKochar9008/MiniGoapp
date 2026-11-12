import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../Minigo/theme/mini_theme.dart';
import '../../../core/constants.dart';
import 'onb_motion.dart';

/// A minimal slot machine: a blue rounded frame holding six tiles, one code
/// character per tile, with a small lever on the side.
///
/// Two ways to drive it:
///  * **Showcase** ([onPull] null) — rolls on its own to [code] shortly after
///    it appears, and again whenever [code] changes (the welcome screen).
///  * **Interactive** ([onPull] set) — the person pulls the lever (drag down
///    anywhere on the machine, or tap it). The parent then sets [rolling]
///    while it fetches the code, and sets [code] to land the reels.
///    [onLanded] fires once the last tile settles.
///
/// Uses the app's own palette (blue frame, sand tiles, ink characters), so it
/// follows light and dark mode. Honours reduce-motion: nothing rolls, the
/// code simply appears.
class OnbSlotMachine extends StatefulWidget {
  /// The code to show. Null keeps the tiles on scattered symbols.
  final String? code;
  final double width;

  /// Showcase mode: wait before the very first roll, so it starts after the
  /// screen has animated in.
  final Duration firstSpinDelay;

  /// Keep the reels rolling (while the parent waits for the code).
  final bool rolling;

  /// Makes the lever interactive; called when it is pulled all the way.
  final VoidCallback? onPull;

  /// Called when the reels have landed on [code].
  final VoidCallback? onLanded;

  /// The tiles have been lifted out (the code reveal flies them away):
  /// draws empty sockets instead.
  final bool tilesOut;

  const OnbSlotMachine({
    super.key,
    required this.code,
    required this.width,
    this.firstSpinDelay = const Duration(milliseconds: 900),
    this.rolling = false,
    this.onPull,
    this.onLanded,
    this.tilesOut = false,
  });

  /// Height the machine lays out at for a given [width].
  static double heightFor(double width) {
    final g = _Geometry(width);
    return g.knobOverhang + g.frameHeight;
  }

  /// Where the six tiles sit inside a machine of [width], relative to its
  /// top-left corner — so a reveal can lift them out from exactly there.
  static List<Rect> tileRects(double width) {
    final g = _Geometry(width);
    return [
      for (var i = 0; i < 6; i++)
        Rect.fromLTWH(
          g.padH + i * (g.tileWidth + g.gap),
          g.knobOverhang + g.padV,
          g.tileWidth,
          g.tileHeight,
        ),
    ];
  }

  /// Key on the machine's gesture surface (tests drag or tap it).
  static const leverKey = ValueKey('onb_slot_lever');

  @override
  State<OnbSlotMachine> createState() => _OnbSlotMachineState();
}

/// Sizes derived from the width (proportions follow the design frame).
class _Geometry {
  final double width;
  _Geometry(this.width);

  double get knobRadius => width * 0.03;
  double get leverWidth => knobRadius * 2.6;

  /// The lever overlaps the frame by half a knob radius so its mount tucks
  /// under the frame edge.
  double get frameWidth => width - leverWidth + knobRadius * 0.5;

  /// Rod position inside the lever's own box: just clear of the frame edge.
  double get rodX => knobRadius * 1.4;
  double get padH => frameWidth * 0.04;
  double get padV => padH * 0.6;
  double get gap => frameWidth * 0.04;
  double get tileWidth => (frameWidth - 2 * padH - 5 * gap) / 6;
  double get tileHeight => tileWidth * 1.56;
  double get frameHeight => tileHeight + 2 * padV;
  double get frameRadius => frameWidth * 0.028;
  double get tileRadius => tileWidth * 0.18;
  double get knobOverhang => knobRadius * 1.4;

  /// How far the knob travels from rest to fully pulled.
  double get leverTravel => frameHeight + knobRadius * 0.2 - knobRadius * 0.4;
}

// ---------------------------------------------------------------------------
// Reel motion — pure functions so they can be tested
// ---------------------------------------------------------------------------

/// Distance (in symbols) a reel has travelled at local time [t] ∈ [0, 1] of
/// a roll covering [travel] symbols: a small wind-up backwards (unless the
/// reel is already moving), a fast run that overshoots the target by a third
/// of a symbol, then a snap back.
@visibleForTesting
double slotReelOffset(double t, double travel, {bool windUp = true}) {
  if (travel == 0 || t <= 0) return 0;
  if (t >= 1) return travel;
  final wind = windUp ? 0.07 : 0.0;
  const land = 0.88, over = 0.32;
  if (t < wind) return -0.24 * math.sin(math.pi * t / wind);
  if (t < land) {
    return (travel + over) *
        Curves.easeOutCubic.transform((t - wind) / (land - wind));
  }
  return travel +
      over * (1 - Curves.easeInOutCubic.transform((t - land) / (1 - land)));
}

/// Symbols a reel must travel from index [from] to land on [target] after
/// [turns] full rotations of an [alphabetLength]-symbol strip.
@visibleForTesting
int slotTravel({
  required int from,
  required int target,
  required int turns,
  required int alphabetLength,
}) =>
    turns * alphabetLength + (target - from) % alphabetLength;

/// Travel from a (possibly fractional) reel [position] that lands exactly on
/// [target], picked as close as possible to [desired] symbols so a reel that
/// is already rolling keeps roughly its speed as it starts to slow down.
@visibleForTesting
double slotTravelNear({
  required double position,
  required int target,
  required double desired,
  required int alphabetLength,
}) {
  final delta = (target - position) % alphabetLength;
  final turns = math.max(0, ((desired - delta) / alphabetLength).round());
  var travel = delta + turns * alphabetLength;
  if (travel < 2) travel += alphabetLength;
  return travel;
}

enum _LeverMove { none, fire, back, nudge }

class _OnbSlotMachineState extends State<OnbSlotMachine>
    with TickerProviderStateMixin {
  static const _alphabet = AppConstants.codeAlphabet;
  static const _reels = 6;
  // The craft screen's sounds are timed to these and to the lever's motion:
  // rerun tool/make_onb_sounds.py after changing them.
  static const _spinMs = 1300;
  static const _staggerMs = 150;

  /// Symbols per second while rolling and waiting for the code.
  static const _rollSpeed = 22.0;

  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: _spinMs + _staggerMs * (_reels - 1)),
  )..addStatusListener(_onSpinStatus);

  late final AnimationController _lever = AnimationController(vsync: this)
    ..addListener(_onLeverTick);
  _LeverMove _leverMove = _LeverMove.none;
  double _leverFrom = 0;

  /// 0 = at rest (knob up), 1 = fully pulled. Painted by the lever.
  final _pull = ValueNotifier<double>(0);
  bool _dragging = false;

  late final Ticker _roller = createTicker(_onRoll);
  Duration _lastRoll = Duration.zero;
  final _rollRepaint = ValueNotifier<int>(0);

  final _reelState = _ReelState(_reels, _alphabet.length);
  final _glyphs = _GlyphCache();
  Timer? _firstSpin;
  Timer? _nudgeTimer;
  bool _configured = false;
  bool _reduce = false;
  bool _spinning = false;

  bool get _interactive => widget.onPull != null;

  @override
  void initState() {
    super.initState();
    // Start on scattered symbols so the first roll has something to roll.
    final rng = math.Random();
    for (var i = 0; i < _reels; i++) {
      _reelState.from[i] = rng.nextInt(_alphabet.length).toDouble();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = onbReduceMotion(context);
    if (_configured && reduce == _reduce) return;
    _configured = true;
    _reduce = reduce;
    _firstSpin?.cancel();
    final code = widget.code;
    if (reduce) {
      _stopRolling();
      _spin.stop();
      if (code != null) _rest(code);
    } else if (code != null && !_interactive) {
      _firstSpin = Timer(widget.firstSpinDelay, () {
        if (mounted) _spinTo(code);
      });
    } else if (code != null) {
      // Interactive and already crafted (e.g. coming back to the screen).
      _rest(code);
    } else if (widget.rolling) {
      _startRolling();
    }
    _syncNudge();
  }

  @override
  void didUpdateWidget(OnbSlotMachine old) {
    super.didUpdateWidget(old);
    if (widget.rolling && !old.rolling && widget.code == null) {
      _startRolling();
    }
    final code = widget.code;
    if (code != null && code != old.code) {
      _firstSpin?.cancel();
      if (_reduce) {
        _stopRolling();
        setState(() => _rest(code));
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onLanded?.call();
        });
      } else {
        _spinTo(code);
      }
    } else if (!widget.rolling && old.rolling && code == null) {
      _stopRolling();
    }
    _syncNudge();
  }

  @override
  void dispose() {
    _firstSpin?.cancel();
    _nudgeTimer?.cancel();
    _roller.dispose();
    _spin.dispose();
    _lever.dispose();
    _pull.dispose();
    _rollRepaint.dispose();
    _glyphs.dispose();
    super.dispose();
  }

  int _indexOf(String ch) => math.max(0, _alphabet.indexOf(ch));

  // ── reels ───────────────────────────────────────────────────────────────

  /// Shows [code] settled, no motion.
  void _rest(String code) {
    for (var i = 0; i < _reels; i++) {
      _reelState.from[i] = i < code.length ? _indexOf(code[i]).toDouble() : 0;
      _reelState.travel[i] = 0;
    }
    _reelState.rollSpeed = 0;
    _spin.value = 1;
  }

  void _startRolling() {
    if (_reduce || _roller.isActive) return;
    // Fold any finished spin into the start positions.
    for (var i = 0; i < _reels; i++) {
      _reelState.from[i] = _reelState.position(i, _spin.value);
      _reelState.travel[i] = 0;
    }
    _reelState.rollSpeed = 0;
    _lastRoll = Duration.zero;
    _roller.start();
  }

  void _stopRolling() {
    if (_roller.isActive) _roller.stop();
    _reelState.rollSpeed = 0;
  }

  void _onRoll(Duration elapsed) {
    final dt = (elapsed - _lastRoll).inMicroseconds / 1e6;
    _lastRoll = elapsed;
    // Ramp up to speed over a quarter of a second.
    _reelState.rollSpeed =
        math.min(_rollSpeed, _reelState.rollSpeed + dt * _rollSpeed * 4);
    for (var i = 0; i < _reels; i++) {
      _reelState.from[i] += _reelState.rollSpeed * dt;
    }
    _rollRepaint.value++;
  }

  void _spinTo(String code) {
    final fromRolling = _roller.isActive;
    final speed = _reelState.rollSpeed;
    _stopRolling();
    final total = _spin.duration!.inMilliseconds;
    for (var i = 0; i < _reels; i++) {
      final position = _reelState.position(i, _spin.value);
      _reelState.from[i] = position;
      final target = i < code.length ? _indexOf(code[i]) : 0;
      final seconds = (_spinMs + _staggerMs * i) / 1000;
      _reelState.travel[i] = fromRolling
          // Already moving: keep roughly the same speed into the slow-down.
          ? slotTravelNear(
              position: position,
              target: target,
              desired: speed * 0.88 * seconds / 3,
              alphabetLength: _alphabet.length,
            )
          : slotTravel(
                from: position.round(),
                target: target,
                turns: 1 + i, // later tiles roll longer and stop later
                alphabetLength: _alphabet.length,
              ).toDouble() +
              (position.round() - position);
      _reelState.ends[i] = (_spinMs + _staggerMs * i) / total;
    }
    _reelState.windUp = !fromRolling;
    _reelState.totalSeconds = total / 1000;
    if (!_interactive) _fireLever(from: 0);
    _spinning = true;
    _spin.forward(from: 0);
  }

  void _onSpinStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !_spinning) return;
    _spinning = false;
    if (mounted) widget.onLanded?.call();
  }

  // ── lever ───────────────────────────────────────────────────────────────

  void _onLeverTick() {
    final t = _lever.value;
    _pull.value = switch (_leverMove) {
      // Down to fully pulled, then spring back up.
      _LeverMove.fire => t < 0.25
          ? _leverFrom + (1 - _leverFrom) * Curves.easeIn.transform(t / 0.25)
          : 1 - Curves.elasticOut.transform((t - 0.25) / 0.75),
      // Let go too early: spring back from where it was.
      _LeverMove.back => _leverFrom * (1 - Curves.elasticOut.transform(t)),
      // A small hint that the lever can be pulled.
      _LeverMove.nudge => 0.16 * math.sin(math.pi * t),
      _LeverMove.none => _pull.value,
    };
  }

  void _fireLever({required double from}) {
    if (_reduce) {
      _pull.value = 0;
      return;
    }
    _leverMove = _LeverMove.fire;
    _leverFrom = from;
    _lever.duration = const Duration(milliseconds: 900);
    _lever.forward(from: 0);
  }

  bool get _canPull =>
      _interactive && widget.code == null && !widget.rolling && !_spinning;

  void _pullLever({double from = 0}) {
    if (!_canPull) return;
    onbThump();
    _fireLever(from: from);
    widget.onPull?.call();
  }

  void _onDragStart(DragStartDetails _) {
    if (!_canPull) return;
    _nudgeTimer?.cancel();
    _lever.stop();
    _dragging = true;
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (!_dragging) return;
    final travel = _Geometry(widget.width).leverTravel;
    final before = _pull.value;
    _pull.value = (_pull.value + d.delta.dy / travel).clamp(0.0, 1.0);
    if ((before < 0.5) != (_pull.value < 0.5)) onbTick();
  }

  void _onDragEnd(DragEndDetails d) {
    if (!_dragging) return;
    _dragging = false;
    final flung = d.velocity.pixelsPerSecond.dy > 700;
    if (_pull.value > 0.55 || (flung && _pull.value > 0.15)) {
      _pullLever(from: _pull.value);
    } else {
      _leverMove = _LeverMove.back;
      _leverFrom = _pull.value;
      _lever.duration = const Duration(milliseconds: 700);
      _lever.forward(from: 0);
      _syncNudge();
    }
  }

  /// While waiting to be pulled, nudge the lever every few seconds.
  void _syncNudge() {
    final want = _canPull && !_reduce;
    if (!want) {
      _nudgeTimer?.cancel();
      _nudgeTimer = null;
      return;
    }
    _nudgeTimer ??= Timer.periodic(const Duration(milliseconds: 2600), (_) {
      if (!mounted || _dragging || _lever.isAnimating || !_canPull) return;
      _leverMove = _LeverMove.nudge;
      _lever.duration = const Duration(milliseconds: 650);
      _lever.forward(from: 0);
    });
  }

  // ── build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final g = _Geometry(widget.width);
    final c = context.mini;
    final machine = RepaintBoundary(
      child: SizedBox(
        width: widget.width,
        height: OnbSlotMachine.heightFor(widget.width),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // Lever behind the frame's right edge, so its mount tucks in.
            Positioned(
              right: 0,
              top: 0,
              width: g.leverWidth,
              height: g.knobOverhang + g.frameHeight,
              child: CustomPaint(
                painter: _LeverPainter(
                  pull: _pull,
                  geometry: g,
                  dark: context.isDarkMini,
                ),
              ),
            ),
            Positioned(
              left: 0,
              top: g.knobOverhang,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 600),
                curve: Curves.easeOutCubic,
                width: g.frameWidth,
                height: g.frameHeight,
                padding: EdgeInsets.symmetric(
                  horizontal: g.padH,
                  vertical: g.padV,
                ),
                decoration: BoxDecoration(
                  color: MiniColors.blue600,
                  borderRadius: BorderRadius.circular(g.frameRadius),
                  boxShadow: miniCardShadow(context, strong: true),
                ),
                child: CustomPaint(
                  size: Size(g.frameWidth - 2 * g.padH, g.tileHeight),
                  painter: _TilesPainter(
                    spin: _spin,
                    roll: _rollRepaint,
                    state: _reelState,
                    glyphs: _glyphs,
                    geometry: g,
                    tile: c.sand,
                    ink: c.ink,
                    empty: widget.tilesOut,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    if (!_interactive) return ExcludeSemantics(child: machine);
    return Semantics(
      button: true,
      enabled: _canPull,
      label: 'Pull the lever to craft your code',
      onTap: _canPull ? _pullLever : null,
      excludeSemantics: true,
      child: GestureDetector(
        key: OnbSlotMachine.leverKey,
        behavior: HitTestBehavior.opaque,
        onTap: _pullLever,
        onVerticalDragStart: _onDragStart,
        onVerticalDragUpdate: _onDragUpdate,
        onVerticalDragEnd: _onDragEnd,
        child: machine,
      ),
    );
  }
}

/// Where each reel starts, how far it travels this roll, and when it stops.
class _ReelState {
  final int alphabetLength;
  final List<double> from;
  final List<double> travel;
  final List<double> ends;
  double totalSeconds = 1;
  bool windUp = true;

  /// Symbols per second while free-rolling (0 when not).
  double rollSpeed = 0;

  _ReelState(int reels, this.alphabetLength)
      : from = List.filled(reels, 0),
        travel = List.filled(reels, 0),
        ends = List.filled(reels, 1);

  double _local(int i, double v) => (v / ends[i]).clamp(0.0, 1.0);

  double position(int i, double v) =>
      from[i] + slotReelOffset(_local(i, v), travel[i], windUp: windUp);

  /// 0..1 — how fast the reel is moving, for a light motion blur.
  double speed(int i, double v) {
    if (rollSpeed > 0) return (rollSpeed / 30).clamp(0.0, 1.0);
    const dv = 0.004;
    final a = slotReelOffset(_local(i, v), travel[i], windUp: windUp);
    final b = slotReelOffset(_local(i, (v + dv).clamp(0.0, 1.0)), travel[i],
        windUp: windUp);
    final symbolsPerSecond = (b - a).abs() / (dv * totalSeconds);
    return (symbolsPerSecond / 30).clamp(0.0, 1.0);
  }
}

// ---------------------------------------------------------------------------
// Glyph cache — one laid-out TextPainter per character and colour
// ---------------------------------------------------------------------------

class _GlyphCache {
  final Map<String, TextPainter> _cache = {};
  double _size = 0;
  Color? _ink;
  bool _listening = false;

  TextPainter get(String ch, {required double size, required Color ink}) {
    if (!_listening) {
      // Google Fonts arrive asynchronously; drop layouts made with the
      // fallback font once the real one is registered.
      PaintingBinding.instance.systemFonts.addListener(_clear);
      _listening = true;
    }
    if (size != _size || ink != _ink) {
      _clear();
      _size = size;
      _ink = ink;
    }
    return _cache.putIfAbsent(
      ch,
      () => TextPainter(
        text: TextSpan(
          text: ch,
          style: GoogleFonts.jetBrainsMono(
            fontSize: size,
            fontWeight: FontWeight.w600,
            height: 1,
            color: ink,
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

// ---------------------------------------------------------------------------
// Painters
// ---------------------------------------------------------------------------

class _TilesPainter extends CustomPainter {
  final Animation<double> spin;
  final _ReelState state;
  final _GlyphCache glyphs;
  final _Geometry geometry;
  final Color tile;
  final Color ink;
  final bool empty;

  _TilesPainter({
    required this.spin,
    required Listenable roll,
    required this.state,
    required this.glyphs,
    required this.geometry,
    required this.tile,
    required this.ink,
    required this.empty,
  }) : super(repaint: Listenable.merge([spin, roll]));

  /// An empty socket: the frame's blue, pressed in.
  static final _socket = Color.lerp(MiniColors.blue600, Colors.black, 0.3)!;

  static const _alphabet = AppConstants.codeAlphabet;

  @override
  void paint(Canvas canvas, Size size) {
    final g = geometry;
    final h = g.tileHeight;
    final glyphSize = math.min(h * 0.46, g.tileWidth * 0.78);
    final tilePaint = Paint()..color = empty ? _socket : tile;

    for (var i = 0; i < 6; i++) {
      final rect = Rect.fromLTWH(i * (g.tileWidth + g.gap), 0, g.tileWidth, h);
      final rrect =
          RRect.fromRectAndRadius(rect, Radius.circular(g.tileRadius));
      canvas.drawRRect(rrect, tilePaint);
      if (empty) continue;

      canvas.save();
      canvas.clipRRect(rrect);
      final pos = state.position(i, spin.value);
      final speed = state.speed(i, spin.value);
      final idx = pos.floor();
      final frac = pos - idx;
      // The symbol leaving upwards and the one arriving from below.
      for (final k in const [0, 1]) {
        final glyph = glyphs.get(
          _alphabet[(idx + k) % _alphabet.length],
          size: glyphSize,
          ink: ink,
        );
        canvas.save();
        canvas.translate(rect.center.dx, rect.center.dy + (k - frac) * h);
        canvas.scale(1, 1 + speed * 0.35); // a hint of motion blur
        glyph.paint(canvas, Offset(-glyph.width / 2, -glyph.height / 2));
        canvas.restore();
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_TilesPainter old) =>
      old.empty != empty ||
      old.tile != tile ||
      old.ink != ink ||
      old.geometry.width != geometry.width;
}

/// The small side lever: dark mount on the frame edge, silver rod, glossy
/// blue knob. Follows [pull]: 0 = knob up, 1 = pulled all the way down.
class _LeverPainter extends CustomPainter {
  final ValueListenable<double> pull;
  final _Geometry geometry;
  final bool dark;

  _LeverPainter({
    required this.pull,
    required this.geometry,
    required this.dark,
  }) : super(repaint: pull);

  @override
  void paint(Canvas canvas, Size size) {
    final g = geometry;
    final r = g.knobRadius;
    final rodX = g.rodX;
    final frameTop = g.knobOverhang;
    final mountY = frameTop + g.frameHeight * 0.52;
    final restKnobY = r;
    final knobY = restKnobY + g.leverTravel * pull.value.clamp(-0.12, 1.0);

    // Mount: a dark metal block on the frame's right edge.
    final mount = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, mountY - r * 1.5, rodX + r * 0.55, r * 2.6),
      Radius.circular(r * 0.4),
    );
    canvas.drawRRect(
      mount,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF6B7180), Color(0xFF2A2E37), Color(0xFF14161B)],
        ).createShader(mount.outerRect),
    );

    // Rod.
    canvas.drawLine(
      Offset(rodX, mountY),
      Offset(rodX, knobY),
      Paint()
        ..strokeWidth = r * 0.55
        ..strokeCap = StrokeCap.round
        ..shader = LinearGradient(colors: [
          const Color(0xFFF2F3F7),
          dark ? const Color(0xFF7C8394) : const Color(0xFF9AA0AE),
          const Color(0xFFDDE0E8),
        ]).createShader(Rect.fromLTWH(rodX - r * 0.3, 0, r * 0.6, size.height)),
    );

    // Knob: glossy blue ball.
    final c = Offset(rodX, knobY);
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.35, -0.45),
          colors: [Color(0xFFBFD0FF), MiniColors.blue500, MiniColors.blue600],
          stops: [0, 0.45, 1],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );
    canvas.drawCircle(
      c.translate(-r * 0.32, -r * 0.36),
      r * 0.22,
      Paint()..color = Colors.white.withValues(alpha: 0.85),
    );
  }

  @override
  bool shouldRepaint(_LeverPainter old) =>
      old.dark != dark || old.geometry.width != geometry.width;
}
