import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';

/// Serializes async critical sections. Each [run] starts only after every
/// earlier one has finished (successfully or not). Not reentrant: a body
/// must never call [run] on the same mutex, or it waits on itself.
class AsyncMutex {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() body) {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    return previous.then((_) => body()).whenComplete(done.complete);
  }
}

/// One queued `send-transfer-fcm` invoke.
@immutable
class TransferPushJob {
  final String transferId;
  final String senderId;
  final String receiverId;

  /// When the push was queued. A job and its re-enqueued replacement differ
  /// here, so a flush removes exactly the entry it processed.
  final DateTime enqueuedAt;

  const TransferPushJob({
    required this.transferId,
    required this.senderId,
    required this.receiverId,
    required this.enqueuedAt,
  });

  /// Older than the transfer it announces can live: pushing it now would
  /// only send the receiver to an expired transfer.
  bool isStale(DateTime now) =>
      now.toUtc().difference(enqueuedAt.toUtc()) >=
      const Duration(hours: AppConstants.transferTtlHours);

  bool sameEntry(TransferPushJob other) =>
      other.transferId == transferId &&
      other.enqueuedAt.toUtc() == enqueuedAt.toUtc();

  Map<String, String> toJson() => {
        'transfer_id': transferId,
        'sender_id': senderId,
        'receiver_id': receiverId,
        'enqueued_at': enqueuedAt.toUtc().toIso8601String(),
      };

  /// [legacyEnqueuedAt] stamps entries written before jobs carried a time.
  static TransferPushJob? fromJson(Map<dynamic, dynamic> json,
      {required DateTime legacyEnqueuedAt}) {
    final tid = json['transfer_id']?.toString() ?? '';
    final sid = json['sender_id']?.toString() ?? '';
    final rid = json['receiver_id']?.toString() ?? '';
    if (tid.isEmpty || sid.isEmpty || rid.isEmpty) return null;
    final at = DateTime.tryParse(json['enqueued_at']?.toString() ?? '');
    return TransferPushJob(
      transferId: tid,
      senderId: sid,
      receiverId: rid,
      enqueuedAt: (at ?? legacyEnqueuedAt).toUtc(),
    );
  }
}

/// Persisted work that must run once the device has connectivity again.
///
/// Every read-modify-write of the stored queue/slot runs under [_lock], so a
/// push enqueued by a finishing send can't be overwritten by a concurrent
/// flush that loaded the queue before it.
class PendingBackendJobs {
  PendingBackendJobs._();

  static const _fcmPendingUserIdKey = 'pending_fcm_token_sync_user_v1';
  static const _fcmPendingMetaKey = 'pending_fcm_token_sync_meta_v1';
  static const _pushQueueKey = 'pending_transfer_fcm_invoke_v1';
  static const _maxPushJobs = 32;

  /// A token sync that hasn't succeeded after this many drains, or for this
  /// long, is dropped (e.g. Firebase keeps returning no token). The token
  /// refresh listener syncs again whenever a token does appear.
  static const maxFcmSyncAttempts = 8;
  static const maxFcmSyncAge = Duration(days: 3);

  static final AsyncMutex _lock = AsyncMutex();

  /// Signed-in app user, set by the offline coordinator. The FCM slot only
  /// counts — and only drains — for this user.
  static String? _activeUserId;

  static void setActiveUser(String? userId) {
    _activeUserId = (userId == null || userId.isEmpty) ? null : userId;
    unawaited(refreshPendingCount());
  }

  /// Live-updating count of queued work the UI can subscribe to.
  /// Updated by enqueue/clear paths and by [refreshPendingCount].
  static final ValueNotifier<int> pendingCount = ValueNotifier<int>(0);

  /// Reload count from persistent storage. Call at startup and after drains.
  static Future<int> refreshPendingCount() async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final push =
        _loadPushQueue(prefs, now: now).where((j) => !j.isStale(now)).length;
    final fcm = prefs.getString(_fcmPendingUserIdKey);
    final active = _activeUserId;
    final fcmCounts = fcm != null && fcm.isNotEmpty && fcm == active;
    final total = push + (fcmCounts ? 1 : 0);
    if (pendingCount.value != total) pendingCount.value = total;
    return total;
  }

  // ── FCM token sync slot ──────────────────────────────────────────────────

  static Future<void> markFcmTokenSyncPending(String userId) async {
    await _lock.run(() async {
      final prefs = await SharedPreferences.getInstance();
      final existing = prefs.getString(_fcmPendingUserIdKey);
      // Re-marking the same user keeps the original time and attempt count,
      // or a sync that keeps failing would never age out.
      if (existing != userId) {
        await prefs.setString(_fcmPendingUserIdKey, userId);
        await prefs.setString(
          _fcmPendingMetaKey,
          jsonEncode({
            'marked_at': DateTime.now().toUtc().toIso8601String(),
            'attempts': 0,
          }),
        );
      }
    });
    await refreshPendingCount();
  }

  static Future<void> clearFcmTokenSyncPending() async {
    await _lock.run(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_fcmPendingUserIdKey);
      await prefs.remove(_fcmPendingMetaKey);
    });
    await refreshPendingCount();
  }

  static Future<String?> peekPendingFcmUserId() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_fcmPendingUserIdKey);
    if (v == null || v.isEmpty) return null;
    return v;
  }

  /// Records one drain that ran the sync and left the slot set. Returns true
  /// when the slot has now been given up on and cleared.
  static Future<bool> noteFcmSyncAttemptFailed(String userId) async {
    final gaveUp = await _lock.run(() async {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString(_fcmPendingUserIdKey) != userId) return false;
      final meta = _readFcmMeta(prefs);
      final attempts = meta.attempts + 1;
      final markedAt = meta.markedAt ?? DateTime.now().toUtc();
      final tooOld =
          DateTime.now().toUtc().difference(markedAt) >= maxFcmSyncAge;
      if (attempts >= maxFcmSyncAttempts || tooOld) {
        await prefs.remove(_fcmPendingUserIdKey);
        await prefs.remove(_fcmPendingMetaKey);
        return true;
      }
      await prefs.setString(
        _fcmPendingMetaKey,
        jsonEncode({
          'marked_at': markedAt.toIso8601String(),
          'attempts': attempts,
        }),
      );
      return false;
    });
    await refreshPendingCount();
    return gaveUp;
  }

  static ({DateTime? markedAt, int attempts}) _readFcmMeta(
    SharedPreferences prefs,
  ) {
    try {
      final raw = prefs.getString(_fcmPendingMetaKey);
      if (raw == null || raw.isEmpty) return (markedAt: null, attempts: 0);
      final m = jsonDecode(raw);
      if (m is! Map) return (markedAt: null, attempts: 0);
      final attempts = m['attempts'];
      return (
        markedAt: DateTime.tryParse(m['marked_at']?.toString() ?? '')?.toUtc(),
        attempts: attempts is int ? attempts : int.tryParse('$attempts') ?? 0,
      );
    } catch (_) {
      return (markedAt: null, attempts: 0);
    }
  }

  // ── Transfer push queue ──────────────────────────────────────────────────

  static Future<void> enqueueTransferPushNotification({
    required String transferId,
    required String senderId,
    required String receiverId,
  }) async {
    await _lock.run(() async {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      final jobs = _loadPushQueue(prefs, now: now)
          .where((j) => j.transferId != transferId && !j.isStale(now))
          .toList()
        ..add(TransferPushJob(
          transferId: transferId,
          senderId: senderId,
          receiverId: receiverId,
          enqueuedAt: now.toUtc(),
        ));
      await _savePushQueue(prefs, jobs);
    });
    await refreshPendingCount();
  }

  /// The queue as it stands, minus jobs older than the transfer TTL (which
  /// are dropped for good). Entries from before jobs carried a time are
  /// stamped now and saved, so later removal can match them exactly.
  static Future<List<TransferPushJob>> takeTransferPushSnapshot() async {
    final jobs = await _lock.run(() async {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      final all = _loadPushQueue(prefs, now: now);
      final live = all.where((j) => !j.isStale(now)).toList();
      final raw = prefs.getString(_pushQueueKey);
      final normalized = jsonEncode([for (final j in live) j.toJson()]);
      if (raw != null && raw != normalized) await _savePushQueue(prefs, live);
      return live;
    });
    await refreshPendingCount();
    return jobs;
  }

  /// Removes exactly [processed] (by transfer and enqueue time). Anything
  /// enqueued after the snapshot — including a fresh job for the same
  /// transfer — stays queued.
  static Future<void> removeTransferPushJobs(
    Iterable<TransferPushJob> processed,
  ) async {
    final done = processed.toList();
    if (done.isEmpty) {
      await refreshPendingCount();
      return;
    }
    await _lock.run(() async {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      final remaining = _loadPushQueue(prefs, now: now)
          .where((j) => !j.isStale(now) && !done.any(j.sameEntry))
          .toList();
      await _savePushQueue(prefs, remaining);
    });
    await refreshPendingCount();
  }

  static Future<List<TransferPushJob>> loadTransferPushQueue() async {
    final prefs = await SharedPreferences.getInstance();
    return _loadPushQueue(prefs, now: DateTime.now());
  }

  static Future<void> _savePushQueue(
    SharedPreferences prefs,
    List<TransferPushJob> jobs,
  ) async {
    if (jobs.isEmpty) {
      await prefs.remove(_pushQueueKey);
      return;
    }
    final capped = jobs.length > _maxPushJobs
        ? jobs.sublist(jobs.length - _maxPushJobs)
        : jobs;
    await prefs.setString(
      _pushQueueKey,
      jsonEncode([for (final j in capped) j.toJson()]),
    );
  }

  static List<TransferPushJob> _loadPushQueue(
    SharedPreferences prefs, {
    required DateTime now,
  }) {
    final raw = prefs.getString(_pushQueueKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((item) => TransferPushJob.fromJson(item, legacyEnqueuedAt: now))
          .whereType<TransferPushJob>()
          .toList();
    } catch (_) {
      return [];
    }
  }
}
