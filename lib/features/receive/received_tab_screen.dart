import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide UserIdentity;

import '../../core/network/connection_status.dart';
import '../../zensend/theme/zen_theme.dart';
import '../../zensend/widgets/zen_widgets.dart';
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
    _loadTransfers();
    _subscribeToRealtime();
    _startRealtimeHealthChecks();
  }

  @override
  void dispose() {
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
    final c = context.zen;
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
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Incoming',
                            style:
                                ZenText.label.copyWith(color: c.inkSoft)),
                        const SizedBox(height: 4),
                        Text('Received',
                            style: ZenText.title.copyWith(color: c.ink)),
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
                            color: ZenColors.success,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          'Live',
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            color: ZenColors.success,
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
                  ? const Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: ZenColors.blue500,
                        ),
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
                                    style: ZenText.bodySoft
                                        .copyWith(color: c.inkSoft)),
                                const SizedBox(height: 20),
                                ZenButton(
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
                              color: ZenColors.blue500,
                              child: ListView.separated(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 12),
                                itemCount: _transfers!.length,
                                separatorBuilder: (_, __) =>
                                    const HairLine(indent: 0),
                                itemBuilder: (context, index) {
                                  final t = _transfers![index];
                                  final senderCode = (t['sender']
                                              as Map?)?['short_code'] ??
                                          '???';
                                  final status =
                                      (t['status'] ?? 'pending') as String;
                                  final createdAt =
                                      (t['created_at'] ?? '') as String;

                                  return _ReceivedTile(
                                    senderCode: senderCode.toString(),
                                    status: status,
                                    timeAgo: _timeAgo(createdAt),
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

  Widget _buildEmpty(ZenThemeExtension c) {
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
                style: ZenText.title.copyWith(color: c.ink)),
            const SizedBox(height: 6),
            Text(
              'Files sent to you will appear here.\nShare your code so others can send you files.',
              textAlign: TextAlign.center,
              style: ZenText.bodySoft.copyWith(color: c.inkSoft),
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
                      color: ZenColors.success,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text('Listening for incoming files',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        color: ZenColors.success,
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
  final String status;
  final String timeAgo;
  final VoidCallback onTap;

  const _ReceivedTile({
    required this.senderCode,
    required this.status,
    required this.timeAgo,
    required this.onTap,
  });

  Color get _tint {
    switch (status) {
      case 'completed':
        return ZenColors.success;
      case 'uploading':
      case 'pending':
        return ZenColors.warn;
      case 'partial':
      case 'failed':
        return ZenColors.danger;
      default:
        return ZenColors.inkFaint;
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
    final c = context.zen;
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
                      ? [ZenColors.blue200, ZenColors.blue50]
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
                color: c.ink.withOpacity(0.55),
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
                          style: ZenText.bodySoft.copyWith(color: c.inkSoft)),
                      Text(fmtCode(senderCode),
                          style: ZenText.codeSmall.copyWith(color: c.ink)),
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
                          style: ZenText.small.copyWith(color: c.inkSoft)),
                      const SizedBox(width: 8),
                      Text(timeAgo,
                          style: ZenText.small.copyWith(color: c.inkFaint)),
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
