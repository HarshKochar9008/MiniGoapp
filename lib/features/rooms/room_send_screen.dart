import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/constants.dart';
import '../../core/contacts/contact_aliases.dart';
import '../../core/network/connection_status.dart';
import '../../core/time/server_clock.dart';
import '../../Minigo/theme/mini_theme.dart';
import '../../Minigo/widgets/mini_widgets.dart';
import '../identity/identity_service.dart';
import '../transfer/transfer_service.dart';
import 'room_lifecycle.dart';
import 'room_realtime_link.dart';
import 'room_service.dart';
import '../../Minigo/theme/mini_icons.dart';

enum _MemberSendStatus { waiting, sending, done, failed }

class _MemberSendState {
  final RoomMember member;
  _MemberSendStatus status = _MemberSendStatus.waiting;
  int completedFiles = 0;
  String? error;
  _MemberSendState(this.member);

  void reset() {
    status = _MemberSendStatus.waiting;
    completedFiles = 0;
    error = null;
  }

  void fail(String? message) {
    status = _MemberSendStatus.failed;
    error = message;
  }
}

/// What the screen is doing. Exactly one at a time; every transition goes
/// through [_RoomSendScreenState._run].
enum _SendPhase {
  /// Choosing files.
  idle,

  /// Send tapped: checking the connection, looking up keys, asking about
  /// members without one. Nothing uploaded yet.
  preparing,

  /// Uploading, one member after another.
  sending,

  /// The run is over and the per-member results are showing. Failed members
  /// can be retried.
  finished,
}

/// Sends the selected files to every other room member as individual
/// transfers, so push notifications, the Received screen, and History all
/// work exactly like a direct send.
class RoomSendScreen extends StatefulWidget {
  final UserIdentity identity;
  final Room room;

  /// Room members excluding the sender.
  final List<RoomMember> recipients;

  /// Files to pre-select, e.g. handed over by the Send screen when a typed
  /// code turned out to be this room's (a share from the gallery).
  final List<PlatformFile> initialFiles;

  const RoomSendScreen({
    super.key,
    required this.identity,
    required this.room,
    required this.recipients,
    this.initialFiles = const [],
  });

  @override
  State<RoomSendScreen> createState() => _RoomSendScreenState();
}

class _RoomSendScreenState extends State<RoomSendScreen>
    with WidgetsBindingObserver {
  List<PlatformFile> _selectedFiles = [];
  late final List<_MemberSendState> _memberStates;
  _SendPhase _phase = _SendPhase.idle;
  String? _error;
  RoomRealtimeLink? _link;
  bool _presenceCheckInFlight = false;

  /// Live mirror of my membership and can_share flag; the server enforces
  /// both on send, this just keeps the UI honest the moment they change.
  bool _canShare = true;
  bool _isMember = true;
  int _permissionGeneration = 0;

  /// Set once the room has ended (expired, or deleted by the host or the
  /// sweep). Terminal: nothing more can be sent from this screen.
  RoomEndReason? _roomEnd;

  /// Cancels the upload in flight. One per run; cancelled when the room ends
  /// mid-send or the screen goes away, so no upload outlives the screen and
  /// keeps holding TransferService's one-send-at-a-time lock.
  TransferCancellationToken? _cancelToken;
  Timer? _expiryAlarm;

  bool get _busy =>
      _phase == _SendPhase.preparing || _phase == _SendPhase.sending;

  String? get _roomEndMessage => _roomEnd == null
      ? null
      : roomEndMessage(_roomEnd!,
          isOwner: widget.room.isOwnedBy(widget.identity.id));

  int get _failedCount =>
      _memberStates.where((s) => s.status == _MemberSendStatus.failed).length;

  bool get _canRetry =>
      _phase == _SendPhase.finished &&
      _failedCount > 0 &&
      _roomEnd == null &&
      _canShare &&
      _selectedFiles.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _memberStates = widget.recipients.map((m) => _MemberSendState(m)).toList();
    _applyInitialFiles();
    if (widget.room.isExpired) {
      _roomEnd = RoomEndReason.expired;
    } else {
      _expiryAlarm = Timer(
        widget.room.timeLeft + const Duration(seconds: 1),
        () => _onRoomEnded(RoomEndReason.expired),
      );
    }
    WidgetsBinding.instance.addObserver(this);
    final roomId = widget.room.id;
    _link = RoomRealtimeLink(
      connect: (onStatus) => RoomService.subscribeToRoom(
        roomId: roomId,
        onMembersChanged: _refreshMyPermission,
        onRoomDeleted: _onRoomGone,
        onStatus: onStatus,
      ),
      // Live again after a drop: a block, a removal or the room's deletion
      // may have happened meanwhile.
      onResync: _refreshMyPermission,
    )..start();
    _refreshMyPermission();
  }

  /// Same limits [_pickFiles] applies, for files that arrive pre-selected.
  void _applyInitialFiles() {
    if (widget.initialFiles.isEmpty) return;
    final seenNames = <String>{};
    final valid = <PlatformFile>[];
    String? error;
    for (final f in widget.initialFiles) {
      if (f.path == null || !seenNames.add(f.name)) continue;
      if ((f.lengthSync() ?? 0) > AppConstants.maxFileSizeBytes) {
        error = '${f.name} exceeds '
            '${AppConstants.maxFileSizeBytes ~/ 1024 ~/ 1024} MB limit '
            'and was skipped';
        continue;
      }
      if (valid.length >= AppConstants.maxFilesPerTransfer) {
        error =
            'Only the first ${AppConstants.maxFilesPerTransfer} files were added';
        break;
      }
      valid.add(f);
    }
    _selectedFiles = valid;
    _error = error;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) _refreshMyPermission();
  }

  /// The room row is gone; server time says whether the host closed it or
  /// the sweep removed it after expiry.
  void _onRoomGone() => _onRoomEnded(roomEndReason(
        expiresAt: widget.room.expiresAt,
        serverNow: ServerClock.instance.now(),
      ));

  @override
  void dispose() {
    // The screen can go away mid-send (app navigation, or the room screen
    // closing everything above it); its upload must stop with it.
    _cancelToken?.cancel();
    _expiryAlarm?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _link?.dispose();
    super.dispose();
  }

  /// The room expired or was deleted. Stops a send in progress via its
  /// token — the server refuses every remaining member anyway, and an upload
  /// that finished after the room ended would only be swept — and keeps the
  /// per-member results on screen with the reason.
  void _onRoomEnded(RoomEndReason reason) {
    if (!mounted || _roomEnd != null) return;
    _expiryAlarm?.cancel();
    setState(() => _roomEnd = reason);
    _cancelToken?.cancel();
  }

  Future<void> _refreshMyPermission() async {
    final generation = ++_permissionGeneration;
    try {
      final members = await RoomService.listMembers(widget.room.id);
      // Only the most recently started check may apply its answer.
      if (!mounted || generation != _permissionGeneration) return;
      final me = widget.identity.id;
      final isMember = members.any((m) => m.userId == me);
      final allowed = canShareInRoom(members, me);
      if (allowed != _canShare || isMember != _isMember) {
        setState(() {
          _canShare = allowed;
          _isMember = isMember;
        });
      }
      if (!isMember) unawaited(_checkPresence(listWasEmpty: members.isEmpty));
    } catch (_) {
      // Keep the last known state; the server still enforces on send.
    }
  }

  /// I'm missing from the member list: was the room deleted (a delete event
  /// this screen may have missed while disconnected) or did it expire?
  Future<void> _checkPresence({required bool listWasEmpty}) async {
    if (_presenceCheckInFlight || _roomEnd != null) return;
    _presenceCheckInFlight = true;
    try {
      final presence = await RoomService.roomPresence(widget.room.id);
      if (!mounted) return;
      // Without room_presence (20261113000005 not applied) an empty list is
      // the room ending for me either way.
      if (presence == RoomPresence.gone || (presence == null && listWasEmpty)) {
        _onRoomGone();
      } else if (presence == RoomPresence.expired) {
        _onRoomEnded(RoomEndReason.expired);
      }
    } catch (_) {
      // Offline: the next refresh asks again.
    } finally {
      _presenceCheckInFlight = false;
    }
  }

  Future<void> _pickFiles() async {
    if (_phase != _SendPhase.idle || _roomEnd != null) return;
    try {
      final result = await FilePicker.pickFiles(type: FileType.any);
      if (!mounted) return;

      final accessible = result.where((f) => f.path != null).toList();
      final oversized = <PlatformFile>[];
      for (final file in accessible) {
        if (await File(file.path!).length() > AppConstants.maxFileSizeBytes) {
          oversized.add(file);
        }
      }
      if (!mounted) return;
      if (oversized.isNotEmpty) {
        setState(() {
          _error = '${oversized.first.name} exceeds '
              '${AppConstants.maxFileSizeBytes ~/ 1024 ~/ 1024} MB limit';
        });
        return;
      }

      final existingNames = _selectedFiles.map((f) => f.name).toSet();
      final newFiles =
          accessible.where((f) => existingNames.add(f.name)).toList();
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
        setState(() => _error = 'Could not pick files. Check app permissions.');
      }
    }
  }

  void _send() => _run(_memberStates);

  void _retryFailed() => _run(_memberStates
      .where((s) => s.status == _MemberSendStatus.failed)
      .toList());

  /// One send run to [targets]: preparing → sending → finished. Any early
  /// exit before the first upload returns to the phase the run started from.
  Future<void> _run(List<_MemberSendState> targets) async {
    if (_busy || _selectedFiles.isEmpty || targets.isEmpty) return;
    final startedFrom = _phase;

    String? refusal;
    if (_roomEnd != null) {
      refusal = _roomEndMessage;
    } else if (!_isMember) {
      refusal = 'You are no longer a member of this room.';
    } else if (!_canShare) {
      refusal = 'The host has paused sharing for you in this room.';
    }
    if (refusal != null) {
      setState(() => _error = refusal);
      return;
    }

    // Busy before the first await: a second tap during the connection check
    // used to start a second loop over the same members.
    setState(() {
      _phase = _SendPhase.preparing;
      _error = null;
    });
    HapticFeedback.lightImpact();

    if (!await ConnectionStatus.instance.refresh()) {
      if (!mounted) return;
      setState(() {
        _phase = startedFrom;
        _error = 'No internet connection. Try again when you are online.';
      });
      return;
    }

    // Resolve every target's E2E public key up front. Doing it here rather
    // than inside the send loop means the "these members can't be encrypted
    // for" warning is one decision, not a dialog interrupting each upload.
    //
    // A lookup that *fails* fails that member — it must not fall back to a
    // plaintext upload, because a keyed recipient expects ciphertext only.
    // A lookup that succeeds with no key is a different case: that member is
    // genuinely unencryptable, and the user is asked about it below.
    final memberKeys = <String, String?>{};
    final lookupFailed = await _resolveKeys(targets, memberKeys);
    if (!mounted) return;

    final unencryptable = targets
        .where((s) =>
            !lookupFailed.containsKey(s.member.userId) &&
            memberKeys[s.member.userId] == null)
        .toList();
    if (unencryptable.isNotEmpty && _roomEnd == null) {
      final proceed = await _confirmSendWithoutEncryption(
        unencryptable.map((s) => _memberName(s.member)).toList(),
      );
      if (!mounted) return;
      if (proceed != true) {
        setState(() => _phase = startedFrom);
        return;
      }
    }

    final token = TransferCancellationToken();
    _cancelToken = token;
    setState(() {
      _phase = _SendPhase.sending;
      for (final s in targets) {
        s.reset();
      }
    });

    for (final state in targets) {
      if (!mounted) return;
      // The room ended (or the server refused the whole room) — the rest are
      // marked below, not attempted.
      if (_roomEnd != null || token.isCancelled) break;

      final keyFailure = lookupFailed[state.member.userId];
      if (keyFailure != null) {
        setState(() => state.fail(keyFailure));
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
          cancellationToken: token,
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
          state.completedFiles = result.completedFiles;
          if (result.success) {
            state.status = _MemberSendStatus.done;
          } else {
            state.fail(_roomEndMessage ?? 'Some files failed');
          }
        });
      } catch (e) {
        // A room transfer that expired mid-upload expired with its room
        // (the sweep expires them together), so it ends the run too.
        final roomRefusal = classifyRoomSendRefusal(e) ??
            (e is TransferNotAcceptingUploadsException && e.expired
                ? RoomSendRefusal.roomEnded
                : null);
        // (sendFiles clears its saved resume job itself on a room refusal.)
        if (!mounted) return;
        if (roomRefusal == RoomSendRefusal.roomEnded) {
          _onRoomEnded(roomEndReason(
            expiresAt: widget.room.expiresAt,
            serverNow: ServerClock.instance.now(),
          ));
        }
        setState(() {
          if (roomRefusal == RoomSendRefusal.shareDenied) {
            // Blocked, or no longer a member; the check below says which.
            _canShare = false;
          }
          state.fail(_roomEndMessage ??
              roomRefusal?.message ??
              e.toString().replaceAll('Exception: ', ''));
        });
        if (roomRefusal == RoomSendRefusal.shareDenied) {
          unawaited(_refreshMyPermission());
        }
        // A room-wide refusal applies to every remaining member: stop here
        // rather than collect the same refusal from each of them.
        if (roomRefusal?.isRoomWide == true) break;
      }
    }

    if (!mounted) return;
    HapticFeedback.heavyImpact();
    setState(() {
      // Nobody may be left on "Waiting" under the summary.
      final skippedReason = _roomEndMessage ??
          (_canShare ? 'Not sent' : RoomSendRefusal.shareDenied.message);
      for (final s in targets) {
        if (s.status == _MemberSendStatus.waiting ||
            s.status == _MemberSendStatus.sending) {
          s.fail(skippedReason);
        }
      }
      _cancelToken = null;
      _phase = _SendPhase.finished;
      final failures = _failedCount;
      if (_roomEnd != null) {
        _error = '${_roomEndMessage!} Sending stopped.';
      } else if (failures > 0) {
        _error = failures == _memberStates.length
            ? 'Sending failed for all members.'
            : 'Sent, but $failures member(s) failed.';
      }
    });
  }

  /// Fills [keys] with each target's public key (null: none published) and
  /// returns the targets that can't be sent to, with the reason.
  ///
  /// One `room_member_public_keys` call, matched by user id — the id the
  /// transfer is addressed to. Only when that RPC isn't deployed yet does it
  /// fall back to the old per-member lookup by short code.
  Future<Map<String, String>> _resolveKeys(
    List<_MemberSendState> targets,
    Map<String, String?> keys,
  ) async {
    final failed = <String, String>{};
    final List<Map<String, dynamic>>? rows;
    try {
      rows = await RoomService.memberPublicKeyRows(widget.room.id);
    } catch (e) {
      if (!mounted) return failed;
      final refusal = classifyRoomSendRefusal(e);
      if (refusal == RoomSendRefusal.roomEnded) {
        _onRoomGone();
      } else if (refusal == RoomSendRefusal.shareDenied) {
        // The server no longer counts me as a member.
        setState(() => _canShare = false);
        unawaited(_refreshMyPermission());
      }
      final reason = _roomEndMessage ??
          refusal?.message ??
          'Could not check encryption keys';
      for (final s in targets) {
        failed[s.member.userId] = reason;
      }
      return failed;
    }

    if (rows != null) {
      final resolved = resolveRoomMemberKeys(
        targets.map((s) => s.member.userId),
        rows,
      );
      keys.addAll(resolved.keys);
      for (final id in resolved.notMembers) {
        failed[id] = RoomSendRefusal.recipientNotMember.message;
      }
      return failed;
    }

    // Before 20261113000005: one lookup per member, by code.
    for (final state in targets) {
      try {
        final recip =
            await IdentityService.findUserByCode(state.member.shortCode);
        final key = (recip?['public_key'] as String?)?.trim();
        keys[state.member.userId] = (key == null || key.isEmpty) ? null : key;
      } catch (_) {
        failed[state.member.userId] =
            'Could not check this member\'s encryption key';
      }
    }
    return failed;
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
      _selectedFiles.fold<int>(0, (sum, f) => sum + (f.lengthSync() ?? 0));

  /// Bottom actions for the current phase.
  Widget _buildActions() {
    if (_busy) {
      return MiniButton(
        label: _phase == _SendPhase.preparing ? 'Preparing…' : 'Sending…',
        loading: true,
      );
    }
    if (_phase == _SendPhase.finished || _roomEnd != null) {
      final done = MiniButton(
        label: 'Done',
        style: _canRetry ? MiniBtnStyle.secondary : MiniBtnStyle.primary,
        onPressed: () => Navigator.pop(context),
      );
      if (!_canRetry) return done;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          MiniButton(
            label: 'Retry failed ($_failedCount)',
            onPressed: _retryFailed,
          ),
          const SizedBox(height: 10),
          done,
        ],
      );
    }
    return MiniButton(
      label: 'Send to ${_memberStates.length} member(s)',
      onPressed:
          _selectedFiles.isEmpty || !_canShare || !_isMember ? null : _send,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    // System back must be blocked too, not just the AppBar close: popping
    // mid-send abandons the loop between members, so some members get the
    // files and the rest never do. (Navigator.pop ignores this; dispose
    // cancels the upload in that case.)
    final editable = _phase == _SendPhase.idle && _roomEnd == null;
    return PopScope(
      canPop: !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _busy) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Wait for the send to finish.'),
            ),
          );
        }
      },
      child: Scaffold(
        backgroundColor: c.paper,
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(MiniIcons.close),
            onPressed: _busy ? null : () => Navigator.pop(context),
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
                        if (editable && _selectedFiles.isNotEmpty)
                          Material(
                            color: c.inkSoft.withValues(
                                alpha: context.isDarkMini ? 0.16 : 0.10),
                            borderRadius:
                                BorderRadius.circular(MiniRadius.pill),
                            child: InkWell(
                              onTap: _pickFiles,
                              borderRadius:
                                  BorderRadius.circular(MiniRadius.pill),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 13, vertical: 7),
                                child: Text(
                                  'Add more',
                                  style: GoogleFonts.outfit(
                                    fontSize: 12.5,
                                    height: 1.2,
                                    color: c.inkSoft,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    if (_selectedFiles.isEmpty)
                      GestureDetector(
                        onTap: editable ? _pickFiles : null,
                        child: Container(
                          height: 160,
                          decoration: miniCard(context),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                MiniIconPlate(
                                  icon: MiniIcons.add,
                                  tint: c.accent,
                                  size: 52,
                                  iconSize: 26,
                                  radius: 10,
                                ),
                                const SizedBox(height: 14),
                                Text(
                                  'Tap to choose files',
                                  style: MiniText.body.copyWith(
                                    fontWeight: FontWeight.w500,
                                    color: c.ink,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      )
                    else
                      for (var i = 0; i < _selectedFiles.length; i++)
                        Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          decoration:
                              miniCard(context, radius: MiniRadius.tile),
                          child: MiniFileRow(
                            name: _selectedFiles[i].name,
                            size: TransferService.formatFileSize(
                                _selectedFiles[i].lengthSync() ?? 0),
                            mimeCategory: MiniFileRow.categoryFromFileName(
                                _selectedFiles[i].name),
                            trailing: !editable
                                ? null
                                : GestureDetector(
                                    onTap: () => setState(() {
                                      _selectedFiles = List.from(_selectedFiles)
                                        ..removeAt(i);
                                    }),
                                    child: Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: Icon(MiniIcons.close,
                                          size: 16, color: c.inkFaint),
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

                    if (_roomEnd != null && !_busy) ...[
                      const SizedBox(height: 8),
                      StatusBanner(
                        icon: MiniIcons.timer,
                        text: '${_roomEndMessage!} Nothing more can be sent '
                            'to it.',
                        tint: MiniColors.warn,
                      ),
                    ] else if (!_isMember && !_busy) ...[
                      const SizedBox(height: 8),
                      StatusBanner(
                        icon: MiniIcons.blocked,
                        text: 'You are no longer a member of this room.',
                        tint: MiniColors.warn,
                      ),
                    ] else if (!_canShare && !_busy) ...[
                      const SizedBox(height: 8),
                      StatusBanner(
                        icon: MiniIcons.blocked,
                        text: 'The host has paused sharing for you '
                            'in this room.',
                        tint: MiniColors.warn,
                      ),
                    ],

                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      StatusBanner(
                        icon: MiniIcons.error,
                        text: _error!,
                        tint: MiniColors.danger,
                      ),
                    ],

                    if (_phase == _SendPhase.sending) ...[
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
              child: _buildActions(),
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
          MiniIcons.history,
          c.inkFaint,
          'Waiting',
        ),
      _MemberSendStatus.sending => (
          MiniIcons.send,
          c.accent,
          'Sending $completedFiles / $totalFiles',
        ),
      _MemberSendStatus.done => (
          MiniIcons.success,
          MiniColors.success,
          'Delivered',
        ),
      _MemberSendStatus.failed => (
          MiniIcons.error,
          MiniColors.danger,
          error ?? 'Failed',
        ),
    };

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 11, 14, 11),
      decoration: miniCard(context, radius: MiniRadius.tile),
      child: Row(
        children: [
          MiniIconPlate(
              icon: icon, tint: tint, size: 36, iconSize: 18, radius: 8),
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
                    letterSpacing: -0.2,
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
          const SizedBox(width: 8),
          Text(
            detail,
            style: GoogleFonts.outfit(
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              color: tint,
            ),
          ),
        ],
      ),
    );
  }
}
