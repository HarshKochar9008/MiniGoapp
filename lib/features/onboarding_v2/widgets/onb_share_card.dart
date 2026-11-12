import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../Minigo/theme/mini_theme.dart';
import '../onboarding_content.dart';

/// The "Send me files" card. Drawn entirely from fixed
/// tone colours so the exported PNG looks identical in light and dark mode.
class OnbShareCard extends StatelessWidget {
  final OnbCardTone tone;
  final String headline;

  /// The nickname, if they set one.
  final String? name;

  /// Null shows a "??? · ???" placeholder (the code doesn't exist yet).
  final String? code;

  /// Null shows a blank QR plate.
  final String? qrData;
  final String? footnote;
  final double width;

  const OnbShareCard({
    super.key,
    required this.tone,
    required this.headline,
    required this.width,
    this.name,
    this.code,
    this.qrData,
    this.footnote,
  });

  static const aspect = 1.28;

  /// The exported PNG's width — 260 pt at @3x — however big the card is
  /// drawn on screen.
  static const exportWidth = 780.0;

  /// The card in the RepaintBoundary keyed [boundary], as a PNG
  /// [exportWidth] pixels wide; null if it can't be captured.
  static Future<Uint8List?> capture(GlobalKey boundary) async {
    try {
      final box =
          boundary.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (box == null) return null;
      final image = await box.toImage(pixelRatio: exportWidth / box.size.width);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return bytes?.buffer.asUint8List();
    } catch (e) {
      if (kDebugMode) debugPrint('share card: capture failed: $e');
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = width / 320;
    final height = width * aspect;
    final codeText = code == null ? '??? · ???' : fmtCode(code!);
    return Semantics(
      label: 'Share card. $headline. '
          '${name != null ? '$name. ' : ''}'
          '${code == null ? 'Your code appears here.' : 'Code ${code!.split('').join(' ')}.'}',
      excludeSemantics: true,
      child: MediaQuery.withNoTextScaling(
        child: Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24 * s),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: tone.background.length == 1
                  ? [tone.background.first, tone.background.first]
                  : tone.background,
            ),
            boxShadow: [
              BoxShadow(
                color: tone.background.first.withValues(alpha: 0.35),
                blurRadius: 30 * s,
                offset: Offset(0, 14 * s),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24 * s),
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(painter: _CardDecorPainter(tone.accent)),
                ),
                Padding(
                  padding: EdgeInsets.all(22 * s),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Image.asset('assets/minigo_ufo.png', width: 34 * s),
                          SizedBox(width: 8 * s),
                          Expanded(
                            child: Text(
                              name ?? 'MiniGo',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.outfit(
                                fontSize: 16 * s,
                                fontWeight: FontWeight.w600,
                                color: tone.ink,
                                letterSpacing: -0.2,
                              ),
                            ),
                          ),
                          if (name != null)
                            Text(
                              'MiniGo',
                              style: GoogleFonts.outfit(
                                fontSize: 11 * s,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.8,
                                color: tone.inkSoft,
                              ),
                            ),
                        ],
                      ),
                      const Spacer(),
                      Text(
                        headline,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.outfit(
                          fontSize: 29 * s,
                          height: 1.05,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.9,
                          color: tone.ink,
                        ),
                      ),
                      SizedBox(height: 10 * s),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          codeText,
                          style: GoogleFonts.jetBrainsMono(
                            fontSize: 30 * s,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 3,
                            color: code == null ? tone.inkSoft : tone.ink,
                          ),
                        ),
                      ),
                      SizedBox(height: 18 * s),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          _QrPlate(data: qrData, size: 92 * s, tone: tone),
                          SizedBox(width: 14 * s),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Scan with your camera',
                                  style: GoogleFonts.outfit(
                                    fontSize: 13 * s,
                                    height: 1.3,
                                    fontWeight: FontWeight.w500,
                                    color: tone.ink,
                                  ),
                                ),
                                if (footnote != null) ...[
                                  SizedBox(height: 4 * s),
                                  Text(
                                    footnote!,
                                    style: GoogleFonts.outfit(
                                      fontSize: 11.5 * s,
                                      height: 1.3,
                                      color: tone.inkSoft,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QrPlate extends StatelessWidget {
  final String? data;
  final double size;
  final OnbCardTone tone;
  const _QrPlate({required this.data, required this.size, required this.tone});

  @override
  Widget build(BuildContext context) {
    final pad = size * 0.09;
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(pad),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(size * 0.14),
      ),
      child: data == null
          ? GridView.count(
              crossAxisCount: 3,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: pad * 0.6,
              crossAxisSpacing: pad * 0.6,
              children: List.generate(
                9,
                (i) => DecoratedBox(
                  decoration: BoxDecoration(
                    color: MiniColors.sandDeep
                        .withValues(alpha: i.isEven ? 1 : 0.5),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            )
          : QrImageView(
              data: data!,
              version: QrVersions.auto,
              padding: EdgeInsets.zero,
              backgroundColor: Colors.white,
              errorCorrectionLevel: QrErrorCorrectLevel.M,
              eyeStyle: const QrEyeStyle(
                eyeShape: QrEyeShape.square,
                color: MiniColors.ink,
              ),
              dataModuleStyle: const QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.square,
                color: MiniColors.ink,
              ),
            ),
    );
  }
}

class _CardDecorPainter extends CustomPainter {
  final Color accent;
  _CardDecorPainter(this.accent);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width * 0.92, size.height * 0.1);
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (var i = 1; i <= 4; i++) {
      ring.color = accent.withValues(alpha: 0.22 - i * 0.04);
      canvas.drawCircle(center, size.width * 0.16 * i, ring);
    }
    final rng = math.Random(3);
    final dot = Paint();
    for (var i = 0; i < 18; i++) {
      dot.color = accent.withValues(alpha: 0.18 + rng.nextDouble() * 0.3);
      canvas.drawCircle(
        Offset(rng.nextDouble() * size.width,
            rng.nextDouble() * size.height * 0.55),
        0.8 + rng.nextDouble() * 1.4,
        dot,
      );
    }
  }

  @override
  bool shouldRepaint(_CardDecorPainter old) => old.accent != accent;
}

/// Tweens between card tones so swatch changes morph instead of snapping.
class OnbToneTween extends Tween<OnbCardTone> {
  OnbToneTween({super.begin, super.end});

  @override
  OnbCardTone lerp(double t) => OnbCardTone.lerp(begin!, end!, t);
}
