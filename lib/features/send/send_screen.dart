import 'dart:async';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../../core/constants.dart';
import '../../core/network/connection_status.dart';
import '../../core/network/network_errors.dart';
import '../../zensend/theme/zen_theme.dart';
import '../../zensend/widgets/zen_widgets.dart';
import '../identity/identity_service.dart';
import '../transfer/transfer_progress_widgets.dart';
import '../transfer/transfer_service.dart';

class SendScreen extends StatefulWidget {
  final UserIdentity identity;
  const SendScreen({super.key, required this.identity});

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
    _refreshPowerSaveMode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_checkInterruptedUploadRecovery());
    });
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
              fileNames.length == 1
                  ? 'Already added:'
                  : 'Already added:',
              style: ZenText.bodySoft,
            ),
            const SizedBox(height: 8),
            ...fileNames.map(
              (name) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(name,
                    style: ZenText.small,
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
      setState(() {
        _error = pushReadiness.reason ??
            'Incoming delivery while recipient app is closed is not configured.';
      });
      return;
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${result.completedFiles} file(s) sent successfully'),
          ),
        );
        Navigator.pop(context);
      } else {
        final failureMessage = _buildPartialFailureMessage(result);
        setState(() {
          _error = failureMessage;
          _sending = false;
        });
      }
    } on TransferCancelledException catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Transfer cancelled';
          _sending = false;
        });
      }
    } on FileTooLargeException catch (e) {
      if (mounted) {
        setState(() {
          _error = _toUserFriendlyError(e.toString());
          _sending = false;
        });
      }
    } on TooManyFilesException catch (e) {
      if (mounted) {
        setState(() {
          _error = _toUserFriendlyError(e.toString());
          _sending = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = _toUserFriendlyError(e.toString());
          _sending = false;
        });
      }
    } finally {
      _uploadCancellationToken = null;
    }
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
    return Scaffold(
      backgroundColor: ZenColors.paper,
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
                color: ZenColors.paperDeep,
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
                        color: ZenColors.ink,
                      ),
                      decoration: InputDecoration(
                        hintText: '— — —   — — —',
                        hintStyle: GoogleFonts.jetBrainsMono(
                          fontSize: 18,
                          color: ZenColors.inkFaint,
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
                                style: GoogleFonts.inter(
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
                            Text('Files', style: ZenText.label),
                            if (_selectedFiles.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                '${_selectedFiles.length} selected · ${_formatSize(_totalSize)}',
                                style: ZenText.small,
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
                          color: ZenColors.paperDeep.withOpacity(0.5),
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
                                  child: const Padding(
                                    padding: EdgeInsets.all(12),
                                    child: Icon(Icons.close_rounded,
                                        size: 16,
                                        color: ZenColors.inkFaint),
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
                      style: ZenText.small,
                    ),
                  ],
                ],
              ),
            ),
          ),

          // Send button
          if (_codeValidated && _selectedFiles.isNotEmpty)
            Container(
              color: ZenColors.paper,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              child: _sending
                  ? ZenButton(
                      label: _buildSendingLabel(),
                      loading: true,
                      onPressed: null,
                      leading: GestureDetector(
                        onTap: _cancelUpload,
                        child: const Icon(Icons.close_rounded,
                            size: 16, color: ZenColors.inkFaint),
                      ),
                    )
                  : ZenButton(
                      label: 'Send',
                      leading: const Icon(Icons.north_east_rounded,
                          size: 16, color: ZenColors.paper),
                      onPressed: _send,
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

class _EmptyFilesZen extends StatelessWidget {
  final VoidCallback onPick;
  const _EmptyFilesZen({required this.onPick});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPick,
      child: Container(
        height: 160,
        decoration: BoxDecoration(
          color: ZenColors.paperDeep,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: ZenColors.divider),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.add_circle_outline_rounded,
                  size: 36, color: ZenColors.inkFaint),
              const SizedBox(height: 14),
              Text('Tap to choose files', style: ZenText.bodySoft),
              const SizedBox(height: 4),
              Text('Images, videos, documents — any type',
                  style: ZenText.small),
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
          style: GoogleFonts.inter(
            fontSize: 13,
            color: color ?? ZenColors.inkSoft,
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
