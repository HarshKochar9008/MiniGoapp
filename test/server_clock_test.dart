import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:minigo/core/time/server_clock.dart';

/// ServerClock turns one `server_now()` round trip into an offset applied to
/// the device clock. Pure Dart: the fetcher and the local clock are fakes.
void main() {
  late DateTime local;
  DateTime localNow() => local;

  setUp(() {
    local = DateTime.utc(2026, 11, 13, 12);
  });

  test('starts at the device clock with a zero offset', () {
    final clock = ServerClock(
      fetchServerTime: () async => throw StateError('unused'),
      localNow: localNow,
    );
    expect(clock.isSynced, isFalse);
    expect(clock.offset, Duration.zero);
    expect(clock.now(), local);
  });

  test('offset is measured against the midpoint of the round trip', () async {
    // Server is 5 minutes ahead; the request takes 2 s each way.
    final clock = ServerClock(
      fetchServerTime: () async {
        local = local.add(const Duration(seconds: 2));
        final server = local.add(const Duration(minutes: 5));
        local = local.add(const Duration(seconds: 2));
        return server;
      },
      localNow: localNow,
    );
    await clock.ensureSynced();
    expect(clock.isSynced, isTrue);
    expect(clock.offset, const Duration(minutes: 5));
    expect(clock.now(), local.add(const Duration(minutes: 5)));
  });

  test('a slow device clock gets a negative offset', () async {
    final clock = ServerClock(
      fetchServerTime: () async => local.subtract(const Duration(minutes: 3)),
      localNow: localNow,
    );
    await clock.refresh();
    expect(clock.offset, const Duration(minutes: -3));
  });

  test('falls back to zero when the RPC is missing, and does not hammer it',
      () async {
    var calls = 0;
    final clock = ServerClock(
      fetchServerTime: () async {
        calls++;
        throw Exception('PGRST202: function server_now not found');
      },
      localNow: localNow,
      retryAfter: const Duration(minutes: 1),
    );
    await clock.ensureSynced();
    expect(clock.isSynced, isFalse);
    expect(clock.offset, Duration.zero);
    expect(clock.now(), local);

    await clock.ensureSynced(); // inside the back-off window
    expect(calls, 1);

    local = local.add(const Duration(minutes: 2));
    await clock.ensureSynced(); // back-off elapsed
    expect(calls, 2);
  });

  test('ensureSynced measures once; refresh re-measures', () async {
    var calls = 0;
    var serverAhead = const Duration(seconds: 10);
    final clock = ServerClock(
      fetchServerTime: () async {
        calls++;
        return local.add(serverAhead);
      },
      localNow: localNow,
    );
    await clock.ensureSynced();
    await clock.ensureSynced();
    expect(calls, 1);
    expect(clock.offset, const Duration(seconds: 10));

    serverAhead = const Duration(seconds: 40);
    await clock.refresh();
    expect(calls, 2);
    expect(clock.offset, const Duration(seconds: 40));
  });

  test('a failed refresh keeps the last good offset', () async {
    var fail = false;
    final clock = ServerClock(
      fetchServerTime: () async {
        if (fail) throw Exception('offline');
        return local.add(const Duration(minutes: 1));
      },
      localNow: localNow,
    );
    await clock.refresh();
    fail = true;
    await clock.refresh();
    expect(clock.isSynced, isTrue);
    expect(clock.offset, const Duration(minutes: 1));
  });

  test('concurrent callers share one request', () async {
    var calls = 0;
    final gate = Completer<DateTime>();
    final clock = ServerClock(
      fetchServerTime: () {
        calls++;
        return gate.future;
      },
      localNow: localNow,
    );
    final a = clock.ensureSynced();
    final b = clock.refresh();
    gate.complete(local.add(const Duration(seconds: 3)));
    await Future.wait([a, b]);
    expect(calls, 1);
    expect(clock.offset, const Duration(seconds: 3));
  });

  test('a sample with a very slow round trip is discarded', () async {
    final clock = ServerClock(
      fetchServerTime: () async {
        local = local.add(const Duration(seconds: 45));
        return local.add(const Duration(minutes: 10));
      },
      localNow: localNow,
      maxRoundTrip: const Duration(seconds: 20),
    );
    await clock.refresh();
    expect(clock.isSynced, isFalse);
    expect(clock.offset, Duration.zero);
  });
}
