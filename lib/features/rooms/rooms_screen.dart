import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/constants.dart';
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

  @override
  void initState() {
    super.initState();
    _loadRooms();
  }

  Future<void> _loadRooms() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rooms = await RoomService.listMyRooms(widget.identity.id);
      if (!mounted) return;
      setState(() {
        _rooms = rooms;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
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
                        Text('Together',
                            style: ZenText.label.copyWith(color: c.inkSoft)),
                        const SizedBox(height: 4),
                        Text('Rooms',
                            style: ZenText.title.copyWith(color: c.ink)),
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
                  ? const Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: MiniColors.blue600,
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
                              color: MiniColors.blue600,
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
    final c = context.zen;
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

  @override
  Widget build(BuildContext context) {
    final c = context.zen;
    return Material(
      color: c.paperDeep.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: MiniColors.blue50,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.groups_rounded,
                    size: 20, color: MiniColors.blue600),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            room.name,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.outfit(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                              color: c.ink,
                            ),
                          ),
                        ),
                        if (isOwner) ...[
                          const SizedBox(width: 6),
                          _Chip(label: 'Host'),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      fmtCode(room.code),
                      style: GoogleFonts.jetBrainsMono(
                        fontSize: 12,
                        letterSpacing: 1.5,
                        color: c.inkSoft,
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.person_outline_rounded,
                          size: 14, color: c.inkFaint),
                      const SizedBox(width: 3),
                      Text(
                        '${room.memberCount}/${AppConstants.maxRoomMembers}',
                        style: GoogleFonts.outfit(
                          fontSize: 12,
                          color: c.inkFaint,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    room.isExpired
                        ? 'Expired'
                        : '${room.timeLeft.inMinutes}m left',
                    style: GoogleFonts.outfit(
                      fontSize: 11,
                      color: room.timeLeft.inMinutes < 10
                          ? MiniColors.warn
                          : c.inkFaint,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 6),
              Icon(Icons.chevron_right_rounded, size: 18, color: c.inkFaint),
            ],
          ),
        ),
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
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: MiniColors.blue50,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: GoogleFonts.outfit(
          fontSize: 10,
          fontWeight: FontWeight.w500,
          color: MiniColors.blue600,
        ),
      ),
    );
  }
}

class _EmptyRooms extends StatelessWidget {
  final ZenThemeExtension c;
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
            Text('No rooms yet', style: ZenText.bodySoft),
            const SizedBox(height: 6),
            Text(
              'Create a room and share its code, or join one '
              'with a code from a friend. Up to '
              '${AppConstants.maxRoomMembers} people per room.',
              textAlign: TextAlign.center,
              style: ZenText.small,
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
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _creating = false;
        _error = 'Could not create the room. Check your connection.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return _RoomSheetScaffold(
      title: 'Create a room',
      subtitle: 'You get a code others can use to join — '
          'up to ${AppConstants.maxRoomMembers} people.',
      error: _error,
      button: ZenButton(
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
        style: GoogleFonts.outfit(fontSize: 16, color: MiniColors.ink),
        decoration: InputDecoration(
          hintText: 'Room name',
          hintStyle:
              GoogleFonts.outfit(fontSize: 16, color: MiniColors.inkFaint),
          counterText: '',
          filled: true,
          fillColor: MiniColors.paperDeep,
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
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _joining = false;
        _error = 'Could not join the room. Check your connection.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return _RoomSheetScaffold(
      title: 'Join a room',
      subtitle: 'Ask the host for their room code.',
      error: _error,
      button: ZenButton(
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
          color: MiniColors.ink,
        ),
        decoration: InputDecoration(
          hintText: '— — —   — — —',
          hintStyle: GoogleFonts.jetBrainsMono(
            fontSize: 18,
            color: MiniColors.inkFaint,
            letterSpacing: 3,
          ),
          counterText: '',
          filled: true,
          fillColor: MiniColors.paperDeep,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          suffixIcon: IconButton(
            icon: const Icon(Icons.qr_code_scanner_rounded,
                size: 20, color: MiniColors.inkSoft),
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
    final c = context.zen;
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
            Text(title, style: ZenText.title.copyWith(color: c.ink)),
            const SizedBox(height: 4),
            Text(subtitle, style: ZenText.small),
            const SizedBox(height: 16),
            child,
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(
                error!,
                style: ZenText.small.copyWith(color: MiniColors.danger),
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
