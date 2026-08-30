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
import '../transfer/transfer_service.dart';
import '../../Minigo/widgets/mini_widgets.dart';

enum HomeAutoAction { showQr, openSend }

class HomeScreen extends StatefulWidget {
  final UserIdentity identity;
  final HomeAutoAction? autoAction;
  final VoidCallback? onActionConsumed;

  /// Jump to the History tab — the "All" link on the recent list.
  final VoidCallback? onSeeAll;
  const HomeScreen({
    super.key,
    required this.identity,
    this.autoAction,
    this.onActionConsumed,
    this.onSeeAll,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Map<String, dynamic>> _recent = const [];

  @override
  void initState() {
    super.initState();
    _scheduleAutoAction(widget.autoAction);
    _loadRecent();
  }

  Future<void> _loadRecent() async {
    try {
      final recent = await TransferService.getRecentTransfers(
        widget.identity.id,
      );
      if (mounted) setState(() => _recent = recent);
    } catch (_) {
      // Offline or unreachable — the section just stays hidden.
    }
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
    _loadRecent();
  }

  Future<void> _openSend() async {
    HapticFeedback.selectionClick();
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SendScreen(identity: widget.identity),
      ),
    );
    _loadRecent();
  }

  Future<void> _openReceived() async {
    HapticFeedback.selectionClick();
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReceivedTabScreen(identity: widget.identity),
      ),
    );
    _loadRecent();
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
                      child: Column(
                        children: [
                          Padding(
                            padding:
                                const EdgeInsets.fromLTRB(24, 26, 24, 24),
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
                              ],
                            ),
                          ),
                          // Flush three-cell footer — full-width rule above,
                          // full-height rules between, so the actions read as
                          // part of the code card rather than as loose tiles.
                          Container(height: 1, color: c.divider),
                          IntrinsicHeight(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(
                                  child: _ActionTile(
                                    icon: Icons.crop_free_rounded,
                                    label: 'Scan',
                                    onTap: _scanAndSend,
                                  ),
                                ),
                                _ActionDivider(color: c.divider),
                                Expanded(
                                  child: _ActionTile(
                                    icon: Icons.qr_code_2_rounded,
                                    label: 'QR',
                                    onTap: _showQr,
                                  ),
                                ),
                                _ActionDivider(color: c.divider),
                                Expanded(
                                  child: _ActionTile(
                                    icon: Icons.ios_share_rounded,
                                    label: 'Share',
                                    onTap: _shareCode,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    // Quiet footnote — no plate, no tint. It is a hint, not a
                    // status, so it sits under the card at the lowest contrast
                    // that still reads.
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.info_outline_rounded,
                              size: 15, color: c.inkFaint),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Share this code with others to send them files. '
                              'No account needed.',
                              style: GoogleFonts.outfit(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w400,
                                color: c.inkFaint,
                                height: 1.45,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_recent.isNotEmpty) ...[
                      const SizedBox(height: 26),
                      RecentSection(
                        transfers: _recent,
                        userId: widget.identity.id,
                        onSeeAll: widget.onSeeAll,
                      ),
                    ],
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

/// Full-height rule between two quick actions, splitting the card footer into
/// three cells.
class _ActionDivider extends StatelessWidget {
  final Color color;
  const _ActionDivider({required this.color});

  @override
  Widget build(BuildContext context) => Container(width: 1, color: color);
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
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 15),
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


/// Newest few transfers, one line each. Hidden entirely when empty — a blank
/// list on the home screen is noise, and History already has the full view.
class RecentSection extends StatelessWidget {
  final List<Map<String, dynamic>> transfers;
  final String userId;
  final VoidCallback? onSeeAll;

  const RecentSection({
    super.key,
    required this.transfers,
    required this.userId,
    this.onSeeAll,
  });

  /// Compact age for the trailing slot — same UTC convention as History.
  static String _ago(String iso) {
    final t = DateTime.tryParse(iso);
    if (t == null) return '';
    final d = DateTime.now().toUtc().difference(t);
    if (d.inMinutes < 1) return 'now';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24) return '${d.inHours}h';
    if (d.inDays == 1) return 'Yest';
    return '${d.inDays}d';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
          child: Row(
            children: [
              Text(
                'RECENT',
                style: MiniText.label
                    .copyWith(color: c.inkFaint, letterSpacing: 1.2),
              ),
              const Spacer(),
              if (onSeeAll != null)
                GestureDetector(
                  onTap: onSeeAll,
                  behavior: HitTestBehavior.opaque,
                  child: Text(
                    'All',
                    style: GoogleFonts.outfit(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: c.accent,
                    ),
                  ),
                ),
            ],
          ),
        ),
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: miniCard(context),
          child: Column(
            children: [
              for (var i = 0; i < transfers.length; i++) ...[
                if (i > 0) const HairLine(indent: 70),
                _recentRow(context, transfers[i]),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _recentRow(BuildContext context, Map<String, dynamic> t) {
    final files = (t['_files'] as List?) ?? const [];
    final name = files.isEmpty
        ? 'Transfer'
        : (files.first['file_name'] ?? 'File').toString();
    final bytes = files.fold<int>(
      0,
      (sum, f) => sum + ((f['file_size'] as num?)?.toInt() ?? 0),
    );
    final direction = t['sender_id'] == userId ? 'Sent' : 'Received';
    final subtitle = [
      direction,
      if (files.isNotEmpty)
        '${files.length} file${files.length == 1 ? '' : 's'}',
      if (bytes > 0) TransferService.formatFileSize(bytes),
    ].join(' · ');

    return MiniFileRow(
      name: name,
      size: subtitle,
      mimeCategory: MiniFileRow.categoryFromFileName(name),
      trailing: Text(
        _ago((t['created_at'] ?? '').toString()),
        style: MiniText.small.copyWith(color: context.mini.inkFaint),
      ),
    );
  }
}
