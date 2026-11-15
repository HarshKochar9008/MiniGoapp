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

import '../../core/analytics/analytics.dart';
import '../../core/constants.dart';
import '../../core/crypto/e2e_crypto.dart';
import '../../core/network/network_errors.dart';
import '../../core/offline/pending_backend_jobs.dart';
import '../../core/security/app_security.dart';
import '../../core/supabase_config.dart';
import '../../core/utils/local_platform_file.dart';
import '../../core/utils/safe_file_name.dart';
import '../identity/identity_service.dart';
import 'r2_storage.dart';
import 'transfer_status.dart';

export 'transfer_status.dart';

// ── Models ───────────────────────────────────────────────────────────────────

enum FileUploadStatus { pending, hashing, uploading, completed, failed }

/// Outcome of checking a downloaded file against the sender's recorded
/// SHA-256. [noHashRecorded] is deliberately distinct from [verified]: a file
/// nobody can check is not a file that passed.
enum IntegrityCheck { verified, mismatch, noHashRecorded }

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

  /// The run didn't finish, and its saved job was kept: sending the same
  /// files again (or the Send screen's resume prompt) continues this
  /// transfer. False when finished, or when every undelivered file is gone
  /// from the device.
  final bool canResume;

  const TransferResult({
    required this.success,
    required this.completedFiles,
    required this.totalFiles,
    required this.fileStates,
    this.canResume = false,
  });
}

/// One file of a transfer's whole set, as one send run sees it.
class _PlannedFile {
  final String name;
  final int size;

  /// Position in the transfer's original file list; names the storage object.
  /// Null only for a file with no path at all, which can't be uploaded.
  final int? slot;

  /// The file on this device, or null when it is no longer selected/present.
  final PlatformFile? local;

  /// Where the saved job last saw this file (resume entries only).
  final String? savedPath;

  const _PlannedFile({
    required this.name,
    required this.size,
    required this.slot,
    required this.local,
    this.savedPath,
  });

  String storagePath(String transferId) =>
      '$transferId/${slot}_${TransferService.sanitizeFileName(name)}';
}

class PendingUploadJob {
  final String senderId;
  final String receiverId;
  final String? receiverCode;

  /// Recipient's X25519 public key at validation time; persisted so a resumed
  /// send stays end-to-end encrypted instead of silently uploading plaintext.
  final String? receiverPublicKey;

  /// Server `transfers.id` for this interrupted send; persisted so resume never
  /// creates a second row for the same pending job.
  final String? transferId;

  /// Set when the send went through a room. Persisted so a resume that has
  /// to create a fresh row keeps it a room transfer (the server checks the
  /// room and derives the name; the client value only selects it).
  final String? roomId;
  final String? roomName;
  final List<PendingUploadFile> files;
  final DateTime createdAt;

  const PendingUploadJob({
    required this.senderId,
    required this.receiverId,
    required this.files,
    required this.createdAt,
    this.receiverCode,
    this.receiverPublicKey,
    this.transferId,
    this.roomId,
    this.roomName,
  });

  List<PlatformFile> toPlatformFiles() {
    return files
        .map(
          (f) => LocalPlatformFile(
            name: f.name,
            path: f.path,
            size: f.size,
          ),
        )
        .toList();
  }

  Map<String, dynamic> toJson() {
    final tid = transferId?.trim();
    final key = receiverPublicKey?.trim();
    final rid = roomId?.trim();
    return {
      'sender_id': senderId,
      'receiver_id': receiverId,
      'receiver_code': receiverCode,
      if (key != null && key.isNotEmpty) 'receiver_public_key': key,
      if (tid != null && tid.isNotEmpty) 'transfer_id': tid,
      if (rid != null && rid.isNotEmpty) 'room_id': rid,
      if (rid != null && rid.isNotEmpty && roomName != null)
        'room_name': roomName,
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
    final keyRaw = (json['receiver_public_key']?.toString() ?? '').trim();
    final roomRaw = (json['room_id']?.toString() ?? '').trim();
    final roomNameRaw = json['room_name']?.toString();

    return PendingUploadJob(
      senderId: senderId,
      receiverId: receiverId,
      receiverCode: (json['receiver_code'] as String?)?.trim(),
      receiverPublicKey: keyRaw.isNotEmpty ? keyRaw : null,
      transferId: transferId,
      roomId: roomRaw.isNotEmpty ? roomRaw : null,
      roomName: roomRaw.isNotEmpty ? roomNameRaw : null,
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
    final parsedSize = size is int ? size : int.tryParse('$size');
    // 0 is a real size: dropping empty files shifted every later file's index
    // and broke the index-keyed resume match (re-uploads, duplicate rows).
    if (name.isEmpty || path.isEmpty || parsedSize == null || parsedSize < 0) {
      return null;
    }
    return PendingUploadFile(name: name, path: path, size: parsedSize);
  }
}

// ── Exceptions ───────────────────────────────────────────────────────────────

class FileTooLargeException implements Exception, NamesUserFile {
  final String fileName;
  final int size;
  FileTooLargeException(this.fileName, this.size);

  @override
  String get logDescription =>
      'File too large (${(size / 1024 / 1024).toStringAsFixed(0)} MB).';

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

class IntegrityException implements Exception, NamesUserFile {
  final String fileName;
  IntegrityException(this.fileName);

  @override
  String get logDescription => 'Integrity check failed.';

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

/// The uploaded bytes are ciphertext but the server schema cannot store the
/// encryption metadata; committing the row anyway would hand the receiver
/// undecryptable data. Not retryable.
class EncryptedSchemaUnsupportedException implements Exception {
  @override
  String toString() =>
      'The server does not support encrypted transfers yet. Please update and try again.';
}

/// The recipient published no X25519 public key, so their files can only be
/// uploaded as plaintext. Sending is refused unless the caller explicitly opts
/// in via `allowUnencrypted: true`, so the end-to-end guarantee can never be
/// dropped silently — the caller has to have told the user first.
class RecipientNotEncryptableException implements Exception {
  @override
  String toString() =>
      'This recipient has not published an encryption key, so these files '
      'cannot be end-to-end encrypted.';
}

/// The server will not take more files for this transfer: it was completed or
/// has expired (a room transfer expires with its room, which can be as soon
/// as 30 minutes). Retrying cannot help, so the whole send stops.
class TransferNotAcceptingUploadsException implements Exception {
  /// True when the transfer is known to have expired (vs. completed).
  final bool expired;
  const TransferNotAcceptingUploadsException({this.expired = false});

  @override
  String toString() => expired
      ? 'This transfer expired before all files were sent.'
      : 'This transfer is already closed and cannot take more files.';
}

/// The transfer has expired, so its files can no longer be downloaded.
/// Raised without retrying: the answer will not change.
class TransferExpiredException implements Exception {
  const TransferExpiredException();

  @override
  String toString() => 'This transfer has expired. Its files are no longer '
      'available.';
}

/// The stored object is bigger than any file MiniGo sends. The size shown to
/// the receiver is whatever the sender declared, so the real byte count is
/// capped here. Raised without retrying: the object will not shrink.
class DownloadTooLargeException implements Exception {
  const DownloadTooLargeException();

  @override
  String toString() =>
      'This file is larger than MiniGo allows, so the download was stopped.';
}

/// A second sendFiles started while one is in flight; they would fight over
/// the single persisted pending-job slot and mark each other failed.
class ConcurrentTransferException implements Exception {
  @override
  String toString() =>
      'Another transfer is already in progress. Wait for it to finish first.';
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

/// Force-closes an [HttpClient] when its transfer is cancelled or stops moving
/// bytes. Without it, a socket that silently stops acknowledging (Wi-Fi drop
/// mid-transfer) blocks `addStream` / the response stream until the OS gives
/// up — many minutes — and the cancel token is never even checked, because
/// the only checks run when the next chunk flows.
class _HttpWatchdog {
  _HttpWatchdog(this._client, this._token) {
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _check());
  }

  static const stallTimeout = Duration(seconds: 60);

  final HttpClient _client;
  final TransferCancellationToken? _token;
  late final Timer _timer;
  DateTime _lastActivity = DateTime.now();
  bool _cancelled = false;
  bool _stalled = false;

  /// Call whenever bytes move.
  void touch() => _lastActivity = DateTime.now();

  void _check() {
    if (_token?.isCancelled == true) {
      _cancelled = true;
    } else if (DateTime.now().difference(_lastActivity) > stallTimeout) {
      _stalled = true;
    } else {
      return;
    }
    _timer.cancel();
    _client.close(force: true);
  }

  void stop() => _timer.cancel();

  /// What a forced close really meant, for rethrowing in place of the raw
  /// socket error it caused; null when the watchdog didn't fire.
  Exception? get abortReason {
    if (_cancelled) return TransferCancelledException();
    if (_stalled) {
      return const SocketException('Connection stalled: no data for 60 s');
    }
    return null;
  }
}

class TransferCancelledException implements Exception {
  final String message;
  TransferCancelledException([this.message = 'Transfer cancelled by user.']);
  @override
  String toString() => message;
}

// ── Resume / status-write outcomes ───────────────────────────────────────────

enum _ResumeVerdict {
  /// Keep uploading into the saved transfer.
  resumable,

  /// The saved transfer already finished: nothing left to upload.
  alreadyComplete,

  /// Missing, not ours, or expired: start a new transfer, leave this row be.
  gone,
}

class _ResumeSnapshot {
  final _ResumeVerdict verdict;
  final TransferStatus? status;
  final Map<String, Map<String, dynamic>> rowsByPath;

  const _ResumeSnapshot(
    this.verdict, {
    this.status,
    this.rowsByPath = const {},
  });
}

enum _StatusWrite {
  /// The row moved to the new status.
  applied,

  /// The row is in a protected status; nothing changed.
  refused,

  /// The write itself failed (offline, trigger, schema).
  failed,
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
  String? _lastStatusSig;
  DateTime? _lastAt;

  static const _minInterval = Duration(milliseconds: 280);

  void notify(List<FileUploadProgress> states) {
    final sig = states
        .map((e) => '${e.status.name}:${(e.progress * 100).round()}')
        .join('|');
    if (sig == _lastSig) return;
    // Every write is a realtime UPDATE delivered to the receiver. Status
    // changes go out at once; percentage ticks at most once per interval.
    final statusSig = states.map((e) => e.status.name).join('|');
    final now = DateTime.now();
    if (statusSig == _lastStatusSig &&
        _lastAt != null &&
        now.difference(_lastAt!) < _minInterval) {
      return;
    }
    _lastSig = sig;
    _lastStatusSig = statusSig;
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

  /// Most bytes a download may write: the send limit plus room for the
  /// cipher's per-chunk tags.
  static const _maxDownloadBytes =
      AppConstants.maxFileSizeBytes + 4 * 1024 * 1024;

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
        status = FileUploadStatus.values
            .byName((m['status'] ?? 'pending').toString());
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
  /// Delegates to the shared [safeFileName] primitive so the upload path and
  /// the receiver's save path can never drift apart.
  static String sanitizeFileName(String name) => safeFileName(name);

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
    if (R2Storage.enabled) {
      final slash = storagePath.indexOf('/');
      String? signedUrl;
      if (slash > 0) {
        try {
          signedUrl = await R2Storage.getUploadUrl(
            transferId: storagePath.substring(0, slash),
            fileName: storagePath.substring(slash + 1),
          );
        } on R2SigningException catch (e) {
          // R2 not configured/deployed yet, or unreachable — use the
          // Supabase path instead.
          if (kDebugMode) debugPrint('R2 upload signing unavailable: $e');
        } on R2RefusedException catch (e) {
          // The signer said no. Never route around that through Supabase
          // Storage: 409 means the transfer is completed or expired, which
          // no retry fixes; 401/403 fail this attempt and retry normally.
          if (e.notAcceptingUploads) {
            throw const TransferNotAcceptingUploadsException();
          }
          rethrow;
        }
      }
      if (signedUrl != null) {
        await _r2Upload(
          url: signedUrl,
          file: file,
          contentType: contentType,
          onProgress: onProgress,
          cancellationToken: cancellationToken,
        );
        return;
      }
    }

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
        // tus_client_dart 2.5.0's own retry is broken: _getData() advances the
        // offset before the PATCH is sent, and a retry re-sends the stale
        // Upload-Offset header with the *next* chunk's bytes, so every retry
        // fails (409) — and the stream's onDone resets the retry counter, so
        // it never gives up and ignores cancel. Fail fast instead: sendFiles'
        // own retry loop re-runs this with a fresh client and session token,
        // and x-upsert makes the restart safe.
        retries: 0,
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

  // ── Cloudflare R2: streaming PUT to a presigned URL (constant memory) ────────

  static Future<void> _r2Upload({
    required String url,
    required File file,
    required String contentType,
    void Function(int sent, int total)? onProgress,
    TransferCancellationToken? cancellationToken,
  }) async {
    final fileLength = await file.length();
    final httpClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    final watchdog = _HttpWatchdog(httpClient, cancellationToken);
    try {
      final request = await httpClient.putUrl(Uri.parse(url));
      request.headers.set('Content-Type', contentType);
      request.contentLength = fileLength;

      var bytesSent = 0;
      final progressStream = file.openRead().map((chunk) {
        if (cancellationToken?.isCancelled == true) {
          throw TransferCancelledException();
        }
        watchdog.touch();
        bytesSent += chunk.length;
        onProgress?.call(bytesSent, fileLength);
        return chunk;
      });

      await request.addStream(progressStream);
      watchdog.touch();
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode >= 400) {
        throw StorageUploadException(response.statusCode, body);
      }
    } catch (_) {
      final reason = watchdog.abortReason;
      if (reason != null) throw reason;
      rethrow;
    } finally {
      watchdog.stop();
      httpClient.close();
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

    final httpClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    final watchdog = _HttpWatchdog(httpClient, cancellationToken);
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
        watchdog.touch();
        bytesSent += chunk.length;
        onProgress?.call(bytesSent, fileLength);
        return chunk;
      });

      await request.addStream(progressStream);
      watchdog.touch();
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode >= 400) {
        throw StorageUploadException(response.statusCode, body);
      }
    } catch (_) {
      final reason = watchdog.abortReason;
      if (reason != null) throw reason;
      rethrow;
    } finally {
      watchdog.stop();
      httpClient.close();
    }
  }

  static String _receiverCodeKey(String? code) {
    final t = (code ?? '').trim();
    if (t.isEmpty) return '';
    return AppConstants.normalizeShortCode(t);
  }

  /// Whether [validFiles] continues [pending], and if so where each file
  /// sits in it. Returns null when this is a different send; otherwise
  /// `slots[k]` is the index in `pending.files` of `validFiles[k]`.
  ///
  /// A resume may carry a SUBSET of the saved files, in any order — files
  /// removed from the device since, or dropped from the selection. The slot,
  /// not the position in the new selection, names the file's storage object
  /// (`<transferId>/<slot>_<name>`), so a delivered file keeps matching its
  /// `transfer_files` row and is never uploaded twice. A selection with any
  /// file the saved job doesn't have is a different send.
  ///
  /// Pure; unit-tested.
  @visibleForTesting
  static List<int>? matchResumeSlots(
    PendingUploadJob? pending, {
    required String receiverId,
    required String? receiverCode,
    required List<PendingUploadFile> validFiles,
    String? roomId,
  }) {
    if (pending == null || validFiles.isEmpty) return null;
    if (pending.receiverId != receiverId) return null;
    // A room send never resumes some other send's transfer. A send with no
    // room (the Send screen's resume) may continue a room job: the saved job
    // is how it learns the room.
    if (roomId != null && roomId != pending.roomId) return null;
    if (_receiverCodeKey(pending.receiverCode) !=
        _receiverCodeKey(receiverCode)) {
      return null;
    }
    final used = List<bool>.filled(pending.files.length, false);
    final slots = <int>[];
    for (final b in validFiles) {
      var slot = -1;
      for (var j = 0; j < pending.files.length; j++) {
        final a = pending.files[j];
        if (!used[j] &&
            a.name == b.name &&
            a.size == b.size &&
            a.path == b.path) {
          slot = j;
          break;
        }
      }
      if (slot < 0) return null;
      used[slot] = true;
      slots.add(slot);
    }
    return slots;
  }

  /// What an interrupted send's transfer row allows. Network errors propagate:
  /// "couldn't check" must not be mistaken for any of these.
  ///
  /// [_ResumeVerdict.resumable] carries the rows already in `transfer_files`,
  /// keyed by `storage_path` — not by `file_name`: two names can sanitize to
  /// the same one, and the second file would then look already uploaded.
  static Future<_ResumeSnapshot> _loadTransferResumeSnapshot({
    required SupabaseClient client,
    required String transferId,
    required String senderId,
    required String receiverId,
  }) async {
    final transfer = await client
        .from('transfers')
        .select('sender_id,receiver_id,status,created_at')
        .eq('id', transferId)
        .maybeSingle();
    if (transfer == null ||
        transfer['sender_id']?.toString() != senderId ||
        transfer['receiver_id']?.toString() != receiverId) {
      return const _ResumeSnapshot(_ResumeVerdict.gone);
    }
    final status =
        TransferStatus.effectiveOf(Map<String, dynamic>.from(transfer));
    if (status == TransferStatus.expired) {
      return const _ResumeSnapshot(_ResumeVerdict.gone);
    }

    final rows = await client
        .from('transfer_files')
        .select()
        .eq('transfer_id', transferId);
    final out = <String, Map<String, dynamic>>{};
    for (final raw in rows) {
      final m = Map<String, dynamic>.from(raw);
      final path = (m['storage_path'] ?? '').toString();
      if (path.isNotEmpty) out[path] = m;
    }
    return _ResumeSnapshot(
      status == TransferStatus.completed
          ? _ResumeVerdict.alreadyComplete
          : _ResumeVerdict.resumable,
      status: status,
      rowsByPath: out,
    );
  }

  /// Settles a transfer whose saved send is being dropped (discarded, or
  /// replaced by a different send). It becomes `partial` when the receiver
  /// already has files from it, else `failed` — and only ever from a state
  /// [TransferStatus.mayAbandon] allows, so a completed, partial or expired
  /// transfer keeps its outcome. If the files can't be counted (offline), the
  /// row is left alone: an honest `pending` until the TTL beats a false
  /// `failed`.
  static Future<void> _settleAbandonedTransfer(
    SupabaseClient client,
    String transferId,
  ) async {
    bool hasFiles;
    try {
      final rows = await client
          .from('transfer_files')
          .select('id')
          .eq('transfer_id', transferId)
          .limit(1);
      hasFiles = rows.isNotEmpty;
    } catch (_) {
      return;
    }
    await _writeStatus(
      client,
      transferId,
      hasFiles ? TransferStatus.partial : TransferStatus.failed,
      protect: {
        for (final s in TransferStatus.values)
          if (!s.mayAbandon) s,
      },
    );
  }

  /// Room refusals raised by the `transfers_check_room` insert trigger. The
  /// saved job describes a send that can never go through.
  static bool _isRoomRefusal(Object e) {
    final raw = e.toString();
    return raw.contains('room_expired') ||
        raw.contains('room_share_denied') ||
        raw.contains('room_recipient_not_member');
  }

  // ── Send files ───────────────────────────────────────────────────────────

  /// True while a [sendFiles] call is running. Two concurrent sends would
  /// fight over the single persisted pending-job slot and mark each other's
  /// in-flight transfer as failed, so the second caller is rejected instead.
  static bool _sendInFlight = false;

  /// Whether a send is uploading right now. Local cleanup checks this first —
  /// deleting its temp copies or resume state mid-upload would fail the send.
  static bool get isSendInFlight => _sendInFlight;

  static Future<TransferResult> sendFiles({
    required String senderId,
    required String receiverId,
    required List<PlatformFile> files,
    required void Function(List<FileUploadProgress> states) onProgress,
    TransferCancellationToken? cancellationToken,
    String? receiverCode,
    String? roomId,
    String? roomName,

    /// Recipient's base64url X25519 public key. When present, every file is
    /// end-to-end encrypted before upload so the server only stores ciphertext.
    String? recipientPublicKey,

    /// Set only after the user has been told, in the UI, that this transfer
    /// will not be end-to-end encrypted. Without it a missing
    /// [recipientPublicKey] is a hard error rather than a quiet downgrade to a
    /// plaintext upload.
    bool allowUnencrypted = false,
  }) async {
    AppSecurity.instance.ensureTransfersAllowed();
    final hasKey =
        recipientPublicKey != null && recipientPublicKey.trim().isNotEmpty;
    if (!hasKey && !allowUnencrypted) {
      throw RecipientNotEncryptableException();
    }

    if (_sendInFlight) throw ConcurrentTransferException();
    _sendInFlight = true;
    try {
      return await _sendFilesInner(
        senderId: senderId,
        receiverId: receiverId,
        files: files,
        onProgress: onProgress,
        cancellationToken: cancellationToken,
        receiverCode: receiverCode,
        roomId: roomId,
        roomName: roomName,
        recipientPublicKey: recipientPublicKey,
      );
    } finally {
      _sendInFlight = false;
    }
  }

  static Future<TransferResult> _sendFilesInner({
    required String senderId,
    required String receiverId,
    required List<PlatformFile> files,
    required void Function(List<FileUploadProgress> states) onProgress,
    TransferCancellationToken? cancellationToken,
    String? receiverCode,
    String? roomId,
    String? roomName,
    String? recipientPublicKey,
  }) async {
    // The size the picker reported, else read from disk. Resolved once so the
    // limit check, progress, the resume match and the stored file_size agree.
    // An unreadable file counts as 0 here; the upload loop fails it below.
    final sizes = <int>[];
    for (final file in files) {
      final size = await file.length() ?? 0;
      if (size > AppConstants.maxFileSizeBytes) {
        throw FileTooLargeException(file.name, size);
      }
      sizes.add(size);
    }
    if (files.length > AppConstants.maxFilesPerTransfer) {
      throw TooManyFilesException(files.length);
    }
    final validFiles = [
      for (var i = 0; i < files.length; i++)
        if (files[i].path != null)
          PendingUploadFile(
            name: files[i].name,
            path: files[i].path!,
            size: sizes[i],
          ),
    ];

    final validLocal = [
      for (final f in files)
        if (f.path != null) f,
    ];

    final existingPending = await getPendingUploadJob(senderId: senderId);
    final slots = matchResumeSlots(
      existingPending,
      receiverId: receiverId,
      receiverCode: receiverCode,
      validFiles: validFiles,
      roomId: roomId,
    );
    final matches = slots != null;

    // One entry per file of the transfer's WHOLE set. Continuing a saved
    // transfer, that is the saved job's list — possibly more than was
    // selected this time (files since removed from the device): those
    // entries have no local file, and still count towards the final status.
    // The slot names the storage object, so it must be the file's position
    // in the ORIGINAL list. A new transfer is just the current selection.
    List<_PlannedFile> freshPlan() {
      var slot = 0;
      return [
        for (var i = 0; i < files.length; i++)
          _PlannedFile(
            name: files[i].name,
            size: sizes[i],
            slot: files[i].path != null ? slot++ : null,
            local: files[i],
          ),
      ];
    }

    List<_PlannedFile> resumePlan() {
      final saved = existingPending!.files;
      final localBySlot = <int, PlatformFile>{
        for (var k = 0; k < slots!.length; k++) slots[k]: validLocal[k],
      };
      return [
        for (var j = 0; j < saved.length; j++)
          _PlannedFile(
            name: saved[j].name,
            size: saved[j].size,
            slot: j,
            local: localBySlot[j],
            savedPath: saved[j].path,
          ),
      ];
    }

    // Provisional until the saved transfer is checked below: if it can't be
    // continued, a new transfer carries only the current selection.
    var plan = matches ? resumePlan() : freshPlan();
    // The saved job keeps the ORIGINAL list, so a later resume maps to the
    // same slots.
    var jobFiles = matches ? existingPending!.files : validFiles;

    // A resume started from the plain Send screen doesn't know the send went
    // through a room; the saved job does.
    final effectiveRoomId =
        roomId ?? (matches ? existingPending?.roomId : null);
    final effectiveRoomName = roomId != null
        ? roomName
        : (matches ? existingPending?.roomName : null);

    final pendingTid = existingPending?.transferId?.trim();
    final orphanTid = (!matches && pendingTid != null && pendingTid.isNotEmpty)
        ? pendingTid
        : null;

    await SupabaseConfig.ensureValidSession();
    final client = SupabaseConfig.client;

    // Sender's own short code, denormalized onto the transfer so the receiver
    // can display it without reading the sender's (now private) users row.
    final senderCode = IdentityService.identityNotifier.value?.shortCode;

    if (orphanTid != null) {
      // A different send replaces the saved one (another recipient, or a
      // selection with files the saved job never had). Settle the old
      // transfer — partial when the receiver already has files from it,
      // never "failed" over them.
      await _settleAbandonedTransfer(client, orphanTid);
    }

    final createdAtBase = (matches && existingPending != null)
        ? existingPending.createdAt
        : DateTime.now().toUtc();
    final earlyTid = matches && pendingTid != null && pendingTid.isNotEmpty
        ? pendingTid
        : null;

    Future<void> saveJob(String? tid) => _storePendingUploadJob(
          senderId: senderId,
          receiverId: receiverId,
          receiverCode: receiverCode,
          receiverPublicKey: recipientPublicKey,
          files: jobFiles,
          transferId: tid,
          createdAt: createdAtBase,
          roomId: effectiveRoomId,
          roomName: effectiveRoomName,
        );

    await saveJob(earlyTid);

    Future<String> insertNewTransfer() async {
      try {
        final transfer = await _insertTransferRow({
          'sender_id': senderId,
          'receiver_id': receiverId,
          'status': TransferStatus.pending.dbValue,
          if (senderCode != null) 'sender_code': senderCode,
          if (receiverCode != null) 'receiver_code': receiverCode,
          if (effectiveRoomId != null) 'room_id': effectiveRoomId,
          if (effectiveRoomName != null) 'room_name': effectiveRoomName,
        });
        return transfer['id'] as String;
      } catch (e) {
        // The room refused the row; the saved job can never go through.
        if (_isRoomRefusal(e)) await clearPendingUploadJob();
        rethrow;
      }
    }

    late final String transferId;
    Map<String, Map<String, dynamic>> resumeByStoragePath = {};

    if (earlyTid != null) {
      final snap = await _loadTransferResumeSnapshot(
        client: client,
        transferId: earlyTid,
        senderId: senderId,
        receiverId: receiverId,
      );
      switch (snap.verdict) {
        case _ResumeVerdict.alreadyComplete:
          // It finished before the app could clear the saved job (the final
          // status write and the clear are separated by the push call).
          // Nothing is left to upload, and a second transfer would only
          // duplicate the files at the receiver.
          await clearPendingUploadJob();
          final done = [
            for (final e in plan)
              FileUploadProgress(
                fileName: e.name,
                fileSize: e.size,
                status: FileUploadStatus.completed,
                progress: 1.0,
                sha256: e.slot == null
                    ? null
                    : _rowSha(snap.rowsByPath[e.storagePath(earlyTid)]),
              ),
          ];
          onProgress(done);
          return TransferResult(
            success: true,
            completedFiles: plan.length,
            totalFiles: plan.length,
            fileStates: done,
          );
        case _ResumeVerdict.resumable:
          transferId = earlyTid;
          resumeByStoragePath = snap.rowsByPath;
          // Back to pending, so the receiver shows live progress again rather
          // than the previous run's partial/failed outcome. Conditional: a
          // transfer that was completed or expired meanwhile is left alone.
          if (snap.status?.isSettled ?? false) {
            await _writeStatus(client, transferId, TransferStatus.pending);
          }
        case _ResumeVerdict.gone:
          // Deleted, not ours, or expired: its outcome stands. Start afresh
          // with just what is selected now.
          plan = freshPlan();
          jobFiles = validFiles;
          transferId = await insertNewTransfer();
      }
    } else {
      // No transfer to continue (a job saved before its row existed counts
      // too): the new one is just the current selection.
      plan = freshPlan();
      jobFiles = validFiles;
      transferId = await insertNewTransfer();
    }

    await saveJob(transferId);

    var states = [
      for (final e in plan)
        FileUploadProgress(fileName: e.name, fileSize: e.size),
    ];

    for (var i = 0; i < plan.length; i++) {
      // Same path the upload loop below writes for this file.
      final slot = plan[i].slot;
      if (slot == null) continue;
      final row = resumeByStoragePath[plan[i].storagePath(transferId)];
      if (row != null) {
        states = _updateState(
          states,
          i,
          states[i].copyWith(
            status: FileUploadStatus.completed,
            progress: 1.0,
            sha256: _rowSha(row) ?? states[i].sha256,
          ),
        );
      }
    }

    var completedCount =
        states.where((s) => s.status == FileUploadStatus.completed).length;

    onProgress(states);

    final progressBroadcaster =
        _TransferProgressBroadcaster(client, transferId);
    void report(List<FileUploadProgress> s) {
      onProgress(s);
      progressBroadcaster.notify(s);
    }

    // Whenever a run stops early, delivered files decide partial vs failed:
    // the receiver is never told "failed" about files it can download.
    bool anyDelivered() =>
        states.any((s) => s.status == FileUploadStatus.completed);

    // Files that failed because they are no longer on the device. A run
    // whose only undelivered files are these can't be helped by resuming.
    final missing = <int>{};

    try {
      for (var i = 0; i < plan.length; i++) {
        if (cancellationToken?.isCancelled == true) {
          throw TransferCancelledException();
        }
        // A send under way when a critical threat lands stops before the
        // next file is read or encrypted.
        AppSecurity.instance.ensureTransfersAllowed();

        if (states[i].status == FileUploadStatus.completed) {
          report(states);
          continue;
        }

        final entry = plan[i];
        final filePath = entry.local?.path;

        if (filePath == null || !await File(filePath).exists()) {
          missing.add(i);
          // On a resume, a saved file that is still on disk but wasn't
          // selected was left out on purpose; say so rather than "missing".
          final saved = entry.savedPath;
          final leftOut = entry.local == null &&
              saved != null &&
              await File(saved).exists();
          states = _updateState(
            states,
            i,
            states[i].copyWith(
              status: FileUploadStatus.failed,
              error: leftOut
                  ? 'Left out when this send was resumed'
                  : 'File not accessible on disk',
            ),
          );
          report(states);
          continue;
        }

        final diskFile = File(filePath);
        final safeName = sanitizeFileName(entry.name);
        final mimeType =
            lookupMimeType(entry.name) ?? 'application/octet-stream';
        // Slot prefix keeps paths unique when two files share a name (or
        // sanitize to the same name) — otherwise the upsert upload of the
        // second file overwrites the first object — and stays the same across
        // resumes of a subset, so a delivered file is recognised by its row.
        // Receivers read the path from transfer_files.storage_path.
        final storagePath = entry.storagePath(transferId);

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

        // ── Phase 2: (optional) encrypt, then upload with retry ─────────
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

        // End-to-end encrypt the file bytes when we have the recipient's
        // public key. The server then only ever stores ciphertext.
        File uploadFile = diskFile;
        File? encTemp;
        Map<String, dynamic> encMeta = const {'is_encrypted': false};
        if (recipientPublicKey != null && recipientPublicKey.isNotEmpty) {
          try {
            final fileKey = E2ECrypto.newFileKey();
            encTemp = await _encryptedTempFile(transferId, safeName);
            await E2ECrypto.encryptFile(
              src: diskFile,
              dst: encTemp,
              contentKey: fileKey.contentKey,
              baseNonce: fileKey.baseNonce,
            );
            final sealedKey = await E2ECrypto.sealContentKey(
              contentKey: fileKey.contentKey,
              recipientPublicKeyB64: recipientPublicKey,
            );
            uploadFile = encTemp;
            encMeta = {
              'is_encrypted': true,
              'enc_algo': E2ECrypto.algoTag,
              'enc_wrapped_key': sealedKey,
              'enc_nonce': E2ECrypto.encodeB64(fileKey.baseNonce),
              'enc_chunk_size': E2ECrypto.chunkSize,
            };
          } catch (e) {
            // The recipient has a public key, so silently downgrading to a
            // plaintext upload would break the E2E guarantee. Fail this file.
            if (kDebugMode) debugPrint('Encrypt failed for $safeName: $e');
            try {
              if (encTemp != null && encTemp.existsSync()) {
                await encTemp.delete();
              }
            } catch (_) {}
            states = _updateState(
              states,
              i,
              states[i].copyWith(
                status: FileUploadStatus.failed,
                error: 'Could not encrypt this file for the recipient.',
              ),
            );
            report(states);
            continue;
          }
        }

        var uploaded = false;
        String? lastError;

        try {
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
                file: uploadFile,
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
                'file_size': entry.size,
                'mime_type': mimeType,
                'storage_path': storagePath,
                'sha256_hash': hash,
                ...encMeta,
              });

              uploaded = true;
              break;
            } catch (e) {
              // Stopping for good: cancelled, or the server closed the
              // transfer. Neither improves on a retry.
              if (e is TransferCancelledException ||
                  e is TransferNotAcceptingUploadsException) {
                rethrow;
              }
              lastError = e.toString().replaceAll('Exception: ', '');
              // Schema-level failures are deterministic; retrying re-uploads
              // the whole file for the same result.
              if (e is EncryptedSchemaUnsupportedException) break;
              if (attempt < _maxRetries) {
                await Future.delayed(Duration(seconds: attempt * 2));
              }
            }
          }
        } finally {
          try {
            if (encTemp != null && encTemp.existsSync()) {
              await encTemp.delete();
            }
          } catch (_) {}
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
      final anyDone = anyDelivered();

      await progressBroadcaster.flushFinal(states);
      final write = await _writeStatus(
        client,
        transferId,
        allDone
            ? TransferStatus.completed
            : anyDone
                ? TransferStatus.partial
                : TransferStatus.failed,
      );
      if (write == _StatusWrite.refused &&
          await _isExpiredOnServer(client, transferId)) {
        // Closed under us — typically its room expired mid-send, and the
        // sweep deleted what had arrived. Handled by the clause below.
        throw const TransferNotAcceptingUploadsException(expired: true);
      }
      if (anyDone && write != _StatusWrite.refused) {
        await _triggerIncomingTransferPush(
          transferId: transferId,
          senderId: senderId,
          receiverId: receiverId,
        );
      }

      // The saved job stays while some undelivered file could still go: it
      // holds this transfer's id, so the resume prompt — or sending the same
      // files again — continues THIS transfer, skipping files already
      // delivered, instead of creating a second one that duplicates them at
      // the receiver. When every undelivered file is gone from the device,
      // no resume can help: the transfer stays partial/failed, and the job
      // is cleared rather than nagging forever.
      var canResume = false;
      for (var i = 0; i < states.length; i++) {
        if (states[i].status != FileUploadStatus.completed &&
            !missing.contains(i)) {
          canResume = true;
          break;
        }
      }
      if (!canResume) {
        await clearPendingUploadJob();
      }

      return TransferResult(
        success: allDone,
        completedFiles: completedCount,
        totalFiles: plan.length,
        fileStates: states,
        canResume: canResume,
      );
    } on TransferCancelledException {
      final anyDone = anyDelivered();
      try {
        await progressBroadcaster.flushFinal(states);
      } catch (_) {}
      final write = await _writeStatus(
        client,
        transferId,
        anyDone ? TransferStatus.partial : TransferStatus.failed,
      );
      if (anyDone && write == _StatusWrite.applied) {
        // What arrived before the stop stays downloadable; tell the receiver.
        // Not awaited: the user asked to stop, and the push retries itself.
        unawaited(_triggerIncomingTransferPush(
          transferId: transferId,
          senderId: senderId,
          receiverId: receiverId,
        ));
      }
      // Stopping was deliberate; resuming it on next launch would just nag.
      await clearPendingUploadJob();
      rethrow;
    } on TransferNotAcceptingUploadsException {
      try {
        await progressBroadcaster.flushFinal(states);
      } catch (_) {}
      // The server closed the transfer (completed or expired): a status write
      // would be refused, and the saved job can never go through.
      await clearPendingUploadJob();
      rethrow;
    } catch (e) {
      final anyDone = anyDelivered();
      try {
        await progressBroadcaster.flushFinal(states);
      } catch (_) {}
      final write = await _writeStatus(
        client,
        transferId,
        anyDone ? TransferStatus.partial : TransferStatus.failed,
      );
      if (anyDone && write == _StatusWrite.applied) {
        unawaited(_triggerIncomingTransferPush(
          transferId: transferId,
          senderId: senderId,
          receiverId: receiverId,
        ));
      }
      // The job deliberately survives. Per-file failures — dropped
      // connections and stalls included — are absorbed by the loop above and
      // end on the normal path, which also keeps the job when any file
      // failed. What reaches here stopped the loop itself: a security
      // restriction, a local I/O error, or the session going away. Either
      // way the resume prompt in send_screen offers to continue this transfer.
      rethrow;
    }
  }

  static String? _rowSha(Map<String, dynamic>? row) {
    final sha = row?['sha256_hash']?.toString();
    return (sha != null && sha.isNotEmpty) ? sha : null;
  }

  /// Whether the transfer is (effectively) expired on the server, or gone.
  /// Errors answer false: "couldn't check" is not "expired".
  static Future<bool> _isExpiredOnServer(
    SupabaseClient client,
    String transferId,
  ) async {
    try {
      final row = await client
          .from('transfers')
          .select('status,created_at')
          .eq('id', transferId)
          .maybeSingle();
      if (row == null) return true;
      return TransferStatus.effectiveOf(Map<String, dynamic>.from(row)) ==
          TransferStatus.expired;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _storePendingUploadJob({
    required String senderId,
    required String receiverId,
    required List<PendingUploadFile> files,
    String? receiverCode,
    String? receiverPublicKey,

    /// When null, job is still "in flight" before a `transfers` row exists; used
    /// so a process kill still leaves enough state to offer resume/discards UI.
    String? transferId,
    DateTime? createdAt,
    String? roomId,
    String? roomName,
  }) async {
    if (files.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();

    final tid = transferId?.trim();
    final job = PendingUploadJob(
      senderId: senderId,
      receiverId: receiverId,
      receiverCode: receiverCode,
      receiverPublicKey: receiverPublicKey,
      transferId: (tid != null && tid.isNotEmpty) ? tid : null,
      createdAt: createdAt ?? DateTime.now().toUtc(),
      files: files,
      roomId: roomId,
      roomName: roomName,
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

  /// Clears local pending send state and settles the server transfer so a
  /// discarded job cannot leave a dangling `pending` row: `partial` when the
  /// receiver already has some of its files, else `failed`. A transfer that
  /// already finished (completed, partial, expired) keeps its outcome.
  static Future<void> discardPendingUploadJob({
    required String senderId,
  }) async {
    final job = await getPendingUploadJob(senderId: senderId);
    final tid = job?.transferId?.trim();
    if (tid != null && tid.isNotEmpty) {
      try {
        await SupabaseConfig.ensureValidSession();
        await _settleAbandonedTransfer(SupabaseConfig.client, tid);
      } catch (_) {}
    }
    await clearPendingUploadJob();
  }

  /// The only way this client changes `transfers.status`. A conditional
  /// update: it never overwrites a status in [protect] (default
  /// [TransferStatus.protectedFrom] for [to]), so a final write can't leave
  /// completed or expired, and an abandon can't clobber a real outcome. The
  /// server trigger enforces the same rules; filtering here just means a
  /// refused write is a no-op instead of an exception.
  ///
  /// Legacy schemas where `status` is a Postgres enum missing some labels
  /// answer 22P02 for an unknown value in the filter or in [to]. Those retry
  /// with only the core labels in the filter, then with 'pending' as the
  /// value (the old fallback) — never with 'completed' unless asked.
  ///
  /// Never throws: status is metadata, and an error here used to skip the
  /// pending-job cleanup and replace a cancel with a generic error.
  static Future<_StatusWrite> _writeStatus(
    SupabaseClient client,
    String transferId,
    TransferStatus to, {
    Set<TransferStatus>? protect,
  }) async {
    assert(to != TransferStatus.expired && to != TransferStatus.uploading,
        'expired is written by the server sweep only; uploading is legacy');
    final guard = protect ?? TransferStatus.protectedFrom(to);

    Future<_StatusWrite> attempt(
      TransferStatus value,
      Iterable<TransferStatus> notFrom,
    ) async {
      final rows = await client
          .from('transfers')
          .update({'status': value.dbValue})
          .eq('id', transferId)
          .not('status', 'in', [for (final s in notFrom) s.dbValue])
          .select('id');
      return rows.isEmpty ? _StatusWrite.refused : _StatusWrite.applied;
    }

    bool isEnumMiss(Object e) => e is PostgrestException && e.code == '22P02';

    try {
      return await attempt(to, guard);
    } catch (e) {
      if (!isEnumMiss(e)) return _StatusWrite.failed;
    }
    const core = {TransferStatus.completed, TransferStatus.expired};
    final coreGuard = guard.intersection(core);
    try {
      return await attempt(to, coreGuard);
    } catch (e) {
      if (!isEnumMiss(e)) return _StatusWrite.failed;
    }
    if (to == TransferStatus.pending || to == TransferStatus.completed) {
      return _StatusWrite.failed;
    }
    try {
      return await attempt(TransferStatus.pending, coreGuard);
    } catch (_) {
      return _StatusWrite.failed;
    }
  }

  /// Insert a `transfers` row and return it. Falls back without the
  /// denormalized code columns if a not-yet-migrated schema lacks them.
  static Future<Map<String, dynamic>> _insertTransferRow(
      Map<String, dynamic> data) async {
    try {
      return Map<String, dynamic>.from(await SupabaseConfig.client
          .from('transfers')
          .insert(data)
          .select()
          .single());
    } on PostgrestException catch (e) {
      if (e.code == '42703' || e.code == 'PGRST204') {
        final fallback = Map<String, dynamic>.from(data)
          ..remove('sender_code')
          ..remove('receiver_code');
        return Map<String, dynamic>.from(await SupabaseConfig.client
            .from('transfers')
            .insert(fallback)
            .select()
            .single());
      }
      rethrow;
    }
  }

  /// Temp file that holds the encrypted bytes for one upload.
  static Future<File> _encryptedTempFile(
      String transferId, String safeName) async {
    final tempDir = await getTemporaryDirectory();
    final dir = Directory('${tempDir.path}/enc_out');
    if (!await dir.exists()) await dir.create(recursive: true);
    final unique =
        '${transferId.hashCode}_${DateTime.now().microsecondsSinceEpoch}';
    return File('${dir.path}/${unique}_$safeName.enc');
  }

  /// Insert a transfer_files row.
  /// Falls back without the optional `enc_*` columns when they don't exist:
  ///   - 42703: PostgreSQL undefined_column
  ///   - PGRST204: PostgREST column not found in schema cache
  ///
  /// `sha256_hash` is NOT part of that fallback. Dropping it used to produce a
  /// row the receiver can never integrity-check, which for an unencrypted
  /// transfer means no integrity signal at all — a silent downgrade of the
  /// same shape as sending plaintext to a keyed recipient. The column predates
  /// every migration in this repo, so its absence is a broken schema, not an
  /// old one, and failing loudly is correct.
  static Future<void> _insertTransferFile(Map<String, dynamic> data) async {
    try {
      await SupabaseConfig.client.from('transfer_files').insert(data);
    } on PostgrestException catch (e) {
      if (e.code == '42703' || e.code == 'PGRST204') {
        if (data['is_encrypted'] == true) {
          // The stored bytes are ciphertext; a row without the enc_* metadata
          // would make the receiver save undecryptable garbage.
          throw EncryptedSchemaUnsupportedException();
        }
        // Drop optional columns a not-yet-migrated schema may lack.
        final fallback = Map<String, dynamic>.from(data)
          ..remove('is_encrypted')
          ..remove('enc_algo')
          ..remove('enc_wrapped_key')
          ..remove('enc_nonce')
          ..remove('enc_chunk_size');
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
    // Bounded: the offline drain awaits this with its _running flag set, so a
    // hung socket here blocked every later drain for the session.
    await SupabaseConfig.client.functions.invoke(
      'send-transfer-fcm',
      body: {
        'record': {
          'id': transferId,
          'sender_id': senderId,
          'receiver_id': receiverId,
        },
      },
    ).timeout(const Duration(seconds: 20));
  }

  /// Retries edge invokes that failed with a retryable network error after upload.
  static Future<void> flushPendingTransferPushNotifications() async {
    // A snapshot, not the live queue: a push enqueued while this flush is
    // invoking the edge function must survive it. Only the jobs processed
    // here are removed afterwards, under the queue lock.
    final jobs = await PendingBackendJobs.takeTransferPushSnapshot();
    if (jobs.isEmpty) return;

    final processed = <TransferPushJob>[];
    for (final job in jobs) {
      try {
        await _invokeSendTransferFcmEdge(
          transferId: job.transferId,
          senderId: job.senderId,
          receiverId: job.receiverId,
        );
        processed.add(job);
      } catch (e) {
        // Non-retryable failures are dropped so the queue cannot wedge.
        if (!NetworkErrors.isRetryableFailure(e)) processed.add(job);
        if (kDebugMode) {
          debugPrint('Pending FCM invoke for ${job.transferId}: $e');
        }
      }
    }
    await PendingBackendJobs.removeTransferPushJobs(processed);
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

      // Recipient rows are no longer directly readable (RLS restricts `users`
      // reads to self). Readiness is resolved by the edge function's dry-run,
      // which checks the recipient's token with the service role.
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
        .select(
            '*, sender:users!transfers_sender_id_fkey(short_code, deleted_at)')
        .eq('receiver_id', userId)
        .order('created_at', ascending: false)
        .range(offset, offset + AppConstants.transfersPageSize - 1);

    return _withEffectiveStatuses(result);
  }

  /// Rewrites each row's `status` to its [TransferStatus.effectiveOf] value:
  /// a transfer past its TTL reads as expired even before the server sweep
  /// has stamped it. Every transfer fetch goes through this (incoming, sent,
  /// recent, and the receiver's single-row read), so no two screens can
  /// disagree about whether the same transfer has expired.
  static List<Map<String, dynamic>> _withEffectiveStatuses(List<dynamic> rows) {
    final now = DateTime.now();
    return [
      for (final raw in rows)
        withEffectiveStatus(Map<String, dynamic>.from(raw), now: now),
    ];
  }

  /// [_withEffectiveStatuses] for one row — also for realtime records.
  static Map<String, dynamic> withEffectiveStatus(
    Map<String, dynamic> row, {
    DateTime? now,
  }) =>
      {...row, 'status': TransferStatus.effectiveOf(row, now: now).dbValue};

  // ── Sent transfers (history) ───────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> getSentTransfers(
    String userId, {
    int page = 0,
  }) async {
    await SupabaseConfig.ensureValidSession();
    final offset = page * AppConstants.transfersPageSize;

    final result = await SupabaseConfig.client
        .from('transfers')
        .select(
            '*, receiver:users!transfers_receiver_id_fkey(short_code, deleted_at)')
        .eq('sender_id', userId)
        .order('created_at', ascending: false)
        .range(offset, offset + AppConstants.transfersPageSize - 1);

    return _withEffectiveStatuses(result);
  }

  // ── Recent transfers, both directions (home screen summary) ────────────

  /// Newest transfers in either direction with their file rows attached under
  /// `_files`, for a one-line summary. Two queries instead of an embedded
  /// select so it does not depend on a FK being exposed to PostgREST.
  static Future<List<Map<String, dynamic>>> getRecentTransfers(
    String userId, {
    int limit = 3,
  }) async {
    await SupabaseConfig.ensureValidSession();
    final transfers = _withEffectiveStatuses(
      await SupabaseConfig.client
          .from('transfers')
          .select('id, sender_id, created_at, status')
          .or('sender_id.eq.$userId,receiver_id.eq.$userId')
          .order('created_at', ascending: false)
          .limit(limit),
    );
    if (transfers.isEmpty) return transfers;

    final files = List<Map<String, dynamic>>.from(
      await SupabaseConfig.client
          .from('transfer_files')
          .select('transfer_id, file_name, file_size')
          .inFilter('transfer_id', transfers.map((t) => t['id']).toList()),
    );

    return transfers
        .map((t) => {
              ...t,
              '_files':
                  files.where((f) => f['transfer_id'] == t['id']).toList(),
            })
        .toList();
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
    return row == null
        ? null
        : withEffectiveStatus(Map<String, dynamic>.from(row));
  }

  // ── Streaming download (constant memory, collision-safe) ───────────────

  static Future<File> downloadToFile({
    required String storagePath,
    required String fileName,
    required void Function(int received, int total) onProgress,
    TransferCancellationToken? cancellationToken,
    bool isEncrypted = false,
    String? encWrappedKey,
    String? encNonce,
    int? encChunkSize,

    /// `transfer_files.enc_algo`. Selects the chunk format; only v2 can detect
    /// a truncated ciphertext. Defaults to v1 because rows written before the
    /// v2 rollout have no tag recorded.
    String? encAlgo,
  }) async {
    AppSecurity.instance.ensureTransfersAllowed();
    await SupabaseConfig.ensureValidSession();
    // R2 hybrid: prefer a presigned R2 URL, falling back to Supabase Storage
    // when signing fails or the object predates the R2 cutover (HTTP 404).
    var useR2 = R2Storage.enabled;

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
        // One client per attempt: the watchdog force-closes it on a stall or
        // cancel, and a closed client can't serve the next attempt.
        final httpClient = HttpClient()
          ..connectionTimeout = const Duration(seconds: 30);
        final watchdog = _HttpWatchdog(httpClient, cancellationToken);
        try {
          String url;
          if (useR2) {
            try {
              url = await R2Storage.getDownloadUrl(storagePath);
            } on R2SigningException catch (e) {
              if (kDebugMode) debugPrint('R2 download signing unavailable: $e');
              useR2 = false;
              url = await _supabaseSignedUrl(storagePath);
            }
          } else {
            url = await _supabaseSignedUrl(storagePath);
          }

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
          if (totalBytes > _maxDownloadBytes) {
            throw const DownloadTooLargeException();
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

            watchdog.touch();
            sink!.add(chunk);
            receivedBytes += chunk.length;
            // No (or a false) length header: stop at the cap regardless.
            if (receivedBytes > _maxDownloadBytes) {
              throw const DownloadTooLargeException();
            }
            final safeTotal = totalBytes > 0 ? totalBytes : receivedBytes;
            onProgress(receivedBytes, safeTotal);
          }

          await sink?.close();
          sink = null;
          // Decryption moves no network bytes; it must not count as a stall.
          watchdog.stop();
          // A critical threat may have landed mid-download: hand over no
          // bytes and keep the private key out of it.
          AppSecurity.instance.ensureTransfersAllowed();
          if (!isEncrypted) return file;
          final plain = await _decryptDownloadedFile(
            cipherFile: file,
            fileName: fileName,
            encWrappedKey: encWrappedKey,
            encNonce: encNonce,
            encChunkSize: encChunkSize,
            encAlgo: encAlgo,
          );
          // Decryption can't be interrupted part-way, but a cancel that
          // landed during it must still win: hand back nothing.
          if (cancellationToken?.isCancelled == true) {
            try {
              if (await plain.exists()) await plain.delete();
            } catch (_) {}
            throw TransferCancelledException();
          }
          return plain;
        } catch (e) {
          await sink?.close();
          sink = null;
          // Wrong key or tampered ciphertext fails identically every time —
          // retrying only re-downloads the whole file to fail again.
          if (e is E2EDecryptException) rethrow;
          if (e is SecurityRestrictedException ||
              e is DownloadTooLargeException) {
            if (await file.exists()) await file.delete();
            rethrow;
          }
          // The signer refused. Never fall back to Supabase Storage around
          // it. 410: expired — final, no retries. 403: not a party, or the
          // row is gone — also final. 401 (session) retries below.
          if (e is R2RefusedException && e.status != 401) {
            if (await file.exists()) await file.delete();
            if (e.expired) throw const TransferExpiredException();
            rethrow;
          }
          lastError = (watchdog.abortReason ?? e)
              .toString()
              .replaceAll('Exception: ', '');

          // Object not on R2 (uploaded before the cutover) — use Supabase
          // Storage for the remaining attempts.
          if (useR2 && lastError.contains('HTTP 404')) {
            useR2 = false;
          }

          if (cancellationToken?.isCancelled == true) {
            if (await file.exists()) {
              await file.delete();
            }
            throw TransferCancelledException();
          }

          final isLastAttempt = attempt >= maxAttempts;
          if (isLastAttempt) break;

          await Future.delayed(Duration(seconds: attempt * 2));
        } finally {
          watchdog.stop();
          httpClient.close();
        }
      }

      if (await file.exists()) {
        await file.delete();
      }
      throw Exception(
          'Download failed after $maxAttempts attempts: $lastError');
    } finally {
      await sink?.close();
    }
  }

  /// Decrypts a downloaded ciphertext file into a plaintext temp file using
  /// this device's private key, deletes the ciphertext, and returns the
  /// plaintext file. Throws [E2EDecryptException] if the key material is
  /// missing or authentication fails.
  static Future<File> _decryptDownloadedFile({
    required File cipherFile,
    required String fileName,
    required String? encWrappedKey,
    required String? encNonce,
    required int? encChunkSize,
    required String? encAlgo,
  }) async {
    final authUid = SupabaseConfig.client.auth.currentUser?.id;
    if (authUid == null) {
      throw const E2EDecryptException(
          'Not signed in, so this file can’t be decrypted.');
    }
    if (encWrappedKey == null || encWrappedKey.isEmpty || encNonce == null) {
      throw const E2EDecryptException('Missing encryption metadata.');
    }

    final contentKey = await E2ECrypto.unsealContentKey(
      wrappedKeyB64: encWrappedKey,
      authUid: authUid,
    );

    final tempDir = await getTemporaryDirectory();
    final uniquePrefix =
        '${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(99999)}';
    final plainFile = File(
        '${tempDir.path}/${uniquePrefix}_dec_${sanitizeFileName(fileName)}');

    try {
      await E2ECrypto.decryptFile(
        src: cipherFile,
        dst: plainFile,
        contentKey: contentKey,
        baseNonce: E2ECrypto.decodeB64(encNonce),
        // Rows predating the v2 rollout carry no tag; they are all v1.
        algo: (encAlgo == null || encAlgo.isEmpty)
            ? E2ECrypto.algoTagV1
            : encAlgo,
        plaintextChunkSize: encChunkSize ?? E2ECrypto.chunkSize,
      );
    } catch (e) {
      try {
        if (await plainFile.exists()) await plainFile.delete();
      } catch (_) {}
      rethrow;
    } finally {
      try {
        if (await cipherFile.exists()) await cipherFile.delete();
      } catch (_) {}
    }
    return plainFile;
  }

  /// Verify a downloaded file's SHA-256 against the stored hash.
  ///
  /// Returns a tri-state rather than a bool on purpose. This used to answer
  /// `true` when no hash was recorded, which reads as "verified" at every call
  /// site and quietly turns an unverifiable file into a passing one.
  /// [IntegrityCheck.noHashRecorded] forces the caller to decide.
  static Future<IntegrityCheck> verifySha256(
    File file,
    String? expectedHash, {
    TransferCancellationToken? cancellationToken,
  }) async {
    final expected = expectedHash?.trim();
    if (expected == null || expected.isEmpty) {
      return IntegrityCheck.noHashRecorded;
    }
    final actualHash =
        await computeSha256(file, cancellationToken: cancellationToken);
    return actualHash == expected
        ? IntegrityCheck.verified
        : IntegrityCheck.mismatch;
  }

  /// Convenience: get a signed URL for browser/external download.
  /// Prefers R2 when the hybrid path is enabled, falling back to Supabase only
  /// when R2 is unavailable — an [R2RefusedException] propagates.
  static Future<String> getDownloadUrl(String storagePath) async {
    if (R2Storage.enabled) {
      try {
        return await R2Storage.getDownloadUrl(storagePath);
      } on R2SigningException catch (e) {
        if (kDebugMode) debugPrint('R2 download signing unavailable: $e');
      }
    }
    return _supabaseSignedUrl(storagePath);
  }

  /// Supabase Storage signed URL for one stored object (1 hour validity).
  static Future<String> _supabaseSignedUrl(String storagePath) async {
    await SupabaseConfig.ensureValidSession();
    return await SupabaseConfig.client.storage
        .from('transfers')
        .createSignedUrl(storagePath, 3600);
  }

  // ── Supabase Realtime ────────────────────────────────────────────────────

  /// Subscribe to incoming transfers via Postgres CDC.
  /// Listens for both INSERT (new transfer created) and UPDATE (status changed
  /// to completed) so the receiver is notified when files are actually ready.
  /// Monotonic suffix so every subscription gets its own channel topic.
  /// Two screens subscribing with the same name would share one topic, and
  /// whichever screen disposed first would silently kill the other's
  /// subscription via removeChannel.
  static int _channelSeq = 0;

  static RealtimeChannel? subscribeToIncoming({
    required String userId,
    required void Function(
      Map<String, dynamic> newRecord,
      PostgresChangeEvent event,
    ) onTransferChange,
  }) {
    try {
      final channel =
          SupabaseConfig.client.channel('incoming-$userId-${++_channelSeq}');

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

  /// Subscribe to the caller's OWN sent transfers (`sender_id = userId`), so
  /// History can show a send settling (pending → completed / partial /
  /// failed, or expired by the sweep) without a manual refresh. Each upload
  /// progress write is also an UPDATE here; callers react to status changes
  /// only. Its own channel topic, like [subscribeToIncoming].
  static RealtimeChannel? subscribeToOutgoing({
    required String userId,
    required void Function(
      Map<String, dynamic> newRecord,
      PostgresChangeEvent event,
    ) onTransferChange,
  }) {
    try {
      final channel =
          SupabaseConfig.client.channel('outgoing-$userId-${++_channelSeq}');
      for (final event in const [
        PostgresChangeEvent.insert,
        PostgresChangeEvent.update,
      ]) {
        channel.onPostgresChanges(
          event: event,
          schema: 'public',
          table: 'transfers',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'sender_id',
            value: userId,
          ),
          callback: (PostgresChangePayload payload) {
            onTransferChange(
              Map<String, dynamic>.from(payload.newRecord),
              event,
            );
          },
        );
      }
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
      final channel = SupabaseConfig.client
          .channel('xfer-detail-$transferId-${++_channelSeq}');

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
