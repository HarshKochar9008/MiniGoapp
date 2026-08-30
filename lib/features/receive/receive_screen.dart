import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:disk_space_plus/disk_space_plus.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/analytics/analytics.dart';
import '../../core/constants.dart';
import '../../core/network/connection_status.dart';
import '../../core/supabase_config.dart';
import '../../Minigo/theme/mini_theme.dart';
import '../../Minigo/widgets/mini_widgets.dart';
import '../transfer/transfer_progress_widgets.dart';
import '../transfer/transfer_service.dart';
import 'save_file.dart';

class ReceiveScreen extends StatefulWidget {
  final String transferId;
  final String senderCode;

  const ReceiveScreen({
    super.key,
    required this.transferId,
    required this.senderCode,
  });

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen>
    with WidgetsBindingObserver {
  static const _downloadedKeysPrefix = 'downloaded_files_';
  static const int _storageSafetyBufferBytes = 50 * 1024 * 1024; // 50 MB
  final Battery _battery = Battery();
  List<Map<String, dynamic>>? _files;
  bool _loading = true;
  String? _loadError;
  String? _transferStatus;
  List<FileUploadProgress>? _senderLiveStates;
  RealtimeChannel? _detailChannel;
  final Map<String, _FileDownloadState> _dlStates = {};
  final Map<String, TransferCancellationToken> _downloadTokens = {};
  Set<String> _persistedDownloads = {};
  bool _powerSaveMode = false;
  late final VoidCallback _onConnectionChanged;

  bool get _transferTerminal {
    final s = _transferStatus;
    return s == 'completed' ||
        s == 'partial' ||
        s == 'failed' ||
        s == 'expired';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ConnectionStatus.instance.ensureStarted();
    _onConnectionChanged = () {
      if (!ConnectionStatus.instance.online.value) return;
      if (_loadError != null && mounted) {
        _loadFiles();
      }
    };
    ConnectionStatus.instance.online.addListener(_onConnectionChanged);
    _refreshPowerSaveMode();
    _loadPersistedState();
    _loadFiles();
    _loadTransferMetaAndSubscribe();
  }

  @override
  void dispose() {
    ConnectionStatus.instance.online.removeListener(_onConnectionChanged);
    WidgetsBinding.instance.removeObserver(this);
    final ch = _detailChannel;
    _detailChannel = null;
    if (ch != null) {
      TransferService.unsubscribe(ch);
    }
    super.dispose();
  }

  void _applyTransferSnapshot(Map<String, dynamic> row) {
    final parsed =
        TransferService.parseUploadProgressPayload(row['upload_progress']);
    setState(() {
      _transferStatus = (row['status'] ?? 'pending').toString();
      _senderLiveStates = parsed;
    });
  }

  Future<void> _loadTransferMetaAndSubscribe() async {
    final uid = SupabaseConfig.client.auth.currentUser?.id;
    if (uid == null || !mounted) return;
    final row = await TransferService.getTransferForReceiver(
      transferId: widget.transferId,
      receiverId: uid,
    );
    if (!mounted) return;
    if (row != null) {
      _applyTransferSnapshot(row);
    }
    _detailChannel = TransferService.subscribeToTransferDetail(
      transferId: widget.transferId,
      receiverId: uid,
      onTransferRow: (r) {
        if (!mounted) return;
        _applyTransferSnapshot(r);
      },
      onTransferFileInserted: (_) {
        if (!mounted) return;
        _loadFiles();
      },
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshPowerSaveMode();
      unawaited(ConnectionStatus.instance.refresh());
    }
  }

  Future<void> _refreshPowerSaveMode() async {
    final enabled = await _isPowerSaveModeEnabled();
    if (!mounted) return;
    setState(() => _powerSaveMode = enabled);
  }

  Future<void> _loadPersistedState() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(
      '$_downloadedKeysPrefix${widget.transferId}',
    );
    if (saved != null && mounted) {
      setState(() {
        _persistedDownloads = saved.toSet();
        for (final fileId in _persistedDownloads) {
          _dlStates[fileId] = const _FileDownloadState(
            status: _DownloadStatus.completed,
            progress: 1.0,
          );
        }
      });
    }
  }

  Future<void> _markDownloaded(String fileId) async {
    _persistedDownloads.add(fileId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      '$_downloadedKeysPrefix${widget.transferId}',
      _persistedDownloads.toList(),
    );
  }

  Future<void> _loadFiles() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final files = await TransferService.getTransferFiles(widget.transferId);
      if (mounted) {
        setState(() {
          _files = files;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadError =
              'Could not load files: ${e.toString().replaceAll('Exception: ', '')}';
          _loading = false;
        });
      }
    }
  }

  String _formatSize(dynamic bytes) {
    final b = (bytes is int) ? bytes : int.tryParse(bytes.toString()) ?? 0;
    return TransferService.formatFileSize(b);
  }

  Future<bool> _isPowerSaveModeEnabled() async {
    try {
      return await _battery.isInBatterySaveMode;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _confirmPowerSaveIfNeeded(int fileSize) async {
    if (fileSize < AppConstants.largeUploadWarnThresholdBytes) return true;
    final powerSave = await _isPowerSaveModeEnabled();
    if (!powerSave || !mounted) return true;

    final c = context.mini;
    final approved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.paperDeep,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MiniRadius.card),
        ),
        title: Text(
          'Battery saver is on',
          style: MiniText.title.copyWith(color: c.ink, fontSize: 20),
        ),
        content: Text(
          'This file is ${TransferService.formatFileSize(fileSize)}. '
          'Power-save mode can pause or throttle long downloads. Continue anyway?',
          style: MiniText.bodySoft,
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

  Future<bool> _hasAggregateStorageForPendingDownloads() async {
    final files = _files;
    if (files == null || files.isEmpty) return true;

    var requiredBytes = 0;
    for (final file in files) {
      final fileId = file['id'] as String;
      final state = _dlStates[fileId]?.status;
      if (_persistedDownloads.contains(fileId) ||
          state == _DownloadStatus.completed) {
        continue;
      }
      final rawSize = file['file_size'];
      requiredBytes += rawSize is int ? rawSize : int.tryParse('$rawSize') ?? 0;
    }

    if (requiredBytes <= 0) return true;

    final freeSpaceGb = await DiskSpacePlus().getFreeDiskSpace ?? 0.0;
    final freeSpaceBytes = (freeSpaceGb * 1024 * 1024 * 1024).toInt();
    return freeSpaceBytes >= (requiredBytes + _storageSafetyBufferBytes);
  }

  Widget _buildPowerSaveBanner() {
    if (!_powerSaveMode) return const SizedBox.shrink();
    return StatusBanner(
      icon: Icons.battery_saver_rounded,
      text: 'Battery saver is on. Large downloads may be slower or pause.',
      tint: MiniColors.warn,
    );
  }

  Future<void> _downloadFile(Map<String, dynamic> file) async {
    final fileId = file['id'] as String;
    final storagePath = file['storage_path'] as String;
    final fileName = file['file_name'] as String;
    final expectedHash = file['sha256_hash'] as String?;
    final isEncrypted = file['is_encrypted'] == true;
    final encWrappedKey = file['enc_wrapped_key'] as String?;
    final encNonce = file['enc_nonce'] as String?;
    final encAlgo = file['enc_algo'] as String?;
    final rawChunk = file['enc_chunk_size'];
    final encChunkSize = rawChunk is int ? rawChunk : int.tryParse('$rawChunk');

    if (!await ConnectionStatus.instance.refresh()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No internet connection. Connect to download.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    if (_persistedDownloads.contains(fileId)) return;
    final existingState = _dlStates[fileId];
    if (existingState?.status == _DownloadStatus.completed) return;

    final rawSize = file['file_size'];
    final fileSize = rawSize is int ? rawSize : int.tryParse('$rawSize') ?? 0;
    final powerApproved = await _confirmPowerSaveIfNeeded(fileSize);
    if (!powerApproved) {
      if (mounted) {
        setState(() => _dlStates[fileId] = const _FileDownloadState(
              status: _DownloadStatus.failed,
              error: 'Download postponed due to battery saver mode',
            ));
      }
      return;
    }

    final freeSpaceGb = await DiskSpacePlus().getFreeDiskSpace ?? 0.0;
    final freeSpaceBytes = (freeSpaceGb * 1024 * 1024 * 1024).toInt();
    if (fileSize > 0 &&
        freeSpaceBytes > 0 &&
        freeSpaceBytes < (fileSize + _storageSafetyBufferBytes)) {
      if (mounted) {
        setState(() => _dlStates[fileId] = _FileDownloadState(
              status: _DownloadStatus.failed,
              error:
                  'Not enough free storage. Need ${TransferService.formatFileSize(fileSize + _storageSafetyBufferBytes)} including safety buffer.',
            ));
      }
      return;
    }

    final cancellationToken = TransferCancellationToken();
    _downloadTokens[fileId] = cancellationToken;
    setState(() => _dlStates[fileId] = const _FileDownloadState(
          status: _DownloadStatus.downloading,
        ));
    Analytics.instance.logEvent(AnalyticsEvents.downloadStarted, {
      'bytes': fileSize,
    });

    try {
      final downloadedFile = await TransferService.downloadToFile(
        storagePath: storagePath,
        fileName: fileName,
        cancellationToken: cancellationToken,
        isEncrypted: isEncrypted,
        encWrappedKey: encWrappedKey,
        encNonce: encNonce,
        encChunkSize: encChunkSize,
        encAlgo: encAlgo,
        onProgress: (received, total) {
          if (mounted) {
            setState(() => _dlStates[fileId] = _FileDownloadState(
                  status: _DownloadStatus.downloading,
                  progress: total > 0 ? received / total : 0,
                ));
          }
        },
      );

      if (mounted) {
        setState(() => _dlStates[fileId] = const _FileDownloadState(
              status: _DownloadStatus.verifying,
              progress: 1.0,
            ));
      }

      final integrity = await TransferService.verifySha256(
        downloadedFile,
        expectedHash,
      );
      if (integrity == IntegrityCheck.mismatch) {
        if (mounted) {
          setState(() => _dlStates[fileId] = const _FileDownloadState(
                status: _DownloadStatus.failed,
                error: 'Integrity check failed — file may be corrupted',
              ));
        }
        return;
      }
      // noHashRecorded stays null rather than true: the file is saved, but
      // nothing here is entitled to call it verified.
      final bool? hashVerified =
          integrity == IntegrityCheck.verified ? true : null;

      if (mounted) {
        setState(() => _dlStates[fileId] = _FileDownloadState(
              status: _DownloadStatus.saving,
              progress: 1.0,
            ));
      }

      final saved = await saveFileToDevice(downloadedFile, fileName);

      await _markDownloaded(fileId);

      if (mounted) {
        HapticFeedback.mediumImpact();
        Analytics.instance.logEvent(AnalyticsEvents.downloadCompleted, {
          'bytes': fileSize,
          'verified': hashVerified == true,
        });
        setState(() => _dlStates[fileId] = _FileDownloadState(
              status: _DownloadStatus.completed,
              progress: 1.0,
              savedLocation: saved.label,
              openTarget: saved.open,
            ));

        // Say "not verified" out loud. Previously this just dropped the
        // "(verified)" suffix, which nobody reads as a warning.
        final suffix = hashVerified == true
            ? '  (verified)'
            : isEncrypted
                ? ''
                : '  (integrity not verified)';
        final openTarget = saved.open;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Saved to ${saved.label}$suffix'),
            duration: const Duration(seconds: 4),
            behavior: SnackBarBehavior.floating,
            action: openTarget == null
                ? null
                : SnackBarAction(
                    label: 'Open',
                    onPressed: () => _openSaved(openTarget),
                  ),
          ),
        );
      }
    } on TransferCancelledException catch (_) {
      Analytics.instance.logEvent(AnalyticsEvents.downloadCancelled);
      if (mounted) {
        setState(() => _dlStates[fileId] = const _FileDownloadState(
              status: _DownloadStatus.failed,
              error: 'Download cancelled',
            ));
      }
    } on PermissionDeniedException catch (e) {
      Analytics.instance.logError(AnalyticsEvents.downloadFailed, e);
      if (mounted) {
        setState(() => _dlStates[fileId] = _FileDownloadState(
              status: _DownloadStatus.failed,
              error: e.message,
            ));
      }
    } catch (e) {
      Analytics.instance.logError(AnalyticsEvents.downloadFailed, e);
      if (mounted) {
        HapticFeedback.lightImpact();
        setState(() => _dlStates[fileId] = _FileDownloadState(
              status: _DownloadStatus.failed,
              error:
                  'Download failed: ${e.toString().replaceAll('Exception: ', '')}',
            ));
      }
    } finally {
      _downloadTokens.remove(fileId);
    }
  }

  void _cancelDownload(String fileId) {
    _downloadTokens[fileId]?.cancel();
  }

  Widget _buildReceiveBody() {
    final c = context.mini;
    final files = _files ?? const <Map<String, dynamic>>[];
    final hasFiles = files.isNotEmpty;
    final live = _senderLiveStates;
    final showLive = !_transferTerminal && live != null && live.isNotEmpty;

    if (!hasFiles && !showLive) {
      final waiting = !_transferTerminal;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.hourglass_empty_rounded, size: 40, color: c.inkFaint),
              const SizedBox(height: 16),
              Text(
                waiting
                    ? 'Waiting for the sender…'
                    : 'No files in this transfer',
                textAlign: TextAlign.center,
                style: MiniText.bodySoft,
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        if (showLive) ...[
          Text('Sender upload', style: MiniText.label),
          const SizedBox(height: 10),
          TransferUploadProgressList(
            states: live,
            headerPrefix: 'Live from sender',
          ),
          if (hasFiles) const SizedBox(height: 24),
        ],
        if (hasFiles) ...[
          if (showLive) ...[
            Text('Ready to download', style: MiniText.label),
            const SizedBox(height: 10),
          ],
          ...files.map((file) {
            final fileId = file['id'] as String;
            final dlState = _dlStates[fileId];
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _FileDownloadTile(
                fileName: file['file_name'] as String,
                fileSize: _formatSize(file['file_size']),
                state: dlState,
                onDownload: () => _downloadFile(file),
                onCancel: () => _cancelDownload(fileId),
                onOpen: dlState?.openTarget == null
                    ? null
                    : () => _openSaved(dlState!.openTarget!),
              ),
            );
          }),
        ],
      ],
    );
  }

  /// Hands a finished download to the phone's viewer — the gallery for media,
  /// the system chooser for everything else.
  Future<void> _openSaved(String target) async {
    try {
      await openSavedFile(target);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e is PlatformException
              ? e.message ?? 'Could not open this file'
              : 'Could not open this file'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _downloadAll() async {
    if (_files == null || _files!.isEmpty) return;
    HapticFeedback.selectionClick();
    Analytics.instance.logEvent(AnalyticsEvents.downloadAllRequested, {
      'pending': _files!.length,
    });
    final aggregateOk = await _hasAggregateStorageForPendingDownloads();
    if (!aggregateOk) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Not enough free storage for all pending files. '
              'Download fewer files or free up space first.',
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    for (final file in _files!) {
      final fileId = file['id'] as String;
      final state = _dlStates[fileId];
      if (state == null || state.status != _DownloadStatus.completed) {
        await _downloadFile(file);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    final allCompleted = _files != null &&
        _files!.isNotEmpty &&
        _files!.every(
            (f) => _dlStates[f['id']]?.status == _DownloadStatus.completed);

    return Scaffold(
      backgroundColor: c.paper,
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 16, 6),
              child: Row(
                children: [
                  Material(
                    color: c.sand,
                    shape: const CircleBorder(),
                    child: InkWell(
                      onTap: () => Navigator.pop(context),
                      customBorder: const CircleBorder(),
                      child: Padding(
                        padding: const EdgeInsets.all(9),
                        child: Icon(Icons.arrow_back_rounded,
                            color: c.ink, size: 20),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('From',
                            style: MiniText.label.copyWith(color: c.inkFaint)),
                        const SizedBox(height: 3),
                        Text(
                          fmtCode(widget.senderCode),
                          style: MiniText.code.copyWith(
                            fontSize: 16,
                            color: c.ink,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_files != null && _files!.isNotEmpty && !allCompleted)
                    Material(
                      color: c.accentSoft,
                      borderRadius: BorderRadius.circular(MiniRadius.pill),
                      child: InkWell(
                        onTap: _downloadAll,
                        borderRadius: BorderRadius.circular(MiniRadius.pill),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 9),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.download_rounded,
                                  size: 15, color: c.accent),
                              const SizedBox(width: 6),
                              Text(
                                'All',
                                style: GoogleFonts.outfit(
                                  fontSize: 13,
                                  height: 1.2,
                                  color: c.accent,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            _buildPowerSaveBanner(),

            // Content
            Expanded(
              child: _loading
                  ? ListView.builder(
                      physics: const NeverScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      itemCount: 4,
                      itemBuilder: (_, __) => const Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: TransferTileSkeleton(),
                      ),
                    )
                  : _loadError != null
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(48),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  _loadError!,
                                  textAlign: TextAlign.center,
                                  style: MiniText.bodySoft,
                                ),
                                const SizedBox(height: 20),
                                MiniButton(
                                  label: 'Retry',
                                  onPressed: _loadFiles,
                                ),
                              ],
                            ),
                          ),
                        )
                      : _buildReceiveBody(),
            ),
          ],
        ),
      ),
    );
  }
}

enum _DownloadStatus {
  idle,
  downloading,
  verifying,
  saving,
  completed,
  failed,
}

class _FileDownloadState {
  final _DownloadStatus status;
  final double progress;
  final String? savedLocation;
  final String? error;

  /// Handle for [openSavedFile], or null where nothing can open the file.
  final String? openTarget;

  const _FileDownloadState({
    this.status = _DownloadStatus.idle,
    this.progress = 0,
    this.savedLocation,
    this.error,
    this.openTarget,
  });
}

class _FileDownloadTile extends StatelessWidget {
  final String fileName;
  final String fileSize;
  final _FileDownloadState? state;
  final VoidCallback onDownload;
  final VoidCallback onCancel;
  final VoidCallback? onOpen;

  const _FileDownloadTile({
    required this.fileName,
    required this.fileSize,
    required this.state,
    required this.onDownload,
    required this.onCancel,
    this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.mini;
    final status = state?.status ?? _DownloadStatus.idle;

    return Container(
      padding: const EdgeInsets.all(15),
      decoration: miniCard(context, radius: MiniRadius.tile),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: _iconBg(status, c.accent),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(_fileIcon(status),
                    color: _iconColor(status, c.accent), size: 20),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.outfit(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -0.2,
                        color: c.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(fileSize, style: MiniText.small),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _buildTrailing(status, c.accent),
            ],
          ),
          if (status == _DownloadStatus.downloading) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(MiniRadius.pill),
              child: LinearProgressIndicator(
                value: state!.progress,
                backgroundColor: c.sand,
                valueColor: AlwaysStoppedAnimation(c.accent),
                minHeight: 6,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Downloading… ${(state!.progress * 100).toInt()}%',
              style: MiniText.small,
            ),
          ],
          if (status == _DownloadStatus.verifying) ...[
            const SizedBox(height: 8),
            Text('Verifying integrity…',
                style: GoogleFonts.outfit(
                    color: c.accent,
                    fontSize: 12,
                    fontWeight: FontWeight.w500)),
          ],
          if (status == _DownloadStatus.saving) ...[
            const SizedBox(height: 8),
            Text('Saving to device…',
                style: GoogleFonts.outfit(
                    color: MiniColors.warn,
                    fontSize: 12,
                    fontWeight: FontWeight.w500)),
          ],
          if (status == _DownloadStatus.completed) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.check_circle_rounded, color: c.inkFaint, size: 14),
                const SizedBox(width: 5),
                Text('Saved',
                    style:
                        MiniText.small.copyWith(fontWeight: FontWeight.w500)),
              ],
            ),
            if (state?.savedLocation != null) ...[
              const SizedBox(height: 3),
              Text(
                state!.savedLocation!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    GoogleFonts.jetBrainsMono(color: c.inkFaint, fontSize: 11),
              ),
            ],
          ],
          if (status == _DownloadStatus.failed && state?.error != null) ...[
            const SizedBox(height: 8),
            Text(
              state!.error!,
              style: GoogleFonts.outfit(
                color: MiniColors.danger,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }

  IconData _fileIcon(_DownloadStatus status) {
    switch (status) {
      case _DownloadStatus.completed:
        return Icons.check_circle_rounded;
      case _DownloadStatus.failed:
        return Icons.error_rounded;
      default:
        return Icons.insert_drive_file_rounded;
    }
  }

  Color _iconBg(_DownloadStatus status, Color accent) {
    switch (status) {
      case _DownloadStatus.completed:
        return MiniColors.success.withValues(alpha: 0.1);
      case _DownloadStatus.failed:
        return MiniColors.danger.withValues(alpha: 0.1);
      default:
        return accent.withValues(alpha: 0.1);
    }
  }

  Color _iconColor(_DownloadStatus status, Color accent) {
    switch (status) {
      case _DownloadStatus.completed:
        return MiniColors.success;
      case _DownloadStatus.failed:
        return MiniColors.danger;
      default:
        return accent;
    }
  }

  Widget _buildTrailing(_DownloadStatus status, Color accent) {
    switch (status) {
      case _DownloadStatus.idle:
      case _DownloadStatus.failed:
        return GestureDetector(
          onTap: onDownload,
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(Icons.download_rounded, color: accent, size: 19),
          ),
        );
      case _DownloadStatus.downloading:
        return GestureDetector(
          onTap: onCancel,
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: MiniColors.danger.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(9),
            ),
            child: const Icon(Icons.close_rounded,
                color: MiniColors.danger, size: 19),
          ),
        );
      case _DownloadStatus.verifying:
      case _DownloadStatus.saving:
        return SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2.4,
            strokeCap: StrokeCap.round,
            color: accent,
          ),
        );
      case _DownloadStatus.completed:
        final open = onOpen;
        if (open == null) {
          return const Icon(Icons.check_rounded,
              color: MiniColors.success, size: 20);
        }
        return GestureDetector(
          onTap: open,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: MiniColors.success.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text('Open',
                style: GoogleFonts.outfit(
                    color: MiniColors.success,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
          ),
        );
    }
  }
}
