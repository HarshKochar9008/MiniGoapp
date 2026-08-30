import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/constants.dart';

/// Slot-machine reveal for a short code. Each character is its own reel: it
/// spins through the code alphabet and decelerates onto its final glyph, the
/// reels landing left to right so the code reads as it settles.
///
/// Only two glyphs per reel are built on any frame — the one leaving and the
/// one arriving — so a six-character code costs twelve `Text` widgets rather
/// than a full alphabet strip per column.
///
/// Honours the platform "reduce motion" setting: the code is shown settled and
/// nothing spins.
class MiniCodeReel extends StatefulWidget {
  /// The code to land on, e.g. `A4X9K2`.
  final String code;
  final TextStyle style;

  /// Glyph pool the reels spin through. Only the characters a code can
  /// actually contain, so the blur never shows an impossible letter.
  final String alphabet;

  /// Rendered every [groupSize] characters — mirrors `fmtCode`.
  final String separator;
  final int groupSize;

  /// Dead time before the first reel moves. The reveal is worth nothing while
  /// the screen is still animating in on a cold open, so the reels sit still
  /// until the card has settled.
  final Duration delay;

  /// How long the first reel spins. Each later reel runs [stagger] longer, so
  /// the last lands `stagger * (length - 1)` after the first.
  final Duration spin;
  final Duration stagger;

  /// Full alphabet passes a reel makes before settling. Higher reads faster
  /// and blurrier for the same [spin].
  final int cycles;

  /// A soft click as each reel lands.
  final bool haptics;

  const MiniCodeReel({
    super.key,
    required this.code,
    required this.style,
    this.alphabet = AppConstants.codeAlphabet,
    this.separator = ' · ',
    this.groupSize = 3,
    this.delay = const Duration(milliseconds: 550),
    this.spin = const Duration(milliseconds: 900),
    this.stagger = const Duration(milliseconds: 130),
    this.cycles = 3,
    this.haptics = true,
  });

  @override
  State<MiniCodeReel> createState() => _MiniCodeReelState();
}

class _MiniCodeReelState extends State<MiniCodeReel>
    with SingleTickerProviderStateMixin {
  /// Fast out of the gate, then a long hard brake — a reel with friction on it.
  static const _brake = Cubic(0.12, 0.72, 0.06, 1);

  late final AnimationController _ctrl;

  /// One eased slice of the shared clock per reel. A reel that lands early
  /// simply finishes early and holds its glyph.
  List<Animation<double>> _reels = const [];

  /// Where on the controller each reel comes to rest, for the landing clicks.
  List<double> _ends = const [];
  List<bool> _landed = const [];

  bool _reduceMotion = false;
  bool _started = false;

  /// Cached glyph metrics — the reels only line up if every cell is the same
  /// size, and measuring the pool is too costly to redo every frame.
  Size? _cell;
  Object? _cellKey;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this)..addListener(_clickOnLanding);
    _configure();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // MediaQuery is only safe from here down, and the flag can change while
    // the widget is alive, so re-evaluate each time.
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (!_started || reduce != _reduceMotion) {
      _reduceMotion = reduce;
      _started = true;
      _roll();
    }
  }

  @override
  void didUpdateWidget(MiniCodeReel old) {
    super.didUpdateWidget(old);
    final relaid = old.delay != widget.delay ||
        old.spin != widget.spin ||
        old.stagger != widget.stagger ||
        old.cycles != widget.cycles ||
        old.alphabet != widget.alphabet ||
        old.code.length != widget.code.length;
    if (relaid) {
      _configure();
      _roll();
    } else if (old.code != widget.code) {
      _roll();
    }
    if (old.style != widget.style || old.alphabet != widget.alphabet) {
      _cellKey = null;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// Lay the reels out along one controller so they share a clock.
  void _configure() {
    final n = widget.code.length;
    final delayMs = widget.delay.inMilliseconds.clamp(0, 60000);
    final spinMs = widget.spin.inMilliseconds;
    final staggerMs = widget.stagger.inMilliseconds;
    final totalMs = delayMs + spinMs + staggerMs * (n > 1 ? n - 1 : 0);

    _ctrl.duration = Duration(milliseconds: totalMs);

    if (n == 0 || totalMs <= 0) {
      _ends = List<double>.filled(n, 1);
      _reels = List<Animation<double>>.filled(n, kAlwaysCompleteAnimation);
      _landed = List<bool>.filled(n, true);
      return;
    }

    // The delay is the head of the same clock, so nothing needs a timer of
    // its own to fire — and cancelling a roll cancels the wait with it.
    final begin = (delayMs / totalMs).clamp(0.0, 0.998);
    _ends = [
      for (var i = 0; i < n; i++)
        // An Interval divides by (end - begin), so every reel must own a
        // non-zero slice even when `spin` rounds to nothing.
        ((delayMs + spinMs + staggerMs * i) / totalMs)
            .clamp(begin + 0.001, 1.0),
    ];
    _reels = [
      for (final end in _ends)
        CurvedAnimation(
          parent: _ctrl,
          curve: Interval(begin, end, curve: _brake),
        ),
    ];
    _landed = List<bool>.filled(n, false);
  }

  void _roll() {
    _landed = List<bool>.filled(widget.code.length, false);
    if (_reduceMotion || (_ctrl.duration ?? Duration.zero) <= Duration.zero) {
      _ctrl
        ..stop()
        ..value = 1;
      return;
    }
    _ctrl.forward(from: 0);
  }

  void _clickOnLanding() {
    if (!widget.haptics || _reduceMotion) return;
    for (var i = 0; i < _ends.length && i < _landed.length; i++) {
      if (!_landed[i] && _ctrl.value >= _ends[i]) {
        _landed[i] = true;
        HapticFeedback.selectionClick();
      }
    }
  }

  /// Widest glyph in the pool, and the tallest line — every cell uses it.
  Size _measure(TextScaler scaler) {
    final key = Object.hash(widget.style, widget.alphabet, scaler);
    final cached = _cell;
    if (cached != null && _cellKey == key) return cached;

    var width = 0.0;
    var height = 0.0;
    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    );
    for (final glyph in widget.alphabet.characters) {
      painter.text = TextSpan(text: glyph, style: widget.style);
      painter.layout();
      if (painter.width > width) width = painter.width;
      if (painter.height > height) height = painter.height;
    }
    painter.dispose();

    final cell = Size(width, height);
    _cell = cell;
    _cellKey = key;
    return cell;
  }

  @override
  Widget build(BuildContext context) {
    final cell = _measure(MediaQuery.textScalerOf(context));
    final chars = widget.code.characters.toList();
    final pool = widget.alphabet.characters.toList();

    final children = <Widget>[];
    for (var i = 0; i < chars.length; i++) {
      if (i > 0 && widget.groupSize > 0 && i % widget.groupSize == 0) {
        children.add(Text(widget.separator, style: widget.style));
      }
      children.add(_Reel(
        target: chars[i],
        pool: pool,
        style: widget.style,
        cell: cell,
        cycles: widget.cycles,
        progress: i < _reels.length ? _reels[i] : kAlwaysCompleteAnimation,
      ));
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: children,
    );
  }
}

/// One column. Spins the pool upward and stops with [target] in the window.
class _Reel extends StatelessWidget {
  final String target;
  final List<String> pool;
  final TextStyle style;
  final Size cell;
  final int cycles;
  final Animation<double> progress;

  const _Reel({
    required this.target,
    required this.pool,
    required this.style,
    required this.cell,
    required this.cycles,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    final landing = pool.indexOf(target);

    // A character outside the pool has no reel position to land on, so show it
    // plainly rather than spinning to the wrong glyph.
    if (landing < 0 || pool.isEmpty) {
      return SizedBox.fromSize(
        size: cell,
        child: Center(child: Text(target, style: style)),
      );
    }

    // Travel in glyphs, picked so the reel stops exactly on `landing`:
    // travel % pool.length == landing.
    final travel = cycles * pool.length + landing;

    return SizedBox.fromSize(
      size: cell,
      child: ClipRect(
        child: AnimatedBuilder(
          animation: progress,
          builder: (context, _) {
            final at = progress.value * travel;
            final index = at.floor();
            final slip = at - index;

            Widget glyph(int i, double dy) => Positioned(
                  left: 0,
                  right: 0,
                  top: dy,
                  height: cell.height,
                  child: Center(
                    child: Text(
                      pool[i % pool.length],
                      style: style,
                      maxLines: 1,
                      softWrap: false,
                    ),
                  ),
                );

            return Stack(
              children: [
                // The glyph leaving upward, and the next following it in.
                glyph(index, -slip * cell.height),
                glyph(index + 1, (1 - slip) * cell.height),
              ],
            );
          },
        ),
      ),
    );
  }
}
