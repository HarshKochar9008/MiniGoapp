import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide UserIdentity;

import '../../core/contacts/contact_aliases.dart';
import '../../core/network/connection_status.dart';
import '../../Minigo/theme/mini_theme.dart';
import '../../Minigo/widgets/mini_widgets.dart';
import '../contacts/contact_alias_sheet.dart';
import '../identity/identity_service.dart';
import '../transfer/transfer_service.dart';
import 'receive_screen.dart';

class ReceivedTabScreen extends StatefulWidget {
  final UserIdentity identity;
  const ReceivedTabScreen({super.key, required this.identity});

  @override
  State<ReceivedTabScreen> createState() => _ReceivedTabScreenState();
}

class _ReceivedTabScreenState extends State<ReceivedTabScreen>
    with WidgetsBindingObserver {
  List<Map<String, dynamic>>? _transfers;
  bool _loading = true;
  String? _error;
  RealtimeChannel? _channel;
  Timer? _realtimeHealthTimer;
  DateTime _lastRealtimeSignalAt = DateTime.now().toUtc();
  late final VoidCallback _onConnectionChanged;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ConnectionStatus.instance.ensureStarted();
    _onConnectionChanged = () {
      if (!ConnectionStatus.instance.online.value) return;
      if (_error != null && mounted) {
        _loadTransfers();
      }
    };
    ConnectionStatus.instance.online.addListener(_onConnectionChanged);
    ContactAliases.ensureLoaded();
    ContactAliases.revision.addListener(_onAliasesChanged);
    _loadTransfers();
    _subscribeToRealtime();
    _startRealtimeHealthChecks();
  }

  void _onAliasesChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    ContactAliases.revision.removeListener(_onAliasesChanged);
    ConnectionStatus.instance.online.removeListener(_onConnectionChanged);
    WidgetsBinding.instance.removeObserver(this);
    _realtimeHealthTimer?.cancel();
    if (_channel != null) TransferService.unsubscribe(_channel!);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(ConnectionStatus.instance.refresh());
      _loadTransfers();
      _ensureRealtimeHealthy(forceResubscribe: true);
    }
  }

  void _subscribeToRealtime() {
    _lastRealtimeSignalAt = DateTime.now().toUtc();
    _channel = TransferService.subscribeToIncoming(
      userId: widget.identity.id,
      onTransferChange: (record, event) {
        _lastRealtimeSignalAt = DateTime.now().toUtc();
        _loadTransfers();
        if (!mounted) return;
        if (event == PostgresChangeEvent.insert) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Incoming transfer…')),
          );
          return;
        }
        final status = record['status'] as String? ?? 'pending';
        if (status == 'completed' || status == 'partial') {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                status == 'completed'
                    ? 'New files ready to download!'
                    : 'Some files are ready to download.',
              ),
            ),
          );
        }
      },
    );
  }

  void _startRealtimeHealthChecks() {
    _realtimeHealthTimer?.cancel();
    _realtimeHealthTimer = Timer.periodic(
        const Duration(seconds: 45), (_) => _ensureRealtimeHealthy());
  }

  Future<void> _ensureRealtimeHealthy(
      {bool forceResubscribe = false}) async {
    final staleFor =
        DateTime.now().toUtc().difference(_lastRealtimeSignalAt);
    final stale = staleFor > const Duration(minutes: 3);
    if (!forceResubscribe && !stale && _channel != null) return;

    final old = _channel;
    _channel = null;
    if (old != null) {
      await TransferService.unsubscribe(old);
    }
    if (!mounted) return;
    _subscribeToRealtime();
  }

  Future<void> _loadTransfers() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final transfers = await TransferService.getIncomingTransfers(
        widget.identity.id,
        page: 0,
      );
      if (mounted) {
        final active = transfers
            .where((t) => (t['status'] ?? 'pending') != 'expired')
            .toList();
        setState(() {
          _transfers = active;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Could not load transfers. Check your connection.';
          _loading = false;
        });
      }
    }
  }

  String _timeAgo(String isoDate) {
    final date = DateTime.tryParse(isoDate);
    if (date == null) return '';
    final diff = DateTime.now().toUtc().difference(date);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Scaffold(
      backgroundColor: c.paper,
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 12, 6),
              child: Row(
                children: [
                  if (Navigator.of(context).canPop())
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: IconButton(
                        icon: Icon(Icons.arrow_back_rounded,
                            color: c.ink, size: 22),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Incoming',
                            style:
                                MiniText.label.copyWith(color: c.inkSoft)),
                        const SizedBox(height: 4),
                        Text('Received',
                            style: MiniText.title.copyWith(color: c.ink)),
                      ],
                    ),
                  ),
                  if (_channel != null)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: const BoxDecoration(
                            color: MiniColors.success,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          'Live',
                          style: GoogleFonts.outfit(
                            fontSize: 11,
                            color: MiniColors.success,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: Icon(Icons.refresh_rounded,
                        color: c.inkFaint, size: 20),
                    onPressed: _loadTransfers,
                  ),
                ],
              ),
            ),
            const HairLine(indent: 20),

            // Content
            Expanded(
              child: _loading
                  ? ListView.builder(
                      physics: const NeverScrollableScrollPhysics(),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      itemCount: 5,
                      itemBuilder: (_, __) => const Padding(
                        padding: EdgeInsets.only(bottom: 6),
                        child: TransferTileSkeleton(),
                      ),
                    )
                  : _error != null
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(48),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(_error!,
                                    textAlign: TextAlign.center,
                                    style: MiniText.bodySoft
                                        .copyWith(color: c.inkSoft)),
                                const SizedBox(height: 20),
                                MiniButton(
                                  label: 'Retry',
                                  onPressed: _loadTransfers,
                                ),
                              ],
                            ),
                          ),
                        )
                      : _transfers == null || _transfers!.isEmpty
                          ? _buildEmpty(c)
                          : RefreshIndicator(
                              onRefresh: _loadTransfers,
                              color: MiniColors.blue500,
                              child: ListView.separated(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 12),
                                itemCount: _transfers!.length,
                                separatorBuilder: (_, __) =>
                                    const HairLine(indent: 0),
                                itemBuilder: (context, index) {
                                  final t = _transfers![index];
                                  final senderCode = t['sender_code'] ??
                                      (t['sender'] as Map?)?['short_code'] ??
                                      '???';
                                  final senderId =
                                      t['sender_id'] as String?;
                                  final status =
                                      (t['status'] ?? 'pending') as String;
                                  final createdAt =
                                      (t['created_at'] ?? '') as String;

                                  return _ReceivedTile(
                                    senderCode: senderCode.toString(),
                                    senderAlias:
                                        ContactAliases.aliasFor(senderId),
                                    roomName: t['room_name'] as String? ??
                                        (t['room_id'] != null ? 'room' : null),
                                    status: status,
                                    timeAgo: _timeAgo(createdAt),
                                    onEditAlias: senderId == null
                                        ? null
                                        : () => ContactAliasSheet.show(
                                              context,
                                              userId: senderId,
                                              code: senderCode.toString(),
                                            ),
                                    onTap: () => Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => ReceiveScreen(
                                          transferId: t['id'] as String,
                                          senderCode: senderCode.toString(),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty(MiniThemeExtension c) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: c.paperDeep,
              ),
              child: Icon(Icons.south_west_rounded, color: c.inkFaint),
            ),
            const SizedBox(height: 18),
            Text('Nothing here yet',
                style: MiniText.title.copyWith(color: c.ink)),
            const SizedBox(height: 6),
            Text(
              'Files sent to you will appear here.\nShare your code so others can send you files.',
              textAlign: TextAlign.center,
              style: MiniText.bodySoft.copyWith(color: c.inkSoft),
            ),
            if (_channel != null) ...[
              const SizedBox(height: 16),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 5,
                    height: 5,
                    decoration: const BoxDecoration(
                      color: MiniColors.success,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text('Listening for incoming files',
                      style: GoogleFonts.outfit(
                        fontSize: 11,
                        color: MiniColors.success,
                      )),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ReceivedTile extends StatelessWidget {
  final String senderCode;
  final String? senderAlias;

  /// Set when this transfer was shared through a room.
  final String? roomName;
  final String status;
  final String timeAgo;
  final VoidCallback onTap;
  final VoidCallback? onEditAlias;

  const _ReceivedTile({
    required this.senderCode,
    required this.status,
    required this.timeAgo,
    required this.onTap,
    this.senderAlias,
    this.roomName,
    this.onEditAlias,
  });

  Color get _tint {
    switch (status) {
      case 'completed':
        return MiniColors.success;
      case 'uploading':
      case 'pending':
        return MiniColors.warn;
      case 'partial':
      case 'failed':
        return MiniColors.danger;
      default:
        return MiniColors.inkFaint;
    }
  }

  String get _label {
    switch (status) {
      case 'completed':
        return 'Ready to download';
      case 'uploading':
        return 'Uploading…';
      case 'pending':
        return 'Pending';
      case 'partial':
        return 'Partial';
      case 'failed':
        return 'Failed';
      default:
        return status;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                gradient: LinearGradient(
                  colors: status == 'completed'
                      ? [MiniColors.blue200, MiniColors.blue50]
                      : [c.sand, c.paperDeep],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Icon(
                status == 'completed'
                    ? Icons.download_done_rounded
                    : Icons.south_west_rounded,
                size: 18,
                color: c.ink.withValues(alpha: 0.55),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('From ',
                          style: MiniText.bodySoft.copyWith(color: c.inkSoft)),
                      if (senderAlias != null) ...[
                        Flexible(
                          child: Text(
                            senderAlias!,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.outfit(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: c.ink,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(fmtCode(senderCode),
                            style: MiniText.codeSmall
                                .copyWith(color: c.inkFaint, fontSize: 11)),
                      ] else
                        Text(fmtCode(senderCode),
                            style: MiniText.codeSmall.copyWith(color: c.ink)),
                      if (onEditAlias != null) ...[
                        const SizedBox(width: 6),
                        GestureDetector(
                          onTap: onEditAlias,
                          child: Padding(
                            padding: const EdgeInsets.all(3),
                            child: Icon(
                              senderAlias != null
                                  ? Icons.edit_outlined
                                  : Icons.person_add_alt_outlined,
                              size: 14,
                              color: c.inkFaint,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Container(
                        width: 5,
                        height: 5,
                        decoration: BoxDecoration(
                          color: _tint,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(_label,
                          style: MiniText.small.copyWith(color: c.inkSoft)),
                      const SizedBox(width: 8),
                      Text(timeAgo,
                          style: MiniText.small.copyWith(color: c.inkFaint)),
                      if (roomName != null) ...[
                        const SizedBox(width: 8),
                        Flexible(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: MiniColors.blue50,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.groups_rounded,
                                    size: 11, color: MiniColors.blue600),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    roomName!,
                                    overflow: TextOverflow.ellipsis,
                                    style: GoogleFonts.outfit(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w500,
                                      color: MiniColors.blue600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: c.inkFaint, size: 20),
          ],
        ),
      ),
    );
  }
}
