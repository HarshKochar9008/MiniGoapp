import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/analytics/analytics.dart';
import '../../core/constants.dart';
import '../../core/native/native_share.dart';
import '../../Minigo/theme/mini_icons.dart';
import '../../Minigo/theme/mini_theme.dart';
import '../../Minigo/widgets/mini_widgets.dart';
import '../settings/settings_components.dart';

/// Bottom sheet that displays the user's own code — or, with [forRoom], a
/// room's join code — as a scannable QR image, with Copy code and Share.
///
/// Copying confirms inside the sheet rather than with a snack bar, which
/// would show behind it.
class QrCodeSheet extends StatefulWidget {
  final String code;
  final bool forRoom;

  /// What Share sends, worded by the screen that opened the sheet.
  final String shareText;
  final String? shareSubject;

  const QrCodeSheet({
    super.key,
    required this.code,
    required this.shareText,
    this.shareSubject,
    this.forRoom = false,
  });

  static Future<void> show(
    BuildContext context,
    String code, {
    required String shareText,
    String? shareSubject,
    bool forRoom = false,
  }) =>
      showMiniSheet<void>(
        context,
        builder: (_) => QrCodeSheet(
          code: code,
          shareText: shareText,
          shareSubject: shareSubject,
          forRoom: forRoom,
        ),
      );

  @override
  State<QrCodeSheet> createState() => _QrCodeSheetState();
}

class _QrCodeSheetState extends State<QrCodeSheet> {
  static const _copiedFor = Duration(seconds: 2);

  bool _copied = false;
  Timer? _copiedTimer;

  @override
  void dispose() {
    _copiedTimer?.cancel();
    super.dispose();
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.code));
    HapticFeedback.selectionClick();
    if (!widget.forRoom) {
      Analytics.instance
          .logEvent(AnalyticsEvents.codeCopied, {'source': 'qr'});
    }
    setState(() => _copied = true);
    _copiedTimer?.cancel();
    _copiedTimer = Timer(_copiedFor, () {
      if (mounted) setState(() => _copied = false);
    });
  }

  void _share() {
    HapticFeedback.selectionClick();
    if (!widget.forRoom) {
      Analytics.instance
          .logEvent(AnalyticsEvents.codeShared, {'source': 'qr'});
    }
    NativeShareService.shareText(widget.shareText,
        subject: widget.shareSubject);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    final forRoom = widget.forRoom;
    return MiniSheetFrame(
      // On a narrow phone the icons go, so "Copy code" stays on one line.
      footer: LayoutBuilder(
        builder: (context, box) {
          final icons = box.maxWidth >= 300;
          return Row(
            children: [
              Expanded(
                child: MiniButton(
                  label: _copied ? 'Copied' : 'Copy code',
                  style: MiniBtnStyle.tonal,
                  leading: icons
                      ? Icon(
                          _copied ? MiniIcons.check : MiniIcons.copy,
                          size: 18,
                          color: c.ink,
                        )
                      : null,
                  onPressed: _copy,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: MiniButton(
                  label: 'Share',
                  style: MiniBtnStyle.accent,
                  leading: icons
                      ? const Icon(
                          MiniIcons.shareSheet,
                          size: 18,
                          color: Colors.white,
                        )
                      : null,
                  onPressed: _share,
                ),
              ),
            ],
          );
        },
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    forRoom ? 'Room QR code' : 'Your QR code',
                    style: MiniText.title.copyWith(color: c.ink, fontSize: 24),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              _CloseButton(onPressed: () => Navigator.pop(context)),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            forRoom
                ? 'Scan this from Join room in MiniGo.'
                : 'Ask someone to scan this to send you files.',
            style: MiniText.bodySoft.copyWith(color: c.inkSoft, height: 1.45),
          ),
          const SizedBox(height: 24),
          Center(
            child: LayoutBuilder(
              builder: (context, box) => Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  // White in both themes: scanners need the contrast.
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(MiniRadius.card + 4),
                  border: Border.all(color: c.divider),
                ),
                child: QrImageView(
                  // An https link (not the bare code) so every camera app
                  // offers to open it; the page redirects into MiniGo's send
                  // screen. A room code must not become a "send to this
                  // user" link, so it stays bare — the in-app scanner reads
                  // that directly.
                  data: forRoom
                      ? AppConstants.normalizeShortCode(widget.code)
                      : AppConstants.qrPayloadForCode(widget.code),
                  version: QrVersions.auto,
                  size: math.min(200, box.maxWidth - 38),
                  backgroundColor: Colors.white,
                  errorCorrectionLevel: QrErrorCorrectLevel.M,
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Center(
            child: Semantics(
              button: true,
              label: 'Copy code ${widget.code}',
              excludeSemantics: true,
              child: Material(
                color: c.sand,
                borderRadius: BorderRadius.circular(MiniRadius.pill),
                child: InkWell(
                  onTap: _copy,
                  borderRadius: BorderRadius.circular(MiniRadius.pill),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 11, 16, 11),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          fmtCode(widget.code),
                          style: MiniText.code.copyWith(
                            color: c.ink,
                            fontSize: 18,
                            letterSpacing: 3,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Icon(
                          _copied ? MiniIcons.check : MiniIcons.copy,
                          size: 16,
                          color: _copied ? MiniColors.success : c.inkSoft,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CloseButton extends StatelessWidget {
  final VoidCallback onPressed;
  const _CloseButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Tooltip(
      message: 'Close',
      child: Material(
        color: c.sand,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(MiniIcons.close, size: 20, color: c.ink),
          ),
        ),
      ),
    );
  }
}

/// Camera scanner sheet — pops with the scanned code when a valid 6-character
/// recipient code is detected. Returns null if dismissed without scanning.
class QrScannerSheet extends StatefulWidget {
  final String title;
  const QrScannerSheet({super.key, this.title = "Scan recipient's QR code"});

  static Future<String?> show(BuildContext context,
          {String title = "Scan recipient's QR code"}) =>
      showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => QrScannerSheet(title: title),
      );

  @override
  State<QrScannerSheet> createState() => _QrScannerSheetState();
}

class _QrScannerSheetState extends State<QrScannerSheet> {
  late final MobileScannerController _ctrl;
  bool _scanned = false;

  @override
  void initState() {
    super.initState();
    _ctrl = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      facing: CameraFacing.back,
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_scanned) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;
      // New QRs carry a minigo://send deep link; older ones the bare code.
      final code = AppConstants.codeFromSendDeepLink(raw) ??
          AppConstants.normalizeShortCode(raw.trim());
      if (AppConstants.isValidShortCodeFormat(code)) {
        _scanned = true;
        HapticFeedback.mediumImpact();
        Navigator.pop(context, code);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height * 0.72;
    return Container(
      height: height,
      decoration: const BoxDecoration(
        color: Colors.black,
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(MiniRadius.sheet)),
      ),
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: _SheetHandle(color: Colors.white24),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              widget.title,
              style: GoogleFonts.outfit(
                color: Colors.white70,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(MiniRadius.card),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    MobileScanner(
                      controller: _ctrl,
                      onDetect: _onDetect,
                      errorBuilder: (context, error) => Container(
                        color: Colors.black87,
                        alignment: Alignment.center,
                        child: Text(
                          'Camera unavailable.\nCheck permissions in Settings.',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.outfit(
                            color: Colors.white54,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                    // Viewfinder guide
                    IgnorePointer(
                      child: Container(
                        width: 220,
                        height: 220,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.white70, width: 3),
                          borderRadius: BorderRadius.circular(MiniRadius.card),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Cancel',
                style: GoogleFonts.outfit(
                  color: Colors.white54,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
          SizedBox(height: MediaQuery.of(context).padding.bottom),
        ],
      ),
    );
  }
}

class _SheetHandle extends StatelessWidget {
  final Color color;
  const _SheetHandle({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 5,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(MiniRadius.pill),
      ),
    );
  }
}
