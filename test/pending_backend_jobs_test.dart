import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:minigo/core/offline/pending_backend_jobs.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The persisted push queue and FCM slot. Every read-modify-write runs under
/// one async mutex, so a job enqueued while a flush is invoking the edge
/// function survives it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const queueKey = 'pending_transfer_fcm_invoke_v1';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PendingBackendJobs.setActiveUser(null);
  });

  group('AsyncMutex', () {
    test('runs bodies one at a time, in call order', () async {
      final mutex = AsyncMutex();
      final log = <String>[];
      final gate = Completer<void>();

      final a = mutex.run(() async {
        log.add('a start');
        await gate.future;
        log.add('a end');
      });
      final b = mutex.run(() async => log.add('b'));

      await Future<void>.delayed(Duration.zero);
      expect(log, ['a start']); // b waits for a
      gate.complete();
      await Future.wait([a, b]);
      expect(log, ['a start', 'a end', 'b']);
    });

    test('a throwing body does not wedge the next one', () async {
      final mutex = AsyncMutex();
      await expectLater(
        mutex.run<void>(() async => throw StateError('boom')),
        throwsStateError,
      );
      expect(await mutex.run(() async => 42), 42);
    });
  });

  group('transfer push queue', () {
    Future<void> enqueue(String tid) =>
        PendingBackendJobs.enqueueTransferPushNotification(
          transferId: tid,
          senderId: 'sender',
          receiverId: 'receiver',
        );

    test('concurrent enqueues all persist', () async {
      await Future.wait([for (var i = 0; i < 10; i++) enqueue('t$i')]);
      final jobs = await PendingBackendJobs.loadTransferPushQueue();
      expect(jobs.map((j) => j.transferId).toSet(),
          {for (var i = 0; i < 10; i++) 't$i'});
    });

    test('a job enqueued during a flush survives it', () async {
      await enqueue('old');
      final snapshot = await PendingBackendJobs.takeTransferPushSnapshot();
      expect(snapshot.map((j) => j.transferId), ['old']);

      // A send finishes while the flush is invoking the edge function.
      await enqueue('new');

      await PendingBackendJobs.removeTransferPushJobs(snapshot);
      final left = await PendingBackendJobs.loadTransferPushQueue();
      expect(left.map((j) => j.transferId), ['new']);
    });

    test('re-enqueueing the same transfer mid-flush is not removed', () async {
      await enqueue('t');
      final snapshot = await PendingBackendJobs.takeTransferPushSnapshot();
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await enqueue('t'); // fresh entry, new enqueuedAt
      await PendingBackendJobs.removeTransferPushJobs(snapshot);
      final left = await PendingBackendJobs.loadTransferPushQueue();
      expect(left, hasLength(1));
      expect(left.single.transferId, 't');
    });

    test('jobs older than the transfer TTL are dropped', () async {
      final stale = DateTime.now()
          .toUtc()
          .subtract(const Duration(hours: 25))
          .toIso8601String();
      SharedPreferences.setMockInitialValues({
        queueKey: jsonEncode([
          {
            'transfer_id': 'stale',
            'sender_id': 's',
            'receiver_id': 'r',
            'enqueued_at': stale,
          },
        ]),
      });
      await enqueue('fresh');
      final snapshot = await PendingBackendJobs.takeTransferPushSnapshot();
      expect(snapshot.map((j) => j.transferId), ['fresh']);
    });

    test('legacy entries get a stamp that later removal can match', () async {
      SharedPreferences.setMockInitialValues({
        queueKey: jsonEncode([
          {'transfer_id': 'legacy', 'sender_id': 's', 'receiver_id': 'r'},
        ]),
      });
      final snapshot = await PendingBackendJobs.takeTransferPushSnapshot();
      expect(snapshot.single.transferId, 'legacy');
      await PendingBackendJobs.removeTransferPushJobs(snapshot);
      expect(await PendingBackendJobs.loadTransferPushQueue(), isEmpty);
    });
  });

  group('FCM token sync slot', () {
    test('counts only for the active user', () async {
      await PendingBackendJobs.markFcmTokenSyncPending('u1');
      PendingBackendJobs.setActiveUser('u2');
      expect(await PendingBackendJobs.refreshPendingCount(), 0);
      PendingBackendJobs.setActiveUser('u1');
      expect(await PendingBackendJobs.refreshPendingCount(), 1);
    });

    test('gives up after the attempt cap instead of sticking forever',
        () async {
      await PendingBackendJobs.markFcmTokenSyncPending('u1');
      var gaveUp = false;
      for (var i = 0; i < PendingBackendJobs.maxFcmSyncAttempts; i++) {
        // A failing sync re-marks the slot; that must not reset the count.
        await PendingBackendJobs.markFcmTokenSyncPending('u1');
        gaveUp = await PendingBackendJobs.noteFcmSyncAttemptFailed('u1');
      }
      expect(gaveUp, isTrue);
      expect(await PendingBackendJobs.peekPendingFcmUserId(), isNull);
    });
  });
}
