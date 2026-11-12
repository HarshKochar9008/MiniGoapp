import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../Minigo/theme/mini_theme.dart';
import '../../../Minigo/widgets/mini_widgets.dart';
import '../../../core/constants.dart';
import '../onboarding_content.dart';
import '../widgets/onb_motion.dart';
import '../widgets/onb_share_card.dart';
import '../widgets/onb_widgets.dart';
import 'onb_setup_screens.dart' show OnbTiltSway;

// ---------------------------------------------------------------------------
// Screen 6 — Share-card demo
// ---------------------------------------------------------------------------

class OnbCardScreen extends StatelessWidget {
  final String code;
  final String? nickname;
  final int toneIndex;
  final int lineIndex;
  final ValueChanged<int> onTone;
  final ValueChanged<int> onLine;
  final VoidCallback onUseCard;

  const OnbCardScreen({
    super.key,
    required this.code,
    required this.nickname,
    required this.toneIndex,
    required this.lineIndex,
    required this.onTone,
    required this.onLine,
    required this.onUseCard,
  });

  @override
  Widget build(BuildContext context) {
    return OnbStagger(
      child: OnbPage(
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 4),
            const OnbTitle(
              title: 'Make your share card',
            ),
            const SizedBox(height: 20),
            _CardDesigner(
              code: code,
              nickname: nickname,
              toneIndex: toneIndex,
              lineIndex: lineIndex,
              onTone: onTone,
              onLine: onLine,
            ),
          ],
        ),
        bottom: OnbReveal(
          index: 6,
          child: OnbSheen(
            borderRadius: BorderRadius.circular(MiniRadius.pill),
            child: MiniButton(label: 'Use this card', onPressed: onUseCard),
          ),
        ),
      ),
    );
  }
}

/// The tiltable card preview with its colour and line pickers.
class _CardDesigner extends StatefulWidget {
  final String code;
  final String? nickname;
  final int toneIndex;
  final int lineIndex;
  final ValueChanged<int> onTone;
  final ValueChanged<int> onLine;

  const _CardDesigner({
    required this.code,
    required this.nickname,
    required this.toneIndex,
    required this.lineIndex,
    required this.onTone,
    required this.onLine,
  });

  @override
  State<_CardDesigner> createState() => _CardDesignerState();
}

class _CardDesignerState extends State<_CardDesigner> {
  Offset _tilt = Offset.zero;
  bool _dragging = false;

  double _cardWidth(BoxConstraints constraints) {
    final h = MediaQuery.sizeOf(context).height;
    return math.min(
      math.min(270.0, constraints.maxWidth * 0.82),
      h * 0.36 / OnbShareCard.aspect,
    );
  }

  Widget _tiltable(Widget card) {
    return GestureDetector(
      onPanStart: (_) => setState(() => _dragging = true),
      onPanUpdate: (d) => setState(() {
        _tilt = Offset(
          (_tilt.dx + d.delta.dx / 160).clamp(-0.45, 0.45),
          (_tilt.dy - d.delta.dy / 160).clamp(-0.35, 0.35),
        );
      }),
      onPanEnd: (_) => setState(() {
        _dragging = false;
        _tilt = Offset.zero;
      }),
      child: TweenAnimationBuilder<Offset>(
        tween: Tween(end: _tilt),
        duration: Duration(milliseconds: _dragging ? 60 : 900),
        curve: _dragging ? Curves.linear : Curves.elasticOut,
        builder: (context, tilt, child) =>
            OnbTiltSway(extraTilt: tilt, child: child!),
        child: card,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OnbReveal(
          index: 3,
          child: Center(
            child: LayoutBuilder(builder: (context, constraints) {
              final w = _cardWidth(constraints);
              return _tiltable(
                OnbSheen(
                  borderRadius: BorderRadius.circular(24 * w / 320),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 520),
                    transitionBuilder: (child, anim) {
                      // A quick flip around the horizontal axis.
                      final flip = Tween(begin: math.pi / 2, end: 0.0).animate(
                          CurvedAnimation(
                              parent: anim, curve: Curves.easeOutBack));
                      return AnimatedBuilder(
                        animation: flip,
                        child: child,
                        builder: (context, child) => Transform(
                          alignment: Alignment.center,
                          transform: Matrix4.identity()
                            ..setEntry(3, 2, 0.0015)
                            ..rotateX(flip.value),
                          child: child,
                        ),
                      );
                    },
                    layoutBuilder: (current, previous) => Stack(
                      alignment: Alignment.center,
                      children: [if (current != null) current],
                    ),
                    child: TweenAnimationBuilder<OnbCardTone>(
                      key: ValueKey(widget.lineIndex),
                      tween: OnbToneTween(
                        end: onbCardTones[widget.toneIndex],
                      ),
                      duration: const Duration(milliseconds: 520),
                      curve: Curves.easeOutCubic,
                      builder: (context, tone, _) => OnbShareCard(
                        tone: tone,
                        headline: onbCardLines[widget.lineIndex],
                        name: widget.nickname,
                        code: widget.code,
                        qrData: AppConstants.qrPayloadForCode(widget.code),
                        footnote: 'or enter my code in MiniGo',
                        width: w,
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
        const SizedBox(height: 22),
        OnbReveal(
          index: 4,
          child: _StylePanel(
            toneIndex: widget.toneIndex,
            lineIndex: widget.lineIndex,
            onTone: (i) {
              onbTick();
              widget.onTone(i);
            },
            onLine: (i) {
              onbTick();
              widget.onLine(i);
            },
          ),
        ),
        const SizedBox(height: 4),
      ],
    );
  }
}

/// The card's two choices in one panel: colour (as tiny cards) and line
/// (a swipeable selector, like a camera's mode switcher).
class _StylePanel extends StatelessWidget {
  final int toneIndex;
  final int lineIndex;
  final ValueChanged<int> onTone;
  final ValueChanged<int> onLine;

  const _StylePanel({
    required this.toneIndex,
    required this.lineIndex,
    required this.onTone,
    required this.onLine,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
      decoration: miniCard(context, strong: true),
      child: Column(
        children: [
          Row(
            children: [
              for (var i = 0; i < onbCardTones.length; i++)
                Expanded(
                  child: _ToneSwatch(
                    tone: onbCardTones[i],
                    selected: i == toneIndex,
                    onTap: () => onTone(i),
                  ),
                ),
            ],
          ),
          Divider(height: 18, thickness: 1, color: c.dividerSoft),
          _LineSelector(
            lines: onbCardLines,
            index: lineIndex,
            onChanged: onLine,
          ),
        ],
      ),
    );
  }
}

/// A colourway as a tiny share card: its gradient, two lines of "text" and
/// a QR mark. The chosen one lifts, gets a ring and shows its name.
class _ToneSwatch extends StatelessWidget {
  final OnbCardTone tone;
  final bool selected;
  final VoidCallback onTap;

  const _ToneSwatch({
    required this.tone,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    const curve = Curves.easeOutBack;
    const duration = Duration(milliseconds: 380);
    return OnbPressable(
      onTap: onTap,
      pressedScale: 0.9,
      selected: selected,
      semanticLabel: '${tone.name} card colour',
      child: SizedBox(
        width: double.infinity,
        child: Column(
          children: [
            AnimatedSlide(
              offset: Offset(0, selected ? -0.05 : 0.02),
              duration: duration,
              curve: curve,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                width: 46,
                height: 58,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(13),
                  border: Border.all(
                    color: selected ? c.accent : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  padding: const EdgeInsets.fromLTRB(5, 6, 5, 5),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(9),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: tone.background,
                    ),
                    border: Border.all(color: c.divider, width: 0.8),
                    boxShadow: selected
                        ? [
                            BoxShadow(
                              color: c.accent.withValues(alpha: 0.3),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ]
                        : const [],
                  ),
                  child: _MiniCardMarks(tone: tone),
                ),
              ),
            ),
            const SizedBox(height: 3),
            AnimatedOpacity(
              opacity: selected ? 1 : 0,
              duration: const Duration(milliseconds: 220),
              child: SizedBox(
                height: 15,
                child: OverflowBox(
                  maxWidth: 90,
                  child: Text(
                    tone.name,
                    maxLines: 1,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.outfit(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: c.ink,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniCardMarks extends StatelessWidget {
  final OnbCardTone tone;
  const _MiniCardMarks({required this.tone});

  @override
  Widget build(BuildContext context) {
    Widget bar(double widthFactor, double height, Color color) =>
        FractionallySizedBox(
          widthFactor: widthFactor,
          child: Container(
            height: height,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(height),
            ),
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        bar(0.8, 3, tone.ink.withValues(alpha: 0.9)),
        const SizedBox(height: 3),
        bar(0.5, 2.4, tone.inkSoft.withValues(alpha: 0.6)),
        const Spacer(),
        Row(
          children: [
            Container(
              width: 11,
              height: 11,
              decoration: BoxDecoration(
                color: tone.ink.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(2.5),
              ),
            ),
            const Spacer(),
            Container(
              width: 4,
              height: 4,
              decoration:
                  BoxDecoration(color: tone.accent, shape: BoxShape.circle),
            ),
          ],
        ),
      ],
    );
  }
}

/// The card's line, picked by swiping (or tapping a neighbour). The chosen
/// one sits in the middle in the accent colour, with a dot under it.
class _LineSelector extends StatefulWidget {
  final List<String> lines;
  final int index;
  final ValueChanged<int> onChanged;

  const _LineSelector({
    required this.lines,
    required this.index,
    required this.onChanged,
  });

  @override
  State<_LineSelector> createState() => _LineSelectorState();
}

class _LineSelectorState extends State<_LineSelector> {
  late final PageController _pages = PageController(
    initialPage: widget.index,
    viewportFraction: 0.46,
  );

  @override
  void didUpdateWidget(_LineSelector old) {
    super.didUpdateWidget(old);
    if (widget.index != old.index &&
        _pages.hasClients &&
        _pages.page?.round() != widget.index) {
      _pages.animateToPage(widget.index,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic);
    }
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  double get _page => _pages.hasClients && _pages.position.haveDimensions
      ? _pages.page ?? widget.index.toDouble()
      : widget.index.toDouble();

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Column(
      children: [
        SizedBox(
          height: 36,
          child: ShaderMask(
            // Fade the neighbours out towards the panel's edges.
            shaderCallback: (rect) => const LinearGradient(
              colors: [
                Color(0x00000000),
                Color(0xFF000000),
                Color(0xFF000000),
                Color(0x00000000),
              ],
              stops: [0, 0.2, 0.8, 1],
            ).createShader(rect),
            blendMode: BlendMode.dstIn,
            child: PageView.builder(
              controller: _pages,
              itemCount: widget.lines.length,
              onPageChanged: widget.onChanged,
              itemBuilder: (context, i) => AnimatedBuilder(
                animation: _pages,
                builder: (context, _) {
                  final d = (_page - i).abs().clamp(0.0, 1.0);
                  return Semantics(
                    button: true,
                    selected: i == widget.index,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _pages.animateToPage(i,
                          duration: const Duration(milliseconds: 320),
                          curve: Curves.easeOutCubic),
                      child: Center(
                        child: Transform.scale(
                          scale: 1 - 0.1 * d,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              widget.lines[i],
                              maxLines: 1,
                              style: GoogleFonts.outfit(
                                fontSize: 15.5,
                                fontWeight: FontWeight.w600,
                                letterSpacing: -0.2,
                                color: Color.lerp(c.accent, c.inkFaint, d),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
        Container(
          width: 5,
          height: 5,
          decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle),
        ),
      ],
    );
  }
}
