import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../Minigo/theme/mini_icons.dart';
import '../../../Minigo/theme/mini_theme.dart';
import '../../../Minigo/widgets/mini_ufo.dart';
import '../../../Minigo/widgets/mini_widgets.dart';
import '../../../core/constants.dart';
import '../onboarding_content.dart';
import '../widgets/onb_motion.dart';
import '../widgets/onb_share_card.dart';
import 'onb_setup_screens.dart' show OnbCopyButton;

typedef OnbShareCallback = Future<bool> Function(
  Uint8List? png,
  String text,
  String fileStem,
  Rect? origin,
);

// ---------------------------------------------------------------------------
// Screen 7 — "Your card is ready": the card drops out of the saucer
// ---------------------------------------------------------------------------

/// The card's widest on screen; it shrinks to fit what the text and buttons
/// leave.
const _maxCardW = 260.0;

/// The saucer's width as a share of the card's, and the height it takes
/// above the card as a share of its own width.
const _ufoScale = 0.36;
const _ufoSlot = 0.56;
const _ufoGap = 6.0;

/// Narrower than this beside the saucer, the saucer makes way for the card.
const _minCardWithUfo = 200.0;

/// The card shrinks to this before the page scrolls instead.
const _minCardW = 120.0;

class OnbShareScreen extends StatefulWidget {
  final OnbCardTone tone;
  final String line;
  final String code;
  final String? nickname;
  final OnbShareCallback share;
  final VoidCallback onCopy;
  final VoidCallback onContinue;

  const OnbShareScreen({
    super.key,
    required this.tone,
    required this.line,
    required this.code,
    required this.nickname,
    required this.share,
    required this.onCopy,
    required this.onContinue,
  });

  @override
  State<OnbShareScreen> createState() => _OnbShareScreenState();
}

class _OnbShareScreenState extends State<OnbShareScreen>
    with SingleTickerProviderStateMixin {
  final _cardKey = GlobalKey();
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );
  int _burst = 0;
  bool _sharing = false;
  bool _copied = false;
  Timer? _copiedReset;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(() {
      if (_burst == 0 && _ctrl.value >= 0.55) {
        setState(() => _burst = 1);
        onbThump();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (onbReduceMotion(context)) {
      _ctrl.value = 1;
    } else {
      _ctrl.forward();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _copiedReset?.cancel();
    super.dispose();
  }

  Future<void> _share(BuildContext buttonContext) async {
    if (_sharing) return;
    final box = buttonContext.findRenderObject() as RenderBox?;
    final origin =
        box == null ? null : box.localToGlobal(Offset.zero) & box.size;
    setState(() => _sharing = true);
    try {
      final png = await OnbShareCard.capture(_cardKey);
      await widget.share(png, onbPersonalShareText(widget.code),
          'minigo-card-${widget.code}', origin);
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  void _copy() {
    widget.onCopy();
    setState(() => _copied = true);
    _copiedReset?.cancel();
    _copiedReset = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  Widget _card(double width) {
    return OnbShareCard(
      tone: widget.tone,
      headline: widget.line,
      name: widget.nickname,
      code: widget.code,
      qrData: AppConstants.qrPayloadForCode(widget.code),
      footnote: 'or enter my code in MiniGo',
      width: width,
    );
  }

  /// The saucer over the card, as big as [box] allows.
  Widget _hero(BoxConstraints box, double t) {
    final descend = onbSegment(t, 0.12, 0.55, Curves.easeOutBack);
    final materialize = onbSegment(t, 0.12, 0.4);
    final maxW = math.min(_maxCardW, box.maxWidth - 48);
    final besideUfo = (box.maxHeight - _ufoGap) /
        (OnbShareCard.aspect + _ufoScale * _ufoSlot);
    final ufo = besideUfo >= _minCardWithUfo;
    final cardW =
        math.min(maxW, ufo ? besideUfo : box.maxHeight / OnbShareCard.aspect);
    final cardH = cardW * OnbShareCard.aspect;
    final ufoW = cardW * _ufoScale;
    final slot = ufoW * _ufoSlot;
    final top = ufo ? slot + _ufoGap : 0.0;
    // The card slides out from under the saucer, or drops in from above.
    final rise = ufo ? top - slot / 2 : cardH * 0.3;
    return Align(
      alignment: const Alignment(0, 0.5),
      child: SizedBox(
        width: cardW,
        height: top + cardH,
        child: Stack(
          alignment: Alignment.topCenter,
          clipBehavior: Clip.none,
          children: [
            Positioned(
              top: top,
              child: OnbBurst(
                trigger: _burst,
                spread: cardW * 0.9,
                count: 40,
                child: Opacity(
                  opacity: materialize,
                  child: Transform.translate(
                    offset: Offset(0, -rise * (1 - descend)),
                    child: Transform.scale(
                      scale: 0.25 + 0.75 * descend,
                      alignment: Alignment.topCenter,
                      child: OnbSheen(
                        enabled: t >= 1,
                        borderRadius: BorderRadius.circular(24 * cardW / 320),
                        child: RepaintBoundary(
                          key: _cardKey,
                          child: _card(cardW),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (ufo)
              SizedBox(
                height: slot,
                child: MiniUfo(size: ufoW, arrive: false, groundGlow: false),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return OnbPage(
      fillBody: true,
      body: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          final t = _ctrl.value;
          final text = onbSegment(t, 0.6, 0.95);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  children: [
                    // All the page measures of the hero (see
                    // OnbPage.fillBody): it shrinks to this, then scrolls.
                    const SizedBox(height: _minCardW * OnbShareCard.aspect),
                    Positioned.fill(
                      child: LayoutBuilder(
                        builder: (context, box) => _hero(box, t),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Opacity(
                opacity: text,
                child: Transform.translate(
                  offset: Offset(0, 14 * (1 - text)),
                  child: Column(
                    children: [
                      Text(
                        'Your card is ready',
                        style: MiniText.title.copyWith(fontSize: 26),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Send it to whoever’s sending you files. They’ll '
                        'need MiniGo too — the card shows them how.',
                        style: MiniText.bodySoft,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
          );
        },
      ),
      bottom: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, child) => OnbCtaArea(
          visible: _ctrl.value > 0.7,
          children: [child!],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Builder(
              builder: (buttonContext) => MiniButton(
                label: 'Share my card',
                loading: _sharing,
                leading: Icon(
                  MiniIcons.share,
                  size: 18,
                  color: context.isDarkMini ? context.mini.paper : Colors.white,
                ),
                onPressed: () => _share(buttonContext),
              ),
            ),
            const SizedBox(height: 8),
            OnbCopyButton(copied: _copied, onTap: _copy),
            const SizedBox(height: 4),
            MiniButton(
              label: 'Continue',
              style: MiniBtnStyle.ghost,
              onPressed: widget.onContinue,
            ),
            Text(
              'You can share your code any time from Home.',
              style: MiniText.small,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
