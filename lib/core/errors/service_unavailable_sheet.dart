import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../Minigo/theme/mini_theme.dart';
import '../../Minigo/widgets/mini_widgets.dart';
import '../constants.dart';
import 'service_health.dart';

/// Full "our service is down" bottom sheet — shown when the device is online
/// but the backend is unreachable, so the user knows the problem is on our
/// side and what they can do about it.
class ServiceUnavailableSheet extends StatefulWidget {
  final VoidCallback? onRetry;
  const ServiceUnavailableSheet({super.key, this.onRetry});

  static bool _visible = false;

  /// Shows the sheet, guaranteeing only one instance at a time.
  static Future<void> show(BuildContext context,
      {VoidCallback? onRetry}) async {
    if (_visible) return;
    _visible = true;
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => ServiceUnavailableSheet(onRetry: onRetry),
      );
    } finally {
      _visible = false;
    }
  }

  @override
  State<ServiceUnavailableSheet> createState() =>
      _ServiceUnavailableSheetState();
}

class _ServiceUnavailableSheetState extends State<ServiceUnavailableSheet> {
  bool _retrying = false;
  bool _stillDown = false;
  bool _runningDiagnostics = false;
  String? _diagnosticsReport;

  Future<void> _retry() async {
    if (_retrying) return;
    setState(() {
      _retrying = true;
      _stillDown = false;
    });
    final health = await ServiceHealth.instance.check(force: true);
    if (!mounted) return;
    if (health == BackendHealth.healthy) {
      Navigator.pop(context);
      widget.onRetry?.call();
    } else {
      setState(() {
        _retrying = false;
        _stillDown = true;
      });
    }
  }

  Future<void> _contactSupport() async {
    await Clipboard.setData(
      const ClipboardData(text: AppConstants.supportEmail),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Support email copied: ${AppConstants.supportEmail}'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _runDiagnostics() async {
    if (_runningDiagnostics) return;
    setState(() {
      _runningDiagnostics = true;
      _diagnosticsReport = 'Running diagnostics…';
    });
    final report = await ServiceHealth.instance.runDiagnosticsReport();
    if (!mounted) return;
    setState(() {
      _runningDiagnostics = false;
      _diagnosticsReport = report;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Container(
      decoration: BoxDecoration(
        color: c.paperDeep,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(MiniRadius.sheet),
        ),
      ),
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 12,
        bottom: 24 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 5,
                decoration: BoxDecoration(
                  color: c.sandDeep,
                  borderRadius: BorderRadius.circular(MiniRadius.pill),
                ),
              ),
              const SizedBox(height: 30),
              Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  color: MiniColors.warn.withValues(alpha: 0.13),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.cloud_off_rounded,
                  size: 33,
                  color: MiniColors.warn,
                ),
              ),
              const SizedBox(height: 22),
              Text(
                'Service temporarily unavailable',
                textAlign: TextAlign.center,
                style: MiniText.title.copyWith(color: c.ink, fontSize: 20),
              ),
              const SizedBox(height: 10),
              Text(
                'We\'re having trouble reaching MiniGo\'s servers. '
                'This is on our side — not your device or connection. '
                'Your files and transfers are safe.\n\n'
                'Please try again in a few minutes.',
                textAlign: TextAlign.center,
                style: GoogleFonts.outfit(
                  fontSize: 14.5,
                  height: 1.5,
                  color: c.inkSoft,
                ),
              ),
              if (_stillDown) ...[
                const SizedBox(height: 16),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  decoration: BoxDecoration(
                    color: MiniColors.warn.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(MiniRadius.pill),
                  ),
                  child: Text(
                    'Still unavailable — thanks for your patience.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.outfit(
                      fontSize: 13,
                      height: 1.2,
                      color: MiniColors.warn,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 28),
              MiniButton(
                label: _retrying ? 'Trying…' : 'Try again',
                loading: _retrying,
                onPressed: _retrying ? null : _retry,
              ),
              const SizedBox(height: 8),
              MiniButton(
                label: 'Contact support',
                style: MiniBtnStyle.ghost,
                onPressed: _contactSupport,
              ),
              TextButton(
                onPressed: _runningDiagnostics ? null : _runDiagnostics,
                child: Text(
                  _runningDiagnostics
                      ? 'Running diagnostics…'
                      : 'Run diagnostics',
                  style: GoogleFonts.outfit(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: c.inkFaint,
                  ),
                ),
              ),
              if (_diagnosticsReport != null) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: miniWell(context),
                  child: Text(
                    _diagnosticsReport!,
                    style: GoogleFonts.jetBrainsMono(
                      color: c.inkSoft,
                      fontSize: 11,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
