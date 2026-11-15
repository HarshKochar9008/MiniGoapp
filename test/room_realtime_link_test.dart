import 'package:flutter_test/flutter_test.dart';
import 'package:minigo/features/rooms/room_realtime_link.dart';
import 'package:minigo/features/rooms/room_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show RealtimeSubscribeStatus;

/// Supabase realtime keeps no backlog, so a room channel that drops must be
/// replaced and, once live again, trigger a reload. No backend: the channel
/// factory is a fake that only records the status callbacks it was handed.
void main() {
  group('RealtimeLinkTracker', () {
    test('the first SUBSCRIBED needs no resync', () {
      final t = RealtimeLinkTracker();
      expect(t.onStatus(RealtimeSubscribeStatus.subscribed),
          RealtimeLinkAction.none);
    });

    for (final drop in [
      RealtimeSubscribeStatus.channelError,
      RealtimeSubscribeStatus.timedOut,
      RealtimeSubscribeStatus.closed,
    ]) {
      test('$drop → reconnect, then SUBSCRIBED → resync once', () {
        final t = RealtimeLinkTracker();
        t.onStatus(RealtimeSubscribeStatus.subscribed);
        expect(t.onStatus(drop), RealtimeLinkAction.reconnect);
        expect(t.isInterrupted, isTrue);
        expect(t.onStatus(RealtimeSubscribeStatus.subscribed),
            RealtimeLinkAction.resync);
        expect(t.onStatus(RealtimeSubscribeStatus.subscribed),
            RealtimeLinkAction.none);
      });
    }

    test('a channel that never came up still resyncs when it finally does', () {
      final t = RealtimeLinkTracker();
      t.onStatus(RealtimeSubscribeStatus.timedOut);
      expect(t.onStatus(RealtimeSubscribeStatus.subscribed),
          RealtimeLinkAction.resync);
    });

    test('backoff doubles, caps, and resets once live', () {
      final t = RealtimeLinkTracker(
        initialDelay: const Duration(seconds: 1),
        maxDelay: const Duration(seconds: 30),
      );
      final delays = [for (var i = 0; i < 7; i++) t.nextDelay().inSeconds];
      expect(delays, [1, 2, 4, 8, 16, 30, 30]);
      t.onStatus(RealtimeSubscribeStatus.subscribed);
      expect(t.nextDelay(), const Duration(seconds: 1));
    });
  });

  group('RoomRealtimeLink', () {
    late List<RealtimeStatusCallback> opened;
    late int resyncs;
    late RoomRealtimeLink link;

    setUp(() {
      opened = [];
      resyncs = 0;
      link = RoomRealtimeLink(
        connect: (onStatus) {
          opened.add(onStatus);
          return null; // no backend in tests
        },
        onResync: () => resyncs++,
        tracker: RealtimeLinkTracker(
          initialDelay: const Duration(milliseconds: 1),
          maxDelay: const Duration(milliseconds: 4),
        ),
      );
    });

    tearDown(() => link.dispose());

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 30));

    test('replaces a dropped channel and resyncs when the new one is live',
        () async {
      link.start();
      expect(opened, hasLength(1));
      opened[0](RealtimeSubscribeStatus.subscribed, null);
      expect(resyncs, 0);

      opened[0](RealtimeSubscribeStatus.channelError, Exception('down'));
      await settle();
      expect(opened, hasLength(2));

      opened[1](RealtimeSubscribeStatus.subscribed, null);
      expect(resyncs, 1);
    });

    test('a burst of errors schedules one replacement', () async {
      link.start();
      opened[0](RealtimeSubscribeStatus.channelError, null);
      opened[0](RealtimeSubscribeStatus.timedOut, null);
      opened[0](RealtimeSubscribeStatus.channelError, null);
      await settle();
      expect(opened, hasLength(2));
    });

    test('the replaced channel closing is not mistaken for a new drop',
        () async {
      link.start();
      opened[0](RealtimeSubscribeStatus.channelError, null);
      await settle();
      expect(opened, hasLength(2));
      // The old channel reports `closed` as it is removed.
      opened[0](RealtimeSubscribeStatus.closed, null);
      await settle();
      expect(opened, hasLength(2));
      opened[0](RealtimeSubscribeStatus.subscribed, null);
      expect(resyncs, 0);
    });

    test('nothing reconnects or resyncs after dispose', () async {
      link.start();
      opened[0](RealtimeSubscribeStatus.channelError, null);
      link.dispose();
      await settle();
      expect(opened, hasLength(1));
      opened[0](RealtimeSubscribeStatus.subscribed, null);
      expect(resyncs, 0);
    });
  });
}
