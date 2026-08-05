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
                    icon:
                        Icon(Icons.refresh_rounded, color: c.inkSoft, size: 21),
                    onPressed: _loadRooms,
                  ),
                ],
              ),
            ),

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
                                physics: const AlwaysScrollableScrollPhysics(),
                                padding:
                                    const EdgeInsets.fromLTRB(20, 12, 20, 24),
                                itemCount: _rooms.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 10),
                                itemBuilder: (context, i) => _RoomCard(
                                  room: _rooms[i],
                                  isOwner:
                                      _rooms[i].isOwnedBy(widget.identity.id),
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
    final fg = primary ? Colors.white : c.ink;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(MiniRadius.card),
        boxShadow: miniCardShadow(context, strong: primary),
      ),
      child: Material(
        color: primary ? MiniColors.blue600 : c.paperDeep,
        borderRadius: BorderRadius.circular(MiniRadius.card),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(MiniRadius.card),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: primary
                        ? Colors.white.withValues(alpha: 0.18)
                        : c.accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(icon,
                      size: 20, color: primary ? Colors.white : c.accent),
                ),
                const SizedBox(height: 14),
                Text(
                  title,
                  style: GoogleFonts.outfit(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2,
                    color: fg,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: GoogleFonts.outfit(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: primary
                        ? Colors.white.withValues(alpha: 0.8)
                        : c.inkFaint,
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
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(MiniRadius.card),
        boxShadow: miniCardShadow(context),
      ),
      child: Material(
        color: c.paperDeep,
        borderRadius: BorderRadius.circular(MiniRadius.card),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(MiniRadius.card),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
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
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.4,
                          color: c.ink,
                        ),
                      ),
                    ),
                    if (isOwner) _Chip(label: 'Host'),
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
                  decoration: BoxDecoration(
                    color: c.sand,
                    borderRadius: BorderRadius.circular(MiniRadius.pill),
                  ),
                  child: Text(
                    fmtCode(room.code),
                    style: GoogleFonts.jetBrainsMono(
                      fontSize: 13,
                      letterSpacing: 1,
                      fontWeight: FontWeight.w600,
                      color: c.ink,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    if (room.memberNames.isNotEmpty) ...[
                      _MemberAvatars(names: room.memberNames),
                      const SizedBox(width: 9),
                    ],
                    Text(
                      '${room.memberCount} member${room.memberCount == 1 ? '' : 's'}',
                      style: GoogleFonts.outfit(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: c.inkSoft,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      _timeLeftLabel(),
                      style: GoogleFonts.outfit(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
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
    const size = 26.0;
    const overlap = 17.0;
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
                    _tints[i % _tints.length].withValues(alpha: 0.20),
                    c.paperDeep,
                  ),
                  shape: BoxShape.circle,
                  border: Border.all(color: c.paperDeep, width: 2),
                ),
                child: Text(
                  shown[i].characters.first.toUpperCase(),
                  style: GoogleFonts.outfit(
                    fontSize: 11,
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
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: BoxDecoration(
        color: context.mini.accentSoft,
        borderRadius: BorderRadius.circular(MiniRadius.pill),
      ),
      child: Text(
        label,
        style: GoogleFonts.outfit(
          fontSize: 11.5,
          height: 1,
          fontWeight: FontWeight.w600,
          color: context.mini.accent,
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
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: c.accent.withValues(alpha: 0.12),
              ),
              child: Icon(Icons.groups_rounded, size: 30, color: c.accent),
            ),
            const SizedBox(height: 20),
            Text('No rooms yet', style: MiniText.title.copyWith(color: c.ink)),
            const SizedBox(height: 8),
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
  int _lifetimeMinutes = AppConstants.defaultRoomLifetimeMinutes;
  bool _creating = false;
  String? _error;

  static String _lifetimeLabel(int minutes) =>
      minutes < 60 ? '${minutes}m' : '${minutes ~/ 60}h';

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
        lifetimeMinutes: _lifetimeMinutes,
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _nameController,
            enabled: !_creating,
            autofocus: true,
            maxLength: AppConstants.maxRoomNameLength,
            textCapitalization: TextCapitalization.sentences,
            style: GoogleFonts.outfit(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: c.ink,
            ),
            decoration: InputDecoration(
              hintText: 'Room name',
              hintStyle: GoogleFonts.outfit(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: c.inkFaint,
              ),
              counterText: '',
              filled: true,
              fillColor: c.sand,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(MiniRadius.control),
                borderSide: BorderSide.none,
              ),
            ),
            onSubmitted: (_) => _create(),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Text('Expires in',
                    style: MiniText.small.copyWith(color: c.inkSoft)),
              ),
              for (final minutes
                  in AppConstants.roomLifetimeMinutesOptions) ...[
                const SizedBox(width: 8),
                _LifetimeChip(
                  label: _lifetimeLabel(minutes),
                  selected: minutes == _lifetimeMinutes,
                  onTap: _creating
                      ? null
                      : () {
                          HapticFeedback.selectionClick();
                          setState(() => _lifetimeMinutes = minutes);
                        },
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _LifetimeChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  const _LifetimeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Material(
      color: selected ? MiniColors.blue600 : c.sand,
      borderRadius: BorderRadius.circular(MiniRadius.pill),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(MiniRadius.pill),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
          child: Text(
            label,
            style: GoogleFonts.outfit(
              fontSize: 13,
              height: 1.1,
              fontWeight: FontWeight.w500,
              color: selected ? Colors.white : c.inkSoft,
            ),
          ),
        ),
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
          fontWeight: FontWeight.w600,
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
          fillColor: c.sand,
          contentPadding: const EdgeInsets.symmetric(vertical: 18),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(MiniRadius.control),
            borderSide: BorderSide.none,
          ),
          suffixIcon: IconButton(
            icon:
                Icon(Icons.qr_code_scanner_rounded, size: 20, color: c.inkSoft),
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
          color: c.paperDeep,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(MiniRadius.sheet),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(22, 12, 22, 26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 5,
                decoration: BoxDecoration(
                  color: c.sandDeep,
                  borderRadius: BorderRadius.circular(MiniRadius.pill),
                ),
              ),
            ),
            const SizedBox(height: 22),
            Text(title, style: MiniText.title.copyWith(color: c.ink)),
            const SizedBox(height: 6),
            Text(subtitle, style: MiniText.bodySoft),
            const SizedBox(height: 20),
            child,
            if (error != null) ...[
              const SizedBox(height: 10),
              Text(
                error!,
                style: MiniText.small.copyWith(
                  color: MiniColors.danger,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
            const SizedBox(height: 20),
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
