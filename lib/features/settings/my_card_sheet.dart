import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../Minigo/theme/mini_icons.dart';
import '../../Minigo/theme/mini_theme.dart';
import '../../Minigo/widgets/mini_widgets.dart';
import '../onboarding_v2/onboarding_content.dart';
import '../onboarding_v2/onboarding_services.dart';
import '../onboarding_v2/widgets/onb_share_card.dart';
import 'settings_components.dart';

/// The share card they styled in onboarding — colour, line, nickname, code
/// and QR — with a button that sends it as a picture.
class MyCardSheet extends StatefulWidget {
  final String code;
  final String? nickname;
  final OnbCardStyle style;

  const MyCardSheet({
    super.key,
    required this.code,
    required this.nickname,
    required this.style,
  });

  static Future<void> show(
    BuildContext context, {
    required String code,
    required String? nickname,
  }) async {
    final style = await const OnbServices().loadCardStyle();
    if (!context.mounted) return;
    await showMiniSheet<void>(
      context,
      builder: (_) =>
          MyCardSheet(code: code, nickname: nickname, style: style),
    );
  }

  @override
  State<MyCardSheet> createState() => _MyCardSheetState();
}

class _MyCardSheetState extends State<MyCardSheet> {
  final _cardKey = GlobalKey();
  bool _sharing = false;

  Future<void> _share(BuildContext buttonContext) async {
    if (_sharing) return;
    final box = buttonContext.findRenderObject() as RenderBox?;
    final origin =
        box == null ? null : box.localToGlobal(Offset.zero) & box.size;
    setState(() => _sharing = true);
    try {
      await const OnbServices().shareCard(
        png: await OnbShareCard.capture(_cardKey),
        text: onbPersonalShareText(widget.code),
        fileStem: 'minigo-card-${widget.code}',
        origin: origin,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('my card: share failed: $e');
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return MiniSheetFrame(
      footer: Builder(
        builder: (buttonContext) => MiniButton(
          label: 'Share my card',
          loading: _sharing,
          leading: Icon(
            MiniIcons.share,
            size: 18,
            color: context.isDarkMini ? c.paper : Colors.white,
          ),
          onPressed: () => _share(buttonContext),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'YOUR CARD',
            style: MiniText.label.copyWith(
              color: c.inkFaint,
              letterSpacing: 0.9,
            ),
          ),
          const SizedBox(height: 22),
          LayoutBuilder(
            builder: (context, box) => RepaintBoundary(
              key: _cardKey,
              child: OnbShareCard(
                tone: onbCardTones[widget.style.tone],
                headline: onbCardLines[widget.style.line],
                name: widget.nickname,
                code: widget.code,
                qrData: AppConstants.qrPayloadForCode(widget.code),
                footnote: 'or enter my code in MiniGo',
                width: math.min(260, box.maxWidth),
              ),
            ),
          ),
          const SizedBox(height: 22),
          Text(
            'Send it to whoever’s sending you files. They’ll need MiniGo '
            'too — the card shows them how.',
            textAlign: TextAlign.center,
            style: MiniText.small.copyWith(color: c.inkSoft, height: 1.45),
          ),
        ],
      ),
    );
  }
}
