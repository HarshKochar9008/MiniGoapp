import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeChannel;

import '../../core/constants.dart';
import '../../core/contacts/contact_aliases.dart';
import '../../core/network/connection_status.dart';
import '../../Minigo/theme/mini_theme.dart';
import '../../Minigo/widgets/mini_widgets.dart';
import '../identity/identity_service.dart';
import '../transfer/transfer_service.dart';
import 'room_service.dart';

enum _MemberSendStatus { waiting, sending, done, failed }

class _MemberSendState {
  final RoomMember member;
  _MemberSendStatus status = _MemberSendStatus.waiting;
  int completedFiles = 0;
  String? error;
  _MemberSendState(this.member);
}

/// Sends the selected files to every other room member as individual
/// transfers, so push notifications, the Received screen, and History all
/// work exactly like a direct send.
class RoomSendScreen extends StatefulWidget {
  final UserIdentity identity;
  final Room room;

  /// Room members excluding the sender.
  final List<RoomMember> recipients;

  const RoomSendScreen({
    super.key,
    required this.identity,
    required this.room,
    required this.recipients,
  });

  @override
  State<RoomSendScreen> createState() => _RoomSendScreenState();
}

class _RoomSendScreenState extends State<RoomSendScreen> {
  List<PlatformFile> _selectedFiles = [];
  late final List<_MemberSendState> _memberStates;
  bool _sending = false;
  bool _sent = false;
  String? _error;
  RealtimeChannel? _channel;

  /// Live mirror of my can_share flag; the server enforces it on send, this
  /// just keeps the UI honest the moment the host flips the toggle.
  bool _canShare = true;

  @override
  void initState() {
    super.initState();
    _memberStates =
        widget.recipients.map((m) => _MemberSendState(m)).toList();
    _channel = RoomService.subscribeToRoom(
      roomId: widget.room.id,
      onMembersChanged: _refreshMyPermission,
    );
    _refreshMyPermission();
  }

  @override
  void dispose() {
    if (_channel != null) RoomService.unsubscribe(_channel!);
    super.dispose();
  }

  Future<void> _refreshMyPermission() async {
    try {
      final members = await RoomService.listMembers(widget.room.id);
      if (!mounted) return;
      final mine = members.where((m) => m.userId == widget.identity.id);
      final allowed = mine.isEmpty || mine.first.canShare;
      if (allowed != _canShare) setState(() => _canShare = allowed);
    } catch (_) {
      // Keep the last known state; the server still enforces on send.
    }
  }

  Future<void> _pickFiles() async {
    try {
      final result = await FilePicker.pickFiles(
        allowMultiple: true,
        type: FileType.any,
        withData: false,
      );
      if (result == null || !mounted) return;

      final accessible = result.files.where((f) => f.path != null).toList();
      final oversized = accessible
          .where((f) => f.size > AppConstants.maxFileSizeBytes)
          .toList();
      if (oversized.isNotEmpty) {
        setState(() {
          _error = '${oversized.first.name} exceeds '
              '${AppConstants.maxFileSizeBytes ~/ 1024 ~/ 1024} MB limit';
        });
        return;
      }

      final existingNames = _selectedFiles.map((f) => f.name).toSet();
      final newFiles = accessible
          .where((f) => existingNames.add(f.name))
          .toList();
      if (_selectedFiles.length + newFiles.length >
          AppConstants.maxFilesPerTransfer) {
        setState(() {
          _error = 'Max ${AppConstants.maxFilesPerTransfer} files per transfer';
        });
        return;
      }

      setState(() {
        _selectedFiles = [..._selectedFiles, ...newFiles];
        _error = null;
      });
    } catch (_) {
      if (mounted) {
        setState(
            () => _error = 'Could not pick files. Check app permissions.');
      }
    }
  }

  Future<void> _send() async {
    if (_selectedFiles.isEmpty || _sending) return;
    if (!_canShare) {
      setState(
          () => _error = 'The host has paused sharing for you in this room.');
      return;
    }
    if (widget.room.isExpired) {
      setState(() => _error = 'This room has expired.');
      return;
    }
    if (!await ConnectionStatus.instance.refresh()) {
      if (!mounted) return;
      setState(() {
        _error = 'No internet connection. Try again when you are online.';
      });
      return;
    }

    setState(() {
      _sending = true;
      _error = null;
    });
    HapticFeedback.lightImpact();

    // Resolve every member's E2E public key up front. Doing it here rather
    // than inside the send loop means the "these members can't be encrypted
    // for" warning is one decision, not a dialog interrupting each upload.
    //
    // A lookup that *throws* fails that member — it must not fall back to a
    // plaintext upload, because a keyed recipient expects ciphertext only.
    // A lookup that succeeds with no key is a different case: that member is
    // genuinely unencryptable, and the user is asked about it below.
    final memberKeys = <String, String?>{};
    final lookupFailed = <String>{};
    for (final state in _memberStates) {
      try {
        final recip =
            await IdentityService.findUserByCode(state.member.shortCode);
        final key = (recip?['public_key'] as String?)?.trim();
        memberKeys[state.member.userId] =
            (key == null || key.isEmpty) ? null : key;
      } catch (_) {
        lookupFailed.add(state.member.userId);
      }
    }
    if (!mounted) return;

    final unencryptable = _memberStates
        .where((s) =>
            !lookupFailed.contains(s.member.userId) &&
            memberKeys[s.member.userId] == null)
        .toList();
    if (unencryptable.isNotEmpty) {
      final proceed = await _confirmSendWithoutEncryption(
        unencryptable.map((s) => _memberName(s.member)).toList(),
      );
      if (proceed != true || !mounted) {
        setState(() => _sending = false);
        return;
      }
    }

    var failures = 0;
    for (final state in _memberStates) {
      if (!mounted) return;

      if (lookupFailed.contains(state.member.userId)) {
        failures++;
        setState(() {
          state.status = _MemberSendStatus.failed;
          state.error = 'Could not check this member\'s encryption key';
        });
        continue;
      }

      setState(() => state.status = _MemberSendStatus.sending);
      try {
        final recipientKey = memberKeys[state.member.userId];
        final result = await TransferService.sendFiles(
          senderId: widget.identity.id,
          receiverId: state.member.userId,
          receiverCode: state.member.shortCode,
          recipientPublicKey: recipientKey,
          // Only reachable once the dialog above was accepted.
          allowUnencrypted: recipientKey == null,
          files: _selectedFiles,
          roomId: widget.room.id,
          roomName: widget.room.name,
          onProgress: (states) {
            if (!mounted) return;
            setState(() {
              state.completedFiles = states
                  .where((s) => s.status == FileUploadStatus.completed)
                  .length;
            });
          },
        );
        if (!mounted) return;
        setState(() {
          state.status =
              result.success ? _MemberSendStatus.done : _MemberSendStatus.failed;
          state.completedFiles = result.completedFiles;
          if (!result.success) {
            state.error = 'Some files failed';
            failures++;
          }
        });
      } catch (e) {
        if (!mounted) return;
        failures++;
        final raw = e.toString();
        setState(() {
          state.status = _MemberSendStatus.failed;
          state.error = raw.contains('room_share_denied')
              ? 'Sharing is not available in this room right now'
              : raw.replaceAll('Exception: ', '');
        });
        // Permission is per-sender, not per-recipient — no point retrying
        // the remaining members if the host has blocked us.
        if (raw.contains('room_share_denied')) break;
      }
    }

    if (!mounted) return;
    HapticFeedback.heavyImpact();
    setState(() {
      _sending = false;
      _sent = true;
      if (failures > 0) {
        _error = failures == _memberStates.length
            ? 'Sending failed for all members.'
            : 'Sent, but $failures member(s) failed.';
      }
    });
  }

  /// Asked once when one or more members published no X25519 public key, so
  /// their copy of the files can only be uploaded as plaintext. Named
  /// explicitly, because in a room the user is picking recipients in bulk and
  /// would otherwise have no idea which ones are unprotected.
  Future<bool?> _confirmSendWithoutEncryption(List<String> names) {
    final list = names.join(', ');
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Not end-to-end encrypted'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              names.length == 1
                  ? '$list has not published an encryption key.'
                  : 'These members have not published an encryption key: '
                      '$list.',
              style: MiniText.bodySoft,
            ),
            const SizedBox(height: 12),
            Text(
              'Their copy will be uploaded as-is, which means the server can '
              'read it while the transfer is live. Everyone else in this room '
              'still gets an encrypted copy.',
              style: MiniText.small,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Send anyway'),
          ),
        ],
      ),
    );
  }

  String _memberName(RoomMember m) =>
      ContactAliases.aliasFor(m.userId) ?? m.displayName;

  int get _totalSize =>
      _selectedFiles.fold<int>(0, (sum, f) => sum + f.size);

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    // System back must be blocked too, not just the AppBar close: popping
    // mid-send silently abandons the loop between members, so some members
    // get the files and the rest never do.
    return PopScope(
      canPop: !_sending,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _sending) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Sending in progress — please wait for it to finish.'),
            ),
          );
        }
      },
      child: Scaffold(
      backgroundColor: c.paper,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: _sending ? null : () => Navigator.pop(context),
        ),
        title: Text('Share to "${widget.room.name}"'),
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Files
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Files', style: MiniText.label),
                            if (_selectedFiles.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                '${_selectedFiles.length} selected · '
                                '${TransferService.formatFileSize(_totalSize)}',
                                style: MiniText.small,
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (!_sending && !_sent && _selectedFiles.isNotEmpty)
                        GestureDetector(
                          onTap: _pickFiles,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            child: Text(
                              'Add more',
                              style: GoogleFonts.outfit(
                                fontSize: 13,
                                color: c.inkSoft,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  if (_selectedFiles.isEmpty)
                    GestureDetector(
                      onTap: _pickFiles,
                      child: Container(
                        height: 130,
                        decoration: BoxDecoration(
                          color: c.paperDeep,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: c.divider),
                        ),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.add_circle_outline_rounded,
                                  size: 32, color: c.inkFaint),
                              const SizedBox(height: 10),
                              Text('Tap to choose files',
                                  style: MiniText.bodySoft),
                            ],
                          ),
                        ),
                      ),
                    )
                  else
                    for (var i = 0; i < _selectedFiles.length; i++)
                      Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: c.paperDeep.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: MiniFileRow(
                          name: _selectedFiles[i].name,
                          size: TransferService.formatFileSize(
                              _selectedFiles[i].size),
                          mimeCategory: MiniFileRow.categoryFromFileName(
                              _selectedFiles[i].name),
                          trailing: _sending || _sent
                              ? null
                              : GestureDetector(
                                  onTap: () => setState(() {
                                    _selectedFiles =
                                        List.from(_selectedFiles)
                                          ..removeAt(i);
                                  }),
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Icon(Icons.close_rounded,
                                        size: 16,
                                        color: c.inkFaint),
                                  ),
                                ),
                        ),
                      ),

                  const SizedBox(height: 16),
                  Text(
                    'Sending to ${_memberStates.length} member(s)',
                    style: MiniText.label,
                  ),
                  const SizedBox(height: 8),

                  for (final s in _memberStates)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _MemberProgressRow(
                        name: _memberName(s.member),
                        code: s.member.shortCode,
                        status: s.status,
                        completedFiles: s.completedFiles,
                        totalFiles: _selectedFiles.length,
                        error: s.error,
                      ),
                    ),

                  if (!_canShare && !_sent) ...[
                    const SizedBox(height: 8),
                    StatusBanner(
                      icon: Icons.block_rounded,
                      text: 'The host has paused sharing for you '
                          'in this room.',
                      tint: MiniColors.warn,
                    ),
                  ],

                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    StatusBanner(
                      icon: Icons.error_outline_rounded,
                      text: _error!,
                      tint: MiniColors.danger,
                    ),
                  ],

                  if (_sending) ...[
                    const SizedBox(height: 8),
                    Text('Keep the app open while uploading.',
                        style: MiniText.small),
                  ],
                ],
              ),
            ),
          ),

          Container(
            color: c.paper,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: _sent
                ? MiniButton(
                    label: 'Done',
                    onPressed: () => Navigator.pop(context),
                  )
                : MiniButton(
                    label: _sending
                        ? 'Sending…'
                        : 'Send to ${_memberStates.length} member(s)',
                    loading: _sending,
                    onPressed: _selectedFiles.isEmpty || _sending || !_canShare
                        ? null
                        : _send,
                  ),
          ),
        ],
      ),
      ),
    );
  }
}

class _MemberProgressRow extends StatelessWidget {
  final String name;
  final String code;
  final _MemberSendStatus status;
  final int completedFiles;
  final int totalFiles;
  final String? error;

  const _MemberProgressRow({
    required this.name,
    required this.code,
    required this.status,
    required this.completedFiles,
    required this.totalFiles,
    this.error,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    final (icon, tint, detail) = switch (status) {
      _MemberSendStatus.waiting => (
          Icons.schedule_rounded,
          c.inkFaint,
          'Waiting',
        ),
      _MemberSendStatus.sending => (
          Icons.north_east_rounded,
          c.accent,
          'Sending $completedFiles / $totalFiles',
        ),
      _MemberSendStatus.done => (
          Icons.check_circle_rounded,
          MiniColors.success,
          'Delivered',
        ),
      _MemberSendStatus.failed => (
          Icons.error_rounded,
          MiniColors.danger,
          error ?? 'Failed',
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: c.paperDeep.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: tint),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.outfit(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: c.ink,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  fmtCode(code),
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 10,
                    letterSpacing: 1.5,
                    color: c.inkFaint,
                  ),
                ),
              ],
            ),
          ),
          Text(
            detail,
            style: GoogleFonts.outfit(fontSize: 12, color: tint),
          ),
        ],
      ),
    );
  }
}
