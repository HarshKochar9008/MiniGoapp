import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/analytics/analytics.dart';
import '../../core/native/native_share.dart';
import '../../Minigo/theme/mini_theme.dart';
import '../../Minigo/widgets/mini_code_reel.dart';
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
              padding: const EdgeInsets.fromLTRB(20, 18, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('You are',
                            style: MiniText.label.copyWith(color: c.inkFaint)),
                        const SizedBox(height: 5),
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
                  Material(
                    color: c.sand,
                    borderRadius: BorderRadius.circular(MiniRadius.pill),
                    child: InkWell(
                      onTap: _copyCode,
                      borderRadius: BorderRadius.circular(MiniRadius.pill),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 9),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              fmtCode(code),
                              style: MiniText.code.copyWith(
                                fontSize: 15,
                                color: headerCodeColor,
                              ),
                            ),
                            const SizedBox(width: 7),
                            Icon(
                              Icons.copy_rounded,
                              size: 15,
                              color: c.inkSoft,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

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
                      clipBehavior: Clip.antiAlias,
                      decoration: miniCard(context, strong: true),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 26, 24, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Text(
                              'YOUR CODE',
                              style: MiniText.label.copyWith(
                                color: c.inkFaint,
                                letterSpacing: 1.2,
                              ),
                            ),
                            const SizedBox(height: 20),
                            MiniCodeReel(
                              code: code,
                              style: MiniText.codeLarge.copyWith(
                                color: c.ink,
                                letterSpacing: 4,
                              ),
                            ),
                            const SizedBox(height: 22),
                            // One flush strip, hairline-separated — the three
                            // actions belong to the code above them, so they
                            // read as part of the card rather than as tiles.
                            Row(
                              children: [
                                Expanded(
                                  child: _ActionTile(
                                    icon: Icons.qr_code_scanner_rounded,
                                    label: 'Scan',
                                    onTap: _scanAndSend,
                                  ),
                                ),
                                _ActionDivider(color: c.dividerSoft),
                                Expanded(
                                  child: _ActionTile(
                                    icon: Icons.qr_code_rounded,
                                    label: 'QR',
                                    onTap: _showQr,
                                  ),
                                ),
                                _ActionDivider(color: c.dividerSoft),
                                Expanded(
                                  child: _ActionTile(
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
                    ),
                    const SizedBox(height: 20),
                    // Info card
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 16),
                      decoration: BoxDecoration(
                        color: c.accentSoft,
                        borderRadius: BorderRadius.circular(MiniRadius.control),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.info_rounded, size: 19, color: c.accent),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Share this code with others to send them files. ',
                              style: GoogleFonts.outfit(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w500,
                                color: c.accent,
                                height: 1.4,
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
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _PillButton(
              icon: Icons.south_west_rounded,
              label: 'Received',
              background: c.paperDeep,
              foreground: c.ink,
              border: c.divider,
              onTap: _openReceived,
            ),
            const SizedBox(width: 10),
            _PillButton(
              icon: Icons.north_east_rounded,
              label: 'Send',
              background: MiniColors.blue600,
              foreground: Colors.white,
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
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(MiniRadius.pill),
        boxShadow: miniCardShadow(context, strong: border == null),
      ),
      child: Material(
        color: background,
        shape: StadiumBorder(
          side: border != null ? BorderSide(color: border!) : BorderSide.none,
        ),
        child: InkWell(
          onTap: onTap,
          customBorder: const StadiumBorder(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 17),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18, color: foreground),
                const SizedBox(width: 9),
                Text(
                  label,
                  style: GoogleFonts.outfit(
                    fontWeight: FontWeight.w500,
                    letterSpacing: -0.1,
                    fontSize: 15,
                    color: foreground,
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

/// Hairline rule between two quick actions. Short and faint on purpose — it
/// groups the actions instead of boxing each one off.
class _ActionDivider extends StatelessWidget {
  final Color color;
  const _ActionDivider({required this.color});

  @override
  Widget build(BuildContext context) =>
      Container(width: 1, height: 26, color: color);
}

/// Stacked icon + label used for the code card's three quick actions. Drawn on
/// the card itself — no fill, no icon plate, no tint.
class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(MiniRadius.control),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            children: [
              Icon(icon, size: 20, color: c.inkSoft),
              const SizedBox(height: 8),
              Text(
                label,
                style: GoogleFonts.outfit(
                  fontSize: 12.5,
                  height: 1,
                  fontWeight: FontWeight.w500,
                  color: c.inkSoft,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
