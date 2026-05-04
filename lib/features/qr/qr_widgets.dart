import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/constants.dart';
import '../../zensend/theme/zen_theme.dart';

/// Bottom sheet that displays the user's own code as a scannable QR image.
class QrCodeSheet extends StatelessWidget {
  final String code;
  const QrCodeSheet({super.key, required this.code});

  static Future<void> show(BuildContext context, String code) =>
      showModalBottomSheet<void>(
        context: context,
        backgroundColor: Colors.transparent,
        builder: (_) => QrCodeSheet(code: code),
      );

  @override
  Widget build(BuildContext context) {
    final c = context.zen;
    return Container(
      decoration: BoxDecoration(
        color: c.paper,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SheetHandle(color: c.divider),
          const SizedBox(height: 12),
          Text(
            'YOUR QR CODE',
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 2,
              color: c.inkFaint,
            ),
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.07),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: QrImageView(
              data: code,
              version: QrVersions.auto,
              size: 220,
              backgroundColor: Colors.white,
              errorCorrectionLevel: QrErrorCorrectLevel.M,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            fmtCode(code),
            style: ZenText.codeSmall.copyWith(
              color: c.ink,
              fontSize: 18,
              letterSpacing: 3,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Ask someone to scan this to send you files',
            style: ZenText.small.copyWith(color: c.inkSoft),
          ),
        ],
      ),
    );
  }
}

/// Camera scanner sheet — pops with the scanned code when a valid 6-character
/// recipient code is detected. Returns null if dismissed without scanning.
class QrScannerSheet extends StatefulWidget {
  const QrScannerSheet({super.key});

  static Future<String?> show(BuildContext context) =>
      showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => const QrScannerSheet(),
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
      final code = AppConstants.normalizeShortCode(raw.trim());
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
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
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
              "Scan recipient's QR code",
              style: GoogleFonts.inter(
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
                borderRadius: BorderRadius.circular(16),
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
                          style: GoogleFonts.inter(
                            color: Colors.white54,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                    // Viewfinder guide
                    IgnorePointer(
                      child: Container(
                        width: 200,
                        height: 200,
                        decoration: BoxDecoration(
                          border:
                              Border.all(color: Colors.white60, width: 2),
                          borderRadius: BorderRadius.circular(12),
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
                style: GoogleFonts.inter(
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
      width: 36,
      height: 4,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}
