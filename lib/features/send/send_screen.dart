import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
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
import '../transfer/transfer_progress_widgets.dart';
import '../transfer/transfer_service.dart';

class SendScreen extends StatefulWidget {
  final UserIdentity identity;

  /// Files to pre-select, e.g. shared to the app via the system share sheet.
  final List<PlatformFile> initialFiles;

  /// Recipient code to prefill and validate on open, e.g. from the home
  /// screen's QR scan shortcut.
  final String? initialRecipientCode;

  const SendScreen({
    super.key,
    required this.identity,
    this.initialFiles = const [],
    this.initialRecipientCode,
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
  String? _codeError;

  /// Set when validation fails because a code saved in recent recipients no
  /// longer exists — drives the "Forget this code" action under the error.
  String? _staleRecentCode;
  String? _validatedRecipientId;
  String? _validatedRecipientKey;
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
    final initialCode = widget.initialRecipientCode;
    if (initialCode != null) _codeController.text = initialCode;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_checkInterruptedUploadRecovery());
      if (initialCode != null) unawaited(_validateCode());
    });
  }

  void _applyInitialFiles() {
    if (widget.initialFiles.isEmpty) return;
    final seenNames = <String>{};
    final valid = <PlatformFile>[];
    String? error;
    for (final f in widget.initialFiles) {
      if (f.path == null || !seenNames.add(f.name)) continue;
      if (f.size > AppConstants.maxFileSizeBytes) {
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
    final pending = await TransferService.getPendingUploadJob(
      senderId: widget.identity.id,
    );
    if (!mounted || pending == null) return;

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
          'We found an interrupted upload with ${existing.length} file(s). '
          'Do you want to resume it?',
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
    final hasResumedKey = resumedKey != null && resumedKey.isNotEmpty;
    setState(() {
      _selectedFiles = existing;
      _codeError = null;
      _error = 'Resumed interrupted upload. Tap Send to continue.';
      if (pending.receiverCode != null && pending.receiverCode!.isNotEmpty) {
        _codeController.text = pending.receiverCode!;
      }
      if (hasResumedKey) {
        _validatedRecipientId = pending.receiverId;
        _validatedRecipientKey = resumedKey;
        _codeValidated = true;
      } else {
        // Job predates key persistence (or the recipient had no key when the
        // send started). Re-validate so a keyed recipient never resumes into
        // an unencrypted upload.
        _validatedRecipientId = null;
        _validatedRecipientKey = null;
        _codeValidated = false;
      }
    });
    if (!hasResumedKey && _codeController.text.trim().isNotEmpty) {
      await _validateCode();
    }
  }

  Future<bool> _isLikelyMeteredConnection() async {
    try {
      final result = await Connectivity().checkConnectivity();
      return result.contains(ConnectivityResult.mobile);
    } catch (_) {
      return false;
    }
  }

  Future<bool> _confirmMeteredUploadIfNeeded() async {
    final isMetered = await _isLikelyMeteredConnection();
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
      final result = await FilePicker.pickFiles(
        allowMultiple: true,
        type: FileType.any,
        withData: false,
      );
      if (result == null || !mounted) return;

      final accessibleRaw = result.files.where((f) => f.path != null).toList();
      final seenNames = <String>{};
      final accessible = <PlatformFile>[];
      for (final f in accessibleRaw) {
        if (seenNames.add(f.name)) accessible.add(f);
      }

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
      _codeValidated = false;
      _validatedRecipientId = null;
      _validatedRecipientKey = null;
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
    if (_codeValidated || _sending) return const [];
    return RecentRecipients.matching(_codeController.text).take(5).toList();
  }

  Future<void> _applyRecentCode(String code) async {
    _codeFocus.unfocus();
    _codeController.text = code;
    setState(() {
      _codeValidated = false;
      _validatedRecipientId = null;
      _validatedRecipientKey = null;
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

  /// Row shown once a code is validated: confirmation + an optional action to
  /// save (or rename) a local, device-only nickname for this recipient.
  Widget _recipientNameRow() {
    final c = context.mini;
    final alias = ContactAliases.aliasFor(_validatedRecipientId);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Row(
        children: [
          const Icon(Icons.check_circle_rounded,
              size: 16, color: MiniColors.success),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              alias != null ? 'Sending to $alias' : 'Code verified',
              style: MiniText.small.copyWith(color: MiniColors.success),
            ),
          ),
          GestureDetector(
            onTap: _nameRecipient,
            behavior: HitTestBehavior.opaque,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  alias != null
                      ? Icons.edit_outlined
                      : Icons.person_add_alt_outlined,
                  size: 15,
                  color: c.accent,
                ),
                const SizedBox(width: 4),
                Text(
                  alias != null ? 'Rename' : 'Name this person',
                  style: MiniText.small.copyWith(
                    color: c.accent,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _validateCode() async {
    final code = AppConstants.normalizeShortCode(_codeController.text);
    if (code.isEmpty) {
      setState(() => _codeError = 'Enter a recipient code');
      return;
    }
    if (code.length != AppConstants.codeLength) {
      setState(() => _codeError =
          'Code must be exactly ${AppConstants.codeLength} characters');
      return;
    }
    if (!AppConstants.isValidShortCodeFormat(code)) {
      setState(
          () => _codeError = 'Use only A-Z and 2-9 (excluding O, I, L, 0, 1)');
      return;
    }
    if (code == widget.identity.shortCode) {
      setState(() => _codeError = 'You cannot send files to yourself');
      return;
    }

    if (!await ConnectionStatus.instance.refresh()) {
      setState(() => _codeError = 'No internet connection');
      return;
    }

    setState(() {
      _validatingCode = true;
      _codeError = null;
      _staleRecentCode = null;
    });

    try {
      final recipient = await IdentityService.findUserByCode(code);
      if (!mounted) return;

      if (recipient == null) {
        // A dead saved code usually means that person's identity was reset
        // (reinstall, cleared data) and their code changed.
        final isSavedCode = RecentRecipients.all.any((r) => r.code == code);
        Analytics.instance.logEvent(AnalyticsEvents.sendCodeInvalid,
            {'reason': 'not_found', 'stale_recent': isSavedCode});
        HapticFeedback.lightImpact();
        setState(() {
          _codeError = isSavedCode
              ? 'No user found with code "$code". This saved code may be out '
                  'of date — ask them for their current code.'
              : 'No user found with code "$code"';
          _staleRecentCode = isSavedCode ? code : null;
          _validatingCode = false;
        });
        return;
      }

      setState(() {
        _validatingCode = false;
        _codeValidated = true;
        _validatedRecipientId = recipient['id'] as String;
        _validatedRecipientKey = recipient['public_key'] as String?;
      });
      HapticFeedback.lightImpact();
      Analytics.instance.logEvent(AnalyticsEvents.sendCodeValidated);
    } on PostgrestException catch (e) {
      Analytics.instance.logError(AnalyticsEvents.sendCodeInvalid, e);
      if (mounted) {
        setState(() {
          _codeError = 'We had trouble checking this code. Please try again.';
          _validatingCode = false;
        });
        unawaited(AppErrorHandler.maybeShowServiceOutage(context, e));
      }
    } catch (e) {
      Analytics.instance.logError(AnalyticsEvents.sendCodeInvalid, e);
      if (mounted) {
        setState(() {
          _codeError = NetworkErrors.isRetryableFailure(e)
              ? 'Cannot reach MiniGo to validate this code. '
                  'Check your connection and try again.'
              : 'Could not validate this code. Please try again.';
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

    // Checked before the push probe: it costs no network round trip, and it is
    // the more consequential of the two warnings.
    if (!_recipientIsEncryptable) {
      final proceed = await _confirmSendWithoutEncryption();
      if (proceed != true || !mounted) return;
      setState(() => _error = null);
    }

    final pushReadiness =
        await TransferService.verifyClosedAppDeliveryReadiness(
      receiverId: _validatedRecipientId!,
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

    if (!await ConnectionStatus.instance.refresh()) {
      if (!mounted) return;
      setState(() {
        _error = 'No internet connection. Try again when you are online.';
      });
      return;
    }

    setState(() {
      _sending = true;
      _uploadStates = null;
      _error = null;
      _uploadCancellationToken = TransferCancellationToken();
    });

    Analytics.instance.logEvent(AnalyticsEvents.sendStarted, {
      'file_count': _selectedFiles.length,
      'total_bytes': _totalSize,
    });

    try {
      final result = await TransferService.sendFiles(
        senderId: widget.identity.id,
        receiverId: _validatedRecipientId!,
        receiverCode: AppConstants.normalizeShortCode(_codeController.text),
        recipientPublicKey: _validatedRecipientKey,
        // Only ever true once _confirmSendWithoutEncryption() said so above.
        allowUnencrypted: !_recipientIsEncryptable,
        files: _selectedFiles,
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
          label: ContactAliases.aliasFor(_validatedRecipientId),
        ));
        Analytics.instance.logEvent(AnalyticsEvents.sendCompleted, {
          'file_count': result.completedFiles,
          'total_bytes': _totalSize,
        });
        await _showSendSuccessSheet(result.completedFiles);
        if (!mounted) return;
        Navigator.pop(context);
      } else {
        final failureMessage = _buildPartialFailureMessage(result);
        Analytics.instance.logEvent(AnalyticsEvents.sendFailed, {
          'partial': true,
          'completed': result.completedFiles,
          'reason': failureMessage,
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

  String _buildPartialFailureMessage(TransferResult result) {
    final failed = result.fileStates
        .where((s) => s.status == FileUploadStatus.failed)
        .toList();
    if (failed.isEmpty) return 'Some files could not be sent.';
    final first = failed.first;
    final reason = _toUserFriendlyError(first.error ?? 'Unknown error');
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
        message.contains('Upload failed (403')) {
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

  int get _totalSize => _selectedFiles.fold<int>(0, (sum, f) => sum + f.size);

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    return Scaffold(
      backgroundColor: c.paper,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Send to'),
      ),
      body: Column(
        children: [
          // Recipient code input
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: c.paperDeep,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _codeController,
                      focusNode: _codeFocus,
                      // Stays editable after validation: onChanged resets the
                      // validated state, so the user can switch recipients
                      // without leaving the screen.
                      enabled: !_sending,
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
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 14),
                      ),
                      onChanged: (_) {
                        // Rebuild so the recent-code suggestions refilter.
                        setState(() {
                          _staleRecentCode = null;
                          if (_codeValidated) {
                            _codeValidated = false;
                            _validatedRecipientId = null;
                            _validatedRecipientKey = null;
                          }
                        });
                      },
                    ),
                  ),
                  if (!_codeValidated && !_sending)
                    SizedBox(
                      width: 40,
                      height: 44,
                      child: IconButton(
                        icon: const Icon(
                          Icons.qr_code_scanner_rounded,
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
                        onPressed:
                            (_validatingCode || _sending || _codeValidated)
                                ? null
                                : _validateCode,
                        style: FilledButton.styleFrom(
                          backgroundColor: _codeValidated
                              ? MiniColors.success
                              : MiniColors.blue600,
                          disabledBackgroundColor: _codeValidated
                              ? MiniColors.success
                              : MiniColors.blue600.withValues(alpha: 0.5),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                        ),
                        child: _validatingCode
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: MiniColors.paper),
                              )
                            : Text(
                                _codeValidated ? 'Verified ✓' : 'Validate',
                                style: GoogleFonts.outfit(
                                  color: MiniColors.paper,
                                  fontSize: 13,
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
          if (_recentSuggestions.isNotEmpty && !_codeValidated && !_sending)
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
                            color: c.paperDeep,
                            borderRadius: BorderRadius.circular(14),
                            child: InkWell(
                              onTap: () => _applyRecentCode(r.code),
                              borderRadius: BorderRadius.circular(14),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 9),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      fmtCode(r.code),
                                      style: GoogleFonts.jetBrainsMono(
                                        fontSize: 13,
                                        letterSpacing: 1.2,
                                        fontWeight: FontWeight.w500,
                                        color: c.ink,
                                      ),
                                    ),
                                    if (r.label != null) ...[
                                      const SizedBox(height: 2),
                                      ConstrainedBox(
                                        constraints:
                                            const BoxConstraints(maxWidth: 110),
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
          if (_codeValidated) _recipientNameRow(),

          // The recipient published no X25519 key, so these files would go up
          // as plaintext. Say so before the send, not after.
          if (_codeValidated && !_recipientIsEncryptable)
            StatusBanner(
              icon: Icons.lock_open_rounded,
              text: 'This recipient has no encryption key yet — files will '
                  'not be end-to-end encrypted.',
              tint: MiniColors.warn,
            ),

          // Power save banner
          if (_powerSaveMode)
            StatusBanner(
              icon: Icons.battery_saver_rounded,
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
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: c.paperDeep.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: MiniFileRow(
                          name: _selectedFiles[i].name,
                          size: _formatSize(_selectedFiles[i].size),
                          mimeCategory: MiniFileRow.categoryFromFileName(
                              _selectedFiles[i].name),
                          trailing: _sending
                              ? null
                              : GestureDetector(
                                  onTap: () => _removeFile(i),
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Icon(Icons.close_rounded,
                                        size: 16, color: c.inkFaint),
                                  ),
                                ),
                        ),
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
          if (_codeValidated && _selectedFiles.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 34),
              child: FractionallySizedBox(
                widthFactor: 0.7,
                child: _sending
                    ? MiniButton(
                        label: _buildSendingLabel(),
                        loading: true,
                        onPressed: null,
                        leading: GestureDetector(
                          onTap: _cancelUpload,
                          child: Icon(Icons.close_rounded,
                              size: 16, color: c.inkFaint),
                        ),
                      )
                    : _SwipeToSendButton(onSend: _send),
              ),
            ),
        ],
      ),
    );
  }

  String _buildSendingLabel() {
    final states = _uploadStates;
    if (states == null) return 'Preparing…';
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
        height: 160,
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
                  size: 36, color: c.inkFaint),
              const SizedBox(height: 14),
              Text('Tap to choose files', style: MiniText.bodySoft),
              const SizedBox(height: 4),
              Text('Images, videos, documents — any type',
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
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          label,
          style: GoogleFonts.outfit(
            fontSize: 13,
            color: color ?? c.inkSoft,
            fontWeight: FontWeight.w500,
          ),
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
  Animation<double>? _resetAnim;
  double _progress = 0;
  bool _fired = false;

  @override
  void initState() {
    super.initState();
    _resetCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
  }

  @override
  void dispose() {
    _resetCtrl.dispose();
    super.dispose();
  }

  void _snapBack() {
    _resetAnim = Tween<double>(
      begin: _progress,
      end: 0,
    ).animate(CurvedAnimation(parent: _resetCtrl, curve: Curves.easeOutCubic))
      ..addListener(() {
        if (!mounted) return;
        setState(() => _progress = _resetAnim!.value);
      });
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
                    color: c.paperDeep.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(100),
                    border: Border.all(color: c.divider),
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
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: c.inkSoft,
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
                                      .withValues(alpha: 0.22),
                                  blurRadius: 12,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.north_east_rounded,
                              size: 18,
                              color: MiniColors.paper,
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
                padding: const EdgeInsets.fromLTRB(28, 32, 28, 28),
                decoration: BoxDecoration(
                  color: c.paper,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: MiniColors.success.withValues(alpha: 0.18),
                      blurRadius: 32,
                      spreadRadius: 4,
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
                    const SizedBox(height: 18),
                    Text(
                      'Sent',
                      style: GoogleFonts.outfit(
                        fontSize: 26,
                        color: c.ink,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.fileCount == 1
                          ? '1 file delivered'
                          : '${widget.fileCount} files delivered',
                      style: GoogleFonts.outfit(
                        fontSize: 13,
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
      ..color = MiniColors.paper
      ..strokeWidth = 4.5
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
