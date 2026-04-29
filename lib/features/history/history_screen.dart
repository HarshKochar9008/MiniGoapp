import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide UserIdentity;

import '../../core/constants.dart';
import '../../core/network/connection_status.dart';
import '../../zensend/theme/zen_theme.dart';
import '../../zensend/widgets/zen_widgets.dart';
import '../identity/identity_service.dart';
import '../transfer/transfer_service.dart';

enum _HistoryFilter { all, received, sent }

class HistoryScreen extends StatefulWidget {
  final UserIdentity identity;
  const HistoryScreen({super.key, required this.identity});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<Map<String, dynamic>>? _transfers;
  bool _loading = true;
  String? _error;
  RealtimeChannel? _channel;
  int _currentPage = 0;
  bool _hasMore = true;
  _HistoryFilter _filter = _HistoryFilter.all;
  late final VoidCallback _onConnectionChanged;

  @override
  void initState() {
    super.initState();
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
  }

  @override
  void dispose() {
    ConnectionStatus.instance.online.removeListener(_onConnectionChanged);
    if (_channel != null) TransferService.unsubscribe(_channel!);
    super.dispose();
  }

  void _subscribeToRealtime() {
    _channel = TransferService.subscribeToIncoming(
      userId: widget.identity.id,
      onTransferChange: (record, event) {
        _loadTransfers();
        if (!mounted) return;
        if (event == PostgresChangeEvent.insert) {
          final status = record['status'] as String? ?? 'pending';
          final msg = status == 'completed'
              ? 'Transfer ready — files available for download!'
              : 'New file transfer incoming…';
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(msg)));
          return;
        }
        final status = record['status'] as String? ?? 'pending';
        if (status == 'completed' || status == 'partial') {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
              status == 'completed'
                  ? 'Transfer ready — files available for download!'
                  : 'Some files from a transfer are ready to download.',
            ),
          ));
        }
      },
    );
  }

  Future<void> _loadTransfers() async {
    setState(() {
      _loading = true;
      _error = null;
      _currentPage = 0;
    });
    try {
      final incoming = await TransferService.getIncomingTransfers(
          widget.identity.id, page: 0);
      final sent =
          await TransferService.getSentTransfers(widget.identity.id, page: 0);
      final transfers = _mergeAndSort(incoming, sent);
      if (mounted) {
        setState(() {
          _transfers = transfers;
          _loading = false;
          _hasMore = incoming.length >= AppConstants.transfersPageSize ||
              sent.length >= AppConstants.transfersPageSize;
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

  Future<void> _loadMore() async {
    if (!_hasMore) return;
    final nextPage = _currentPage + 1;
    try {
      final moreIncoming = await TransferService.getIncomingTransfers(
          widget.identity.id, page: nextPage);
      final moreSent = await TransferService.getSentTransfers(
          widget.identity.id, page: nextPage);
      final more = _mergeAndSort(moreIncoming, moreSent);
      if (mounted) {
        setState(() {
          _transfers = _mergeSorted(_transfers ?? [], more);
          _currentPage = nextPage;
          _hasMore =
              moreIncoming.length >= AppConstants.transfersPageSize ||
                  moreSent.length >= AppConstants.transfersPageSize;
        });
      }
    } catch (_) {}
  }

  List<Map<String, dynamic>> _mergeAndSort(
    List<Map<String, dynamic>> incoming,
    List<Map<String, dynamic>> sent,
  ) {
    final all = [
      ...incoming.map((t) => {
            ...t,
            '_direction': 'received',
            '_counterpartyCode':
                (t['sender'] as Map?)?['short_code'] ?? '???',
          }),
      ...sent.map((t) => {
            ...t,
            '_direction': 'sent',
            '_counterpartyCode':
                (t['receiver'] as Map?)?['short_code'] ?? '???',
          }),
    ];
    all.sort((a, b) {
      final aDate =
          DateTime.tryParse((a['created_at'] ?? '').toString());
      final bDate =
          DateTime.tryParse((b['created_at'] ?? '').toString());
      if (aDate == null && bDate == null) return 0;
      if (aDate == null) return 1;
      if (bDate == null) return -1;
      return bDate.compareTo(aDate);
    });
    return all;
  }

  List<Map<String, dynamic>> _mergeSorted(
    List<Map<String, dynamic>> existing,
    List<Map<String, dynamic>> more,
  ) {
    final byId = <String, Map<String, dynamic>>{};
    for (final t in [...existing, ...more]) {
      final id = (t['id'] ?? '').toString();
      if (id.isNotEmpty) byId[id] = t;
    }
    final merged = byId.values.toList();
    merged.sort((a, b) {
      final aDate =
          DateTime.tryParse((a['created_at'] ?? '').toString());
      final bDate =
          DateTime.tryParse((b['created_at'] ?? '').toString());
      if (aDate == null && bDate == null) return 0;
      if (aDate == null) return 1;
      if (bDate == null) return -1;
      return bDate.compareTo(aDate);
    });
    return merged;
  }

  List<Map<String, dynamic>> _applyFilter(
      List<Map<String, dynamic>> transfers) {
    switch (_filter) {
      case _HistoryFilter.sent:
        return transfers
            .where((t) => t['_direction'] == 'sent')
            .toList();
      case _HistoryFilter.received:
        return transfers
            .where((t) => t['_direction'] == 'received')
            .toList();
      case _HistoryFilter.all:
        return transfers;
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
    return Scaffold(
      backgroundColor: ZenColors.paper,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
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
                        Text('Transfers', style: ZenText.label),
                        const SizedBox(height: 4),
                        Text('History', style: ZenText.title),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh_rounded,
                        color: ZenColors.inkFaint, size: 20),
                    onPressed: _loadTransfers,
                  ),
                ],
              ),
            ),
            const HairLine(indent: 20),

            // Filter pills
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: ZenColors.paperDeep,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    for (final entry in [
                      ['All', _HistoryFilter.all],
                      ['Received', _HistoryFilter.received],
                      ['Sent', _HistoryFilter.sent],
                    ])
                      Expanded(
                        child: ZenTabPill(
                          label: entry[0] as String,
                          active: _filter == entry[1],
                          onTap: () => setState(
                              () => _filter = entry[1] as _HistoryFilter),
                        ),
                      ),
                  ],
                ),
              ),
            ),

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
                                    style: ZenText.bodySoft),
                                const SizedBox(height: 20),
                                ZenButton(
                                    label: 'Retry',
                                    onPressed: _loadTransfers),
                              ],
                            ),
                          ),
                        )
                      : _transfers == null ||
                              _applyFilter(_transfers!).isEmpty
                          ? _buildEmpty()
                          : RefreshIndicator(
                              onRefresh: _loadTransfers,
                              color: ZenColors.blue500,
                              child: Builder(builder: (context) {
                                final visible =
                                    _applyFilter(_transfers!);
                                return ListView.builder(
                                  itemCount:
                                      visible.length + (_hasMore ? 1 : 0),
                                  itemBuilder: (context, index) {
                                    if (index == visible.length) {
                                      _loadMore();
                                      return const Center(
                                        child: Padding(
                                          padding: EdgeInsets.all(16),
                                          child: SizedBox(
                                            width: 18,
                                            height: 18,
                                            child:
                                                CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: ZenColors.blue500,
                                            ),
                                          ),
                                        ),
                                      );
                                    }
                                    final t = visible[index];
                                    final dir = (t['_direction'] ??
                                            'received')
                                        .toString();
                                    final code = (t['_counterpartyCode'] ??
                                            '???')
                                        .toString();
                                    final status = (t['status'] ?? 'pending')
                                        .toString();
                                    final createdAt =
                                        (t['created_at'] ?? '').toString();
                                    final isExpired = status == 'expired';

                                    return Column(
                                      children: [
                                        _HistoryTile(
                                          direction: dir,
                                          counterpartyCode: code,
                                          status: status,
                                          timeAgo: _timeAgo(createdAt),
                                          isExpired: isExpired,
                                        ),
                                        const HairLine(indent: 72),
                                      ],
                                    );
                                  },
                                );
                              }),
                            ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    final title = switch (_filter) {
      _HistoryFilter.sent => 'No files sent yet',
      _HistoryFilter.received => 'No files received yet',
      _HistoryFilter.all => 'No transfers yet',
    };
    final subtitle = switch (_filter) {
      _HistoryFilter.sent => 'Send files to see them here',
      _HistoryFilter.received =>
        'Share your code so others can send you files',
      _HistoryFilter.all =>
        'Your sent and received files will appear here',
    };
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.inbox_outlined,
              size: 48, color: ZenColors.inkFaint),
          const SizedBox(height: 18),
          Text(title, style: ZenText.title),
          const SizedBox(height: 6),
          Text(subtitle,
              textAlign: TextAlign.center, style: ZenText.bodySoft),
        ],
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  final String direction;
  final String counterpartyCode;
  final String status;
  final String timeAgo;
  final bool isExpired;

  const _HistoryTile({
    required this.direction,
    required this.counterpartyCode,
    required this.status,
    required this.timeAgo,
    this.isExpired = false,
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
      case 'expired':
        return ZenColors.inkFaint;
      default:
        return ZenColors.inkFaint;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isOut = direction == 'sent';
    return Opacity(
      opacity: isExpired ? 0.45 : 1.0,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                gradient: LinearGradient(
                  colors: isOut
                      ? [ZenColors.blue200, ZenColors.blue50]
                      : [ZenColors.sand, ZenColors.paperDeep],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Icon(
                isOut ? Icons.north_east_rounded : Icons.south_west_rounded,
                size: 16,
                color: ZenColors.ink.withOpacity(0.55),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(isOut ? 'To ' : 'From ', style: ZenText.bodySoft),
                      Text(fmtCode(counterpartyCode),
                          style: ZenText.codeSmall
                              .copyWith(color: ZenColors.ink)),
                    ],
                  ),
                  const SizedBox(height: 3),
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
                      Text(
                        isExpired
                            ? 'Expired'
                            : '${isOut ? 'Sent' : 'Received'} · $status',
                        style: ZenText.small,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Text(timeAgo, style: ZenText.small),
          ],
        ),
      ),
    );
  }
}
