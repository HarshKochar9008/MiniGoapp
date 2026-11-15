import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../../core/analytics/analytics.dart';
import '../../core/constants.dart';
import '../../core/contacts/contact_aliases.dart';
import '../../core/contacts/recent_recipients.dart';
import '../../core/errors/app_error_handler.dart';
import '../contacts/contact_alias_sheet.dart';
import '../../core/network/connection_status.dart';
import '../../core/network/network_errors.dart';
import '../../Minigo/theme/mini_theme.dart';
import '../../Minigo/widgets/mini_widgets.dart';
import '../identity/identity_service.dart';
import '../qr/qr_widgets.dart';
import '../rooms/room_lifecycle.dart';
import '../rooms/room_send_screen.dart';
import '../rooms/room_service.dart';
import '../transfer/transfer_progress_widgets.dart';
import '../transfer/transfer_service.dart';
import '../../Minigo/theme/mini_icons.dart';
import 'send_destination.dart';

class SendScreen extends StatefulWidget {
  final UserIdentity identity;

  /// Files to pre-select, e.g. shared to the app via the system share sheet.
  final List<PlatformFile> initialFiles;

  /// Recipient code to prefill and validate on open, e.g. from the home
  /// screen's QR scan shortcut.
  final String? initialRecipientCode;

  /// Works out whether a typed code is a person or a room.
  final SendDestinationResolver resolver;

  const SendScreen({
    super.key,
    required this.identity,
    this.initialFiles = const [],
    this.initialRecipientCode,
    this.resolver = const SendDestinationResolver(),
  });

  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<SendScreen> with WidgetsBindingObserver {
  final _codeController = TextEditingController();
  final _codeFocus = FocusNode();
  List<PlatformFile> _selectedFiles = [];
  List<FileUploadProgress>? _uploadStates;
  bool _validatingCode = false;
  bool _codeValidated = false;
  bool _sending = false;
  String? _error;

  /// Neutral notice (e.g. a resumed upload) — not an error, so not red.
  String? _info;
  String? _codeError;

  /// Set when validation fails because a code saved in recent recipients no
  /// longer exists — drives the "Forget this code" action under the error.
  String? _staleRecentCode;

  /// Numbers each recipient lookup. Anything that changes the code field bumps
  /// it, so a lookup that returns for a code no longer on screen is dropped
  /// instead of marking the new code verified with the old person's id.
  int _validationSeq = 0;
  String? _validatedRecipientId;
  String? _validatedRecipientKey;
  String? _validatedRecipientNickname;

  /// Set instead of the recipient fields when the code is a room's. The
  /// files are then handed to [RoomSendScreen] rather than sent from here.
  RoomDestination? _room;

  /// Joining the room and/or loading its members before the hand-off.
  bool _openingRoom = false;

  /// Rooms I'm in, offered as one-tap destinations and matched against typed
  /// codes without spending a metered room lookup.
  List<Room> _myRooms = const [];
  TransferCancellationToken? _uploadCancellationToken;
  final Battery _battery = Battery();
  bool _powerSaveMode = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ContactAliases.ensureLoaded();
    RecentRecipients.ensureLoaded();
    RecentRecipients.revision.addListener(_onRecentsChanged);
    // Rebuild when the field gains/loses focus so suggestions show/hide.
    _codeFocus.addListener(_onCodeFocusChanged);
    _applyInitialFiles();
    _refreshPowerSaveMode();
    unawaited(_loadMyRooms());
    final initialCode = widget.initialRecipientCode;
    if (initialCode != null) _codeController.text = initialCode;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_checkInterruptedUploadRecovery());
      if (initialCode != null) unawaited(_validateCode());
    });
  }

  /// Best effort: without it the room chips are missing and a room code
  /// costs one metered lookup, nothing more.
  Future<void> _loadMyRooms() async {
    try {
      final rooms = await RoomService.listMyRooms(widget.identity.id);
      if (!mounted) return;
      setState(() => _myRooms = rooms);
    } catch (_) {}
  }

  /// True once the code on screen is known to be a person or a room.
  bool get _destinationResolved => _codeValidated || _room != null;

  /// Forgets what the code resolved to. Call inside setState whenever the
  /// code on screen changes.
  void _clearDestination() {
    _codeValidated = false;
    _validatedRecipientId = null;
    _validatedRecipientKey = null;
    _validatedRecipientNickname = null;
    _room = null;
  }

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
  void dispose() {
    // Nothing else can show or cancel an upload once this screen is gone.
    _uploadCancellationToken?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    RecentRecipients.revision.removeListener(_onRecentsChanged);
    _codeFocus.removeListener(_onCodeFocusChanged);
    _codeFocus.dispose();
    _codeController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshPowerSaveMode();
    }
  }

  Future<void> _refreshPowerSaveMode() async {
    final enabled = await _isPowerSaveModeEnabled();
    if (!mounted) return;
    setState(() => _powerSaveMode = enabled);
  }

  Future<void> _checkInterruptedUploadRecovery() async {
    // A send still running is not "interrupted": offering to discard it would
    // mark the live transfer failed while its files keep arriving.
    if (TransferService.isSendInFlight) return;
    final pending = await TransferService.getPendingUploadJob(
      senderId: widget.identity.id,
    );
    if (!mounted || pending == null || TransferService.isSendInFlight) return;

    final existing = <PlatformFile>[];
    for (final file in pending.toPlatformFiles()) {
      final p = file.path;
      if (p != null && await File(p).exists()) {
        existing.add(file);
      }
    }
    if (!mounted) return;

    if (existing.isEmpty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Interrupted send'),
          content: const Text(
            'A previous send did not finish, but the saved files are no longer '
            'on this device. Discard this reminder?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Discard'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (discard == true) {
        await TransferService.discardPendingUploadJob(
          senderId: widget.identity.id,
        );
      }
      return;
    }

    final shouldResume = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Resume interrupted upload?'),
        content: Text(
          'An upload of ${existing.length} file(s) didn’t finish. Resume it?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Discard'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Resume'),
          ),
        ],
      ),
    );

    if (!mounted) return;
    if (shouldResume != true) {
      await TransferService.discardPendingUploadJob(
          senderId: widget.identity.id);
      return;
    }

    final resumedKey = pending.receiverPublicKey;
    final resumedCode = pending.receiverCode?.trim() ?? '';
    // Only trust the saved recipient when the code it belongs to is what the
    // field will show: a job without a code (or with the field left holding
    // whatever was typed) would otherwise send to an id nobody can see.
    final hasResumedKey =
        resumedKey != null && resumedKey.isNotEmpty && resumedCode.isNotEmpty;
    setState(() {
      _selectedFiles = existing;
      _codeError = null;
      _info = existing.length == pending.files.length
          ? 'Resumed interrupted upload. Swipe to send to continue.'
          : 'Resumed interrupted upload. Some files are no longer on this '
              'device; the rest will finish the same transfer, and files '
              'already delivered won’t be sent again.';
      // Abandon any lookup still running for what was typed before.
      _validationSeq++;
      _validatingCode = false;
      if (resumedCode.isNotEmpty) {
        _codeController.text = resumedCode;
      }
      _clearDestination();
      if (hasResumedKey) {
        _validatedRecipientId = pending.receiverId;
        _validatedRecipientKey = resumedKey;
        _codeValidated = true;
      }
      // Otherwise the job predates key persistence (or the recipient had no
      // key when the send started): re-validate below so a keyed recipient
      // never resumes into an unencrypted upload.
    });
    if (!hasResumedKey && _codeController.text.trim().isNotEmpty) {
      await _validateCode();
    }
  }

  Future<bool> _confirmMeteredUploadIfNeeded() async {
    final isMetered = await ConnectionStatus.instance.isLikelyMetered();
    if (!mounted) return false;
    final threshold = isMetered
        ? AppConstants.cellularMeteredWarnThresholdBytes
        : AppConstants.largeUploadWarnThresholdBytes;
    if (_totalSize < threshold) return true;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isMetered ? 'Using mobile data' : 'Large upload'),
        content: Text(
          isMetered
              ? 'This upload is ${_formatSize(_totalSize)} and may use significant cellular data. Continue?'
              : 'This upload is ${_formatSize(_totalSize)}. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<bool> _isPowerSaveModeEnabled() async {
    try {
      return await _battery.isInBatterySaveMode;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _confirmPowerSaveUploadIfNeeded() async {
    if (_totalSize < AppConstants.largeUploadWarnThresholdBytes) return true;
    final powerSave = await _isPowerSaveModeEnabled();
    if (!powerSave || !mounted) return true;

    final approved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Battery saver is on'),
        content: Text(
          'This upload is ${_formatSize(_totalSize)}. Power-save mode may throttle network. Continue anyway?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    return approved ?? false;
  }

  Future<void> _pickFiles() async {
    try {
      final result = await FilePicker.pickFiles(type: FileType.any);
      if (!mounted) return;

      final accessibleRaw = result.where((f) => f.path != null).toList();
      final seenNames = <String>{};
      final accessible = <PlatformFile>[];
      for (final f in accessibleRaw) {
        if (seenNames.add(f.name)) accessible.add(f);
      }

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
      final duplicates =
          accessible.where((f) => existingNames.contains(f.name)).toList();
      final newFiles =
          accessible.where((f) => !existingNames.contains(f.name)).toList();

      if (newFiles.isEmpty && duplicates.isNotEmpty) {
        _showDuplicateAlert(duplicates.map((f) => f.name).toList());
        return;
      }

      final totalCount = _selectedFiles.length + newFiles.length;
      if (totalCount > AppConstants.maxFilesPerTransfer) {
        setState(() {
          _error = 'Max ${AppConstants.maxFilesPerTransfer} files per transfer';
        });
        return;
      }

      setState(() {
        _selectedFiles = [..._selectedFiles, ...newFiles];
        _error = null;
      });

      if (duplicates.isNotEmpty) {
        _showDuplicateAlert(duplicates.map((f) => f.name).toList());
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Could not pick files. Check app permissions.');
      }
    }
  }

  void _removeFile(int index) {
    setState(() {
      _selectedFiles = List.from(_selectedFiles)..removeAt(index);
    });
  }

  void _clearAll() {
    setState(() {
      _selectedFiles = [];
    });
  }

  void _showDuplicateAlert(List<String> fileNames) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Duplicate files'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              fileNames.length == 1 ? 'Already added:' : 'Already added:',
              style: MiniText.bodySoft,
            ),
            const SizedBox(height: 8),
            ...fileNames.map(
              (name) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(name,
                    style: MiniText.small, overflow: TextOverflow.ellipsis),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _scanCode() async {
    final code = await QrScannerSheet.show(context);
    if (code == null || !mounted) return;
    setState(() {
      _codeController.text = code;
      _clearDestination();
      _codeError = null;
    });
    await _validateCode();
  }

  void _onRecentsChanged() {
    if (mounted) setState(() {});
  }

  void _onCodeFocusChanged() {
    if (mounted) setState(() {});
  }

  /// Recent recipient codes to suggest under the field, filtered by what's
  /// typed. Hidden once a code is validated or while sending.
  List<RecentRecipient> get _recentSuggestions {
    if (_destinationResolved || _sending) return const [];
    return RecentRecipients.matching(_codeController.text).take(5).toList();
  }

  /// Rooms I'm in whose code matches what's typed so far (all of them while
  /// the field is empty).
  List<Room> get _roomSuggestions {
    if (_destinationResolved || _sending) return const [];
    final typed = AppConstants.normalizeShortCode(_codeController.text);
    return _myRooms
        .where((r) => !r.isExpired && r.code.startsWith(typed))
        .take(4)
        .toList();
  }

  Future<void> _applyRecentCode(String code) async {
    _codeFocus.unfocus();
    _codeController.text = code;
    setState(() {
      _clearDestination();
      _codeError = null;
    });
    await _validateCode();
  }

  /// Removes a saved recipient code that no longer resolves to a user, then
  /// clears the field so a current code can be entered.
  Future<void> _forgetStaleRecentCode() async {
    final code = _staleRecentCode;
    if (code == null) return;
    await RecentRecipients.remove(code);
    if (!mounted) return;
    setState(() {
      _staleRecentCode = null;
      _codeError = null;
      _codeController.clear();
    });
    _codeFocus.requestFocus();
  }

  /// Opens the local "Name this person" sheet for the validated recipient.
  /// Optional — the user can skip it and just send.
  Future<void> _nameRecipient() async {
    final id = _validatedRecipientId;
    if (id == null) return;
    await ContactAliasSheet.show(
      context,
      userId: id,
      code: AppConstants.normalizeShortCode(_codeController.text),
    );
    if (mounted) setState(() {}); // reflect the new/updated alias
  }

  /// The name to show for the validated person: my local alias for them,
  /// else the nickname they chose, else nothing (the code is on screen).
  String? get _recipientDisplayName =>
      ContactAliases.aliasFor(_validatedRecipientId) ??
      _validatedRecipientNickname;

  /// Shown once the code is known to be a person's: who the files go to, and
  /// an optional action to save (or rename) a device-only name for them.
  Widget _personCard() {
    final c = context.mini;
    final alias = ContactAliases.aliasFor(_validatedRecipientId);
    final name = _recipientDisplayName;
    final code = AppConstants.normalizeShortCode(_codeController.text);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        decoration: miniCard(context, radius: MiniRadius.control),
        child: Row(
          children: [
            _DestinationAvatar(label: name ?? code, tint: MiniColors.success),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name != null ? 'Sending to $name' : 'Sending to one person',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: MiniText.body.copyWith(
                      fontWeight: FontWeight.w600,
                      color: c.ink,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Person · only they get these files',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: MiniText.small.copyWith(color: c.inkSoft),
                  ),
                ],
              ),
            ),
            if (!_sending)
              _GhostAction(
                label: alias != null ? 'Rename' : 'Name',
                color: c.accent,
                onTap: _nameRecipient,
              ),
          ],
        ),
      ),
    );
  }

  /// Rooms I'm in, as one-tap destinations above the recent people.
  Widget _roomSuggestionChips() {
    final c = context.mini;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
      child: SizedBox(
        width: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('YOUR ROOMS', style: MiniText.label),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final room in _roomSuggestions)
                  Material(
                    color: c.sand,
                    borderRadius: BorderRadius.circular(MiniRadius.chip),
                    child: InkWell(
                      onTap: () => _applyRecentCode(room.code),
                      borderRadius: BorderRadius.circular(MiniRadius.chip),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(MiniIcons.rooms, size: 16, color: c.inkSoft),
                            const SizedBox(width: 8),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                ConstrainedBox(
                                  constraints:
                                      const BoxConstraints(maxWidth: 130),
                                  child: Text(
                                    room.name,
                                    overflow: TextOverflow.ellipsis,
                                    style: GoogleFonts.outfit(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w600,
                                      color: c.ink,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _peopleCount(room.memberCount),
                                  style:
                                      MiniText.small.copyWith(color: c.inkSoft),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _peopleCount(int n) => n == 1 ? '1 person' : '$n people';

  /// Whether the room's button can do anything: a member needs permission to
  /// share and someone to share with; anyone else can always try to join.
  bool _canOpenRoom(RoomDestination dest) {
    if (_openingRoom) return false;
    if (!dest.isMember) return true;
    return dest.canShare && dest.recipients.isNotEmpty;
  }

  /// Shown once the code is known to be a room's. Says plainly that this is a
  /// group, who is in it, and what the button below will do — joining a room
  /// is never silent.
  Widget _roomCard(RoomDestination dest) {
    final c = context.mini;
    final room = dest.room;
    final others = dest.recipients;
    final left = room.timeLeft;

    final String detail;
    Color detailColor = c.inkSoft;
    if (!dest.isMember) {
      detail = 'You’re not in this room yet. Joining adds you as a member '
          'that everyone in it can see. You’ll see who’s in it before '
          'anything is sent.';
    } else if (!dest.canShare) {
      detail = 'The host has paused sharing for you in this room.';
      detailColor = MiniColors.warn;
    } else if (others.isEmpty) {
      detail = 'No one else has joined this room yet, so there’s nobody to '
          'send to.';
      detailColor = MiniColors.warn;
    } else {
      detail = 'Everyone else in this room (${_peopleCount(others.length)}) '
          'will get these files.';
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: miniCard(context, radius: MiniRadius.control),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                MiniIconPlate(icon: MiniIcons.rooms, tint: c.accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        room.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: MiniText.body.copyWith(
                          fontWeight: FontWeight.w600,
                          color: c.ink,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          'Room',
                          if (dest.isMember)
                            '${dest.members.length} '
                                'member${dest.members.length == 1 ? '' : 's'}',
                          roomCardTimeLeft(left),
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: MiniText.small.copyWith(
                          color:
                              left.inMinutes < 10 ? MiniColors.warn : c.inkSoft,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (others.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                _memberNamesLine(others),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: MiniText.small.copyWith(color: c.ink),
              ),
            ],
            const SizedBox(height: 8),
            Text(detail, style: MiniText.small.copyWith(color: detailColor)),
          ],
        ),
      ),
    );
  }

  /// "Asha, Ravi, K7M2PQ and 2 more".
  String _memberNamesLine(List<RoomMember> others) {
    const shown = 3;
    final names = others
        .take(shown)
        .map((m) => ContactAliases.aliasFor(m.userId) ?? m.displayName)
        .join(', ');
    final extra = others.length - shown;
    return extra > 0 ? '$names and $extra more' : names;
  }

  /// Joins the room if needed, then hands the selected files to the room
  /// send screen, which shows every member and does the sending.
  Future<void> _openRoom() async {
    final dest = _room;
    if (dest == null || !_canOpenRoom(dest)) return;
    final me = widget.identity.id;
    final joining = !dest.isMember;
    setState(() {
      _openingRoom = true;
      _error = null;
    });
    HapticFeedback.selectionClick();

    String? failure;
    try {
      if (joining) {
        await RoomService.joinResolvedRoom(room: dest.room, userId: me);
      }
      // Read after the join: this is the list the files will go to.
      final fresh = await widget.resolver.refreshRoom(dest.room, me);
      if (!mounted) return;
      if (!fresh.isMember) {
        failure = joining
            ? 'Couldn’t join this room. Try again.'
            : 'You are no longer a member of this room.';
      } else if (!fresh.canShare || fresh.recipients.isEmpty) {
        // The card explains which; the button is disabled for both.
        setState(() => _room = fresh);
      } else {
        if (joining) unawaited(_loadMyRooms());
        Analytics.instance.logEvent(AnalyticsEvents.sendCodeValidated, {
          'kind': joining ? 'room_joined' : 'room_opened',
          'file_count': _selectedFiles.length,
        });
        await Navigator.pushReplacement(
          context,
          MaterialPageRoute<void>(
            builder: (_) => RoomSendScreen(
              identity: widget.identity,
              room: fresh.room,
              recipients: fresh.recipients,
              initialFiles: List<PlatformFile>.of(_selectedFiles),
            ),
          ),
        );
        return;
      }
    } on RoomFullException catch (e) {
      failure = e.toString();
    } on RoomExpiredException catch (e) {
      failure = e.toString();
    } on RoomClosedException catch (e) {
      failure = e.toString();
    } catch (e) {
      Analytics.instance.logError(AnalyticsEvents.sendFailed, e);
      failure = NetworkErrors.isRetryableFailure(e)
          ? 'Can’t reach MiniGo. Check your connection and try again.'
          : 'Couldn’t open this room. Try again.';
      if (mounted) {
        unawaited(AppErrorHandler.maybeShowServiceOutage(context, e));
      }
    } finally {
      if (mounted) setState(() => _openingRoom = false);
    }
    if (mounted && failure != null) setState(() => _error = failure);
  }

  Future<void> _validateCode() async {
    final seq = ++_validationSeq;
    bool stale() => !mounted || seq != _validationSeq;
    // The bump above orphans any lookup in flight, so it will never clear
    // the spinner itself — every early exit here has to.
    void reject(String message) => setState(() {
          _codeError = message;
          _validatingCode = false;
        });
    final code = AppConstants.normalizeShortCode(_codeController.text);
    if (code.isEmpty) {
      reject('Enter a recipient code');
      return;
    }
    if (code.length != AppConstants.codeLength) {
      reject('Code must be exactly ${AppConstants.codeLength} characters');
      return;
    }
    if (!AppConstants.isValidShortCodeFormat(code)) {
      reject('Use only A-Z and 2-9 (excluding O, I, L, 0, 1)');
      return;
    }
    if (code == widget.identity.shortCode) {
      reject('You cannot send files to yourself');
      return;
    }

    final online = await ConnectionStatus.instance.refresh();
    if (stale()) return;
    if (!online) {
      reject('No internet connection');
      return;
    }

    setState(() {
      _validatingCode = true;
      _codeError = null;
      _staleRecentCode = null;
    });

    try {
      final destination = await widget.resolver.resolve(
        code: code,
        myUserId: widget.identity.id,
        knownRooms: _myRooms,
      );
      if (stale()) return;

      if (destination == null) {
        // A dead saved code usually means that person's identity was reset
        // (reinstall, cleared data) and their code changed.
        final isSavedCode = RecentRecipients.all.any((r) => r.code == code);
        Analytics.instance.logEvent(AnalyticsEvents.sendCodeInvalid,
            {'reason': 'not_found', 'stale_recent': isSavedCode});
        HapticFeedback.lightImpact();
        setState(() {
          _codeError = isSavedCode
              ? 'No one found with code "$code". This saved code may be out '
                  'of date. Ask them for their current code.'
              : 'No person or room found with code "$code"';
          _staleRecentCode = isSavedCode ? code : null;
          _validatingCode = false;
        });
        return;
      }

      setState(() {
        _validatingCode = false;
        _clearDestination();
        switch (destination) {
          case PersonDestination():
            _codeValidated = true;
            _validatedRecipientId = destination.userId;
            _validatedRecipientKey = destination.publicKey;
            _validatedRecipientNickname = destination.nickname;
          case RoomDestination():
            _room = destination;
        }
      });
      HapticFeedback.lightImpact();
      Analytics.instance.logEvent(AnalyticsEvents.sendCodeValidated, {
        'kind': switch (destination) {
          PersonDestination() => 'person',
          RoomDestination(isMember: true) => 'room_member',
          RoomDestination() => 'room_not_member',
        },
      });
    } on RoomExpiredException {
      Analytics.instance.logEvent(
          AnalyticsEvents.sendCodeInvalid, {'reason': 'room_expired'});
      if (stale()) return;
      HapticFeedback.lightImpact();
      reject('This is a room code, but the room has expired.');
    } on RoomLookupThrottledException {
      Analytics.instance.logEvent(
          AnalyticsEvents.sendCodeInvalid, {'reason': 'room_lookup_throttled'});
      if (stale()) return;
      // Only reached once the code was found not to be a person's.
      reject('No person found with code "$code". Too many codes have been '
          'tried to check it as a room. Wait a few minutes and try again.');
    } on PostgrestException catch (e) {
      Analytics.instance.logError(AnalyticsEvents.sendCodeInvalid, e);
      if (mounted && seq == _validationSeq) {
        setState(() {
          _codeError = 'Couldn’t check this code. Try again.';
          _validatingCode = false;
        });
        unawaited(AppErrorHandler.maybeShowServiceOutage(context, e));
      }
    } catch (e) {
      Analytics.instance.logError(AnalyticsEvents.sendCodeInvalid, e);
      if (mounted && seq == _validationSeq) {
        setState(() {
          _codeError = NetworkErrors.isRetryableFailure(e)
              ? 'Can’t reach MiniGo to check this code. Check your '
                  'connection and try again.'
              : 'Couldn’t check this code. Try again.';
          _validatingCode = false;
        });
        unawaited(AppErrorHandler.maybeShowServiceOutage(context, e));
      }
    }
  }

  /// True when the validated recipient published an X25519 public key, i.e.
  /// their files can actually be end-to-end encrypted.
  bool get _recipientIsEncryptable =>
      (_validatedRecipientKey?.trim().isNotEmpty) ?? false;

  Future<void> _send() async {
    if (_validatedRecipientId == null || _selectedFiles.isEmpty) return;

    // The checks below await dialogs and network calls while the code field,
    // recent chips and file list stay editable. Everything confirmed here —
    // above all the "not encrypted" warning — is about this recipient and
    // these files, so the send aborts if either changed in the meantime.
    final recipientId = _validatedRecipientId!;
    final recipientKey = _validatedRecipientKey;
    final recipientCode = AppConstants.normalizeShortCode(_codeController.text);
    final allowUnencrypted = !_recipientIsEncryptable;
    final files = List<PlatformFile>.of(_selectedFiles);
    bool selectionChanged() {
      if (_validatedRecipientId != recipientId ||
          _validatedRecipientKey != recipientKey ||
          AppConstants.normalizeShortCode(_codeController.text) !=
              recipientCode ||
          _selectedFiles.length != files.length) {
        return true;
      }
      for (var i = 0; i < files.length; i++) {
        if (!identical(_selectedFiles[i], files[i])) return true;
      }
      return false;
    }

    // Checked before the push probe: it costs no network round trip, and it is
    // the more consequential of the two warnings.
    if (!_recipientIsEncryptable) {
      final proceed = await _confirmSendWithoutEncryption();
      if (proceed != true || !mounted) return;
      setState(() => _error = null);
    }

    final pushReadiness =
        await TransferService.verifyClosedAppDeliveryReadiness(
      receiverId: recipientId,
    );
    if (!pushReadiness.ready) {
      if (!mounted) return;
      final reason = pushReadiness.reason ??
          'Incoming delivery while recipient app is closed is not configured.';
      final proceed = await _confirmSendWithoutPush(reason);
      if (proceed != true || !mounted) {
        setState(() => _error = reason);
        return;
      }
      // User chose to send anyway — clear stale error and continue.
      setState(() => _error = null);
    }

    final powerApproved = await _confirmPowerSaveUploadIfNeeded();
    if (!powerApproved || !mounted) return;
    final confirmed = await _confirmMeteredUploadIfNeeded();
    if (!confirmed || !mounted) return;

    final online = await ConnectionStatus.instance.refresh();
    if (!mounted) return;
    if (!online) {
      setState(() {
        _error = 'No internet connection. Try again when you are online.';
      });
      return;
    }

    if (selectionChanged()) {
      setState(() {
        _error = 'The recipient or files changed. Check them and send again.';
      });
      return;
    }

    setState(() {
      _sending = true;
      _uploadStates = null;
      _error = null;
      _info = null;
      _uploadCancellationToken = TransferCancellationToken();
    });

    Analytics.instance.logEvent(AnalyticsEvents.sendStarted, {
      'file_count': files.length,
      'total_bytes': _totalSize,
    });

    try {
      final result = await TransferService.sendFiles(
        senderId: widget.identity.id,
        receiverId: recipientId,
        receiverCode: recipientCode,
        recipientPublicKey: recipientKey,
        // Only ever true once _confirmSendWithoutEncryption() said so above.
        allowUnencrypted: allowUnencrypted,
        files: files,
        cancellationToken: _uploadCancellationToken,
        onProgress: (states) {
          if (mounted) setState(() => _uploadStates = states);
        },
      );

      if (!mounted) return;

      if (result.success) {
        HapticFeedback.heavyImpact();
        // Remember this recipient so it can be suggested next time.
        unawaited(RecentRecipients.record(
          AppConstants.normalizeShortCode(_codeController.text),
          label: _recipientDisplayName,
        ));
        Analytics.instance.logEvent(AnalyticsEvents.sendCompleted, {
          'file_count': result.completedFiles,
          'total_bytes': _totalSize,
        });
        await _showSendSuccessSheet(result.completedFiles);
        if (!mounted) return;
        Navigator.pop(context);
      } else {
        // While the saved job is kept, sending the same selection again
        // resumes this transfer and only retries the files that failed.
        final failureMessage = result.canResume
            ? '${_buildPartialFailureMessage(result)} '
                'Swipe to send again to retry.'
            : _buildPartialFailureMessage(result);
        Analytics.instance.logEvent(AnalyticsEvents.sendFailed, {
          'partial': true,
          'completed': result.completedFiles,
          // Not failureMessage: that names the file, and logs leave the
          // device.
          'reason': _firstFailureReason(result) ?? 'unknown',
        });
        HapticFeedback.lightImpact();
        setState(() {
          _error = failureMessage;
          _sending = false;
        });
      }
    } on TransferCancelledException catch (_) {
      Analytics.instance.logEvent(AnalyticsEvents.sendCancelled);
      if (mounted) {
        setState(() {
          _error = 'Transfer cancelled';
          _sending = false;
        });
      }
    } on TransferNotAcceptingUploadsException catch (e) {
      Analytics.instance.logError(AnalyticsEvents.sendFailed, e);
      if (mounted) {
        HapticFeedback.lightImpact();
        setState(() {
          _error = e.expired
              ? 'This transfer expired before all files were sent. '
                  'Files that arrived were removed with it. Send again to '
                  'start a new transfer.'
              : 'This transfer was already closed, so no more files can be '
                  'added to it. Send again to start a new transfer.';
          _sending = false;
        });
      }
    } on FileTooLargeException catch (e) {
      Analytics.instance.logError(AnalyticsEvents.sendFailed, e);
      if (mounted) {
        setState(() {
          _error = _toUserFriendlyError(e.toString());
          _sending = false;
        });
      }
    } on TooManyFilesException catch (e) {
      Analytics.instance.logError(AnalyticsEvents.sendFailed, e);
      if (mounted) {
        setState(() {
          _error = _toUserFriendlyError(e.toString());
          _sending = false;
        });
      }
    } catch (e) {
      Analytics.instance.logError(AnalyticsEvents.sendFailed, e);
      if (mounted) {
        HapticFeedback.lightImpact();
        setState(() {
          _error = _toUserFriendlyError(e.toString());
          _sending = false;
        });
        // If this failed because our backend is down (not the user's
        // connection), escalate to the service-unavailable sheet.
        unawaited(AppErrorHandler.maybeShowServiceOutage(context, e));
      }
    } finally {
      _uploadCancellationToken = null;
    }
  }

  /// Asked before sending when the recipient has published no X25519 public
  /// key. Their files can then only be uploaded as plaintext, which is a real
  /// change in what the server can see — so it is an explicit decision rather
  /// than a silent downgrade. Usually means they are on an older app build.
  Future<bool?> _confirmSendWithoutEncryption() {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Not end-to-end encrypted'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This recipient has not published an encryption key, so these '
              'files cannot be encrypted for them.',
              style: MiniText.bodySoft,
            ),
            const SizedBox(height: 12),
            Text(
              'They will be uploaded as-is, which means the server can read '
              'them while the transfer is live. Ask them to update MiniGo and '
              'open it once to fix this.',
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
            child: const Text('Send unencrypted'),
          ),
        ],
      ),
    );
  }

  /// Asked before sending when the recipient hasn't registered for push.
  /// They can still receive files via the realtime channel if their app is open,
  /// so this is a confirmation, not a hard block.
  Future<bool?> _confirmSendWithoutPush(String reason) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Recipient may not be notified'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(reason, style: MiniText.bodySoft),
            const SizedBox(height: 12),
            Text(
              'If their MiniGo app is open right now, they will still see '
              'the transfer and can download it. Otherwise it will only '
              'arrive the next time they open the app.',
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

  Future<void> _showSendSuccessSheet(int fileCount) async {
    if (!mounted) return;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _SendSuccessDialog(fileCount: fileCount),
    );
  }

  /// Why the first failed file failed, in the words shown to the user.
  String? _firstFailureReason(TransferResult result) {
    for (final s in result.fileStates) {
      if (s.status == FileUploadStatus.failed) {
        return _toUserFriendlyError(s.error ?? 'Unknown error');
      }
    }
    return null;
  }

  String _buildPartialFailureMessage(TransferResult result) {
    final failed = result.fileStates
        .where((s) => s.status == FileUploadStatus.failed)
        .toList();
    if (failed.isEmpty) return 'Some files could not be sent.';
    final first = failed.first;
    final reason = _firstFailureReason(result)!;
    if (failed.length == 1) return '$reason (${first.fileName})';
    return '$reason (${first.fileName}). ${failed.length - 1} more file(s) failed.';
  }

  String _toUserFriendlyError(String raw) {
    var message = raw.replaceAll('Exception: ', '').trim();
    if (message.contains('Failed after')) {
      final idx = message.indexOf(':');
      if (idx != -1 && idx + 1 < message.length) {
        message = message.substring(idx + 1).trim();
      }
    }
    if (message.contains('No internet connection')) {
      return 'No internet connection. Please try again.';
    }
    if (message.contains('File not accessible on disk')) {
      return 'This file is no longer accessible. Please pick it again.';
    }
    if (message.contains('Hash computation failed')) {
      return 'Could not read this file. Please pick it again.';
    }
    if (message.contains('Upload failed (401') ||
        message.contains('Upload failed (403') ||
        message.contains('R2 signing refused')) {
      return 'Upload permission failed. Please try again.';
    }
    if (message.toLowerCase().contains('protocol(413') ||
        message.toLowerCase().contains('payload too large') ||
        message.toLowerCase().contains('creating upload')) {
      return 'File is too large for the server upload limit.';
    }
    if (message.toLowerCase().contains('invalid') &&
        message.toLowerCase().contains('mime')) {
      return 'This file format is not supported.';
    }
    // Unrecognized errors: never surface raw exception text to the user.
    if (message.length > 120 ||
        message.toLowerCase().contains('exception') ||
        message.contains('errno')) {
      return 'Something went wrong while sending. Please try again.';
    }
    return message;
  }

  void _cancelUpload() {
    _uploadCancellationToken?.cancel();
  }

  String _formatSize(int bytes) => TransferService.formatFileSize(bytes);

  int get _totalSize =>
      _selectedFiles.fold<int>(0, (sum, f) => sum + (f.lengthSync() ?? 0));

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return PopScope(
      // Joining a room is one short request; leaving in the middle of it
      // would hide whether the join happened.
      canPop: !_sending && !_openingRoom,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_openingRoom) _confirmLeaveWhileSending();
      },
      child: Scaffold(
        backgroundColor: c.paper,
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(MiniIcons.close),
            onPressed: () => Navigator.maybePop(context),
          ),
          title: const Text('Send to'),
        ),
        body: Column(
          children: [
            // Recipient code input
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Container(
                padding: const EdgeInsets.all(5),
                decoration: miniCard(context, radius: MiniRadius.control),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _codeController,
                        focusNode: _codeFocus,
                        // Stays editable after validation: onChanged resets the
                        // validated state, so the user can switch recipients
                        // without leaving the screen.
                        enabled: !_sending && !_openingRoom,
                        textCapitalization: TextCapitalization.characters,
                        maxLength: AppConstants.codeLength,
                        textAlign: TextAlign.center,
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                              RegExp(r'[A-Za-z0-9]')),
                          _UpperCaseFormatter(),
                        ],
                        style: GoogleFonts.jetBrainsMono(
                          fontSize: 22,
                          letterSpacing: 3,
                          fontWeight: FontWeight.w600,
                          color: c.ink,
                        ),
                        decoration: InputDecoration(
                          hintText: 'Person or room code',
                          hintStyle: MiniText.body.copyWith(
                            fontSize: 17,
                            color: c.inkFaint,
                          ),
                          counterText: '',
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 14),
                        ),
                        onChanged: (_) {
                          // Rebuild so the recent-code suggestions refilter.
                          setState(() {
                            _staleRecentCode = null;
                            // Abandon any lookup still running for the old text.
                            _validationSeq++;
                            _validatingCode = false;
                            _clearDestination();
                          });
                        },
                      ),
                    ),
                    if (!_destinationResolved && !_sending)
                      SizedBox(
                        width: 40,
                        height: 44,
                        child: IconButton(
                          icon: const Icon(
                            MiniIcons.scanQr,
                            size: 20,
                          ),
                          color: c.inkSoft,
                          onPressed: _scanCode,
                          tooltip: 'Scan QR code',
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: SizedBox(
                        height: 44,
                        child: FilledButton(
                          onPressed: (_validatingCode ||
                                  _sending ||
                                  _destinationResolved)
                              ? null
                              : _validateCode,
                          style: FilledButton.styleFrom(
                            backgroundColor: _destinationResolved
                                ? MiniColors.success
                                : MiniColors.blue600,
                            disabledBackgroundColor: _destinationResolved
                                ? MiniColors.success
                                : MiniColors.blue600.withValues(alpha: 0.45),
                            minimumSize: const Size(0, 44),
                            shape: const StadiumBorder(),
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                          ),
                          child: _validatingCode
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.2,
                                    strokeCap: StrokeCap.round,
                                    color: Colors.white,
                                  ),
                                )
                              : Text(
                                  _destinationResolved ? 'Verified' : 'Check',
                                  style: GoogleFonts.outfit(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Recent recipients — pill chips under the code field, filtered by
            // what's typed so far. Tapping one fills and validates the code.
            if (_roomSuggestions.isNotEmpty) _roomSuggestionChips(),
            if (_recentSuggestions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
                child: SizedBox(
                  width: double.infinity,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('RECENT', style: MiniText.label),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final r in _recentSuggestions)
                            Material(
                              color: c.sand,
                              borderRadius:
                                  BorderRadius.circular(MiniRadius.chip),
                              child: InkWell(
                                onTap: () => _applyRecentCode(r.code),
                                borderRadius:
                                    BorderRadius.circular(MiniRadius.chip),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 10),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        fmtCode(r.code),
                                        style: GoogleFonts.jetBrainsMono(
                                          fontSize: 13,
                                          letterSpacing: 1,
                                          fontWeight: FontWeight.w600,
                                          color: c.ink,
                                        ),
                                      ),
                                      if (r.label != null) ...[
                                        const SizedBox(height: 2),
                                        ConstrainedBox(
                                          constraints: const BoxConstraints(
                                              maxWidth: 110),
                                          child: Text(
                                            r.label!,
                                            overflow: TextOverflow.ellipsis,
                                            style: MiniText.small
                                                .copyWith(color: c.inkSoft),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            if (_codeError != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_codeError!,
                        style:
                            MiniText.small.copyWith(color: MiniColors.danger)),
                    if (_staleRecentCode != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: _GhostAction(
                          label: 'Forget this code',
                          color: c.accent,
                          onTap: _forgetStaleRecentCode,
                        ),
                      ),
                  ],
                ),
              ),
            if (_codeValidated) _personCard(),
            if (_room != null) _roomCard(_room!),

            // The recipient published no X25519 key, so these files would go up
            // as plaintext. Say so before the send, not after.
            if (_codeValidated && !_recipientIsEncryptable)
              StatusBanner(
                icon: MiniIcons.unlock,
                text: 'This recipient has no encryption key yet, so files '
                    'won’t be end-to-end encrypted.',
                tint: MiniColors.warn,
              ),

            // Power save banner
            if (_powerSaveMode)
              StatusBanner(
                icon: MiniIcons.batterySaver,
                text:
                    'Battery saver is on. Large uploads may be slower or pause.',
                tint: MiniColors.warn,
              ),

            // Files section
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Files header
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
                                  '${_selectedFiles.length} selected · ${_formatSize(_totalSize)}',
                                  style: MiniText.small,
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (!_sending && _selectedFiles.isNotEmpty) ...[
                          _GhostAction(label: 'Add more', onTap: _pickFiles),
                          const SizedBox(width: 4),
                          _GhostAction(
                              label: 'Clear all',
                              onTap: _clearAll,
                              color: MiniColors.danger),
                        ],
                      ],
                    ),
                    const SizedBox(height: 12),

                    // File list / progress / empty
                    if (_sending && _uploadStates != null)
                      TransferUploadProgressList(states: _uploadStates!)
                    else if (_selectedFiles.isEmpty)
                      _EmptyFilesMini(onPick: _pickFiles)
                    else
                      for (var i = 0; i < _selectedFiles.length; i++) ...[
                        Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          decoration:
                              miniCard(context, radius: MiniRadius.tile),
                          child: MiniFileRow(
                            name: _selectedFiles[i].name,
                            size: _formatSize(
                                _selectedFiles[i].lengthSync() ?? 0),
                            mimeCategory: MiniFileRow.categoryFromFileName(
                                _selectedFiles[i].name),
                            trailing: _sending
                                ? null
                                : GestureDetector(
                                    onTap: () => _removeFile(i),
                                    child: Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: Icon(MiniIcons.close,
                                          size: 16, color: c.inkFaint),
                                    ),
                                  ),
                          ),
                        ),
                      ],

                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      StatusBanner(
                        icon: MiniIcons.error,
                        text: _error!,
                        tint: MiniColors.danger,
                      ),
                    ] else if (_info != null) ...[
                      const SizedBox(height: 8),
                      StatusBanner(
                        icon: MiniIcons.info,
                        text: _info!,
                        tint: MiniColors.blue600,
                      ),
                    ],

                    if (_codeValidated && _selectedFiles.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Keep the app open while uploading.',
                        style: MiniText.small,
                      ),
                    ],
                  ],
                ),
              ),
            ),

            // Send button
            if (_room != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 34),
                child: MiniButton(
                  label: _room!.isMember
                      ? 'Continue to room'
                      : 'Join room & continue',
                  loading: _openingRoom,
                  onPressed: _canOpenRoom(_room!) ? _openRoom : null,
                ),
              )
            else if (_codeValidated && _selectedFiles.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 34),
                child: FractionallySizedBox(
                  widthFactor: 0.7,
                  child: _sending
                      ? MiniButton(
                          label: _buildSendingLabel(),
                          loading: true,
                          onPressed: null,
                          // Once every file is delivered only the status
                          // write and the push remain; a cancel can no longer
                          // stop anything, so don't offer one.
                          leading: _allFilesDelivered
                              ? null
                              : GestureDetector(
                                  onTap: _cancelUpload,
                                  child: Icon(MiniIcons.close,
                                      size: 16, color: c.inkFaint),
                                ),
                        )
                      : _SwipeToSendButton(onSend: _send),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Closing mid-upload cancels it (see [dispose]), so ask first.
  Future<void> _confirmLeaveWhileSending() async {
    if (!_sending) {
      Navigator.pop(context);
      return;
    }
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel this send?'),
        content: const Text(
          'Closing now stops the upload. Files already delivered stay with '
          'the recipient.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep sending'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cancel send'),
          ),
        ],
      ),
    );
    if (leave == true && mounted) Navigator.pop(context);
  }

  bool get _allFilesDelivered {
    final states = _uploadStates;
    return states != null &&
        states.isNotEmpty &&
        states.every((s) => s.status == FileUploadStatus.completed);
  }

  String _buildSendingLabel() {
    final states = _uploadStates;
    if (states == null) return 'Preparing…';
    if (_allFilesDelivered) return 'Finishing…';
    final done =
        states.where((s) => s.status == FileUploadStatus.completed).length;
    return 'Sending $done / ${states.length}';
  }
}

class _EmptyFilesMini extends StatelessWidget {
  final VoidCallback onPick;
  const _EmptyFilesMini({required this.onPick});

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return GestureDetector(
      onTap: onPick,
      child: Container(
        height: 190,
        decoration: miniCard(context),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              MiniIconPlate(
                icon: MiniIcons.add,
                tint: c.accent,
                size: 56,
                iconSize: 28,
                radius: 10,
              ),
              const SizedBox(height: 16),
              Text(
                'Tap to choose files',
                style: MiniText.body.copyWith(
                  fontWeight: FontWeight.w500,
                  color: c.ink,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                  'Up to ${AppConstants.maxFilesPerTransfer} files, '
                  '${AppConstants.maxFileSizeBytes ~/ 1024 ~/ 1024} MB each',
                  style: MiniText.small),
            ],
          ),
        ),
      ),
    );
  }
}

class _GhostAction extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final Color? color;
  const _GhostAction({required this.label, required this.onTap, this.color});

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    final tone = color ?? c.inkSoft;
    return Material(
      color: tone.withValues(alpha: context.isDarkMini ? 0.16 : 0.10),
      borderRadius: BorderRadius.circular(MiniRadius.pill),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(MiniRadius.pill),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          child: Text(
            label,
            style: GoogleFonts.outfit(
              fontSize: 12.5,
              height: 1.2,
              color: tone,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

/// Round initial for a resolved person.
class _DestinationAvatar extends StatelessWidget {
  final String label;
  final Color tint;
  const _DestinationAvatar({required this.label, required this.tint});

  @override
  Widget build(BuildContext context) {
    final trimmed = label.trim();
    return Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tint.withValues(alpha: context.isDarkMini ? 0.20 : 0.12),
        shape: BoxShape.circle,
      ),
      child: Text(
        trimmed.isEmpty ? '?' : trimmed.characters.first.toUpperCase(),
        style: GoogleFonts.outfit(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: tint,
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

class _SwipeToSendButton extends StatefulWidget {
  final Future<void> Function() onSend;
  const _SwipeToSendButton({required this.onSend});

  @override
  State<_SwipeToSendButton> createState() => _SwipeToSendButtonState();
}

class _SwipeToSendButtonState extends State<_SwipeToSendButton>
    with SingleTickerProviderStateMixin {
  static const _thumbSize = 42.0;
  static const _padding = 5.0;
  static const _fireAt = 0.92;

  late final AnimationController _resetCtrl;
  late final CurvedAnimation _resetCurve;
  Animation<double>? _resetAnim;
  double _progress = 0;
  bool _fired = false;

  @override
  void initState() {
    super.initState();
    _resetCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    )..addListener(_onResetTick);
    _resetCurve =
        CurvedAnimation(parent: _resetCtrl, curve: Curves.easeOutCubic);
  }

  @override
  void dispose() {
    _resetCurve.dispose();
    _resetCtrl.dispose();
    super.dispose();
  }

  // One listener for the widget's lifetime. Adding it inside _snapBack put
  // another on the controller for every released drag.
  void _onResetTick() {
    final anim = _resetAnim;
    if (!mounted || anim == null) return;
    setState(() => _progress = anim.value);
  }

  void _snapBack() {
    _resetAnim = Tween<double>(begin: _progress, end: 0).animate(_resetCurve);
    _resetCtrl
      ..reset()
      ..forward();
  }

  Future<void> _fireSend() async {
    if (_fired) return;
    _fired = true;
    HapticFeedback.heavyImpact();
    try {
      await widget.onSend();
    } finally {
      // Re-arm once the send returns. This matters when the send aborts
      // pre-flight (declined dialog, offline) without ever flipping the
      // parent's _sending flag — otherwise the thumb stays stuck forever.
      if (mounted) {
        setState(() => _fired = false);
        _snapBack();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.clamp(220.0, 360.0);
        final travel = width - (_thumbSize + _padding * 2);
        final thumbLeft = _padding + (travel * _progress);
        final fillWidth = _thumbSize + (travel * _progress);
        final nearDone = _progress >= 0.7;

        return Center(
          child: SizedBox(
            width: width,
            height: 52,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(100),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: c.sand.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(100),
                  ),
                  child: GestureDetector(
                    onHorizontalDragStart: (_) {
                      if (_fired) return;
                      HapticFeedback.selectionClick();
                    },
                    onHorizontalDragUpdate: (details) {
                      if (_fired || travel <= 0) return;
                      _resetCtrl.stop();
                      final delta = details.delta.dx / travel;
                      final next = (_progress + delta).clamp(0.0, 1.0);
                      setState(() => _progress = next);
                      if (_progress >= _fireAt) _fireSend();
                    },
                    onHorizontalDragEnd: (_) {
                      if (_fired) return;
                      _snapBack();
                    },
                    onHorizontalDragCancel: () {
                      if (_fired) return;
                      _snapBack();
                    },
                    child: Stack(
                      children: [
                        Positioned(
                          left: _padding,
                          top: _padding,
                          bottom: _padding,
                          width: fillWidth,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: c.accent.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(100),
                            ),
                          ),
                        ),
                        Center(
                          child: Text(
                            nearDone ? 'Release to send' : 'Swipe to send',
                            style: GoogleFonts.outfit(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              letterSpacing: -0.1,
                              color: nearDone ? c.accent : c.inkSoft,
                            ),
                          ),
                        ),
                        Positioned(
                          left: thumbLeft,
                          top: _padding,
                          child: Container(
                            width: _thumbSize,
                            height: _thumbSize,
                            decoration: BoxDecoration(
                              color: MiniColors.blue600,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: MiniColors.blue600
                                      .withValues(alpha: 0.13),
                                  blurRadius: 7,
                                  offset: const Offset(0, 1.8),
                                ),
                              ],
                            ),
                            child: const Icon(
                              MiniIcons.send,
                              size: 19,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SendSuccessDialog extends StatefulWidget {
  final int fileCount;
  const _SendSuccessDialog({required this.fileCount});

  @override
  State<_SendSuccessDialog> createState() => _SendSuccessDialogState();
}

class _SendSuccessDialogState extends State<_SendSuccessDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;
  late final Animation<double> _check;
  Timer? _autoCloseTimer;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 850),
    );
    _scale = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.0, 0.55, curve: Curves.elasticOut),
    );
    _check = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.35, 1.0, curve: Curves.easeOutCubic),
    );
    _ctrl.forward();
    _autoCloseTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  @override
  void dispose() {
    _autoCloseTimer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(40),
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          final scaleVal = 0.6 + 0.4 * _scale.value;
          return Center(
            child: Transform.scale(
              scale: scaleVal,
              child: Container(
                padding: const EdgeInsets.fromLTRB(30, 34, 30, 30),
                decoration: BoxDecoration(
                  color: c.paperDeep,
                  borderRadius: BorderRadius.circular(MiniRadius.card),
                  boxShadow: [
                    BoxShadow(
                      color: MiniColors.success.withValues(alpha: 0.12),
                      blurRadius: 24,
                      spreadRadius: 2.4,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 72,
                      height: 72,
                      child: CustomPaint(
                        painter: _CheckmarkPainter(_check.value),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Sent',
                      style: GoogleFonts.outfit(
                        fontSize: 28,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.8,
                        color: c.ink,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      widget.fileCount == 1
                          ? '1 file delivered'
                          : '${widget.fileCount} files delivered',
                      style: GoogleFonts.outfit(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: c.inkSoft,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _CheckmarkPainter extends CustomPainter {
  final double progress;
  const _CheckmarkPainter(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final center = Offset(r, r);

    final ringPaint = Paint()
      ..color = MiniColors.success.withValues(alpha: 0.18)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, r, ringPaint);

    final innerPaint = Paint()
      ..color = MiniColors.success
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, r * 0.78, innerPaint);

    final strokePaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    final p1 = Offset(r * 0.62, r * 1.02);
    final p2 = Offset(r * 0.90, r * 1.28);
    final p3 = Offset(r * 1.42, r * 0.78);

    if (progress <= 0) return;
    final path = Path()..moveTo(p1.dx, p1.dy);
    if (progress <= 0.5) {
      final t = progress / 0.5;
      path.lineTo(
        p1.dx + (p2.dx - p1.dx) * t,
        p1.dy + (p2.dy - p1.dy) * t,
      );
    } else {
      path.lineTo(p2.dx, p2.dy);
      final t = (progress - 0.5) / 0.5;
      path.lineTo(
        p2.dx + (p3.dx - p2.dx) * t,
        p2.dy + (p3.dy - p2.dy) * t,
      );
    }
    canvas.drawPath(path, strokePaint);
  }

  @override
  bool shouldRepaint(_CheckmarkPainter old) => old.progress != progress;
}
