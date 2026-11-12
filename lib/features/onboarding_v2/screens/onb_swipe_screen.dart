import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../Minigo/theme/mini_icons.dart';
import '../../../Minigo/theme/mini_theme.dart';
import '../onboarding_content.dart';
import '../widgets/onb_motion.dart';
import '../widgets/onb_widgets.dart';

// ---------------------------------------------------------------------------
// Screen 2 — "Sound familiar?" swipe deck
// ---------------------------------------------------------------------------

class OnbSwipeScreen extends StatefulWidget {
  final void Function(OnbStatement statement, bool relates) onAnswer;
  final VoidCallback onDone;

  const OnbSwipeScreen({
    super.key,
    required this.onAnswer,
    required this.onDone,
  });

  @override
  State<OnbSwipeScreen> createState() => _OnbSwipeScreenState();
}

class _OnbSwipeScreenState extends State<OnbSwipeScreen>
    with SingleTickerProviderStateMixin {
  static const _cards = onbStatements;

  int _index = 0;
  Offset _drag = Offset.zero;
  double _width = 320;
  bool _busy = false;
  bool _pastThreshold = false;

  late final AnimationController _anim = AnimationController(vsync: this)
    ..addListener(_tick);
  Offset _from = Offset.zero, _to = Offset.zero;
  Curve _curve = Curves.linear;

  double get _threshold => _width * 0.28;

  void _tick() {
    setState(
        () => _drag = Offset.lerp(_from, _to, _curve.transform(_anim.value))!);
  }

  Future<void> _animateTo(Offset target, Duration d, Curve curve) {
    _from = _drag;
    _to = target;
    _curve = curve;
    _anim.duration = d;
    return _anim.forward(from: 0);
  }

  Future<void> _decide(bool relates) async {
    if (_busy || _index >= _cards.length) return;
    _busy = true;
    onbThump();
    if (!onbReduceMotion(context)) {
      await _animateTo(
        Offset((relates ? 1 : -1) * _width * 1.6, _drag.dy + 70),
        const Duration(milliseconds: 320),
        Curves.easeInCubic,
      );
    }
    if (!mounted) return;
    widget.onAnswer(_cards[_index], relates);
    setState(() {
      _index++;
      _drag = Offset.zero;
      _pastThreshold = false;
    });
    _busy = false;
    if (_index >= _cards.length) {
      await Future<void>.delayed(const Duration(milliseconds: 650));
      if (mounted) widget.onDone();
    }
  }

  void _onPanUpdate(DragUpdateDetails d) {
    if (_busy) return;
    setState(() => _drag += d.delta);
    final past = _drag.dx.abs() > _threshold;
    if (past != _pastThreshold) {
      _pastThreshold = past;
      onbTick();
    }
  }

  void _onPanEnd(DragEndDetails d) {
    if (_busy) return;
    final vx = d.velocity.pixelsPerSecond.dx;
    if (_drag.dx.abs() > _threshold || vx.abs() > 900) {
      _decide(_drag.dx + vx * 0.1 > 0);
    } else {
      _animateTo(
          Offset.zero, const Duration(milliseconds: 650), Curves.elasticOut);
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final done = _index >= _cards.length;
    return OnbStagger(
      child: OnbPage(
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
            const OnbTitle(
              title: 'Sound familiar?',
              subtitle: 'Swipe right if that’s you, left if it’s not.',
            ),
            const SizedBox(height: 30),
            OnbReveal(
              index: 2,
              child: LayoutBuilder(builder: (context, constraints) {
                _width = constraints.maxWidth;
                return Padding(
                  // Room for the cards stacked behind the top one.
                  padding: const EdgeInsets.only(bottom: 30),
                  child: Stack(
                    fit: StackFit.passthrough,
                    clipBehavior: Clip.none,
                    children: [
                      // Hidden copies of every card give the deck the
                      // tallest one's height, so no statement is cut off at
                      // large text sizes or in a longer language.
                      for (var i = 0; i < _cards.length; i++)
                        Visibility.maintain(
                          visible: false,
                          child: _StatementCard(
                            statement: _cards[i],
                            number: i + 1,
                            total: _cards.length,
                            agree: 0,
                            disagree: 0,
                          ),
                        ),
                      Positioned.fill(
                        child: done ? const _DeckDone() : _deck(),
                      ),
                    ],
                  ),
                );
              }),
            ),
            const SizedBox(height: 20),
            OnbReveal(
              index: 3,
              child: _Dots(count: _cards.length, index: _index),
            ),
          ],
        ),
        bottom: OnbReveal(
          index: 4,
          child: AnimatedOpacity(
            opacity: done ? 0.3 : 1,
            duration: const Duration(milliseconds: 250),
            // Flexible: a label too wide for its half wraps instead of
            // overflowing (large text, longer languages).
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                Flexible(
                  child: OnbRoundButton(
                    icon: MiniIcons.close,
                    label: 'Not me',
                    onTap: done ? null : () => _decide(false),
                  ),
                ),
                Flexible(
                  child: OnbRoundButton(
                    icon: MiniIcons.check,
                    label: 'That’s me',
                    primary: true,
                    onTap: done ? null : () => _decide(true),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _deck() {
    final p = (_drag.dx.abs() / _threshold).clamp(0.0, 1.0);
    final visible = math.min(3, _cards.length - _index);
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      alignment: Alignment.topCenter,
      children: [
        for (var d = visible - 1; d >= 0; d--)
          _positioned(d, p, _cards[_index + d], _index + d),
      ],
    );
  }

  Widget _positioned(int depth, double p, OnbStatement s, int i) {
    final card = _StatementCard(
      key: ValueKey(i),
      statement: s,
      number: i + 1,
      total: _cards.length,
      agree: depth == 0 ? (_drag.dx / _threshold).clamp(0.0, 1.0) : 0,
      disagree: depth == 0 ? (-_drag.dx / _threshold).clamp(0.0, 1.0) : 0,
    );
    if (depth > 0) {
      final scale = 1 - 0.06 * depth + 0.06 * p;
      final dy = 18.0 * depth - 18 * p;
      return Transform.translate(
        offset: Offset(0, dy),
        child: Transform.scale(
          scale: scale,
          alignment: Alignment.topCenter,
          child: Opacity(opacity: depth == 2 ? 0.6 + 0.4 * p : 1, child: card),
        ),
      );
    }
    return GestureDetector(
      onPanUpdate: _onPanUpdate,
      onPanEnd: _onPanEnd,
      child: Transform.translate(
        offset: _drag,
        child: Transform.rotate(
          angle: _drag.dx / _width * 0.38,
          alignment: Alignment.bottomCenter,
          child: card,
        ),
      ),
    );
  }
}

class _StatementCard extends StatelessWidget {
  final OnbStatement statement;
  final int number;
  final int total;
  final double agree;
  final double disagree;

  const _StatementCard({
    super.key,
    required this.statement,
    required this.number,
    required this.total,
    required this.agree,
    required this.disagree,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Semantics(
      label: 'Statement $number of $total: ${statement.text}',
      excludeSemantics: true,
      child: Container(
        // A floor, not a fixed height: the deck stretches every card to the
        // tallest statement.
        constraints: const BoxConstraints(minHeight: 270),
        // Less the border's growth while dragged (a border takes layout room
        // too), so the text never moves or outgrows the deck.
        padding: const EdgeInsets.fromLTRB(24, 18, 24, 20) -
            EdgeInsets.all(math.max(agree, disagree)),
        decoration: BoxDecoration(
          color: Color.alphaBlend(
            c.accent.withValues(alpha: 0.10 * agree),
            c.paperDeep,
          ),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: Color.lerp(
              c.divider,
              agree > disagree ? c.accent : c.inkFaint,
              math.max(agree, disagree),
            )!,
            width: 1 + math.max(agree, disagree),
          ),
          boxShadow: [
            ...miniCardShadow(context, strong: true),
            BoxShadow(
              color: c.accent.withValues(alpha: 0.18 * agree),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Stack(
          // Hands the card's height to the column, which spreads out to
          // keep the counter at the bottom.
          fit: StackFit.passthrough,
          children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '“',
                      // Decoration: large text goes to the statement.
                      textScaler: MediaQuery.textScalerOf(context)
                          .clamp(maxScaleFactor: 1),
                      style: GoogleFonts.outfit(
                        fontSize: 64,
                        height: 1,
                        fontWeight: FontWeight.w600,
                        color: c.accent,
                      ),
                    ),
                    Text(
                      statement.text,
                      style: GoogleFonts.outfit(
                        fontSize: 21,
                        height: 1.3,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -0.4,
                        color: c.ink,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
                Text('$number / $total', style: MiniText.label),
              ],
            ),
            Positioned(
              top: 8,
              right: 0,
              child: _Stamp(
                text: 'THAT’S ME',
                color: c.accent,
                angle: 0.22,
                opacity: agree,
              ),
            ),
            Positioned(
              top: 8,
              right: 0,
              child: _Stamp(
                text: 'NOT ME',
                color: c.inkSoft,
                angle: -0.22,
                opacity: disagree,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Stamp extends StatelessWidget {
  final String text;
  final Color color;
  final double angle;
  final double opacity;

  const _Stamp({
    required this.text,
    required this.color,
    required this.angle,
    required this.opacity,
  });

  @override
  Widget build(BuildContext context) {
    if (opacity <= 0) return const SizedBox.shrink();
    return Opacity(
      opacity: opacity,
      child: Transform.rotate(
        angle: angle,
        child: Transform.scale(
          scale: 0.8 + 0.2 * opacity,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              border: Border.all(color: color, width: 2.4),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              text,
              style: GoogleFonts.outfit(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.2,
                color: color,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DeckDone extends StatelessWidget {
  const _DeckDone();

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Center(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 600),
        curve: Curves.elasticOut,
        builder: (context, t, child) => Transform.scale(scale: t, child: child),
        child: Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: c.accentSoft,
            border: Border.all(color: c.accent, width: 2),
          ),
          child: Icon(MiniIcons.check, size: 44, color: c.accent),
        ),
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  final int count;
  final int index;
  const _Dots({required this.count, required this.index});

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return ExcludeSemantics(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(count, (i) {
          final active = i == index;
          final done = i < index;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutBack,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: active ? 22 : 7,
            height: 7,
            decoration: BoxDecoration(
              color: active || done ? c.accent : c.sandDeep,
              borderRadius: BorderRadius.circular(MiniRadius.pill),
            ),
          );
        }),
      ),
    );
  }
}
