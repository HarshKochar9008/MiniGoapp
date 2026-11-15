import 'dart:async';

import 'package:flutter/material.dart';

import '../navigation/root_navigator.dart';
import '../network/connection_status.dart';
import '../notifications/notification_service.dart';
import '../theme.dart';
import '../../features/transfer/transfer_service.dart';
import 'pending_backend_jobs.dart';

/// Offline behavior and retry orchestration
/// -----------------------------------------
///
/// **What is offline here?** The app uses [ConnectionStatus] (from
/// `connectivity_plus`) as a coarse “has a network path” signal. It does not
/// guarantee Supabase is reachable; individual calls still fail and are
/// classified with [NetworkErrors] elsewhere.
///
/// **Queued / retried automatically when the device comes back online**
/// - **FCM token → Supabase** — if saving the device token fails with a
///   retryable network error, [PendingBackendJobs] records the user id;
///   [OfflineSyncCoordinator] runs [NotificationService.syncFcmToken] again.
/// - **Transfer push edge function** — if `send-transfer-fcm` fails after files
///   are uploaded, the invoke is persisted and retried here (non-retryable
///   errors are dropped so the queue cannot wedge).
///
/// **User-visible flows (not headless background uploads)**
/// - **Send / upload** — [TransferService] persists a [PendingUploadJob] before
///   work starts; [SendScreen] offers resume. Large uploads still need the app
///   open; there is no OS-level background uploader.
/// - **Receive / download** — retries exist inside [TransferService.downloadToFile];
///   the receive UI blocks starting a download when offline.
/// - **Identity bootstrap** — [MainShell] retries on connectivity recovery and
///   keeps a timer fallback when startup fails with a retryable error.
///
/// **Triggers for [runPendingWork]** — connectivity flips to online (debounced),
/// app resume, and immediately after coordinator [start] if already online.
class OfflineSyncCoordinator {
  OfflineSyncCoordinator._();
  static final OfflineSyncCoordinator instance = OfflineSyncCoordinator._();

  String? _userId;
  VoidCallback? _onlineListener;
  Timer? _debounce;

  /// The drain in progress, if any; see [runPendingWork].
  Future<void>? _drain;
  bool _rerunRequested = false;
  bool _lastOnline = true;
  DateTime? _lastPendingUploadSnackAt;

  void start({required String userId}) {
    stop();
    _userId = userId;
    PendingBackendJobs.setActiveUser(userId);
    ConnectionStatus.instance.ensureStarted();
    _lastOnline = ConnectionStatus.instance.online.value;

    _onlineListener ??= () {
      final nowOnline = ConnectionStatus.instance.online.value;
      if (nowOnline && !_lastOnline) {
        _scheduleDrain();
      }
      _lastOnline = nowOnline;
    };
    ConnectionStatus.instance.online.addListener(_onlineListener!);

    if (ConnectionStatus.instance.online.value) {
      _scheduleDrain(immediate: true);
    }
  }

  void stop() {
    _debounce?.cancel();
    _debounce = null;
    if (_onlineListener != null) {
      ConnectionStatus.instance.online.removeListener(_onlineListener!);
      _onlineListener = null;
    }
    _userId = null;
    PendingBackendJobs.setActiveUser(null);
  }

  /// Called from lifecycle (e.g. app resumed) to refresh connectivity and drain.
  Future<void> onAppResumed() async {
    await ConnectionStatus.instance.refresh();
    if (ConnectionStatus.instance.online.value) {
      await runPendingWork();
    }
  }

  void _scheduleDrain({bool immediate = false}) {
    _debounce?.cancel();
    if (immediate) {
      unawaited(runPendingWork());
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 450), () {
      unawaited(runPendingWork());
    });
  }

  /// Runs queued backend jobs (FCM sync, transfer push retries). Safe to call
  /// often: a call that arrives while a drain is running doesn't start a
  /// second one, and isn't dropped either — it schedules one more pass after
  /// the current one (work queued mid-drain, e.g. by a send finishing, is
  /// picked up), and returns the running drain's future.
  Future<void> runPendingWork() {
    final running = _drain;
    if (running != null) {
      _rerunRequested = true;
      return running;
    }
    final drain = _drainLoop();
    _drain = drain;
    return drain;
  }

  /// Passes per drain, so a caller re-requesting in a loop can't spin it.
  static const _maxPassesPerDrain = 3;

  Future<void> _drainLoop() async {
    try {
      var passes = 0;
      do {
        _rerunRequested = false;
        passes++;
        await _runOnce();
      } while (_rerunRequested && passes < _maxPassesPerDrain);
    } finally {
      _rerunRequested = false;
      _drain = null;
    }
  }

  Future<void> _runOnce() async {
    final userId = _userId;
    if (userId == null || userId.isEmpty) return;
    try {
      final pendingFcmUser = await PendingBackendJobs.peekPendingFcmUserId();
      if (pendingFcmUser != null && pendingFcmUser != userId) {
        // Left by another identity on this device; it can never be synced
        // from this session, and must not keep the banner up.
        await PendingBackendJobs.clearFcmTokenSyncPending();
      } else if (pendingFcmUser == userId) {
        await NotificationService.syncFcmToken(userId);
        // Still pending after a sync means it failed again — or Firebase gave
        // no token, which syncFcmToken returns on without clearing. Count it,
        // so the slot ages out instead of sticking forever.
        if (await PendingBackendJobs.peekPendingFcmUserId() == userId) {
          await PendingBackendJobs.noteFcmSyncAttemptFailed(userId);
        }
      }

      await TransferService.flushPendingTransferPushNotifications();

      await _maybeNotifyPendingUpload(userId);
    } finally {
      // Always recompute so the UI banner reflects post-drain state, even on
      // partial failures where some jobs remain queued.
      await PendingBackendJobs.refreshPendingCount();
    }
  }

  Future<void> _maybeNotifyPendingUpload(String userId) async {
    // A send that is uploading right now saved its job before starting; it is
    // not "unfinished", and the prompt would offer to discard a live send.
    if (TransferService.isSendInFlight) return;
    final pending = await TransferService.getPendingUploadJob(senderId: userId);
    if (pending == null || TransferService.isSendInFlight) return;

    final now = DateTime.now();
    if (_lastPendingUploadSnackAt != null &&
        now.difference(_lastPendingUploadSnackAt!) <
            const Duration(seconds: 45)) {
      return;
    }
    _lastPendingUploadSnackAt = now;

    final ctx = rootNavigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return;

    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(
        content: const Text(
          'You have an unfinished send. Open Send Files to resume or discard.',
        ),
        behavior: SnackBarBehavior.floating,
        backgroundColor: ctx.mini.ink,
        duration: const Duration(seconds: 5),
      ),
    );
  }
}
