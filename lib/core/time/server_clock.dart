import 'dart:async';

import 'package:flutter/foundation.dart';

import '../supabase_config.dart';

/// Reads the database's current time. Throws when it can't.
typedef ServerTimeFetcher = Future<DateTime> Function();

/// The server's idea of "now", for deadlines the server enforces.
///
/// Room expiry (`rooms.expires_at`) is computed from the database clock, and
/// the server refuses joins and room sends by that clock. Comparing it with
/// the device clock made a phone set a few minutes fast hide live rooms and
/// refuse joins, and one set slow offer rooms the server had already closed.
///
/// This measures one offset against `public.server_now()` (migration
/// 20261113000003), corrected for half the round trip, and applies it to the
/// local clock. The offset is computed once ([ensureSynced]) and can be
/// re-measured ([refresh]). When the RPC is missing (migration not applied
/// yet) or unreachable, the offset keeps its last value — zero to start
/// with — so the worst case is the old device-clock behaviour.
class ServerClock {
  ServerClock({
    ServerTimeFetcher? fetchServerTime,
    DateTime Function()? localNow,
    this.retryAfter = const Duration(minutes: 1),
    this.maxRoundTrip = const Duration(seconds: 20),
  })  : _fetch = fetchServerTime ?? _fetchFromBackend,
        _localNow = localNow ?? DateTime.now;

  static final ServerClock instance = ServerClock();

  /// After a failed measurement, [ensureSynced] waits this long before trying
  /// again, so a missing RPC isn't called on every room list load.
  final Duration retryAfter;

  /// Samples slower than this are discarded: the offset's error is up to half
  /// the round trip.
  final Duration maxRoundTrip;

  final ServerTimeFetcher _fetch;
  final DateTime Function() _localNow;

  Duration _offset = Duration.zero;
  bool _synced = false;
  DateTime? _lastFailure;
  Future<void>? _inFlight;

  /// Server time minus device time. Zero until a measurement succeeds.
  Duration get offset => _offset;

  /// Whether at least one measurement has succeeded.
  bool get isSynced => _synced;

  /// Current server time (UTC), estimated from the device clock.
  DateTime now() => _localNow().toUtc().add(_offset);

  /// Measures the offset unless it already has been. Never throws.
  Future<void> ensureSynced() {
    if (_synced) return Future.value();
    final failedAt = _lastFailure;
    if (failedAt != null && _localNow().difference(failedAt) < retryAfter) {
      return Future.value();
    }
    return refresh();
  }

  /// Re-measures the offset. Concurrent callers share one request. Never
  /// throws; on failure the previous offset is kept.
  Future<void> refresh() =>
      _inFlight ??= _measure().whenComplete(() => _inFlight = null);

  Future<void> _measure() async {
    final sent = _localNow();
    final DateTime server;
    try {
      server = await _fetch();
    } catch (_) {
      _lastFailure = _localNow();
      return;
    }
    final received = _localNow();
    final roundTrip = received.difference(sent);
    if (roundTrip.isNegative || roundTrip > maxRoundTrip) {
      _lastFailure = received;
      return;
    }
    final localMidpoint = sent.add(roundTrip ~/ 2);
    _offset = server.toUtc().difference(localMidpoint.toUtc());
    _synced = true;
    _lastFailure = null;
  }

  static Future<DateTime> _fetchFromBackend() async {
    final raw = await SupabaseConfig.client.rpc('server_now');
    final parsed = DateTime.tryParse(raw?.toString() ?? '');
    if (parsed == null) {
      throw const FormatException('server_now returned no timestamp');
    }
    return parsed.toUtc();
  }

  /// Forgets the measured offset.
  @visibleForTesting
  void reset() {
    _offset = Duration.zero;
    _synced = false;
    _lastFailure = null;
    _inFlight = null;
  }
}
