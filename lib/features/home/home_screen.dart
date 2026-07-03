import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/analytics/analytics.dart';
import '../../core/native/native_share.dart';
import '../../zensend/theme/zen_theme.dart';
import '../../zensend/widgets/zen_widgets.dart';
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
    final c = context.zen;
    final code = widget.identity.shortCode;

    return Scaffold(
      backgroundColor: c.paper,
      body: SafeArea(
        child: Column(
          children: [
            // Top bar
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 12, 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('You are',
                            style: ZenText.label.copyWith(color: c.inkSoft)),
                        if (widget.identity.nickname != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            widget.identity.nickname!,
                            style: ZenText.title.copyWith(color: c.ink),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        fmtCode(code),
                        style: ZenText.code.copyWith(fontSize: 22, color: c.ink),
                      ),
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: _copyCode,
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            Icons.copy_rounded,
                            size: 15,
                            color: c.inkFaint,
                          ),
                        ),
                      ),
                    ],
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
                          color: ZenColors.success.withValues(alpha: 0.22),
                          width: 1,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Text(
                            'YOUR CODE',
                            style: ZenText.label.copyWith(
                              color: ZenColors.success,
                              letterSpacing: 2,
                            ),
                          ),
                          const SizedBox(height: 20),
                          Text(
                            fmtCode(code),
                            style: ZenText.codeLarge.copyWith(
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
                                  icon: Icons.copy_rounded,
                                  label: 'Copy',
                                  onTap: _copyCode,
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
                        color: ZenColors.blue600.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: ZenColors.blue600.withValues(alpha: 0.22),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.info_outline_rounded,
                              size: 18, color: c.accent),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Share this code so others can send you files. '
                              'Tap Send below to send files to someone else.',
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
              background: ZenColors.blue600,
              foreground: ZenColors.paper,
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
    final c = context.zen;
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
