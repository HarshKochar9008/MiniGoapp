import 'dart:async';
import 'dart:io';

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
import '../../Minigo/theme/mini_icons.dart';

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
  static const _downloadedKeysPrefix = AppConstants.prefDownloadedFilesPrefix;
  static const int _storageSafetyBufferBytes = 50 * 1024 * 1024; // 50 MB
  final Battery _battery = Battery();
  List<Map<String, dynamic>>? _files;
  bool _loading = true;
  String? _loadError;

  /// Stored `transfers.status` and `created_at`, as last read. Null until
  /// the first read lands. Use [_status], which applies the client TTL.
  TransferStatus? _storedStatus;
  Object? _createdAt;
  List<FileUploadProgress>? _senderLiveStates;

  /// Bumped by every transfer-row read that starts AND every realtime row
  /// applied, so a slow read can never overwrite a newer status.
  int _metaGen = 0;
  RealtimeChannel? _detailChannel;
  final Map<String, _FileDownloadState> _dlStates = {};
  final Map<String, TransferCancellationToken> _downloadTokens = {};

  /// Set while "All" walks the list, so a second tap doesn't start a
  /// parallel walk.
  bool _downloadingAll = false;
  Set<String> _persistedDownloads = {};
  bool _powerSaveMode = false;
  late final VoidCallback _onConnectionChanged;
  Timer? _filesReloadDebounce;
  int _filesGen = 0;

  /// The transfer's effective status — expired once its TTL has passed,
  /// even before the server sweep stamps it — or null before the first read.
  TransferStatus? get _status {
    final stored = _storedStatus;
    if (stored == null) return null;
    return TransferStatus.effective(stored.dbValue, _createdAt);
  }

  /// The sender's run has ended (for now); live progress is hidden.
  bool get _transferSettled => _status?.isSettled ?? false;

  /// Downloads are refused: the files are gone, or about to be.
  bool get _transferExpired => _status == TransferStatus.expired;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ConnectionStatus.instance.ensureStarted();
    _onConnectionChanged = () {
      if (!ConnectionStatus.instance.online.value) return;
      if (_loadError != null && mounted) {
        _retryLoad();
      }
    };
    ConnectionStatus.instance.online.addListener(_onConnectionChanged);
    _refreshPowerSaveMode();
    _loadPersistedState();
    // Join the channel before the first fetch, so a file committed while the
    // fetch is in flight still arrives as an insert.
    _subscribeToDetail();
    _loadFiles();
    unawaited(_loadTransferMeta());
  }

  @override
  void dispose() {
    _filesReloadDebounce?.cancel();
    // A download that outlives this screen would still save and mark itself
    // done, while a re-opened screen shows it as not downloaded and lets it
    // start a second, duplicate save.
    for (final token in _downloadTokens.values.toList()) {
      token.cancel();
    }
    ConnectionStatus.instance.online.removeListener(_onConnectionChanged);
    WidgetsBinding.instance.removeObserver(this);
    final ch = _detailChannel;
    _detailChannel = null;
    if (ch != null) {
      TransferService.unsubscribe(ch);
    }
    super.dispose();
  }

  /// Applies a transfer row. Returns whether a known effective status
  /// changed (the first read isn't a change: initState loads files anyway).
  bool _applyTransferSnapshot(Map<String, dynamic> row) {
    final before = _status;
    final parsed =
        TransferService.parseUploadProgressPayload(row['upload_progress']);
    setState(() {
      _storedStatus = TransferStatus.parse(row['status']);
      _createdAt = row['created_at'] ?? _createdAt;
      _senderLiveStates = parsed;
    });
    return before != null && _status != before;
  }

  /// The server (or the TTL) says the transfer has expired.
  void _markExpired() {
    if (!mounted || _transferExpired) return;
    _metaGen++;
    setState(() => _storedStatus = TransferStatus.expired);
  }

  void _subscribeToDetail() {
    if (_detailChannel != null) return;
    final uid = SupabaseConfig.client.auth.currentUser?.id;
    if (uid == null) return;
    _detailChannel = TransferService.subscribeToTransferDetail(
      transferId: widget.transferId,
      receiverId: uid,
      onTransferRow: (r) {
        if (!mounted) return;
        // Newer than any read still in flight: that read must not land.
        _metaGen++;
        final changed = _applyTransferSnapshot(r);
        // Inserts committed before the channel joined (or while the app was
        // backgrounded) never arrive; any status change — a run settling, or
        // a resume putting it back to pending — is the chance to pick those
        // files up.
        if (changed) _scheduleFilesReload();
      },
      onTransferFileInserted: (_) {
        if (!mounted) return;
        _scheduleFilesReload();
      },
    );
  }

  Future<void> _loadTransferMeta() async {
    final uid = SupabaseConfig.client.auth.currentUser?.id;
    if (uid == null || !mounted) return;
    final gen = ++_metaGen;
    try {
      final row = await TransferService.getTransferForReceiver(
        transferId: widget.transferId,
        receiverId: uid,
      );
      // A realtime update (or a newer read) landed meanwhile: it is newer.
      if (!mounted || row == null || gen != _metaGen) return;
      if (_applyTransferSnapshot(row)) _scheduleFilesReload();
    } catch (_) {
      // Status and live progress are extras; the file list has its own error
      // state, and the channel above still delivers the next status change.
    }
  }

  /// A burst of file inserts collapses into one silent reload.
  void _scheduleFilesReload() {
    _filesReloadDebounce?.cancel();
    _filesReloadDebounce = Timer(const Duration(milliseconds: 400), () {
      if (mounted) _loadFiles(silent: true);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshPowerSaveMode();
      unawaited(ConnectionStatus.instance.refresh());
      // Realtime events sent while backgrounded are not replayed.
      _subscribeToDetail();
      _loadFiles(silent: true);
      unawaited(_loadTransferMeta());
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

  /// [silent] keeps the current tiles (and their download progress) on
  /// screen instead of swapping them for skeletons, and keeps them on failure.
  Future<void> _loadFiles({bool silent = false}) async {
    // Realtime events can still land after dispose.
    if (!mounted) return;
    final gen = ++_filesGen;
    final showSkeleton = !silent || _files == null;
    if (showSkeleton) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    try {
      final files = await TransferService.getTransferFiles(widget.transferId);
      // An older fetch finishing last must not drop a newer file.
      if (mounted && gen == _filesGen) {
        setState(() {
          _files = files;
          _loading = false;
          _loadError = null;
        });
      }
    } catch (e) {
      if (!mounted || gen != _filesGen || !showSkeleton) return;
      setState(() {
        _loadError =
            'Could not load files: ${e.toString().replaceAll('Exception: ', '')}';
        _loading = false;
      });
    }
  }

  /// Retry after a failed load, also re-joining the channel if it never
  /// opened (no session yet when the screen was built).
  void _retryLoad() {
    _subscribeToDetail();
    _loadFiles();
    unawaited(_loadTransferMeta());
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

  /// Asks before downloading [bytes] over mobile data, as Send asks before an
  /// upload: here someone else picked the size. Never asks on Wi‑Fi.
  Future<bool> _confirmMobileDataIfNeeded(int bytes, {int files = 1}) async {
    if (bytes < AppConstants.cellularMeteredWarnThresholdBytes) return true;
    final metered = await ConnectionStatus.instance.isLikelyMetered();
    if (!metered || !mounted) return true;

    final c = context.mini;
    final size = TransferService.formatFileSize(bytes);
    final approved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.paperDeep,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MiniRadius.card),
        ),
        title: Text(
          'Using mobile data',
          style: MiniText.title.copyWith(color: c.ink, fontSize: 20),
        ),
        content: Text(
          files == 1
              ? 'This file is $size. Downloading it now will use your '
                  'mobile data.'
              : 'These $files files are $size in total. Downloading them '
                  'now will use your mobile data.',
          style: MiniText.bodySoft,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Download'),
          ),
        ],
      ),
    );
    return approved ?? false;
  }

  /// Files not downloaded yet, and their total size.
  ({int count, int bytes}) _pendingDownloads() {
    var count = 0;
    var bytes = 0;
    for (final file in _files ?? const <Map<String, dynamic>>[]) {
      final fileId = file['id'] as String;
      final state = _dlStates[fileId]?.status;
      if (_persistedDownloads.contains(fileId) ||
          state == _DownloadStatus.completed) {
        continue;
      }
      final rawSize = file['file_size'];
      count++;
      bytes += rawSize is int ? rawSize : int.tryParse('$rawSize') ?? 0;
    }
    return (count: count, bytes: bytes);
  }

  Future<bool> _hasAggregateStorageForPendingDownloads() async {
    final requiredBytes = _pendingDownloads().bytes;
    if (requiredBytes <= 0) return true;

    final freeSpaceBytes = await _freeSpaceBytes();
    // Unknown free space doesn't block: the download itself fails cleanly
    // if the disk really is full.
    if (freeSpaceBytes == null) return true;
    return freeSpaceBytes >= (requiredBytes + _storageSafetyBufferBytes);
  }

  /// Free space in bytes, or null when the platform can't say.
  /// disk_space_plus reports megabytes.
  Future<int?> _freeSpaceBytes() async {
    try {
      final freeMb = await DiskSpacePlus().getFreeDiskSpace;
      if (freeMb == null || freeMb <= 0) return null;
      return (freeMb * 1024 * 1024).toInt();
    } catch (_) {
      return null;
    }
  }

  Widget _buildPowerSaveBanner() {
    if (!_powerSaveMode) return const SizedBox.shrink();
    return StatusBanner(
      icon: MiniIcons.batterySaver,
      text: 'Battery saver is on. Large downloads may be slower or pause.',
      tint: MiniColors.warn,
    );
  }

  /// [dataApproved]: "All" already asked about mobile data for the batch.
  Future<void> _downloadFile(
    Map<String, dynamic> file, {
    bool dataApproved = false,
  }) async {
    final fileId = file['id'] as String;
    // Claimed before the first await. The tile only swaps to its ✕ once the
    // pre-checks below finish, so a double tap — or "All" reaching a file
    // already in flight — would otherwise start a second download and save.
    if (_downloadTokens.containsKey(fileId)) return;
    final cancellationToken = TransferCancellationToken();
    _downloadTokens[fileId] = cancellationToken;
    try {
      await _runDownload(file, cancellationToken, dataApproved: dataApproved);
    } finally {
      _downloadTokens.remove(fileId);
    }
  }

  Future<void> _runDownload(
    Map<String, dynamic> file,
    TransferCancellationToken cancellationToken, {
    required bool dataApproved,
  }) async {
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
    if (_transferExpired) {
      _showExpiredSnack();
      return;
    }

    final rawSize = file['file_size'];
    final fileSize = rawSize is int ? rawSize : int.tryParse('$rawSize') ?? 0;
    // Declining leaves the file as it was, ready to download later.
    if (!dataApproved && !await _confirmMobileDataIfNeeded(fileSize)) return;
    final powerApproved = await _confirmPowerSaveIfNeeded(fileSize);
    if (!powerApproved) {
      if (mounted) {
        setState(() => _dlStates[fileId] = const _FileDownloadState(
              status: _DownloadStatus.postponed,
              error: 'Postponed while battery saver is on',
            ));
      }
      return;
    }

    final freeSpaceBytes = await _freeSpaceBytes();
    if (fileSize > 0 &&
        freeSpaceBytes != null &&
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
    if (!mounted) return;
    // The dialogs above can sit open across the TTL, or a realtime update.
    if (_transferExpired) {
      _showExpiredSnack();
      return;
    }

    setState(() => _dlStates[fileId] = const _FileDownloadState(
          status: _DownloadStatus.downloading,
        ));
    Analytics.instance.logEvent(AnalyticsEvents.downloadStarted, {
      'bytes': fileSize,
    });

    // The save step copies this temp file out (MediaStore / Files). It is
    // kept only where it is itself the "Open" target (iOS gallery preview).
    File? downloadedFile;
    var keepTempFile = false;
    try {
      downloadedFile = await TransferService.downloadToFile(
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
        cancellationToken: cancellationToken,
      );
      if (integrity == IntegrityCheck.mismatch) {
        if (mounted) {
          setState(() => _dlStates[fileId] = const _FileDownloadState(
                status: _DownloadStatus.failed,
                error: 'File may be corrupted. It failed the integrity check.',
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

      // Last point a cancel can still win: once saved, the file is the
      // user's, and it is recorded as downloaded.
      if (cancellationToken.isCancelled) throw TransferCancelledException();
      final saved = await saveFileToDevice(downloadedFile, fileName);
      keepTempFile = saved.open == downloadedFile.path;

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
              status: _DownloadStatus.cancelled,
              error: 'Download cancelled',
            ));
      }
    } on TransferExpiredException catch (e) {
      Analytics.instance.logError(AnalyticsEvents.downloadFailed, e);
      if (mounted) {
        setState(() => _dlStates.remove(fileId));
        _markExpired();
        _showExpiredSnack();
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
      final temp = downloadedFile;
      if (temp != null && !keepTempFile) {
        unawaited(temp.delete().then((_) {}, onError: (_) {}));
      }
    }
  }

  void _cancelDownload(String fileId) {
    _downloadTokens[fileId]?.cancel();
  }

  void _showExpiredSnack() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('This transfer has expired. Its files are no longer '
            'available.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Widget _buildReceiveBody() {
    final c = context.mini;
    final files = _files ?? const <Map<String, dynamic>>[];
    final hasFiles = files.isNotEmpty;
    final live = _senderLiveStates;
    final showLive =
        (_status?.showLiveProgress ?? false) && live != null && live.isNotEmpty;
    final expired = _transferExpired;

    if (!hasFiles && !showLive) {
      final waiting = !_transferSettled;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(MiniIcons.pending, size: 40, color: c.inkFaint),
              const SizedBox(height: 16),
              Text(
                expired
                    ? 'This transfer has expired'
                    : waiting
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
        if (expired) ...[
          StatusBanner(
            icon: MiniIcons.timer,
            text: 'This transfer has expired. Its files are no longer '
                'available to download.',
            tint: MiniColors.warn,
          ),
          const SizedBox(height: 12),
        ],
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
                expired: expired,
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
    if (_files == null || _files!.isEmpty || _downloadingAll) return;
    if (_transferExpired) {
      _showExpiredSnack();
      return;
    }
    _downloadingAll = true;
    try {
      await _downloadAllPending();
    } finally {
      _downloadingAll = false;
    }
  }

  Future<void> _downloadAllPending() async {
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

    // One question for the batch, not one per file.
    final pending = _pendingDownloads();
    if (!await _confirmMobileDataIfNeeded(pending.bytes,
        files: pending.count)) {
      return;
    }

    for (final file in _files!) {
      // Expired mid-walk (TTL, realtime, or a refused file): stop here.
      if (!mounted || _transferExpired) return;
      final fileId = file['id'] as String;
      final state = _dlStates[fileId];
      if (state == null || state.status != _DownloadStatus.completed) {
        await _downloadFile(file, dataApproved: true);
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

    return PopScope(
      canPop: _downloadTokens.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeaveDuringDownload();
      },
      child: Scaffold(
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
                        onTap: () => Navigator.maybePop(context),
                        customBorder: const CircleBorder(),
                        child: Padding(
                          padding: const EdgeInsets.all(9),
                          child: Icon(MiniIcons.back, color: c.ink, size: 20),
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('From',
                              style:
                                  MiniText.label.copyWith(color: c.inkFaint)),
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
                    if (_files != null &&
                        _files!.isNotEmpty &&
                        !allCompleted &&
                        !_transferExpired)
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
                                Icon(MiniIcons.download,
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
                                    onPressed: _retryLoad,
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
      ),
    );
  }

  /// Leaving cancels in-flight downloads (see [dispose]), so ask first.
  Future<void> _confirmLeaveDuringDownload() async {
    // canPop is read at build time; the last download may have just ended.
    if (_downloadTokens.isEmpty) {
      Navigator.pop(context);
      return;
    }
    final c = context.mini;
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.paperDeep,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MiniRadius.card),
        ),
        title: Text(
          'Stop downloading?',
          style: MiniText.title.copyWith(color: c.ink, fontSize: 20),
        ),
        content: Text(
          'Leaving this screen cancels the downloads in progress. '
          'You can download them again later.',
          style: MiniText.bodySoft,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep downloading'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (leave == true && mounted) Navigator.pop(context);
  }
}

enum _DownloadStatus {
  idle,
  downloading,
  verifying,
  saving,
  completed,
  failed,

  /// Stopped by the user; can be started again. Not an error.
  cancelled,

  /// Declined at a pre-check (battery saver); can be started again.
  postponed,
}

extension on _DownloadStatus {
  /// Idle-like: the tile offers a download.
  bool get canStart =>
      this == _DownloadStatus.idle ||
      this == _DownloadStatus.failed ||
      this == _DownloadStatus.cancelled ||
      this == _DownloadStatus.postponed;
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

  /// The transfer expired: a file not already saved can't be fetched.
  final bool expired;
  final VoidCallback onDownload;
  final VoidCallback onCancel;
  final VoidCallback? onOpen;

  const _FileDownloadTile({
    required this.fileName,
    required this.fileSize,
    required this.state,
    required this.onDownload,
    required this.onCancel,
    this.expired = false,
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
                Icon(MiniIcons.success, color: c.inkFaint, size: 14),
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
          if ((status == _DownloadStatus.cancelled ||
                  status == _DownloadStatus.postponed) &&
              state?.error != null) ...[
            const SizedBox(height: 8),
            Text(
              state!.error!,
              style: GoogleFonts.outfit(
                color: c.inkSoft,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
          if (expired && status.canStart) ...[
            const SizedBox(height: 8),
            Text(
              'Expired',
              style: GoogleFonts.outfit(
                color: c.inkSoft,
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
        return MiniIcons.success;
      case _DownloadStatus.failed:
        return MiniIcons.error;
      default:
        return MiniIcons.file;
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
      case _DownloadStatus.cancelled:
      case _DownloadStatus.postponed:
        if (expired) {
          return const Icon(MiniIcons.timer,
              color: MiniColors.inkFaint, size: 20);
        }
        return GestureDetector(
          onTap: onDownload,
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(MiniIcons.download, color: accent, size: 19),
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
            child:
                const Icon(MiniIcons.close, color: MiniColors.danger, size: 19),
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
          return const Icon(MiniIcons.check,
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
