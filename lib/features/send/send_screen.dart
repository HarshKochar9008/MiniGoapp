import 'dart:async';
import 'dart:io';

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
import '../../core/network/connection_status.dart';
import '../../core/network/network_errors.dart';
import '../../zensend/theme/zen_theme.dart';
import '../../zensend/widgets/zen_widgets.dart';
import '../identity/identity_service.dart';
import '../qr/qr_widgets.dart';
import '../transfer/transfer_progress_widgets.dart';
import '../transfer/transfer_service.dart';

class SendScreen extends StatefulWidget {
  final UserIdentity identity;

  /// Files to pre-select, e.g. shared to the app via the system share sheet.
  final List<PlatformFile> initialFiles;

  const SendScreen({
    super.key,
    required this.identity,
    this.initialFiles = const [],
  });

  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<SendScreen> with WidgetsBindingObserver {
  final _codeController = TextEditingController();
  List<PlatformFile> _selectedFiles = [];
  List<FileUploadProgress>? _uploadStates;
  bool _validatingCode = false;
  bool _codeValidated = false;
  bool _sending = false;
  String? _error;
  String? _codeError;
  String? _validatedRecipientId;
  TransferCancellationToken? _uploadCancellationToken;
  final Battery _battery = Battery();
  bool _powerSaveMode = false;
  int? _batteryLevel;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ContactAliases.ensureLoaded();
    _applyInitialFiles();
    _refreshPowerSaveMode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_checkInterruptedUploadRecovery());
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
    int? level;
    try {
      level = await _battery.batteryLevel;
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _powerSaveMode = enabled;
      _batteryLevel = level;
    });
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

    setState(() {
      _selectedFiles = existing;
      _validatedRecipientId = pending.receiverId;
      _codeValidated = true;
      _codeError = null;
      _error = 'Resumed interrupted upload. Tap Send to continue.';
      if (pending.receiverCode != null && pending.receiverCode!.isNotEmpty) {
        _codeController.text = pending.receiverCode!;
      }
    });
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

      final accessibleRaw =
          result.files.where((f) => f.path != null).toList();
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
        setState(
            () => _error = 'Could not pick files. Check app permissions.');
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
              'Already added:',
              style: ZenText.bodySoft.copyWith(color: ctx.zen.inkSoft),
            ),
            const SizedBox(height: 8),
            ...fileNames.map(
              (name) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(name,
                    style: ZenText.small.copyWith(color: ctx.zen.inkSoft),
                    overflow: TextOverflow.ellipsis),
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
      _codeError = null;
    });
    await _validateCode();
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
    });

    try {
      final recipient = await IdentityService.findUserByCode(code);
      if (!mounted) return;

      if (recipient == null) {
        Analytics.instance
            .logEvent(AnalyticsEvents.sendCodeInvalid, {'reason': 'not_found'});
        HapticFeedback.lightImpact();
        setState(() {
          _codeError = 'No user found with code "$code"';
          _validatingCode = false;
        });
        return;
      }

      setState(() {
        _validatingCode = false;
        _codeValidated = true;
        _validatedRecipientId = recipient['id'] as String;
      });
      HapticFeedback.lightImpact();
      Analytics.instance.logEvent(AnalyticsEvents.sendCodeValidated);
    } on PostgrestException catch (e) {
      if (mounted) {
        setState(() {
          _codeError = e.message.isNotEmpty
              ? 'Server error: ${e.message}'
              : 'Server rejected this lookup.';
          _validatingCode = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _codeError = NetworkErrors.isRetryableFailure(e)
              ? 'Cannot reach server to validate this code.'
              : 'Could not validate code: $e';
          _validatingCode = false;
        });
      }
    }
  }

  Future<void> _send() async {
    if (_validatedRecipientId == null || _selectedFiles.isEmpty) return;
    final pushReadiness = await TransferService.verifyClosedAppDeliveryReadiness(
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
        receiverCode:
            AppConstants.normalizeShortCode(_codeController.text),
        files: _selectedFiles,
        cancellationToken: _uploadCancellationToken,
        onProgress: (states) {
          if (mounted) setState(() => _uploadStates = states);
        },
      );

      if (!mounted) return;

      if (result.success) {
        HapticFeedback.heavyImpact();
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
      }
    } finally {
      _uploadCancellationToken = null;
    }
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
            Text(reason,
                style: ZenText.bodySoft.copyWith(color: ctx.zen.inkSoft)),
            const SizedBox(height: 12),
            Text(
              'If their MiniGo app is open right now, they will still see '
              'the transfer and can download it. Otherwise it will only '
              'arrive the next time they open the app.',
              style: ZenText.small.copyWith(color: ctx.zen.inkSoft),
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
    return message;
  }

  void _cancelUpload() {
    _uploadCancellationToken?.cancel();
  }

  String _formatSize(int bytes) => TransferService.formatFileSize(bytes);

  int get _totalSize =>
      _selectedFiles.fold<int>(0, (sum, f) => sum + f.size);

  @override
  Widget build(BuildContext context) {
    final c = context.zen;
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
                      enabled: !_sending && !_codeValidated,
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
                        if (_codeValidated) {
                          setState(() {
                            _codeValidated = false;
                            _validatedRecipientId = null;
                          });
                        }
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
                        onPressed: (_validatingCode || _sending || _codeValidated)
                            ? null
                            : _validateCode,
                        style: FilledButton.styleFrom(
                          backgroundColor: _codeValidated
                              ? ZenColors.success
                              : ZenColors.blue600,
                          disabledBackgroundColor: _codeValidated
                              ? ZenColors.success
                              : ZenColors.blue600.withOpacity(0.5),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          padding:
                              const EdgeInsets.symmetric(horizontal: 20),
                        ),
                        child: _validatingCode
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: ZenColors.paper),
                              )
                            : Text(
                                _codeValidated ? 'Verified ✓' : 'Validate',
                                style: GoogleFonts.outfit(
                                  color: ZenColors.paper,
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
          if (_codeError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
              child: Text(_codeError!,
                  style: ZenText.small.copyWith(color: ZenColors.danger)),
            ),
          if (_codeValidated &&
              ContactAliases.aliasFor(_validatedRecipientId) != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
              child: Text(
                'Sending to ${ContactAliases.aliasFor(_validatedRecipientId)}',
                style: ZenText.small.copyWith(color: ZenColors.success),
              ),
            ),

          // Power save banner
          if (_powerSaveMode)
            StatusBanner(
              icon: Icons.battery_saver_rounded,
              text:
                  'Battery saver is on. Large uploads may be slower or pause.',
              tint: ZenColors.warn,
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
                            Text('Files',
                                style: ZenText.label
                                    .copyWith(color: c.inkSoft)),
                            if (_selectedFiles.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                '${_selectedFiles.length} selected · ${_formatSize(_totalSize)}',
                                style: ZenText.small
                                    .copyWith(color: c.inkSoft),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (!_sending && _selectedFiles.isNotEmpty) ...[
                        _GhostAction(
                            label: 'Add more', onTap: _pickFiles),
                        const SizedBox(width: 4),
                        _GhostAction(
                            label: 'Clear all',
                            onTap: _clearAll,
                            color: ZenColors.danger),
                      ],
                    ],
                  ),
                  const SizedBox(height: 12),

                  // File list / progress / empty
                  if (_sending && _uploadStates != null)
                    TransferUploadProgressList(states: _uploadStates!)
                  else if (_selectedFiles.isEmpty)
                    _EmptyFilesZen(onPick: _pickFiles)
                  else
                    for (var i = 0; i < _selectedFiles.length; i++) ...[
                      Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: c.paperDeep.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: ZenFileRow(
                          name: _selectedFiles[i].name,
                          size: _formatSize(_selectedFiles[i].size),
                          mimeCategory: ZenFileRow.categoryFromFileName(
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
                      tint: ZenColors.danger,
                    ),
                  ],

                  if (_codeValidated && _selectedFiles.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Keep the app open while uploading.',
                      style: ZenText.small.copyWith(color: c.inkSoft),
                    ),
                  ],
                ],
              ),
            ),
          ),

          // Send button
          if (_codeValidated && _selectedFiles.isNotEmpty)
            Container(
              color: c.paper,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              child: _sending
                  ? ZenButton(
                      label: _buildSendingLabel(),
                      loading: true,
                      onPressed: null,
                      leading: GestureDetector(
                        onTap: _cancelUpload,
                        child: Icon(Icons.close_rounded,
                            size: 16, color: c.inkFaint),
                      ),
                    )
                  : _HoldToSendButton(onSend: _send),
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

class _EmptyFilesZen extends StatelessWidget {
  final VoidCallback onPick;
  const _EmptyFilesZen({required this.onPick});

  @override
  Widget build(BuildContext context) {
    final c = context.zen;
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
              Text('Tap to choose files',
                  style: ZenText.bodySoft.copyWith(color: c.inkSoft)),
              const SizedBox(height: 4),
              Text('Images, videos, documents — any type',
                  style: ZenText.small.copyWith(color: c.inkSoft)),
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
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          label,
          style: GoogleFonts.outfit(
            fontSize: 13,
            color: color ?? context.zen.inkSoft,
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

class _HoldToSendButton extends StatefulWidget {
  final VoidCallback onSend;
  const _HoldToSendButton({required this.onSend});

  @override
  State<_HoldToSendButton> createState() => _HoldToSendButtonState();
}

class _HoldToSendButtonState extends State<_HoldToSendButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  bool _holding = false;
  bool _fired = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed && !_fired) {
          _fired = true;
          HapticFeedback.heavyImpact();
          widget.onSend();
        }
      });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onPressDown() {
    if (_fired) return;
    HapticFeedback.lightImpact();
    setState(() => _holding = true);
    _ctrl.forward();
  }

  void _cancelHold() {
    if (_fired) return;
    setState(() => _holding = false);
    _ctrl.animateTo(0,
        duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
  }

  String get _label {
    if (_ctrl.value >= 0.85) return 'Release!';
    if (_holding) return 'Keep holding…';
    return 'Hold to send';
  }

  IconData get _icon => Icons.north_east_rounded;

  @override
  Widget build(BuildContext context) {
    // Listener fires onPointerUp unconditionally — GestureDetector.onTapUp
    // can be dropped by the arena if a parent scroll view wins the gesture.
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => _onPressDown(),
      onPointerUp: (_) => _cancelHold(),
      onPointerCancel: (_) => _cancelHold(),
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          final p = _ctrl.value;
          final nearDone = p >= 0.85;
          return Center(
            child: AnimatedScale(
              scale: _holding ? 1.05 : 1.0,
              duration: const Duration(milliseconds: 100),
              curve: Curves.easeOut,
              child: SizedBox(
                height: 50,
                width: 210,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(100),
                    boxShadow: _holding
                        ? [
                            BoxShadow(
                              color: (nearDone
                                      ? const Color(0xFF00C896)
                                      : ZenColors.blue600)
                                  .withOpacity(0.45 * p),
                              blurRadius: 20,
                            ),
                          ]
                        : const [],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(100),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Container(color: ZenColors.ink),
                        if (p > 0)
                          ClipRect(
                            clipper: _HorizontalProgressClipper(p),
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    ZenColors.blue600,
                                    nearDone
                                        ? const Color(0xFF00C896)
                                        : const Color(0xFF3B9EFF),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(_icon, size: 14, color: ZenColors.paper),
                              const SizedBox(width: 6),
                              Text(
                                _label,
                                style: GoogleFonts.outfit(
                                  color: ZenColors.paper,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w400,
                                  letterSpacing: 0.3,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
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
    final c = context.zen;
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
                  color: isDark ? c.paperDeep : c.paper,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: ZenColors.success.withValues(alpha: 0.18),
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
      ..color = ZenColors.success.withOpacity(0.18)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, r, ringPaint);

    final innerPaint = Paint()
      ..color = ZenColors.success
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, r * 0.78, innerPaint);

    final strokePaint = Paint()
      ..color = ZenColors.paper
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

class _HorizontalProgressClipper extends CustomClipper<Rect> {
  final double progress;
  const _HorizontalProgressClipper(this.progress);

  @override
  Rect getClip(Size size) =>
      Rect.fromLTWH(0, 0, size.width * progress, size.height);

  @override
  bool shouldReclip(_HorizontalProgressClipper old) =>
      old.progress != progress;
}
