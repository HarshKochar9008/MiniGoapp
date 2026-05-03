import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:mime/mime.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:tus_client_dart/tus_client_dart.dart';

import '../../core/constants.dart';
import '../../core/network/network_errors.dart';
import '../../core/offline/pending_backend_jobs.dart';
import '../../core/supabase_config.dart';

// ── Models ───────────────────────────────────────────────────────────────────

enum FileUploadStatus { pending, hashing, uploading, completed, failed }

class FileUploadProgress {
  final String fileName;
  final int fileSize;
  final FileUploadStatus status;
  final double progress;
  final String? sha256;
  final String? error;
  final int attempt;

  const FileUploadProgress({
    required this.fileName,
    required this.fileSize,
    this.status = FileUploadStatus.pending,
    this.progress = 0,
    this.sha256,
    this.error,
    this.attempt = 0,
  });

  FileUploadProgress copyWith({
    FileUploadStatus? status,
    double? progress,
    String? sha256,
    String? error,
    int? attempt,
  }) =>
      FileUploadProgress(
        fileName: fileName,
        fileSize: fileSize,
        status: status ?? this.status,
        progress: progress ?? this.progress,
        sha256: sha256 ?? this.sha256,
        error: error,
        attempt: attempt ?? this.attempt,
      );
}

class TransferResult {
  final bool success;
  final int completedFiles;
  final int totalFiles;
  final List<FileUploadProgress> fileStates;

  const TransferResult({
    required this.success,
    required this.completedFiles,
    required this.totalFiles,
    required this.fileStates,
  });
}

class PendingUploadJob {
  final String senderId;
  final String receiverId;
  final String? receiverCode;
  /// Server `transfers.id` for this interrupted send; persisted so resume never
  /// creates a second row for the same pending job.
  final String? transferId;
  final List<PendingUploadFile> files;
  final DateTime createdAt;

  const PendingUploadJob({
    required this.senderId,
    required this.receiverId,
    required this.files,
    required this.createdAt,
    this.receiverCode,
    this.transferId,
  });

  List<PlatformFile> toPlatformFiles() {
    return files
        .map(
          (f) => PlatformFile(
            name: f.name,
            path: f.path,
            size: f.size,
          ),
        )
        .toList();
  }

  Map<String, dynamic> toJson() {
    final tid = transferId?.trim();
    return {
      'sender_id': senderId,
      'receiver_id': receiverId,
      'receiver_code': receiverCode,
      if (tid != null && tid.isNotEmpty) 'transfer_id': tid,
      'created_at': createdAt.toIso8601String(),
      'files': files.map((f) => f.toJson()).toList(),
    };
  }

  static PendingUploadJob? fromJson(Map<String, dynamic> json) {
    final filesRaw = json['files'];
    if (filesRaw is! List) return null;
    final files = filesRaw
        .whereType<Map>()
        .map((e) => PendingUploadFile.fromJson(Map<String, dynamic>.from(e)))
        .whereType<PendingUploadFile>()
        .toList();
    if (files.isEmpty) return null;

    final senderId = (json['sender_id'] ?? '').toString();
    final receiverId = (json['receiver_id'] ?? '').toString();
    if (senderId.isEmpty || receiverId.isEmpty) return null;

    final tidRaw = (json['transfer_id']?.toString() ?? '').trim();
    final transferId = tidRaw.isNotEmpty ? tidRaw : null;

    return PendingUploadJob(
      senderId: senderId,
      receiverId: receiverId,
      receiverCode: (json['receiver_code'] as String?)?.trim(),
      transferId: transferId,
      createdAt: DateTime.tryParse((json['created_at'] ?? '').toString()) ??
          DateTime.now().toUtc(),
      files: files,
    );
  }
}

class PendingUploadFile {
  final String name;
  final String path;
  final int size;

  const PendingUploadFile({
    required this.name,
    required this.path,
    required this.size,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'path': path,
        'size': size,
      };

  static PendingUploadFile? fromJson(Map<String, dynamic> json) {
    final name = (json['name'] ?? '').toString();
    final path = (json['path'] ?? '').toString();
    final size = json['size'];
    final parsedSize = size is int ? size : int.tryParse('$size') ?? 0;
    if (name.isEmpty || path.isEmpty || parsedSize <= 0) return null;
    return PendingUploadFile(name: name, path: path, size: parsedSize);
  }
}

// ── Exceptions ───────────────────────────────────────────────────────────────

class FileTooLargeException implements Exception {
  final String fileName;
  final int size;
  FileTooLargeException(this.fileName, this.size);

  @override
  String toString() =>
      '$fileName is too large (${(size / 1024 / 1024).toStringAsFixed(0)} MB). '
      'Max allowed: ${AppConstants.maxFileSizeBytes ~/ 1024 ~/ 1024} MB.';
}

class TooManyFilesException implements Exception {
  final int count;
  TooManyFilesException(this.count);

  @override
  String toString() =>
      'Too many files ($count). Max: ${AppConstants.maxFilesPerTransfer}.';
}

class IntegrityException implements Exception {
  final String fileName;
  IntegrityException(this.fileName);

  @override
  String toString() => 'Integrity check failed for $fileName.';
}

class NoConnectionException implements Exception {
  @override
  String toString() => 'No internet connection. Please check your network.';
}

class AuthenticationException implements Exception {
  @override
  String toString() => 'Session expired. Please restart the app.';
}

class StorageUploadException implements Exception {
  final int statusCode;
  final String details;
  StorageUploadException(this.statusCode, this.details);

  @override
  String toString() => 'Upload failed ($statusCode): $details';
}

class PushReadinessResult {
  final bool ready;
  final String? reason;

  const PushReadinessResult({
    required this.ready,
    this.reason,
  });
}

class TransferCancellationToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class TransferCancelledException implements Exception {
  final String message;
  TransferCancelledException([this.message = 'Transfer cancelled by user.']);
  @override
  String toString() => message;
}

// ── SHA-256 helper sink ──────────────────────────────────────────────────────

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

// ── Service ──────────────────────────────────────────────────────────────────

/// Throttled writer for `transfers.upload_progress` so receivers see live upload state
/// without flooding PostgREST on every TUS chunk callback.
class _TransferProgressBroadcaster {
  _TransferProgressBroadcaster(this._client, this._transferId);

  final SupabaseClient _client;
  final String _transferId;
  String? _lastSig;
  DateTime? _lastAt;

  void notify(List<FileUploadProgress> states) {
    final sig = states
        .map((e) => '${e.status.name}:${(e.progress * 100).round()}')
        .join('|');
    final now = DateTime.now();
    final elapsed =
        _lastAt == null ? const Duration(days: 1) : now.difference(_lastAt!);
    if (sig == _lastSig && elapsed < const Duration(milliseconds: 280)) {
      return;
    }
    _lastSig = sig;
    _lastAt = now;
    unawaited(_write(states));
  }

  Future<void> flushFinal(List<FileUploadProgress> states) async {
    await _write(states);
  }

  Future<void> _write(List<FileUploadProgress> states) async {
    try {
      await _client.from('transfers').update({
        'upload_progress': TransferService.uploadProgressPayload(states),
      }).eq('id', _transferId);
    } catch (_) {
      // Column may be missing on older DBs; transfer still succeeds locally.
    }
  }
}

class TransferService {
  static const _maxRetries = 3;
  static const _pendingUploadKey = 'pending_upload_job_v1';

  /// JSON snapshot written to [transfers.upload_progress] for receiver realtime UI.
  static List<Map<String, dynamic>> uploadProgressPayload(
    List<FileUploadProgress> states,
  ) {
    return states
        .map(
          (s) => <String, dynamic>{
            'file_name': s.fileName,
            'file_size': s.fileSize,
            'status': s.status.name,
            'progress': s.progress,
            if (s.sha256 != null) 'sha256': s.sha256,
            if (s.error != null) 'error': s.error,
            'attempt': s.attempt,
          },
        )
        .toList();
  }

  /// Parses DB `upload_progress` JSON into [FileUploadProgress] list.
  static List<FileUploadProgress>? parseUploadProgressPayload(dynamic raw) {
    if (raw == null) return null;
    if (raw is! List) return null;
    final out = <FileUploadProgress>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final m = Map<String, dynamic>.from(item);
      final name = (m['file_name'] ?? '').toString();
      if (name.isEmpty) continue;
      final sizeRaw = m['file_size'];
      final size = sizeRaw is int ? sizeRaw : int.tryParse('$sizeRaw') ?? 0;
      FileUploadStatus status;
      try {
        status = FileUploadStatus.values.byName((m['status'] ?? 'pending').toString());
      } catch (_) {
        status = FileUploadStatus.pending;
      }
      final progress = (m['progress'] is num)
          ? (m['progress'] as num).toDouble()
          : double.tryParse('${m['progress']}') ?? 0.0;
      final sha = m['sha256']?.toString();
      final err = m['error']?.toString();
      final attemptRaw = m['attempt'];
      final attempt =
          attemptRaw is int ? attemptRaw : int.tryParse('$attemptRaw') ?? 0;
      out.add(
        FileUploadProgress(
          fileName: name,
          fileSize: size,
          status: status,
          progress: progress.clamp(0.0, 1.0),
          sha256: sha,
          error: err,
          attempt: attempt,
        ),
      );
    }
    return out.isEmpty ? null : out;
  }

  /// Compute SHA-256 of a file using streaming reads (constant memory).
  static Future<String> computeSha256(
    File file, {
    void Function(int processed, int total)? onProgress,
    TransferCancellationToken? cancellationToken,
  }) async {
    final fileLength = await file.length();
    final digestSink = _DigestSink();
    final byteSink = sha256.startChunkedConversion(digestSink);

    var processed = 0;
    await for (final chunk in file.openRead()) {
      if (cancellationToken?.isCancelled == true) {
        throw TransferCancelledException();
      }
      byteSink.add(chunk);
      processed += chunk.length;
      onProgress?.call(processed, fileLength);
    }

    byteSink.close();
    return digestSink.value!.toString();
  }

  /// Strip dangerous chars from file names to prevent path traversal.
  static String sanitizeFileName(String name) {
    var safe = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');
    safe = safe.replaceAll('..', '_');
    if (safe.isEmpty) safe = 'unnamed_file';
    return safe;
  }

  /// Human-readable file size formatting.
  static String formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  /// Supabase Storage TUS endpoint (direct storage hostname when possible).
  static Uri _tusResumableUri() {
    final u = Uri.parse(AppConstants.supabaseUrl);
    final host = u.host;
    if (host.endsWith('.supabase.co') && !host.contains('.storage.')) {
      final projectRef = host.replaceAll('.supabase.co', '');
      return Uri.parse(
        'https://$projectRef.storage.supabase.co/storage/v1/upload/resumable',
      );
    }
    return Uri(
      scheme: u.scheme,
      host: u.host,
      port: u.hasPort ? u.port : null,
      path: '/storage/v1/upload/resumable',
    );
  }

  /// Resumable upload via TUS (6 MiB chunks, per Supabase). Falls back to a single POST stream if TUS is unavailable.
  static Future<void> _uploadStorageFile({
    required String storagePath,
    required File file,
    required String contentType,
    void Function(int sent, int total)? onProgress,
    TransferCancellationToken? cancellationToken,
  }) async {
    await SupabaseConfig.ensureValidSession();
    final session = SupabaseConfig.client.auth.currentSession;
    if (session == null) throw AuthenticationException();

    final fileLength = await file.length();
    Directory? workDir;
    Timer? cancelTimer;
    TusClient? tus;

    Future<void> runTus() async {
      final root = await getApplicationSupportDirectory();
      workDir = Directory(
        '${root.path}/tus/${storagePath.hashCode}_${fileLength}_${DateTime.now().microsecondsSinceEpoch}',
      );
      await workDir!.create(recursive: true);

      tus = TusClient(
        XFile(file.path),
        store: TusFileStore(workDir!),
        maxChunkSize: 6 * 1024 * 1024,
        retries: 12,
        retryInterval: 1,
        retryScale: RetryScale.exponential,
      );

      cancelTimer =
          Timer.periodic(const Duration(milliseconds: 250), (_) async {
        if (cancellationToken?.isCancelled == true) {
          cancelTimer?.cancel();
          try {
            await tus?.cancelUpload();
          } catch (_) {}
        }
      });

      await tus!.upload(
        uri: _tusResumableUri(),
        headers: {
          'Authorization': 'Bearer ${session.accessToken}',
          'apikey': AppConstants.supabaseAnonKey,
          'x-upsert': 'true',
        },
        metadata: {
          'bucketName': 'transfers',
          'objectName': storagePath,
          'contentType': contentType,
          'cacheControl': '3600',
        },
        onProgress: (percent, _) {
          if (fileLength <= 0) return;
          final sent =
              (fileLength * (percent / 100.0)).round().clamp(0, fileLength);
          onProgress?.call(sent, fileLength);
        },
      );

      if (cancellationToken?.isCancelled == true) {
        throw TransferCancelledException();
      }
    }

    try {
      try {
        await runTus();
      } on ProtocolException catch (e) {
        final code = e.code;
        if (code == 404 || code == 405 || code == 501) {
          await _streamUpload(
            storagePath: storagePath,
            file: file,
            contentType: contentType,
            onProgress: onProgress,
            cancellationToken: cancellationToken,
          );
        } else {
          rethrow;
        }
      }
    } finally {
      cancelTimer?.cancel();
      try {
        if (workDir != null && workDir!.existsSync()) {
          await workDir!.delete(recursive: true);
        }
      } catch (_) {}
    }
  }

  // ── Single-shot streaming upload (fallback, avoids loading full file into RAM) ─

  static Future<void> _streamUpload({
    required String storagePath,
    required File file,
    required String contentType,
    void Function(int sent, int total)? onProgress,
    TransferCancellationToken? cancellationToken,
  }) async {
    await SupabaseConfig.ensureValidSession();
    final session = SupabaseConfig.client.auth.currentSession;
    if (session == null) throw AuthenticationException();

    final fileLength = await file.length();
    final url = Uri.parse(
      '${AppConstants.supabaseUrl}/storage/v1/object/transfers/$storagePath',
    );

    final httpClient = HttpClient();
    try {
      final request = await httpClient.postUrl(url);
      request.headers.set('Authorization', 'Bearer ${session.accessToken}');
      request.headers.set('apikey', AppConstants.supabaseAnonKey);
      request.headers.set('Content-Type', contentType);
      request.headers.set('x-upsert', 'true');
      request.contentLength = fileLength;

      var bytesSent = 0;
      final progressStream = file.openRead().map((chunk) {
        if (cancellationToken?.isCancelled == true) {
          throw TransferCancelledException();
        }
        bytesSent += chunk.length;
        onProgress?.call(bytesSent, fileLength);
        return chunk;
      });

      await request.addStream(progressStream);
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode >= 400) {
        throw StorageUploadException(response.statusCode, body);
      }
    } finally {
      httpClient.close();
    }
  }

  static String _receiverCodeKey(String? code) {
    final t = (code ?? '').trim();
    if (t.isEmpty) return '';
    return AppConstants.normalizeShortCode(t);
  }

  static bool _pendingJobMatchesSend(
    PendingUploadJob? pending, {
    required String receiverId,
    required String? receiverCode,
    required List<PlatformFile> validFiles,
  }) {
    if (pending == null) return false;
    if (pending.receiverId != receiverId) return false;
    if (_receiverCodeKey(pending.receiverCode) !=
        _receiverCodeKey(receiverCode)) {
      return false;
    }
    if (pending.files.length != validFiles.length) return false;
    for (var i = 0; i < validFiles.length; i++) {
      final a = pending.files[i];
      final b = validFiles[i];
      if (a.name != b.name || a.size != b.size || a.path != b.path) {
        return false;
      }
    }
    return true;
  }

  /// Eligible rows already in `transfer_files` for this transfer, keyed by
  /// `file_name` (sanitized), or `null` if this transfer must not be resumed.
  static Future<Map<String, Map<String, dynamic>>?> _loadTransferResumeSnapshot({
    required SupabaseClient client,
    required String transferId,
    required String senderId,
    required String receiverId,
  }) async {
    final transfer = await client
        .from('transfers')
        .select('sender_id,receiver_id,status')
        .eq('id', transferId)
        .maybeSingle();
    if (transfer == null) return null;
    if (transfer['sender_id']?.toString() != senderId) return null;
    if (transfer['receiver_id']?.toString() != receiverId) return null;
    final st = (transfer['status'] ?? '').toString().toLowerCase();
    if (st == 'completed' || st == 'expired') return null;

    final rows =
        await client.from('transfer_files').select().eq('transfer_id', transferId);
    final out = <String, Map<String, dynamic>>{};
    for (final raw in rows) {
      final m = Map<String, dynamic>.from(raw);
      final fn = (m['file_name'] ?? '').toString();
      if (fn.isNotEmpty) out[fn] = m;
    }
    return out;
  }

  static Future<void> _abandonOrphanTransfer(
    SupabaseClient client,
    String transferId,
  ) async {
    await _safeUpdateTransferStatus(client, transferId, 'failed');
  }

  // ── Send files ───────────────────────────────────────────────────────────

  static Future<TransferResult> sendFiles({
    required String senderId,
    required String receiverId,
    required List<PlatformFile> files,
    required void Function(List<FileUploadProgress> states) onProgress,
    TransferCancellationToken? cancellationToken,
    String? receiverCode,
  }) async {
    for (final file in files) {
      if (file.size > AppConstants.maxFileSizeBytes) {
        throw FileTooLargeException(file.name, file.size);
      }
    }
    if (files.length > AppConstants.maxFilesPerTransfer) {
      throw TooManyFilesException(files.length);
    }
    final validFiles = files.where((f) => f.path != null).toList();

    final existingPending = await getPendingUploadJob(senderId: senderId);
    final matches = _pendingJobMatchesSend(
      existingPending,
      receiverId: receiverId,
      receiverCode: receiverCode,
      validFiles: validFiles,
    );

    final pendingTid = existingPending?.transferId?.trim();
    final orphanTid = (!matches &&
            pendingTid != null &&
            pendingTid.isNotEmpty)
        ? pendingTid
        : null;

    await SupabaseConfig.ensureValidSession();
    final client = SupabaseConfig.client;

    if (orphanTid != null) {
      await _abandonOrphanTransfer(client, orphanTid);
    }

    final createdAtBase = (matches && existingPending != null)
        ? existingPending.createdAt
        : DateTime.now().toUtc();
    final earlyTid =
        matches && pendingTid != null && pendingTid.isNotEmpty ? pendingTid : null;

    await _storePendingUploadJob(
      senderId: senderId,
      receiverId: receiverId,
      receiverCode: receiverCode,
      files: validFiles,
      transferId: earlyTid,
      createdAt: createdAtBase,
    );

    late final String transferId;
    Map<String, Map<String, dynamic>> resumeByFileName = {};

    if (matches &&
        existingPending?.transferId != null &&
        existingPending!.transferId!.trim().isNotEmpty) {
      final tid = existingPending.transferId!.trim();
      final snap = await _loadTransferResumeSnapshot(
        client: client,
        transferId: tid,
        senderId: senderId,
        receiverId: receiverId,
      );
      if (snap != null) {
        transferId = tid;
        resumeByFileName = snap;
      } else {
        await _abandonOrphanTransfer(client, tid);
        final transfer = await client
            .from('transfers')
            .insert({
              'sender_id': senderId,
              'receiver_id': receiverId,
              'status': 'pending',
            })
            .select()
            .single();
        transferId = transfer['id'] as String;
      }
    } else {
      final transfer = await client
          .from('transfers')
          .insert({
            'sender_id': senderId,
            'receiver_id': receiverId,
            'status': 'pending',
          })
          .select()
          .single();
      transferId = transfer['id'] as String;
    }

    await _storePendingUploadJob(
      senderId: senderId,
      receiverId: receiverId,
      receiverCode: receiverCode,
      files: validFiles,
      transferId: transferId,
      createdAt: createdAtBase,
    );

    var states = files
        .map((f) => FileUploadProgress(fileName: f.name, fileSize: f.size))
        .toList();

    for (var i = 0; i < files.length; i++) {
      final safeName = sanitizeFileName(files[i].name);
      final row = resumeByFileName[safeName];
      if (row != null) {
        final sha = row['sha256_hash']?.toString();
        states = _updateState(
          states,
          i,
          states[i].copyWith(
            status: FileUploadStatus.completed,
            progress: 1.0,
            sha256: (sha != null && sha.isNotEmpty) ? sha : states[i].sha256,
          ),
        );
      }
    }

    var completedCount =
        states.where((s) => s.status == FileUploadStatus.completed).length;

    onProgress(states);

    final progressBroadcaster = _TransferProgressBroadcaster(client, transferId);
    void report(List<FileUploadProgress> s) {
      onProgress(s);
      progressBroadcaster.notify(s);
    }

    try {
      for (var i = 0; i < files.length; i++) {
        if (cancellationToken?.isCancelled == true) {
          throw TransferCancelledException();
        }

        if (states[i].status == FileUploadStatus.completed) {
          report(states);
          continue;
        }

        final file = files[i];
        final filePath = file.path;

        if (filePath == null || !await File(filePath).exists()) {
          states = _updateState(
            states,
            i,
            states[i].copyWith(
              status: FileUploadStatus.failed,
              error: 'File not accessible on disk',
            ),
          );
          report(states);
          continue;
        }

        final diskFile = File(filePath);
        final safeName = sanitizeFileName(file.name);
        final mimeType =
            lookupMimeType(file.name) ?? 'application/octet-stream';
        final storagePath = '$transferId/$safeName';

        // ── Phase 1: SHA-256 ────────────────────────────────────────────
        states = _updateState(
          states,
          i,
          states[i].copyWith(status: FileUploadStatus.hashing, progress: 0),
        );
        report(states);

        String hash;
        try {
          hash = await computeSha256(
            diskFile,
            cancellationToken: cancellationToken,
            onProgress: (p, t) {
              if (t > 0) {
                states = _updateState(
                  states,
                  i,
                  states[i].copyWith(progress: p / t),
                );
                report(states);
              }
            },
          );
        } catch (e) {
          if (e is TransferCancelledException) rethrow;
          states = _updateState(
            states,
            i,
            states[i].copyWith(
              status: FileUploadStatus.failed,
              error:
                  'Hash computation failed: ${e.toString().replaceAll('Exception: ', '')}',
            ),
          );
          report(states);
          continue;
        }

        // ── Phase 2: Upload with retry ──────────────────────────────────
        states = _updateState(
          states,
          i,
          states[i].copyWith(
            status: FileUploadStatus.uploading,
            sha256: hash,
            progress: 0,
          ),
        );
        report(states);

        var uploaded = false;
        String? lastError;

        for (var attempt = 1; attempt <= _maxRetries; attempt++) {
          try {
            states = _updateState(
              states,
              i,
              states[i].copyWith(attempt: attempt, progress: 0),
            );
            report(states);

            await _uploadStorageFile(
              storagePath: storagePath,
              file: diskFile,
              contentType: mimeType,
              cancellationToken: cancellationToken,
              onProgress: (sent, total) {
                if (total > 0) {
                  states = _updateState(
                    states,
                    i,
                    states[i].copyWith(progress: sent / total),
                  );
                  report(states);
                }
              },
            );

            await _insertTransferFile({
              'transfer_id': transferId,
              'file_name': safeName,
              'file_size': file.size,
              'mime_type': mimeType,
              'storage_path': storagePath,
              'sha256_hash': hash,
            });

            uploaded = true;
            break;
          } catch (e) {
            if (e is TransferCancelledException) rethrow;
            lastError = e.toString().replaceAll('Exception: ', '');
            if (attempt < _maxRetries) {
              await Future.delayed(Duration(seconds: attempt * 2));
            }
          }
        }

        if (uploaded) {
          completedCount++;
          states = _updateState(
            states,
            i,
            states[i].copyWith(
              status: FileUploadStatus.completed,
              progress: 1.0,
            ),
          );
        } else {
          states = _updateState(
            states,
            i,
            states[i].copyWith(
              status: FileUploadStatus.failed,
              error: 'Failed after $_maxRetries attempts: $lastError',
            ),
          );
        }
        report(states);
      }

      final allDone =
          states.every((s) => s.status == FileUploadStatus.completed);
      final anyDone = states.any((s) => s.status == FileUploadStatus.completed);

      await progressBroadcaster.flushFinal(states);
      await _safeUpdateTransferStatus(
        client,
        transferId,
        allDone
            ? 'completed'
            : anyDone
                ? 'partial'
                : 'failed',
      );
      if (anyDone) {
        await _triggerIncomingTransferPush(
          transferId: transferId,
          senderId: senderId,
          receiverId: receiverId,
        );
      }

      return TransferResult(
        success: allDone,
        completedFiles: completedCount,
        totalFiles: files.length,
        fileStates: states,
      );
    } catch (e) {
      try {
        await progressBroadcaster.flushFinal(states);
      } catch (_) {}
      await _safeUpdateTransferStatus(client, transferId, 'failed');
      rethrow;
    } finally {
      // If app is force-killed, this won't run and pending job remains for recovery.
      await clearPendingUploadJob();
    }
  }

  static Future<void> _storePendingUploadJob({
    required String senderId,
    required String receiverId,
    required List<PlatformFile> files,
    String? receiverCode,
    /// When null, job is still "in flight" before a `transfers` row exists; used
    /// so a process kill still leaves enough state to offer resume/discards UI.
    String? transferId,
    DateTime? createdAt,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final serializableFiles = files
        .where((f) => f.path != null)
        .map(
          (f) => PendingUploadFile(
            name: f.name,
            path: f.path!,
            size: f.size,
          ),
        )
        .toList();
    if (serializableFiles.isEmpty) return;

    final tid = transferId?.trim();
    final job = PendingUploadJob(
      senderId: senderId,
      receiverId: receiverId,
      receiverCode: receiverCode,
      transferId: (tid != null && tid.isNotEmpty) ? tid : null,
      createdAt: createdAt ?? DateTime.now().toUtc(),
      files: serializableFiles,
    );
    await prefs.setString(_pendingUploadKey, jsonEncode(job.toJson()));
  }

  static Future<PendingUploadJob?> getPendingUploadJob({
    required String senderId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_pendingUploadKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final job = PendingUploadJob.fromJson(decoded);
      if (job == null) return null;
      if (job.senderId != senderId) return null;
      return job;
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearPendingUploadJob() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingUploadKey);
  }

  /// Clears local pending send state and marks the server transfer as failed so
  /// a discarded or obsolete job cannot leave a dangling `pending` transfer.
  static Future<void> discardPendingUploadJob({
    required String senderId,
  }) async {
    final job = await getPendingUploadJob(senderId: senderId);
    final tid = job?.transferId?.trim();
    if (tid != null && tid.isNotEmpty) {
      try {
        await SupabaseConfig.ensureValidSession();
        await _abandonOrphanTransfer(SupabaseConfig.client, tid);
      } catch (_) {}
    }
    await clearPendingUploadJob();
  }

  /// Updates the transfer status, handling the case where `status` is a
  /// Postgres ENUM that may not contain all values (e.g. 'failed', 'partial').
  /// Falls back to 'completed' or 'pending' if the desired value is rejected.
  static Future<void> _safeUpdateTransferStatus(
    SupabaseClient client,
    String transferId,
    String desiredStatus,
  ) async {
    try {
      await client
          .from('transfers')
          .update({'status': desiredStatus}).eq('id', transferId);
    } on PostgrestException catch (e) {
      // 22P02 = invalid_text_representation (enum value not found)
      if (e.code == '22P02') {
        // Try a safe fallback the enum is likely to have
        final fallback =
            (desiredStatus == 'completed') ? 'completed' : 'pending';
        try {
          await client
              .from('transfers')
              .update({'status': fallback}).eq('id', transferId);
        } catch (_) {
          // Status update is non-critical — the files are already uploaded
        }
      }
      // For other errors, silently ignore — don't crash the transfer
    }
  }

  /// Insert a transfer_files row.
  /// Falls back without sha256_hash when the column doesn't exist:
  ///   - 42703: PostgreSQL undefined_column
  ///   - PGRST204: PostgREST column not found in schema cache
  static Future<void> _insertTransferFile(Map<String, dynamic> data) async {
    try {
      await SupabaseConfig.client.from('transfer_files').insert(data);
    } on PostgrestException catch (e) {
      if (e.code == '42703' || e.code == 'PGRST204') {
        final fallback = Map<String, dynamic>.from(data)..remove('sha256_hash');
        await SupabaseConfig.client.from('transfer_files').insert(fallback);
      } else {
        rethrow;
      }
    }
  }

  static Future<void> _invokeSendTransferFcmEdge({
    required String transferId,
    required String senderId,
    required String receiverId,
  }) async {
    await SupabaseConfig.client.functions.invoke(
      'send-transfer-fcm',
      body: {
        'record': {
          'id': transferId,
          'sender_id': senderId,
          'receiver_id': receiverId,
        },
      },
    );
  }

  /// Retries edge invokes that failed with a retryable network error after upload.
  static Future<void> flushPendingTransferPushNotifications() async {
    final jobs = await PendingBackendJobs.loadTransferPushQueue();
    if (jobs.isEmpty) return;

    final remaining = <Map<String, String>>[];
    for (final job in jobs) {
      final transferId = job['transfer_id']!;
      final senderId = job['sender_id']!;
      final receiverId = job['receiver_id']!;
      try {
        await _invokeSendTransferFcmEdge(
          transferId: transferId,
          senderId: senderId,
          receiverId: receiverId,
        );
      } catch (e) {
        if (NetworkErrors.isRetryableFailure(e)) {
          remaining.add(job);
        }
        if (kDebugMode) {
          debugPrint('Pending FCM invoke for $transferId: $e');
        }
      }
    }
    await PendingBackendJobs.saveTransferPushQueue(remaining);
  }

  static Future<void> _triggerIncomingTransferPush({
    required String transferId,
    required String senderId,
    required String receiverId,
  }) async {
    try {
      await _invokeSendTransferFcmEdge(
        transferId: transferId,
        senderId: senderId,
        receiverId: receiverId,
      );
    } catch (e) {
      if (NetworkErrors.isRetryableFailure(e)) {
        await PendingBackendJobs.enqueueTransferPushNotification(
          transferId: transferId,
          senderId: senderId,
          receiverId: receiverId,
        );
      }
      if (kDebugMode) {
        debugPrint('FCM trigger failed for transfer $transferId: $e');
      }
    }
  }

  /// Verifies that closed-app incoming delivery is actually possible before send.
  /// This prevents silent "sent but no notification" failures when push infra
  /// has not been set up yet.
  static Future<PushReadinessResult> verifyClosedAppDeliveryReadiness({
    required String receiverId,
  }) async {
    try {
      await SupabaseConfig.ensureValidSession();

      final receiver = await SupabaseConfig.client
          .from('users')
          .select('fcm_token')
          .eq('id', receiverId)
          .maybeSingle();
      final receiverToken = (receiver?['fcm_token'] as String?)?.trim();
      if (receiverToken == null || receiverToken.isEmpty) {
        return const PushReadinessResult(
          ready: false,
          reason: 'Recipient has not registered for push notifications yet. '
              'Ask them to open Whoosh once with internet and allow notifications.',
        );
      }

      final dryRun = await SupabaseConfig.client.functions.invoke(
        'send-transfer-fcm',
        body: {
          'dry_run': true,
          'record': {'receiver_id': receiverId},
        },
      );

      final rawData = dryRun.data;
      if (rawData is Map<String, dynamic>) {
        final ready = rawData['ready'] == true;
        if (!ready) {
          final reason = (rawData['reason'] as String?)?.trim();
          return PushReadinessResult(
            ready: false,
            reason: reason?.isNotEmpty == true
                ? reason
                : 'Push delivery service is not ready.',
          );
        }
        return const PushReadinessResult(ready: true);
      }

      return const PushReadinessResult(
        ready: false,
        reason: 'Push delivery health check returned an unexpected response.',
      );
    } on FunctionException catch (e) {
      final details = (e.details ?? '').toString();
      final isOldFunctionContract = e.status == 400 &&
          details.toLowerCase().contains('missing transfer record');
      if (isOldFunctionContract) {
        return const PushReadinessResult(
          ready: false,
          reason: 'Push delivery function is outdated. Redeploy '
              '`send-transfer-fcm` with dry-run support, then tap Refresh.',
        );
      }
      return PushReadinessResult(
        ready: false,
        reason: 'Push delivery check failed: '
            '${e.toString().replaceAll('Exception: ', '')}',
      );
    } catch (e) {
      return PushReadinessResult(
        ready: false,
        reason: 'Push delivery check failed: '
            '${e.toString().replaceAll('Exception: ', '')}',
      );
    }
  }

  static List<FileUploadProgress> _updateState(
    List<FileUploadProgress> states,
    int index,
    FileUploadProgress newState,
  ) {
    final updated = List<FileUploadProgress>.from(states);
    updated[index] = newState;
    return updated;
  }

  // ── Incoming transfers (with pagination + TTL filtering) ────────────────

  static Future<List<Map<String, dynamic>>> getIncomingTransfers(
    String userId, {
    int page = 0,
  }) async {
    await SupabaseConfig.ensureValidSession();
    final offset = page * AppConstants.transfersPageSize;

    final result = await SupabaseConfig.client
        .from('transfers')
        .select('*, sender:users!transfers_sender_id_fkey(short_code)')
        .eq('receiver_id', userId)
        .order('created_at', ascending: false)
        .range(offset, offset + AppConstants.transfersPageSize - 1);

    final transfers = List<Map<String, dynamic>>.from(result);

    // Client-side TTL enforcement: mark expired transfers
    final ttlCutoff = DateTime.now()
        .toUtc()
        .subtract(Duration(hours: AppConstants.transferTtlHours));

    return transfers.map((t) {
      final createdAt = DateTime.tryParse(t['created_at'] ?? '');
      if (createdAt != null && createdAt.isBefore(ttlCutoff)) {
        return {...t, 'status': 'expired'};
      }
      return t;
    }).toList();
  }

  // ── Sent transfers (history) ───────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> getSentTransfers(
    String userId, {
    int page = 0,
  }) async {
    await SupabaseConfig.ensureValidSession();
    final offset = page * AppConstants.transfersPageSize;

    final result = await SupabaseConfig.client
        .from('transfers')
        .select('*, receiver:users!transfers_receiver_id_fkey(short_code)')
        .eq('sender_id', userId)
        .order('created_at', ascending: false)
        .range(offset, offset + AppConstants.transfersPageSize - 1);

    return List<Map<String, dynamic>>.from(result);
  }

  static Future<List<Map<String, dynamic>>> getTransferFiles(
    String transferId,
  ) async {
    await SupabaseConfig.ensureValidSession();
    final result = await SupabaseConfig.client
        .from('transfer_files')
        .select()
        .eq('transfer_id', transferId)
        .order('created_at');

    return List<Map<String, dynamic>>.from(result);
  }

  /// Single transfer row for the authenticated receiver (RLS-enforced).
  static Future<Map<String, dynamic>?> getTransferForReceiver({
    required String transferId,
    required String receiverId,
  }) async {
    await SupabaseConfig.ensureValidSession();
    final row = await SupabaseConfig.client
        .from('transfers')
        .select()
        .eq('id', transferId)
        .eq('receiver_id', receiverId)
        .maybeSingle();
    return row == null ? null : Map<String, dynamic>.from(row);
  }

  // ── Streaming download (constant memory, collision-safe) ───────────────

  static Future<File> downloadToFile({
    required String storagePath,
    required String fileName,
    required void Function(int received, int total) onProgress,
    TransferCancellationToken? cancellationToken,
  }) async {
    await SupabaseConfig.ensureValidSession();
    final url = await SupabaseConfig.client.storage
        .from('transfers')
        .createSignedUrl(storagePath, 3600);

    final httpClient = HttpClient();
    IOSink? sink;
    final tempDir = await getTemporaryDirectory();
    // Prefix with random to avoid collisions when multiple files have the same name
    final uniquePrefix =
        '${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(99999)}';
    final file =
        File('${tempDir.path}/${uniquePrefix}_${sanitizeFileName(fileName)}');

    const maxAttempts = 3;
    var lastError = 'Download failed';

    try {
      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        if (cancellationToken?.isCancelled == true) {
          if (await file.exists()) {
            await file.delete();
          }
          throw TransferCancelledException();
        }

        final existingBytes = await file.exists() ? await file.length() : 0;
        HttpClientResponse? response;
        try {
          final request = await httpClient.getUrl(Uri.parse(url));
          if (existingBytes > 0) {
            request.headers
                .set(HttpHeaders.rangeHeader, 'bytes=$existingBytes-');
          }
          response = await request.close();

          if (response.statusCode < 200 || response.statusCode >= 300) {
            throw HttpException('HTTP ${response.statusCode}');
          }

          // If server ignored range and returned full content, restart cleanly.
          final appendMode = existingBytes > 0 &&
              response.statusCode == HttpStatus.partialContent;
          if (!appendMode && existingBytes > 0) {
            await file.writeAsBytes(const <int>[], flush: true);
          }

          sink = file.openWrite(
              mode: appendMode ? FileMode.append : FileMode.write);
          var receivedBytes = appendMode ? existingBytes : 0;

          // Prefer content-range total for resumed downloads.
          int totalBytes = -1;
          final contentRange =
              response.headers.value(HttpHeaders.contentRangeHeader);
          if (contentRange != null) {
            final match =
                RegExp(r'bytes\s+\d+-\d+/(\d+)').firstMatch(contentRange);
            if (match != null) {
              totalBytes = int.tryParse(match.group(1) ?? '') ?? -1;
            }
          }
          if (totalBytes <= 0 && response.contentLength > 0) {
            totalBytes = appendMode
                ? existingBytes + response.contentLength
                : response.contentLength;
          }

          await for (final chunk in response) {
            if (cancellationToken?.isCancelled == true) {
              await sink?.close();
              sink = null;
              if (await file.exists()) {
                await file.delete();
              }
              throw TransferCancelledException();
            }

            sink!.add(chunk);
            receivedBytes += chunk.length;
            final safeTotal = totalBytes > 0 ? totalBytes : receivedBytes;
            onProgress(receivedBytes, safeTotal);
          }

          await sink?.close();
          sink = null;
          return file;
        } catch (e) {
          await sink?.close();
          sink = null;
          lastError = e.toString().replaceAll('Exception: ', '');

          if (cancellationToken?.isCancelled == true) {
            if (await file.exists()) {
              await file.delete();
            }
            throw TransferCancelledException();
          }

          final isLastAttempt = attempt >= maxAttempts;
          if (isLastAttempt) break;

          await Future.delayed(Duration(seconds: attempt * 2));
        }
      }

      if (await file.exists()) {
        await file.delete();
      }
      throw Exception(
          'Download failed after $maxAttempts attempts: $lastError');
    } finally {
      await sink?.close();
      httpClient.close();
    }
  }

  /// Verify a downloaded file's SHA-256 against the stored hash.
  static Future<bool> verifySha256(File file, String? expectedHash) async {
    if (expectedHash == null || expectedHash.isEmpty) return true;
    final actualHash = await computeSha256(file);
    return actualHash == expectedHash;
  }

  /// Convenience: get a signed URL for browser/external download.
  static Future<String> getDownloadUrl(String storagePath) async {
    await SupabaseConfig.ensureValidSession();
    return await SupabaseConfig.client.storage
        .from('transfers')
        .createSignedUrl(storagePath, 3600);
  }

  // ── Supabase Realtime ────────────────────────────────────────────────────

  /// Subscribe to incoming transfers via Postgres CDC.
  /// Listens for both INSERT (new transfer created) and UPDATE (status changed
  /// to completed) so the receiver is notified when files are actually ready.
  static RealtimeChannel? subscribeToIncoming({
    required String userId,
    required void Function(
      Map<String, dynamic> newRecord,
      PostgresChangeEvent event,
    ) onTransferChange,
  }) {
    try {
      final channel = SupabaseConfig.client.channel('incoming-$userId');

      // Notify on new transfer creation
      channel.onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'transfers',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'receiver_id',
          value: userId,
        ),
        callback: (PostgresChangePayload payload) {
          onTransferChange(
            Map<String, dynamic>.from(payload.newRecord),
            PostgresChangeEvent.insert,
          );
        },
      );

      // Also notify when transfer status changes (e.g. pending → completed)
      // so the receiver refreshes and sees files are ready to download
      channel.onPostgresChanges(
        event: PostgresChangeEvent.update,
        schema: 'public',
        table: 'transfers',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'receiver_id',
          value: userId,
        ),
        callback: (PostgresChangePayload payload) {
          onTransferChange(
            Map<String, dynamic>.from(payload.newRecord),
            PostgresChangeEvent.update,
          );
        },
      );

      channel.subscribe();
      return channel;
    } catch (_) {
      return null;
    }
  }

  /// Live updates for one transfer: sender upload snapshots on `transfers` and
  /// new rows on `transfer_files` as each file is committed.
  static RealtimeChannel? subscribeToTransferDetail({
    required String transferId,
    required String receiverId,
    required void Function(Map<String, dynamic> transferRow) onTransferRow,
    required void Function(Map<String, dynamic> fileRow) onTransferFileInserted,
  }) {
    try {
      final channel = SupabaseConfig.client.channel('xfer-detail-$transferId');

      channel.onPostgresChanges(
        event: PostgresChangeEvent.update,
        schema: 'public',
        table: 'transfers',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'id',
          value: transferId,
        ),
        callback: (PostgresChangePayload payload) {
          final row = Map<String, dynamic>.from(payload.newRecord);
          if ((row['receiver_id'] ?? '').toString() == receiverId) {
            onTransferRow(row);
          }
        },
      );

      channel.onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'transfer_files',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'transfer_id',
          value: transferId,
        ),
        callback: (PostgresChangePayload payload) {
          onTransferFileInserted(
            Map<String, dynamic>.from(payload.newRecord),
          );
        },
      );

      channel.subscribe();
      return channel;
    } catch (_) {
      return null;
    }
  }

  static Future<void> unsubscribe(RealtimeChannel channel) async {
    await SupabaseConfig.client.removeChannel(channel);
  }
}
