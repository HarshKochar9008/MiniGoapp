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
  bool _running = false;
  bool _lastOnline = true;
  DateTime? _lastPendingUploadSnackAt;

  void start({required String userId}) {
    stop();
    _userId = userId;
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

  /// Runs queued backend jobs (FCM sync, transfer push retries). Safe to call often.
  Future<void> runPendingWork() async {
    final userId = _userId;
    if (userId == null || userId.isEmpty) return;
    if (_running) return;
    _running = true;
    try {
      final pendingFcmUser = await PendingBackendJobs.peekPendingFcmUserId();
      if (pendingFcmUser == userId) {
        await NotificationService.syncFcmToken(userId);
      }

      await TransferService.flushPendingTransferPushNotifications();

      await _maybeNotifyPendingUpload(userId);
    } finally {
      _running = false;
    }
  }

  Future<void> _maybeNotifyPendingUpload(String userId) async {
    final pending = await TransferService.getPendingUploadJob(senderId: userId);
    if (pending == null) return;

    final now = DateTime.now();
    if (_lastPendingUploadSnackAt != null &&
        now.difference(_lastPendingUploadSnackAt!) < const Duration(seconds: 45)) {
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
        backgroundColor: ZenColors.ink,
        duration: const Duration(seconds: 5),
      ),
    );
  }
}
