import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/constants.dart';
import '../../core/contacts/contact_aliases.dart';
import '../../core/native/native_share.dart';
import '../../core/time/server_clock.dart';
import '../../Minigo/theme/mini_theme.dart';
import '../../Minigo/widgets/mini_code_reel.dart';
import '../../Minigo/widgets/mini_widgets.dart';
import '../contacts/contact_alias_sheet.dart';
import '../identity/identity_service.dart';
import '../qr/qr_widgets.dart';
import 'room_lifecycle.dart';
import 'room_realtime_link.dart';
import 'room_send_screen.dart';
import 'room_service.dart';
import '../../Minigo/theme/mini_icons.dart';

class RoomDetailScreen extends StatefulWidget {
  final UserIdentity identity;
  final Room room;
  const RoomDetailScreen({
    super.key,
    required this.identity,
    required this.room,
  });

  @override
  State<RoomDetailScreen> createState() => _RoomDetailScreenState();
}

class _RoomDetailScreenState extends State<RoomDetailScreen>
    with WidgetsBindingObserver {
  List<RoomMember> _members = [];
  bool _loading = true;

  /// Last member-list load failed (shown with a retry that reloads).
  String? _error;

  /// At least one member-list load succeeded, so [_members] is the server's
  /// answer rather than the empty placeholder.
  bool _loadedOnce = false;

  /// Leave / close in flight, and its own failure — kept apart from [_error]
  /// so retrying a failed leave retries the leave, not a reload.
  bool _leaving = false;
  String? _leaveError;

  /// The room row was deleted while this screen was open (host closed it, or
  /// the expiry sweep removed it). Handled once.
  bool _ended = false;

  /// The send screen pushed from here, while it is open.
  Route<void>? _sendRoute;

  bool get _isOwner => widget.room.isOwnedBy(widget.identity.id);

  /// Server time says the room is past its `expires_at`. Until the sweep
  /// deletes it the room still exists, but nobody can join, share, or change
  /// permissions in it.
  bool get _isExpired => widget.room.isExpired;

  /// Whether I'm in the member list the server returned. Not being in it
  /// means I left or was removed elsewhere.
  bool get _isMember =>
      !_loadedOnce || _members.any((m) => m.userId == widget.identity.id);

  /// Whether the host allows me to share files. Not being in the list means
  /// no: the server refuses room sends from non-members.
  bool get _iCanShare => canShareInRoom(_members, widget.identity.id);

  Timer? _expiryTicker;
  Timer? _expiryAlarm;
  RoomRealtimeLink? _link;
  Timer? _liveReloadDebounce;
  final _reloads = LiveReloadGate();

  /// Host only: people blocked here who have since left (they can't be
  /// unblocked with a switch — they have no member row).
  List<RoomBlockedUser> _blocked = [];
  final _unblockPending = <String>{};

  bool _presenceCheckInFlight = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ContactAliases.ensureLoaded();
    ContactAliases.revision.addListener(_onAliasesChanged);
    // Keep the countdown fresh, and flip to the expired state on time rather
    // than up to one tick late.
    _expiryTicker = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _onExpiryTick(),
    );
    final left = widget.room.timeLeft;
    if (left > Duration.zero) {
      _expiryAlarm = Timer(left + const Duration(seconds: 1), _onExpiryTick);
    }
    _loadMembers();
    final roomId = widget.room.id;
    _link = RoomRealtimeLink(
      connect: (onStatus) => RoomService.subscribeToRoom(
        roomId: roomId,
        onMembersChanged: _onLiveChange,
        onRoomDeleted: _onRoomDisbanded,
        onStatus: onStatus,
      ),
      // Live again after a drop: member changes — or the room's deletion —
      // sent meanwhile were lost. The reload catches both (see
      // _checkPresence).
      onResync: _requestReload,
    )..start();
  }

  /// Back from the background: the socket may have been down the whole
  /// time, the room may have expired or been deleted meanwhile, and the
  /// device clock may have been changed.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted) return;
    unawaited(ServerClock.instance.refresh());
    setState(() {}); // re-evaluate expiry now, not at the next tick
    _requestReload();
  }

  /// A silent reload now, or — if one is in flight — right after it.
  void _requestReload() {
    if (mounted && _reloads.requestReload()) _loadMembers(silent: true);
  }

  void _onAliasesChanged() {
    if (mounted) setState(() {});
  }

  void _onExpiryTick() {
    if (!mounted) return;
    setState(() {});
    if (_isExpired) {
      _expiryTicker?.cancel();
      _expiryAlarm?.cancel();
    }
  }

  /// Collapses bursts of member events into one silent reload. An event that
  /// lands during a load is queued, not dropped.
  void _onLiveChange() {
    _liveReloadDebounce?.cancel();
    _liveReloadDebounce = Timer(
      const Duration(milliseconds: 400),
      _requestReload,
    );
  }

  /// The room row was deleted while we were looking at it — by the host, or
  /// by the expiry sweep. Server time tells the two apart.
  void _onRoomDisbanded() {
    if (!mounted || _leaving || _ended) return;
    _ended = true;
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    final navigator = Navigator.of(context);

    // The send screen stops its own send and says why; popping it (which
    // ignores its PopScope) would throw away the per-member results. Take
    // this dead room out from under it instead, so its Done lands on the
    // rooms list.
    final sendRoute = _sendRoute;
    if (sendRoute != null && sendRoute.isActive) {
      navigator.removeRoute(route);
      return;
    }

    final reason = roomEndReason(
      expiresAt: widget.room.expiresAt,
      serverNow: ServerClock.instance.now(),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(roomEndMessage(reason, isOwner: _isOwner)),
        behavior: SnackBarBehavior.floating,
      ),
    );
    // A bare pop() would close whatever is on top — a dialog, the QR sheet —
    // and leave this dead room showing underneath. Everything above this
    // route belongs to the room, so close it all.
    navigator.popUntil((r) => r == route);
    navigator.pop();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _expiryTicker?.cancel();
    _expiryAlarm?.cancel();
    _liveReloadDebounce?.cancel();
    _link?.dispose();
    ContactAliases.revision.removeListener(_onAliasesChanged);
    super.dispose();
  }

  Color get _expiryTint {
    if (_isExpired) return MiniColors.danger;
    return widget.room.timeLeft.inMinutes < 10
        ? MiniColors.warn
        : context.mini.inkFaint;
  }

  void _showQr() {
    HapticFeedback.selectionClick();
    QrCodeSheet.show(
      context,
      widget.room.code,
      forRoom: true,
      shareText: _shareMessage,
      shareSubject: _shareSubject,
    );
  }

  Future<void> _openRoomSend() async {
    HapticFeedback.selectionClick();
    final recipients =
        _members.where((m) => m.userId != widget.identity.id).toList();
    final route = MaterialPageRoute<void>(
      builder: (_) => RoomSendScreen(
        identity: widget.identity,
        room: widget.room,
        recipients: recipients,
      ),
    );
    _sendRoute = route;
    await Navigator.push(context, route);
    if (identical(_sendRoute, route)) _sendRoute = null;
  }

  Future<void> _loadMembers({bool silent = false}) async {
    final generation = _reloads.begin();
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    // The host's blocked-and-left list rides along; it never throws.
    final blocksFuture = _isOwner && !_isExpired
        ? _fetchBlocks()
        : Future<List<RoomBlockedUser>?>.value(const []);
    try {
      final members = await RoomService.listMembers(widget.room.id);
      final blocks = await blocksFuture;
      if (!mounted || !_reloads.isCurrent(generation)) return;
      setState(() {
        // A permission write still in flight keeps its optimistic value; its
        // own realtime event reloads again once it lands.
        _members = [
          for (final m in members)
            _sharePending.containsKey(m.userId)
                ? m.withCanShare(_sharePending[m.userId]!)
                : m,
        ];
        if (blocks != null) _blocked = blocks;
        _loading = false;
        _loadedOnce = true;
        _error = null;
      });
      // Not in my own room's member list: I left elsewhere, was removed, or
      // the room is gone — the last one may be a deletion this screen never
      // heard about (socket down, app in background).
      if (!members.any((m) => m.userId == widget.identity.id)) {
        unawaited(_checkPresence());
      }
    } catch (_) {
      if (!mounted || !_reloads.isCurrent(generation)) return;
      // Keep showing the last good list — unless a foreground load is
      // waiting on this one, which must not spin forever.
      if (silent && !_loading) return;
      setState(() {
        _error = 'Could not load members. Check your connection.';
        _loading = false;
      });
    } finally {
      if (_reloads.end() && mounted) _loadMembers(silent: true);
    }
  }

  /// Null when the list is unavailable (RPC not deployed, offline): keep
  /// showing the last one.
  Future<List<RoomBlockedUser>?> _fetchBlocks() async {
    try {
      return await RoomService.listBlockedUsers(widget.room.id);
    } catch (_) {
      return null;
    }
  }

  /// Asks the server whether this room still exists, after a reload found me
  /// missing from it. A deleted room gets the same handling as its delete
  /// event.
  Future<void> _checkPresence() async {
    if (_presenceCheckInFlight || _ended || _leaving) return;
    _presenceCheckInFlight = true;
    try {
      final presence = await RoomService.roomPresence(widget.room.id);
      if (!mounted) return;
      // Without room_presence (20261113000005 not applied) "gone" and
      // "removed" look alike: an empty list means the room is over for me
      // either way.
      if (presence == RoomPresence.gone ||
          (presence == null && _members.isEmpty)) {
        _onRoomDisbanded();
      } else if (presence == RoomPresence.expired) {
        setState(() {});
      }
    } catch (_) {
      // Offline: the next reload asks again.
    } finally {
      _presenceCheckInFlight = false;
    }
  }

  String _blockedName(RoomBlockedUser user) =>
      ContactAliases.aliasFor(user.userId) ?? user.displayName;

  Future<void> _unblock(RoomBlockedUser user) async {
    if (!_isOwner || _isExpired || !_unblockPending.add(user.userId)) return;
    HapticFeedback.selectionClick();
    setState(() {});
    final messenger = ScaffoldMessenger.of(context);
    void say(String text) =>
        messenger.showSnackBar(SnackBar(content: Text(text)));
    try {
      await RoomService.unblockUser(
        roomId: widget.room.id,
        userId: user.userId,
      );
      if (!mounted) return;
      setState(() {
        _blocked = _blocked.where((b) => b.userId != user.userId).toList();
      });
      say('${_blockedName(user)} can share again if they rejoin.');
    } on RoomMemberPresentException {
      // They rejoined meanwhile: the member switch is the way now.
      say('${_blockedName(user)} is back in the room — use their switch.');
      _requestReload();
    } on RoomExpiredException {
      say('This room has expired.');
    } catch (_) {
      say('Could not unblock. Check your connection.');
    } finally {
      _unblockPending.remove(user.userId);
      if (mounted) setState(() {});
    }
  }

  /// Members with a can_share write in flight, and the value being written —
  /// a second tap waits it out, so an older request's rollback can never undo
  /// a newer toggle.
  final _sharePending = <String, bool>{};

  Future<void> _toggleMemberShare(RoomMember member, bool value) async {
    if (!_isOwner || _isExpired) return;
    final idx = _members.indexWhere((m) => m.userId == member.userId);
    if (idx == -1 || _sharePending.containsKey(member.userId)) return;
    _sharePending[member.userId] = value;
    HapticFeedback.selectionClick();
    setState(() => _members[idx] = member.withCanShare(value));
    try {
      await RoomService.setMemberCanShare(
        roomId: widget.room.id,
        userId: member.userId,
        canShare: value,
      );
    } catch (e) {
      if (!mounted) return;
      // Look up again: a realtime reload may have replaced the list meanwhile.
      final now = _members.indexWhere((m) => m.userId == member.userId);
      setState(() {
        if (now != -1) _members[now] = _members[now].withCanShare(!value);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e is RoomExpiredException
              ? 'This room has expired.'
              : 'Could not update permission'),
        ),
      );
    } finally {
      _sharePending.remove(member.userId);
    }
  }

  void _copyCode() {
    Clipboard.setData(ClipboardData(text: widget.room.code));
    HapticFeedback.selectionClick();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Room code copied')),
    );
  }

  static const _shareSubject = 'MiniGo room invite';

  String get _shareMessage =>
      'Join my room "${widget.room.name}" on MiniGo with code: '
      '${widget.room.code}';

  void _shareCode() {
    HapticFeedback.selectionClick();
    NativeShareService.shareText(_shareMessage, subject: _shareSubject);
  }

  Future<void> _leaveRoom() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_isOwner ? 'Close this room?' : 'Leave this room?'),
        content: Text(
          _isOwner
              ? 'You are the host. Closing the room removes it for all '
                  '${_members.length} member(s).'
              : 'You can rejoin later with the room code.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: MiniColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(_isOwner ? 'Close room' : 'Leave'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _performLeave();
  }

  /// The leave itself, after confirmation. Also the retry for a failed one.
  Future<void> _performLeave() async {
    if (_leaving) return;
    setState(() {
      _leaving = true;
      _leaveError = null;
    });
    try {
      await RoomService.leaveRoom(
        room: widget.room,
        userId: widget.identity.id,
      );
      if (!mounted) return;
      HapticFeedback.lightImpact();
      Navigator.pop(context);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _leaving = false;
        _leaveError = _isOwner
            ? 'Could not close the room. Check your connection.'
            : 'Could not leave the room. Check your connection.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    final expired = _isExpired;
    final isMember = _isMember;
    return Scaffold(
      backgroundColor: c.paper,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(MiniIcons.back),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(widget.room.name),
        actions: [
          IconButton(
            icon: Icon(MiniIcons.refresh, color: c.inkSoft, size: 21),
            onPressed: _loadMembers,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Room code card
                  Container(
                    width: double.infinity,
                    clipBehavior: Clip.antiAlias,
                    decoration: miniCard(context, strong: true),
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        children: [
                          Text('Room code',
                              style:
                                  MiniText.label.copyWith(color: c.inkFaint)),
                          const SizedBox(height: 12),
                          MiniCodeReel(
                            code: widget.room.code,
                            style: MiniText.code.copyWith(
                              fontSize: 30,
                              fontWeight: FontWeight.w600,
                              color: expired ? c.inkFaint : c.ink,
                              letterSpacing: 4,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 11, vertical: 6),
                            decoration: BoxDecoration(
                              color: _expiryTint.withValues(alpha: 0.12),
                              borderRadius:
                                  BorderRadius.circular(MiniRadius.pill),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(MiniIcons.timer,
                                    size: 14, color: _expiryTint),
                                const SizedBox(width: 5),
                                Text(
                                  roomDetailExpiryLabel(widget.room.timeLeft),
                                  style: GoogleFonts.outfit(
                                    fontSize: 12,
                                    height: 1,
                                    fontWeight: FontWeight.w600,
                                    color: _expiryTint,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 20),
                          // An expired code can't be joined: don't hand it out.
                          Row(
                            children: [
                              Expanded(
                                child: _OutlineBtn(
                                  icon: MiniIcons.copy,
                                  label: 'Copy',
                                  onTap: expired ? null : _copyCode,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _OutlineBtn(
                                  icon: MiniIcons.qr,
                                  label: 'QR',
                                  onTap: expired ? null : _showQr,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _OutlineBtn(
                                  icon: MiniIcons.share,
                                  label: 'Invite',
                                  onTap: expired ? null : _shareCode,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (expired) ...[
                    const SizedBox(height: 12),
                    StatusBanner(
                      icon: MiniIcons.timer,
                      text: 'This room has expired. Nobody can join or share '
                          'files in it, and its files are being removed.',
                      tint: MiniColors.danger,
                    ),
                  ] else if (!isMember) ...[
                    const SizedBox(height: 12),
                    StatusBanner(
                      icon: MiniIcons.blocked,
                      text: 'You are no longer a member of this room.',
                      tint: MiniColors.warn,
                    ),
                  ],
                  const SizedBox(height: 8),

                  SectionHeader(
                    title: 'Members',
                    counter:
                        '${_members.length}/${AppConstants.maxRoomMembers}',
                  ),

                  if (_loading)
                    Padding(
                      padding: const EdgeInsets.all(28),
                      child: Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: c.accent,
                          ),
                        ),
                      ),
                    )
                  else
                    for (final member in _members) ...[
                      _MemberRow(
                        member: member,
                        isYou: member.userId == widget.identity.id,
                        isHost: member.userId == widget.room.ownerId,
                        showShareToggle:
                            _isOwner && member.userId != widget.identity.id,
                        // Visible but frozen once expired: the server refuses
                        // permission changes in an expired room.
                        onShareToggle: expired
                            ? null
                            : (v) => _toggleMemberShare(member, v),
                        onLongPress: member.userId == widget.identity.id
                            ? null
                            : () => ContactAliasSheet.show(
                                  context,
                                  userId: member.userId,
                                  code: member.shortCode,
                                ),
                      ),
                    ],
                  if (_isOwner && _members.length > 1 && !expired)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Use the switches to control who can share files '
                        'in this room.',
                        style: MiniText.small,
                      ),
                    ),

                  if (_isOwner && !expired && _blocked.isNotEmpty) ...[
                    SectionHeader(
                      title: 'Blocked',
                      counter: '${_blocked.length}',
                    ),
                    for (final b in _blocked)
                      _BlockedRow(
                        name: _blockedName(b),
                        code: b.shortCode,
                        busy: _unblockPending.contains(b.userId),
                        onUnblock: () => _unblock(b),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'They left while blocked, and stay blocked if they '
                        'rejoin until you unblock them.',
                        style: MiniText.small,
                      ),
                    ),
                  ],

                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    StatusBanner(
                      icon: MiniIcons.error,
                      text: _error!,
                      tint: MiniColors.danger,
                      onTap: _loadMembers,
                    ),
                  ],
                ],
              ),
            ),
          ),

          // Share files / leave / close room
          Container(
            color: c.paper,
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_leaveError != null) ...[
                  StatusBanner(
                    icon: MiniIcons.error,
                    text: '${_leaveError!} Tap to try again.',
                    tint: MiniColors.danger,
                    onTap: _leaving ? null : _performLeave,
                  ),
                  const SizedBox(height: 10),
                ],
                if (!expired && _members.length > 1 && _iCanShare) ...[
                  MiniButton(
                    label: 'Share files to room',
                    leading: Icon(
                      MiniIcons.send,
                      size: 17,
                      color: context.isDarkMini ? c.paper : Colors.white,
                    ),
                    onPressed: _openRoomSend,
                  ),
                  const SizedBox(height: 10),
                ],
                MiniButton(
                  label: _leaving
                      ? (_isOwner ? 'Closing…' : 'Leaving…')
                      : _isOwner
                          ? 'Close room'
                          : 'Leave room',
                  style: MiniBtnStyle.danger,
                  loading: _leaving,
                  onPressed: _leaving ? null : _leaveRoom,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  final RoomMember member;
  final bool isYou;
  final bool isHost;
  final bool showShareToggle;
  final ValueChanged<bool>? onShareToggle;
  final VoidCallback? onLongPress;

  const _MemberRow({
    required this.member,
    required this.isYou,
    required this.isHost,
    this.showShareToggle = false,
    this.onShareToggle,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    // Local alias wins over the member's self-set nickname
    final name = ContactAliases.aliasFor(member.userId) ?? member.displayName;
    return GestureDetector(
      onLongPress: onLongPress,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: miniCard(context, radius: MiniRadius.tile),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: isHost ? c.accent.withValues(alpha: 0.12) : c.sand,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  name.characters.first.toUpperCase(),
                  style: GoogleFonts.outfit(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: isHost ? c.accent : c.inkSoft,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isYou ? '$name (you)' : name,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.outfit(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      letterSpacing: -0.2,
                      color: c.ink,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    fmtCode(member.shortCode),
                    style: GoogleFonts.jetBrainsMono(
                      fontSize: 11.5,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w500,
                      color: c.inkFaint,
                    ),
                  ),
                ],
              ),
            ),
            if (isHost)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: c.accentSoft,
                  borderRadius: BorderRadius.circular(MiniRadius.pill),
                ),
                child: Text(
                  'Host',
                  style: GoogleFonts.outfit(
                    fontSize: 11,
                    height: 1,
                    fontWeight: FontWeight.w600,
                    color: c.accent,
                  ),
                ),
              )
            else if (showShareToggle)
              // Host's control: allow/block this member from sharing files.
              // Only the host sees this — members are not shown who is blocked.
              Transform.scale(
                scale: 0.8,
                child: Switch.adaptive(
                  value: member.canShare,
                  onChanged: onShareToggle,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Someone the host blocked who has left: name, code, Unblock.
class _BlockedRow extends StatelessWidget {
  final String name;
  final String code;
  final bool busy;
  final VoidCallback onUnblock;

  const _BlockedRow({
    required this.name,
    required this.code,
    required this.busy,
    required this.onUnblock,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: miniCard(context, radius: MiniRadius.tile),
      child: Row(
        children: [
          Icon(MiniIcons.blocked, size: 18, color: c.inkFaint),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.outfit(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w500,
                    color: c.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  fmtCode(code),
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 11,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w500,
                    color: c.inkFaint,
                  ),
                ),
              ],
            ),
          ),
          if (busy)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: c.accent,
                ),
              ),
            )
          else
            TextButton(
              onPressed: onUnblock,
              child: const Text('Unblock'),
            ),
        ],
      ),
    );
  }
}

class _OutlineBtn extends StatelessWidget {
  final IconData icon;
  final String label;

  /// Null renders the button disabled.
  final VoidCallback? onTap;
  const _OutlineBtn(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    final fg = onTap == null ? c.inkFaint : c.ink;
    return Material(
      color: c.sand,
      borderRadius: BorderRadius.circular(MiniRadius.control),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(MiniRadius.control),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 13),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: fg),
              const SizedBox(width: 7),
              Text(
                label,
                style: GoogleFonts.outfit(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
