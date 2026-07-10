import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeChannel;

import '../../core/constants.dart';
import '../../core/errors/app_error_handler.dart';
import '../../Minigo/theme/mini_theme.dart';
import '../../Minigo/widgets/mini_widgets.dart';
import '../identity/identity_service.dart';
import '../qr/qr_widgets.dart';
import 'room_detail_screen.dart';
import 'room_service.dart';

class RoomsScreen extends StatefulWidget {
  final UserIdentity identity;
  const RoomsScreen({super.key, required this.identity});

  @override
  State<RoomsScreen> createState() => _RoomsScreenState();
}

class _RoomsScreenState extends State<RoomsScreen> {
  List<Room> _rooms = [];
  bool _loading = true;
  String? _error;
  RealtimeChannel? _channel;
  Timer? _liveReloadDebounce;

  @override
  void initState() {
    super.initState();
    _loadRooms();
    _channel = RoomService.subscribeToMyRooms(
      userId: widget.identity.id,
      onChange: _onLiveChange,
    );
  }

  @override
  void dispose() {
    _liveReloadDebounce?.cancel();
    if (_channel != null) RoomService.unsubscribe(_channel!);
    super.dispose();
  }

  /// A burst of realtime events (e.g. several members joining) collapses
  /// into one silent reload.
  void _onLiveChange() {
    _liveReloadDebounce?.cancel();
    _liveReloadDebounce = Timer(const Duration(milliseconds: 400), () {
      if (mounted && !_loading) _loadRooms(silent: true);
    });
  }

  Future<void> _loadRooms({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final rooms = await RoomService.listMyRooms(widget.identity.id);
      if (!mounted) return;
      setState(() {
        _rooms = rooms;
        _loading = false;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      if (silent) return; // keep showing the last good list
      setState(() {
        _error = 'Could not load rooms. Check your connection.';
        _loading = false;
      });
    }
  }

  Future<void> _openRoom(Room room) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RoomDetailScreen(
          identity: widget.identity,
          room: room,
        ),
      ),
    );
    if (mounted) _loadRooms();
  }

  Future<void> _createRoom() async {
    HapticFeedback.selectionClick();
    final room = await _CreateRoomSheet.show(context, widget.identity.id);
    if (room == null || !mounted) return;
    await _openRoom(room);
  }

  Future<void> _joinRoom() async {
    HapticFeedback.selectionClick();
    final room = await _JoinRoomSheet.show(context, widget.identity.id);
    if (room == null || !mounted) return;
    await _openRoom(room);
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
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Together',
                            style: MiniText.label.copyWith(color: c.inkSoft)),
                        const SizedBox(height: 4),
                        Text('Rooms',
                            style: MiniText.title.copyWith(color: c.ink)),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.refresh_rounded,
                        color: c.inkFaint, size: 20),
                    onPressed: _loadRooms,
                  ),
                ],
              ),
            ),
            const HairLine(indent: 20),

            // Create / Join actions
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Row(
                children: [
                  Expanded(
                    child: _RoomAction(
                      icon: Icons.add_rounded,
                      title: 'Create room',
                      subtitle: 'Start a new room',
                      primary: true,
                      onTap: _createRoom,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _RoomAction(
                      icon: Icons.login_rounded,
                      title: 'Join room',
                      subtitle: 'Enter a room code',
                      onTap: _joinRoom,
                    ),
                  ),
                ],
              ),
            ),

            SectionHeader(
              title: 'Your rooms',
              counter: _rooms.isEmpty ? null : '${_rooms.length}',
            ),
            const HairLine(indent: 20),

            Expanded(
              child: _loading
                  ? Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: c.accent,
                        ),
                      ),
                    )
                  : _error != null
                      ? Padding(
                          padding: const EdgeInsets.all(20),
                          child: StatusBanner(
                            icon: Icons.wifi_off_rounded,
                            text: _error!,
                            tint: MiniColors.danger,
                            onTap: _loadRooms,
                          ),
                        )
                      : _rooms.isEmpty
                          ? _EmptyRooms(c: c)
                          : RefreshIndicator(
                              onRefresh: _loadRooms,
                              color: c.accent,
                              child: ListView.separated(
                                physics:
                                    const AlwaysScrollableScrollPhysics(),
                                padding:
                                    const EdgeInsets.fromLTRB(20, 12, 20, 24),
                                itemCount: _rooms.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 10),
                                itemBuilder: (context, i) => _RoomCard(
                                  room: _rooms[i],
                                  isOwner: _rooms[i]
                                      .isOwnedBy(widget.identity.id),
                                  onTap: () => _openRoom(_rooms[i]),
                                ),
                              ),
                            ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoomAction extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool primary;
  final VoidCallback onTap;

  const _RoomAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    final fg = primary ? MiniColors.paper : c.ink;
    return Material(
      color: primary ? MiniColors.blue600 : c.paperDeep,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 22, color: fg),
              const SizedBox(height: 10),
              Text(
                title,
                style: GoogleFonts.outfit(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: fg,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: GoogleFonts.outfit(
                  fontSize: 11,
                  color: primary
                      ? MiniColors.paper.withValues(alpha: 0.75)
                      : c.inkFaint,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoomCard extends StatelessWidget {
  final Room room;
  final bool isOwner;
  final VoidCallback onTap;

  const _RoomCard({
    required this.room,
    required this.isOwner,
    required this.onTap,
  });

  String _timeLeftLabel() {
    if (room.isExpired) return 'Expired';
    final left = room.timeLeft;
    if (left.inHours > 0) {
      return '${left.inHours}h ${left.inMinutes % 60}m left';
    }
    return '${left.inMinutes}m left';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Material(
      color: c.paperDeep.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      room.name,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.outfit(
                        fontSize: 17,
                        fontWeight: FontWeight.w500,
                        color: c.ink,
                      ),
                    ),
                  ),
                  if (isOwner) _Chip(label: 'Host'),
                ],
              ),
              const SizedBox(height: 10),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: c.paperDeep,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  fmtCode(room.code),
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 13,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w500,
                    color: c.ink,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  if (room.memberNames.isNotEmpty) ...[
                    _MemberAvatars(names: room.memberNames),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    '${room.memberCount} member${room.memberCount == 1 ? '' : 's'}',
                    style: GoogleFonts.outfit(
                      fontSize: 13,
                      color: c.inkSoft,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _timeLeftLabel(),
                    style: GoogleFonts.outfit(
                      fontSize: 12,
                      color: !room.isExpired && room.timeLeft.inMinutes < 10
                          ? MiniColors.warn
                          : c.inkFaint,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Overlapping pastel initial circles for up to three room members.
class _MemberAvatars extends StatelessWidget {
  final List<String> names;
  const _MemberAvatars({required this.names});

  static const _tints = [
    MiniColors.blue600,
    MiniColors.success,
    MiniColors.warn,
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    final shown = names.take(3).toList();
    const size = 22.0;
    const overlap = 14.0;
    return SizedBox(
      width: size + (shown.length - 1) * overlap,
      height: size,
      child: Stack(
        children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(
              left: i * overlap,
              child: Container(
                width: size,
                height: size,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Color.alphaBlend(
                    _tints[i % _tints.length].withValues(alpha: 0.18),
                    c.paper,
                  ),
                  shape: BoxShape.circle,
                  border: Border.all(color: c.paper, width: 1.5),
                ),
                child: Text(
                  shown[i].characters.first.toUpperCase(),
                  style: GoogleFonts.outfit(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: _tints[i % _tints.length],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  const _Chip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: MiniColors.blue600.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: GoogleFonts.outfit(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: MiniColors.blue600,
        ),
      ),
    );
  }
}

class _EmptyRooms extends StatelessWidget {
  final MiniThemeExtension c;
  const _EmptyRooms({required this.c});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.groups_outlined, size: 44, color: c.inkFaint),
            const SizedBox(height: 16),
            Text('No rooms yet', style: MiniText.bodySoft),
            const SizedBox(height: 6),
            Text(
              'Create a room and share its code, or join one '
              'with a code from a friend. Up to '
              '${AppConstants.maxRoomMembers} people per room.',
              textAlign: TextAlign.center,
              style: MiniText.small,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Create room sheet
// ---------------------------------------------------------------------------

class _CreateRoomSheet extends StatefulWidget {
  final String ownerId;
  const _CreateRoomSheet({required this.ownerId});

  static Future<Room?> show(BuildContext context, String ownerId) {
    return showModalBottomSheet<Room>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CreateRoomSheet(ownerId: ownerId),
    );
  }

  @override
  State<_CreateRoomSheet> createState() => _CreateRoomSheetState();
}

class _CreateRoomSheetState extends State<_CreateRoomSheet> {
  final _nameController = TextEditingController();
  bool _creating = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Give your room a name');
      return;
    }
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final room = await RoomService.createRoom(
        ownerId: widget.ownerId,
        name: name,
      );
      if (!mounted) return;
      HapticFeedback.lightImpact();
      Navigator.pop(context, room);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _creating = false;
        _error = 'Could not create the room. Check your connection.';
      });
      unawaited(AppErrorHandler.maybeShowServiceOutage(context, e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return _RoomSheetScaffold(
      title: 'Create a room',
      subtitle: 'You get a code others can use to join — '
          'up to ${AppConstants.maxRoomMembers} people.',
      error: _error,
      button: MiniButton(
        label: _creating ? 'Creating…' : 'Create room',
        loading: _creating,
        onPressed: _creating ? null : _create,
      ),
      child: TextField(
        controller: _nameController,
        enabled: !_creating,
        autofocus: true,
        maxLength: AppConstants.maxRoomNameLength,
        textCapitalization: TextCapitalization.sentences,
        style: GoogleFonts.outfit(fontSize: 16, color: c.ink),
        decoration: InputDecoration(
          hintText: 'Room name',
          hintStyle:
              GoogleFonts.outfit(fontSize: 16, color: c.inkFaint),
          counterText: '',
          filled: true,
          fillColor: c.paperDeep,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
        onSubmitted: (_) => _create(),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Join room sheet
// ---------------------------------------------------------------------------

class _JoinRoomSheet extends StatefulWidget {
  final String userId;
  const _JoinRoomSheet({required this.userId});

  static Future<Room?> show(BuildContext context, String userId) {
    return showModalBottomSheet<Room>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _JoinRoomSheet(userId: userId),
    );
  }

  @override
  State<_JoinRoomSheet> createState() => _JoinRoomSheetState();
}

class _JoinRoomSheetState extends State<_JoinRoomSheet> {
  final _codeController = TextEditingController();
  bool _joining = false;
  String? _error;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _scanQr() async {
    final code = await QrScannerSheet.show(context);
    if (code == null || !mounted) return;
    _codeController.text = code;
    await _join();
  }

  Future<void> _join() async {
    final code = AppConstants.normalizeShortCode(_codeController.text);
    if (!AppConstants.isValidShortCodeFormat(code)) {
      setState(() =>
          _error = 'Enter the ${AppConstants.codeLength}-character room code');
      return;
    }
    setState(() {
      _joining = true;
      _error = null;
    });
    try {
      final room = await RoomService.joinRoom(
        userId: widget.userId,
        code: code,
      );
      if (!mounted) return;
      HapticFeedback.lightImpact();
      Navigator.pop(context, room);
    } on RoomFullException {
      if (!mounted) return;
      setState(() {
        _joining = false;
        _error =
            'This room is full (${AppConstants.maxRoomMembers} members max).';
      });
    } on RoomNotFoundException {
      if (!mounted) return;
      setState(() {
        _joining = false;
        _error = 'No room found with that code.';
      });
    } on RoomExpiredException {
      if (!mounted) return;
      setState(() {
        _joining = false;
        _error = 'This room has expired.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _joining = false;
        _error = 'Could not join the room. Check your connection.';
      });
      unawaited(AppErrorHandler.maybeShowServiceOutage(context, e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return _RoomSheetScaffold(
      title: 'Join a room',
      subtitle: 'Ask the host for their room code.',
      error: _error,
      button: MiniButton(
        label: _joining ? 'Joining…' : 'Join room',
        loading: _joining,
        onPressed: _joining ? null : _join,
      ),
      child: TextField(
        controller: _codeController,
        enabled: !_joining,
        autofocus: true,
        textCapitalization: TextCapitalization.characters,
        maxLength: AppConstants.codeLength,
        textAlign: TextAlign.center,
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
          _UpperCaseFormatter(),
        ],
        style: GoogleFonts.jetBrainsMono(
          fontSize: 22,
          letterSpacing: 3,
          fontWeight: FontWeight.w500,
          color: c.ink,
        ),
        decoration: InputDecoration(
          hintText: '— — —   — — —',
          hintStyle: GoogleFonts.jetBrainsMono(
            fontSize: 18,
            color: c.inkFaint,
            letterSpacing: 3,
          ),
          counterText: '',
          filled: true,
          fillColor: c.paperDeep,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          suffixIcon: IconButton(
            icon: Icon(Icons.qr_code_scanner_rounded,
                size: 20, color: c.inkSoft),
            tooltip: 'Scan room QR',
            onPressed: _joining ? null : _scanQr,
          ),
        ),
        onSubmitted: (_) => _join(),
      ),
    );
  }
}

/// Shared sheet chrome: rounded top, title, input, error line, action button.
class _RoomSheetScaffold extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget child;
  final Widget button;
  final String? error;

  const _RoomSheetScaffold({
    required this.title,
    required this.subtitle,
    required this.child,
    required this.button,
    this.error,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: c.paper,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: c.divider,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(title, style: MiniText.title.copyWith(color: c.ink)),
            const SizedBox(height: 4),
            Text(subtitle, style: MiniText.small),
            const SizedBox(height: 16),
            child,
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(
                error!,
                style: MiniText.small.copyWith(color: MiniColors.danger),
              ),
            ],
            const SizedBox(height: 16),
            button,
          ],
        ),
      ),
    );
  }
}

class _UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    return newValue.copyWith(text: newValue.text.toUpperCase());
  }
}
