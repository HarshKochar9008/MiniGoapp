import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../Minigo/theme/mini_icons.dart';
import '../../../Minigo/theme/mini_theme.dart';
import '../../../Minigo/widgets/mini_widgets.dart';
import '../../identity/identity_service.dart';
import '../onboarding_content.dart';
import '../onboarding_sounds.dart' show OnbSoundCue;
import '../widgets/onb_motion.dart';
import '../widgets/onb_share_card.dart';
import '../widgets/onb_code_reveal.dart';
import '../widgets/onb_widgets.dart';

/// Gentle idle sway for a card preview — a slow figure-eight in 3D.
class OnbTiltSway extends StatefulWidget {
  final Widget child;
  final Offset extraTilt;
  const OnbTiltSway({
    super.key,
    required this.child,
    this.extraTilt = Offset.zero,
  });

  @override
  State<OnbTiltSway> createState() => _OnbTiltSwayState();
}

class _OnbTiltSwayState extends State<OnbTiltSway>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 7),
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
    return AnimatedBuilder(
      animation: _ctrl,
      child: widget.child,
      builder: (context, child) {
        final t = _ctrl.value * math.pi * 2;
        final ry = math.sin(t) * 0.10 + widget.extraTilt.dx;
        final rx = math.cos(t * 2) * 0.05 + widget.extraTilt.dy;
        return Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.0012)
            ..rotateY(ry)
            ..rotateX(rx),
          child: child,
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Screen 4 — Nickname
// ---------------------------------------------------------------------------

class OnbNicknameScreen extends StatefulWidget {
  final TextEditingController controller;
  final OnbCardTone tone;
  final String line;
  final VoidCallback onNext;
  final VoidCallback onSkip;

  const OnbNicknameScreen({
    super.key,
    required this.controller,
    required this.tone,
    required this.line,
    required this.onNext,
    required this.onSkip,
  });

  @override
  State<OnbNicknameScreen> createState() => _OnbNicknameScreenState();
}

class _OnbNicknameScreenState extends State<OnbNicknameScreen> {
  static const maxLength = 24;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    final nick = widget.controller.text.trim();
    return OnbStagger(
      child: OnbPage(
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
            const OnbTitle(
              title: 'What should we call you?',
              subtitle: 'It goes on your share card, and people in your Rooms '
                  'will see it. Totally optional.',
            ),
            const SizedBox(height: 22),
            OnbReveal(
              index: 2,
              child: TextField(
                controller: widget.controller,
                maxLength: maxLength,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => widget.onNext(),
                buildCounter: (_,
                        {required currentLength,
                        required isFocused,
                        maxLength}) =>
                    null,
                style: MiniText.body.copyWith(
                  fontSize: 18,
                  fontWeight: FontWeight.w500,
                ),
                decoration: InputDecoration(
                  hintText: 'e.g. Alex, BlueBunny',
                  filled: true,
                  fillColor: c.paperDeep,
                  prefixIcon: Icon(MiniIcons.edit, color: c.inkFaint, size: 20),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(MiniRadius.control),
                    borderSide: BorderSide(color: c.divider),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(MiniRadius.control),
                    borderSide: BorderSide(color: c.divider),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(MiniRadius.control),
                    borderSide: BorderSide(color: c.accent, width: 2),
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
                ),
              ),
            ),
            const SizedBox(height: 28),
            OnbReveal(
              index: 3,
              child: Center(
                child: LayoutBuilder(builder: (context, constraints) {
                  final w = math.min(250.0, constraints.maxWidth * 0.8);
                  return OnbTiltSway(
                    child: OnbSheen(
                      borderRadius: BorderRadius.circular(24 * w / 320),
                      child: OnbShareCard(
                        tone: widget.tone,
                        headline: widget.line,
                        name: nick.isEmpty ? null : nick,
                        width: w,
                      ),
                    ),
                  );
                }),
              ),
            ),
          ],
        ),
        bottom: OnbReveal(
          index: 5,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              MiniButton(label: 'Looks good', onPressed: widget.onNext),
              const SizedBox(height: 6),
              MiniButton(
                label: 'Skip for now',
                style: MiniBtnStyle.ghost,
                onPressed: widget.onSkip,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Screen 5 — Craft your code: pull the lever, the reels land on your real
// code, and the tiles fly out into a big glowing row (OnbCodeStage).
// ---------------------------------------------------------------------------

enum _Craft { idle, crafting, revealed, failed }

class OnbCraftScreen extends StatefulWidget {
  /// Creates (or loads) the identity — the real server call.
  final Future<UserIdentity> Function() create;

  /// Set when coming back to this screen after the code was crafted.
  final UserIdentity? initialIdentity;
  final ValueChanged<UserIdentity> onCrafted;
  final VoidCallback onPulled;

  /// Sound cues, sent as the lever and reels move.
  final ValueChanged<OnbSoundCue> onSound;
  final VoidCallback onNext;

  /// Offered once crafting fails, so someone without a connection isn't
  /// stuck here: the app crafts the code itself once they're back online.
  final VoidCallback onSkip;

  const OnbCraftScreen({
    super.key,
    required this.create,
    required this.onCrafted,
    required this.onPulled,
    required this.onSound,
    required this.onNext,
    required this.onSkip,
    this.initialIdentity,
  });

  @override
  State<OnbCraftScreen> createState() => _OnbCraftScreenState();
}

class _OnbCraftScreenState extends State<OnbCraftScreen> {
  late _Craft _state =
      widget.initialIdentity != null ? _Craft.revealed : _Craft.idle;
  late String? _code = widget.initialIdentity?.shortCode;

  /// The reveal has locked in: show the caption and the button.
  late bool _settled = widget.initialIdentity != null;
  Timer? _settle;

  /// Identity creation starts as soon as the screen shows, so the pull
  /// usually lands without waiting on the network.
  Future<UserIdentity>? _pending;
  bool _pendingFailed = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialIdentity == null) _start();
  }

  @override
  void dispose() {
    _settle?.cancel();
    super.dispose();
  }

  Future<UserIdentity> _start() {
    _pendingFailed = false;
    final future = widget.create();
    _pending = future;
    future.then((_) {}, onError: (Object _) {
      _pendingFailed = true;
    });
    return future;
  }

  Future<void> _onPull() async {
    if (_state == _Craft.crafting || _state == _Craft.revealed) return;
    widget.onPulled();
    // With reduce motion the reels don't roll; the code just appears.
    final rolls = !onbReduceMotion(context);
    widget.onSound(OnbSoundCue.leverPull);
    if (rolls) widget.onSound(OnbSoundCue.reelsSpin);
    setState(() => _state = _Craft.crafting);
    // Let the reels roll a beat even when the code is already here.
    final minRoll = Future<void>.delayed(const Duration(milliseconds: 700));
    try {
      final future =
          (_pending == null || _pendingFailed) ? _start() : _pending!;
      final identity = await future.timeout(const Duration(seconds: 20));
      await minRoll;
      if (!mounted) return;
      widget.onCrafted(identity);
      // The landing sound is timed from here: the reels start slowing down
      // on the next frame.
      if (rolls) widget.onSound(OnbSoundCue.reelsLand);
      setState(() => _code = identity.shortCode); // reels land → _onLanded
    } catch (_) {
      await minRoll;
      if (!mounted) return;
      if (rolls) widget.onSound(OnbSoundCue.reelsStop);
      _pendingFailed = true;
      setState(() => _state = _Craft.failed);
    }
  }

  void _onLanded() {
    if (!mounted || _state == _Craft.revealed) return;
    onbThump();
    widget.onSound(OnbSoundCue.codeReveal);
    setState(() => _state = _Craft.revealed);
    if (onbReduceMotion(context)) {
      setState(() => _settled = true);
    } else {
      _settle = Timer(OnbCodeStage.settleDelay, () {
        if (mounted) setState(() => _settled = true);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final revealed = _state == _Craft.revealed;
    // Until the reveal settles, keep the last caption ("Crafting…") up.
    final caption = revealed && !_settled ? _Craft.crafting : _state;
    return OnbPage(
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          OnbCodeStage(
            code: _code,
            rolling: _state == _Craft.crafting && _code == null,
            revealed: revealed,
            onPull: _onPull,
            onLanded: _onLanded,
          ),
          const SizedBox(height: 26),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 350),
            switchInCurve: Curves.easeOutCubic,
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SlideTransition(
                position: Tween(begin: const Offset(0, 0.15), end: Offset.zero)
                    .animate(anim),
                child: child,
              ),
            ),
            child:
                KeyedSubtree(key: ValueKey(caption), child: _caption(caption)),
          ),
        ],
      ),
      // Picked by `revealed`, not by the failure, so the label doesn't swap
      // while the area hides again for another pull.
      bottom: OnbCtaArea(
        visible: (revealed && _settled) || _state == _Craft.failed,
        children: revealed
            ? [
                MiniButton(
                    label: 'Make my share card', onPressed: widget.onNext),
              ]
            : [
                MiniButton(
                  label: 'Continue without a code',
                  style: MiniBtnStyle.ghost,
                  onPressed: widget.onSkip,
                ),
                Text(
                  'You’ll get your code once you’re back online.',
                  style: MiniText.small,
                  textAlign: TextAlign.center,
                ),
              ],
      ),
    );
  }

  Widget _caption(_Craft state) {
    switch (state) {
      case _Craft.idle:
        return const _CraftCaption(
          title: 'Pull the lever',
          subtitle: 'to craft your unique code.',
        );
      case _Craft.crafting:
        return const _CraftCaption(
          title: 'Crafting your code',
          subtitle: 'a few quiet moments…',
        );
      case _Craft.failed:
        return const _CraftCaption(
          title: 'Couldn\'t craft your code',
          subtitle: 'Check your internet connection and pull again.',
        );
      case _Craft.revealed:
        return const _CraftCaption(
          title: 'This is you.',
          subtitle: 'Anyone can send you files with this code. It reveals '
              'nothing about you.',
        );
    }
  }
}

class _CraftCaption extends StatelessWidget {
  final String title;
  final String subtitle;
  const _CraftCaption({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(title, style: MiniText.title, textAlign: TextAlign.center),
        const SizedBox(height: 6),
        Text(subtitle, style: MiniText.bodySoft, textAlign: TextAlign.center),
      ],
    );
  }
}

class _CopyButton extends StatelessWidget {
  final bool copied;
  final VoidCallback onTap;
  const _CopyButton({required this.copied, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Semantics(
      button: true,
      label: copied ? 'Copied' : 'Copy code',
      excludeSemantics: true,
      child: Material(
        color: c.paperDeep,
        borderRadius: BorderRadius.circular(MiniRadius.pill),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(MiniRadius.pill),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(MiniRadius.pill),
              border: Border.all(color: c.divider),
            ),
            alignment: Alignment.center,
            child: OnbCopiedLabel(copied: copied, idle: 'Copy code'),
          ),
        ),
      ),
    );
  }
}

/// Public so the share screen can reuse the same copy affordance.
class OnbCopyButton extends StatelessWidget {
  final bool copied;
  final VoidCallback onTap;
  const OnbCopyButton({super.key, required this.copied, required this.onTap});

  @override
  Widget build(BuildContext context) =>
      _CopyButton(copied: copied, onTap: onTap);
}
