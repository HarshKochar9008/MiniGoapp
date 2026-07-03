import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/constants.dart';
import '../../core/contacts/contact_aliases.dart';
import '../../core/native/native_share.dart';
import '../../zensend/theme/zen_theme.dart';
import '../../zensend/widgets/zen_widgets.dart';
import '../contacts/contact_alias_sheet.dart';
import '../identity/identity_service.dart';
import 'room_service.dart';

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

class _RoomDetailScreenState extends State<RoomDetailScreen> {
  List<RoomMember> _members = [];
  bool _loading = true;
  bool _leaving = false;
  String? _error;

  bool get _isOwner => widget.room.isOwnedBy(widget.identity.id);

  @override
  void initState() {
    super.initState();
    ContactAliases.ensureLoaded();
    ContactAliases.revision.addListener(_onAliasesChanged);
    _loadMembers();
  }

  void _onAliasesChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    ContactAliases.revision.removeListener(_onAliasesChanged);
    super.dispose();
  }

  Future<void> _loadMembers() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final members = await RoomService.listMembers(widget.room.id);
      if (!mounted) return;
      setState(() {
        _members = members;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load members. Check your connection.';
        _loading = false;
      });
    }
  }

  void _copyCode() {
    Clipboard.setData(ClipboardData(text: widget.room.code));
    HapticFeedback.selectionClick();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Room code copied')),
    );
  }

  void _shareCode() {
    HapticFeedback.selectionClick();
    NativeShareService.shareText(
      'Join my room "${widget.room.name}" on MiniGo with code: '
      '${widget.room.code}',
      subject: 'MiniGo room invite',
    );
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
            style: FilledButton.styleFrom(backgroundColor: ZenColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(_isOwner ? 'Close room' : 'Leave'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _leaving = true);
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
        _error = 'Could not leave the room. Check your connection.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.zen;
    return Scaffold(
      backgroundColor: c.paper,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(widget.room.name),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh_rounded, color: c.inkFaint, size: 20),
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
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: c.sand,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: ZenColors.blue600.withValues(alpha: 0.18),
                      ),
                    ),
                    child: Column(
                      children: [
                        Text('Room code',
                            style: ZenText.label.copyWith(color: c.inkSoft)),
                        const SizedBox(height: 10),
                        Text(
                          fmtCode(widget.room.code),
                          textAlign: TextAlign.center,
                          style: ZenText.code.copyWith(
                            fontSize: 30,
                            color: c.ink,
                            letterSpacing: 4,
                          ),
                        ),
                        const SizedBox(height: 18),
                        Row(
                          children: [
                            Expanded(
                              child: _OutlineBtn(
                                icon: Icons.copy_rounded,
                                label: 'Copy',
                                onTap: _copyCode,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: _OutlineBtn(
                                icon: Icons.share_rounded,
                                label: 'Invite',
                                onTap: _shareCode,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),

                  SectionHeader(
                    title: 'Members',
                    counter:
                        '${_members.length}/${AppConstants.maxRoomMembers}',
                  ),
                  const HairLine(),

                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.all(28),
                      child: Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: ZenColors.blue600,
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
                        onLongPress: member.userId == widget.identity.id
                            ? null
                            : () => ContactAliasSheet.show(
                                  context,
                                  userId: member.userId,
                                  code: member.shortCode,
                                ),
                      ),
                      const HairLine(indent: 56),
                    ],

                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    StatusBanner(
                      icon: Icons.error_outline_rounded,
                      text: _error!,
                      tint: ZenColors.danger,
                      onTap: _loadMembers,
                    ),
                  ],
                ],
              ),
            ),
          ),

          // Leave / close room
          Container(
            color: c.paper,
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            child: ZenButton(
              label: _leaving
                  ? 'Leaving…'
                  : _isOwner
                      ? 'Close room'
                      : 'Leave room',
              style: ZenBtnStyle.danger,
              loading: _leaving,
              onPressed: _leaving ? null : _leaveRoom,
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
  final VoidCallback? onLongPress;

  const _MemberRow({
    required this.member,
    required this.isYou,
    required this.isHost,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.zen;
    // Local alias wins over the member's self-set nickname
    final name = ContactAliases.aliasFor(member.userId) ?? member.displayName;
    return GestureDetector(
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: isHost
                    ? c.accent.withValues(alpha: 0.12)
                    : c.paperDeep,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  name.characters.first.toUpperCase(),
                  style: GoogleFonts.outfit(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: isHost ? c.accent : c.inkSoft,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isYou ? '$name (you)' : name,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.outfit(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: c.ink,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    fmtCode(member.shortCode),
                    style: GoogleFonts.jetBrainsMono(
                      fontSize: 11,
                      letterSpacing: 1.5,
                      color: c.inkFaint,
                    ),
                  ),
                ],
              ),
            ),
            if (isHost)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: c.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  'Host',
                  style: GoogleFonts.outfit(
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    color: c.accent,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _OutlineBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _OutlineBtn(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.zen;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: c.paper,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c.divider),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 15, color: c.ink),
            const SizedBox(width: 6),
            Text(
              label,
              style: GoogleFonts.outfit(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: c.ink,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
