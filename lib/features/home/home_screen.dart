import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/analytics/analytics.dart';
import '../../core/native/native_share.dart';
import '../../Minigo/theme/mini_theme.dart';
import '../../Minigo/widgets/mini_widgets.dart';
import '../identity/identity_service.dart';
import '../qr/qr_widgets.dart';
import '../receive/received_tab_screen.dart';
import '../send/send_screen.dart';

enum HomeAutoAction { showQr, openSend }

class HomeScreen extends StatefulWidget {
  final UserIdentity identity;
  final HomeAutoAction? autoAction;
  final VoidCallback? onActionConsumed;
  const HomeScreen({
    super.key,
    required this.identity,
    this.autoAction,
    this.onActionConsumed,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    _scheduleAutoAction(widget.autoAction);
  }

  void _scheduleAutoAction(HomeAutoAction? action) {
    if (action == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (action == HomeAutoAction.showQr) _showQr();
      if (action == HomeAutoAction.openSend) _openSend();
      widget.onActionConsumed?.call();
    });
  }

  @override
  void didUpdateWidget(HomeScreen old) {
    super.didUpdateWidget(old);
    if (widget.autoAction != null && widget.autoAction != old.autoAction) {
      _scheduleAutoAction(widget.autoAction);
    }
  }

  void _copyCode() {
    Clipboard.setData(ClipboardData(text: widget.identity.shortCode));
    HapticFeedback.selectionClick();
    Analytics.instance.logEvent(AnalyticsEvents.codeCopied, {'source': 'home'});
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Code copied')),
    );
  }

  void _shareCode() {
    HapticFeedback.selectionClick();
    Analytics.instance.logEvent(AnalyticsEvents.codeShared, {'source': 'home'});
    NativeShareService.shareText(
      'Send me files on MiniGo using my code: ${widget.identity.shortCode}',
      subject: 'MiniGo invite',
    );
  }

  void _showQr() {
    HapticFeedback.selectionClick();
    Analytics.instance.logEvent(AnalyticsEvents.qrShown);
    QrCodeSheet.show(context, widget.identity.shortCode);
  }

  /// Scan a friend's QR and jump straight into sending to them.
  Future<void> _scanAndSend() async {
    HapticFeedback.selectionClick();
    final code = await QrScannerSheet.show(context);
    if (code == null || !mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SendScreen(
          identity: widget.identity,
          initialRecipientCode: code,
        ),
      ),
    );
  }

  void _openSend() {
    HapticFeedback.selectionClick();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SendScreen(identity: widget.identity),
      ),
    );
  }

  void _openReceived() {
    HapticFeedback.selectionClick();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReceivedTabScreen(identity: widget.identity),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    final code = widget.identity.shortCode;
    final displayName = widget.identity.nickname ?? 'MiniGo User';
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final headerCodeColor = isDark ? c.accent : c.ink;

    return Scaffold(
      backgroundColor: c.paper,
      body: SafeArea(
        child: Column(
          children: [
            // Top bar
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 12, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('You are',
                            style: MiniText.label.copyWith(color: c.inkSoft)),
                        const SizedBox(height: 4),
                        Text(
                          displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: MiniText.title.copyWith(color: c.ink),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  GestureDetector(
                    onTap: _copyCode,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            fmtCode(code),
                            style: MiniText.code.copyWith(
                              fontSize: 19,
                              color: headerCodeColor,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Icon(
                            Icons.copy_rounded,
                            size: 15,
                            color: c.inkFaint,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const HairLine(indent: 20),

            // Large code card
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 28, 20, 100),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Code card
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(28),
                      decoration: BoxDecoration(
                        color: c.sand,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: MiniColors.success.withValues(alpha: 0.22),
                          width: 1,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Text(
                            'YOUR CODE',
                            style: MiniText.label.copyWith(
                              color: MiniColors.success,
                              letterSpacing: 2,
                            ),
                          ),
                          const SizedBox(height: 20),
                          Text(
                            fmtCode(code),
                            style: MiniText.codeLarge.copyWith(
                              color: c.ink,
                              letterSpacing: 4,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 24),
                          Row(
                            children: [
                              Expanded(
                                child: _OutlineBtn(
                                  icon: Icons.qr_code_scanner_rounded,
                                  label: 'Scan',
                                  onTap: _scanAndSend,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _OutlineBtn(
                                  icon: Icons.qr_code_rounded,
                                  label: 'QR',
                                  onTap: _showQr,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _OutlineBtn(
                                  icon: Icons.share_rounded,
                                  label: 'Share',
                                  onTap: _shareCode,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 28),
                    // Info card
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 14),
                      decoration: BoxDecoration(
                        color: c.accent.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                            color: c.accent.withValues(alpha: 0.35)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.info_outline_rounded,
                              size: 18, color: c.accent),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Share this code with others to send them files. ',
                              style: GoogleFonts.outfit(
                                fontSize: 12,
                                color: c.accent,
                                height: 1.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _PillButton(
              icon: Icons.south_west_rounded,
              label: 'Received',
              background: c.paper,
              foreground: c.ink,
              border: c.divider,
              onTap: _openReceived,
            ),
            const SizedBox(width: 10),
            _PillButton(
              icon: Icons.north_east_rounded,
              label: 'Send',
              background: MiniColors.blue600,
              foreground: MiniColors.paper,
              onTap: _openSend,
            ),
          ],
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }
}

class _PillButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color background;
  final Color foreground;
  final Color? border;
  final VoidCallback onTap;

  const _PillButton({
    required this.icon,
    required this.label,
    required this.background,
    required this.foreground,
    required this.onTap,
    this.border,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: background,
      shape: StadiumBorder(
        side: border != null ? BorderSide(color: border!) : BorderSide.none,
      ),
      elevation: border != null ? 0 : 2,
      shadowColor: Colors.black26,
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 15),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: foreground),
              const SizedBox(width: 8),
              Text(
                label,
                style: GoogleFonts.outfit(
                  fontWeight: FontWeight.w400,
                  letterSpacing: 0.5,
                  fontSize: 15,
                  color: foreground,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OutlineBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _OutlineBtn(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: c.paper,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c.divider),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 15, color: c.ink),
            const SizedBox(width: 6),
            Text(
              label,
              style: GoogleFonts.outfit(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: c.ink,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
