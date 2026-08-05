import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide UserIdentity;

import 'package:google_fonts/google_fonts.dart';

import '../../core/analytics/analytics.dart';
import '../../core/constants.dart';
import '../../core/contacts/contact_aliases.dart';
import '../../core/network/connection_status.dart';
import '../../Minigo/theme/mini_theme.dart';
import '../../Minigo/widgets/mini_widgets.dart';
import '../contacts/contact_alias_sheet.dart';
import '../identity/identity_service.dart';
import '../transfer/transfer_service.dart';

enum _HistoryFilter { all, received, sent }

/// Top-level split: person-to-person transfers vs transfers through rooms.
enum _HistorySource { direct, rooms }

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
  _HistorySource _source = _HistorySource.direct;
  late final VoidCallback _onConnectionChanged;
  final Set<String> _hiddenIds = <String>{};

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
    ContactAliases.ensureLoaded();
    ContactAliases.revision.addListener(_onAliasesChanged);
    _loadTransfers();
    _subscribeToRealtime();
  }

  void _onAliasesChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    ContactAliases.revision.removeListener(_onAliasesChanged);
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
          widget.identity.id,
          page: 0);
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
          widget.identity.id,
          page: nextPage);
      final moreSent = await TransferService.getSentTransfers(
          widget.identity.id,
          page: nextPage);
      final more = _mergeAndSort(moreIncoming, moreSent);
      if (mounted) {
        setState(() {
          _transfers = _mergeSorted(_transfers ?? [], more);
          _currentPage = nextPage;
          _hasMore = moreIncoming.length >= AppConstants.transfersPageSize ||
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
            '_counterpartyCode': t['sender_code'] ??
                (t['sender'] as Map?)?['short_code'] ??
                '???',
            '_counterpartyId': t['sender_id'],
          }),
      ...sent.map((t) => {
            ...t,
            '_direction': 'sent',
            '_counterpartyCode': t['receiver_code'] ??
                (t['receiver'] as Map?)?['short_code'] ??
                '???',
            '_counterpartyId': t['receiver_id'],
          }),
    ];
    all.sort((a, b) {
      final aDate = DateTime.tryParse((a['created_at'] ?? '').toString());
      final bDate = DateTime.tryParse((b['created_at'] ?? '').toString());
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
      final aDate = DateTime.tryParse((a['created_at'] ?? '').toString());
      final bDate = DateTime.tryParse((b['created_at'] ?? '').toString());
      if (aDate == null && bDate == null) return 0;
      if (aDate == null) return 1;
      if (bDate == null) return -1;
      return bDate.compareTo(aDate);
    });
    return merged;
  }

  /// Room transfers keep their denormalized room_name even after the room
  /// row is deleted (room_id goes NULL then), so check both.
  static bool _isRoomTransfer(Map<String, dynamic> t) =>
      t['room_id'] != null || t['room_name'] != null;

  List<Map<String, dynamic>> _applyFilter(
      List<Map<String, dynamic>> transfers) {
    final visible = transfers
        .where((t) => !_hiddenIds.contains((t['id'] ?? '').toString()))
        .where((t) => _source == _HistorySource.rooms
            ? _isRoomTransfer(t)
            : !_isRoomTransfer(t))
        .toList();
    switch (_filter) {
      case _HistoryFilter.sent:
        return visible.where((t) => t['_direction'] == 'sent').toList();
      case _HistoryFilter.received:
        return visible.where((t) => t['_direction'] == 'received').toList();
      case _HistoryFilter.all:
        return visible;
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
                        Text('Transfers',
                            style: MiniText.label.copyWith(color: c.inkSoft)),
                        const SizedBox(height: 4),
                        Text('History',
                            style: MiniText.title.copyWith(color: c.ink)),
                      ],
                    ),
                  ),
                  IconButton(
                    icon:
                        Icon(Icons.refresh_rounded, color: c.inkSoft, size: 21),
                    onPressed: _loadTransfers,
                  ),
                ],
              ),
            ),

            // Direct / Rooms tabs
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Row(
                children: [
                  _SourceTab(
                    icon: Icons.swap_horiz_rounded,
                    label: 'Direct',
                    active: _source == _HistorySource.direct,
                    onTap: () =>
                        setState(() => _source = _HistorySource.direct),
                  ),
                  const SizedBox(width: 22),
                  _SourceTab(
                    icon: Icons.groups_outlined,
                    label: 'Rooms',
                    active: _source == _HistorySource.rooms,
                    onTap: () => setState(() => _source = _HistorySource.rooms),
                  ),
                ],
              ),
            ),

            // Filter pills
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: c.sand,
                  borderRadius: BorderRadius.circular(MiniRadius.pill),
                ),
                child: Row(
                  children: [
                    for (final entry in [
                      ['All', _HistoryFilter.all],
                      ['Received', _HistoryFilter.received],
                      ['Sent', _HistoryFilter.sent],
                    ])
                      Expanded(
                        child: MiniTabPill(
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
                  ? ListView.builder(
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: 6,
                      itemBuilder: (_, __) => const Padding(
                        padding: EdgeInsets.symmetric(vertical: 2),
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
                                    label: 'Retry', onPressed: _loadTransfers),
                              ],
                            ),
                          ),
                        )
                      : _transfers == null || _applyFilter(_transfers!).isEmpty
                          // The current tab may be empty only because its
                          // transfers sit on pages not fetched yet — keep
                          // paging before declaring it empty.
                          ? (_transfers != null && _hasMore
                              ? Builder(builder: (context) {
                                  _loadMore();
                                  return ListView.builder(
                                    physics:
                                        const NeverScrollableScrollPhysics(),
                                    itemCount: 3,
                                    itemBuilder: (_, __) =>
                                        const TransferTileSkeleton(),
                                  );
                                })
                              : _buildEmpty(c))
                          : RefreshIndicator(
                              onRefresh: _loadTransfers,
                              color: c.accent,
                              child: Builder(builder: (context) {
                                final visible = _applyFilter(_transfers!);
                                return ListView.builder(
                                  itemCount:
                                      visible.length + (_hasMore ? 1 : 0),
                                  itemBuilder: (context, index) {
                                    if (index == visible.length) {
                                      _loadMore();
                                      return const TransferTileSkeleton();
                                    }
                                    final t = visible[index];
                                    final dir = (t['_direction'] ?? 'received')
                                        .toString();
                                    final code =
                                        (t['_counterpartyCode'] ?? '???')
                                            .toString();
                                    final counterpartyId =
                                        t['_counterpartyId'] as String?;
                                    final roomLabel = t['room_name']
                                            as String? ??
                                        (t['room_id'] != null ? 'room' : null);
                                    final status =
                                        (t['status'] ?? 'pending').toString();
                                    final createdAt =
                                        (t['created_at'] ?? '').toString();
                                    final isExpired = status == 'expired';
                                    final id = (t['id'] ?? '').toString();
                                    final canDismiss = status == 'completed' ||
                                        status == 'expired' ||
                                        status == 'failed' ||
                                        status == 'partial';

                                    final tile = Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                          16, 5, 16, 5),
                                      child: _HistoryTile(
                                        direction: dir,
                                        counterpartyCode: code,
                                        counterpartyAlias:
                                            ContactAliases.aliasFor(
                                                counterpartyId),
                                        status: status,
                                        timeAgo: _timeAgo(createdAt),
                                        isExpired: isExpired,
                                        roomLabel: roomLabel,
                                        onEditAlias: counterpartyId == null
                                            ? null
                                            : () => ContactAliasSheet.show(
                                                  context,
                                                  userId: counterpartyId,
                                                  code: code,
                                                ),
                                      ),
                                    );
                                    if (!canDismiss || id.isEmpty) {
                                      return tile;
                                    }
                                    return Dismissible(
                                      key: ValueKey('history-$id'),
                                      direction: DismissDirection.endToStart,
                                      background: Container(
                                        alignment: Alignment.centerRight,
                                        margin: const EdgeInsets.fromLTRB(
                                            16, 5, 16, 5),
                                        padding:
                                            const EdgeInsets.only(right: 24),
                                        decoration: BoxDecoration(
                                          color: MiniColors.danger
                                              .withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(
                                              MiniRadius.tile),
                                        ),
                                        child: const Icon(
                                          Icons.delete_rounded,
                                          color: MiniColors.danger,
                                          size: 22,
                                        ),
                                      ),
                                      onDismissed: (_) {
                                        HapticFeedback.mediumImpact();
                                        setState(() {
                                          _hiddenIds.add(id);
                                        });
                                      },
                                      child: tile,
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

  Widget _buildEmpty(MiniThemeExtension c) {
    final inRooms = _source == _HistorySource.rooms;
    final title = switch (_filter) {
      _HistoryFilter.sent =>
        inRooms ? 'No files sent in rooms yet' : 'No files sent yet',
      _HistoryFilter.received =>
        inRooms ? 'No files received in rooms yet' : 'No files received yet',
      _HistoryFilter.all =>
        inRooms ? 'No room transfers yet' : 'No direct transfers yet',
    };
    final subtitle = inRooms
        ? 'Files shared in rooms will appear here, '
            'even after the room expires.'
        : switch (_filter) {
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
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: c.accent.withValues(alpha: 0.12),
            ),
            child: Icon(inRooms ? Icons.groups_rounded : Icons.inbox_rounded,
                size: 30, color: c.accent),
          ),
          const SizedBox(height: 20),
          Text(title, style: MiniText.title.copyWith(color: c.ink)),
          const SizedBox(height: 8),
          Text(subtitle,
              textAlign: TextAlign.center,
              style: MiniText.bodySoft.copyWith(color: c.inkSoft)),
        ],
      ),
    );
  }
}

/// Underlined scope tab (Direct / Rooms) — visually distinct from the
/// direction filter pills below it.
class _SourceTab extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _SourceTab({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    final color = active ? c.accent : c.inkFaint;
    return InkWell(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      borderRadius: BorderRadius.circular(MiniRadius.pill),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 17, color: color),
                const SizedBox(width: 7),
                Text(
                  label,
                  style: GoogleFonts.outfit(
                    fontSize: 15,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                    letterSpacing: -0.2,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 3),
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            height: 3,
            width: active ? 44 : 0,
            decoration: BoxDecoration(
              color: c.accent,
              borderRadius: BorderRadius.circular(MiniRadius.pill),
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  final String direction;
  final String counterpartyCode;
  final String? counterpartyAlias;
  final String status;
  final String timeAgo;
  final bool isExpired;

  /// Room name (or 'room' fallback) when sent/received through a room.
  final String? roomLabel;
  final VoidCallback? onEditAlias;

  const _HistoryTile({
    required this.direction,
    required this.counterpartyCode,
    required this.status,
    required this.timeAgo,
    this.counterpartyAlias,
    this.isExpired = false,
    this.roomLabel,
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
      case 'expired':
        return MiniColors.inkFaint;
      default:
        return MiniColors.inkFaint;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    final isOut = direction == 'sent';
    return Opacity(
      opacity: isExpired ? 0.45 : 1.0,
      child: Container(
        decoration: miniCard(context, radius: MiniRadius.tile),
        padding: const EdgeInsets.fromLTRB(14, 13, 16, 13),
        child: Row(
          children: [
            MiniIconPlate(
              icon: isOut ? Icons.north_east_rounded : Icons.south_west_rounded,
              tint: isOut ? c.accent : MiniColors.success,
              size: 40,
              iconSize: 19,
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(isOut ? 'To ' : 'From ',
                          style: MiniText.bodySoft.copyWith(color: c.inkSoft)),
                      if (counterpartyAlias != null) ...[
                        Flexible(
                          child: GestureDetector(
                            onLongPress: onEditAlias,
                            child: Text(
                              counterpartyAlias!,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.outfit(
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                                letterSpacing: -0.2,
                                color: c.ink,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      GestureDetector(
                        onLongPress: onEditAlias,
                        onTap: () {
                          Clipboard.setData(
                              ClipboardData(text: counterpartyCode));
                          HapticFeedback.selectionClick();
                          Analytics.instance.logEvent(
                              AnalyticsEvents.codeCopied,
                              {'source': 'history'});
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content:
                                  Text('Copied ${fmtCode(counterpartyCode)}'),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        },
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(fmtCode(counterpartyCode),
                                style: counterpartyAlias != null
                                    ? MiniText.codeSmall.copyWith(
                                        color: c.inkFaint, fontSize: 11)
                                    : MiniText.codeSmall
                                        .copyWith(color: c.ink)),
                            const SizedBox(width: 4),
                            Icon(Icons.copy_rounded,
                                size: 11, color: c.inkFaint),
                          ],
                        ),
                      ),
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
                        (isExpired
                                ? 'Expired'
                                : '${isOut ? 'Sent' : 'Received'} · $status') +
                            (roomLabel != null ? ' · $roomLabel' : ''),
                        style: MiniText.small.copyWith(color: c.inkSoft),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Text(timeAgo, style: MiniText.small.copyWith(color: c.inkSoft)),
          ],
        ),
      ),
    );
  }
}
