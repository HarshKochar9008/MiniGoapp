import 'dart:async';
import 'dart:math' as math;

import 'package:supabase_flutter/supabase_flutter.dart'
    show RealtimeChannel, RealtimeSubscribeStatus;

import 'room_service.dart';

/// What to do about a channel status change.
enum RealtimeLinkAction {
  /// Nothing.
  none,

  /// The channel is live again after an interruption: events sent while it
  /// was down are lost, so reload.
  resync,

  /// The channel errored, timed out or closed: replace it after
  /// [RealtimeLinkTracker.nextDelay].
  reconnect,
}

/// Pure bookkeeping behind [RoomRealtimeLink]: whether a SUBSCRIBED follows
/// an interruption (so a reload must catch up), and the reconnect backoff.
class RealtimeLinkTracker {
  RealtimeLinkTracker({
    this.initialDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
  });

  final Duration initialDelay;
  final Duration maxDelay;

  bool _interrupted = false;
  int _failures = 0;

  /// Whether the channel has been down since it was last live.
  bool get isInterrupted => _interrupted;

  RealtimeLinkAction onStatus(RealtimeSubscribeStatus status) {
    switch (status) {
      case RealtimeSubscribeStatus.subscribed:
        _failures = 0;
        if (!_interrupted) return RealtimeLinkAction.none;
        _interrupted = false;
        return RealtimeLinkAction.resync;
      case RealtimeSubscribeStatus.channelError:
      case RealtimeSubscribeStatus.timedOut:
      case RealtimeSubscribeStatus.closed:
        _interrupted = true;
        return RealtimeLinkAction.reconnect;
    }
  }

  /// Delay before the next reconnect: 1 s, 2 s, 4 s … capped at [maxDelay].
  /// Resets when the channel reaches SUBSCRIBED.
  Duration nextDelay() {
    final factor = 1 << math.min(_failures, 16);
    _failures++;
    final delay = initialDelay * factor;
    return delay > maxDelay ? maxDelay : delay;
  }
}

/// Creates a channel that reports its status to `onStatus`, or null when it
/// can't be created at all (no backend client).
typedef RoomChannelFactory = RealtimeChannel? Function(
    RealtimeStatusCallback onStatus);

/// Keeps one room realtime channel alive.
///
/// Supabase delivers no backlog: events sent while a channel was errored,
/// timed out or closed are simply gone. So when the channel drops, this
/// replaces it with exponential backoff, and when a channel is SUBSCRIBED
/// again after a drop it calls [onResync] so the screen reloads what it may
/// have missed.
class RoomRealtimeLink {
  RoomRealtimeLink({
    required RoomChannelFactory connect,
    required void Function() onResync,
    RealtimeLinkTracker? tracker,
  })  : _connect = connect,
        _onResync = onResync,
        _tracker = tracker ?? RealtimeLinkTracker();

  final RoomChannelFactory _connect;
  final void Function() _onResync;
  final RealtimeLinkTracker _tracker;

  RealtimeChannel? _channel;
  int _generation = 0;
  Timer? _retry;
  bool _disposed = false;

  void start() => _open();

  void _open() {
    if (_disposed) return;
    final generation = ++_generation;
    _channel = _connect((status, _) => _onStatus(generation, status));
  }

  void _onStatus(int generation, RealtimeSubscribeStatus status) {
    // A replaced channel reports `closed` when it is removed: not ours any
    // more.
    if (_disposed || generation != _generation) return;
    switch (_tracker.onStatus(status)) {
      case RealtimeLinkAction.none:
        break;
      case RealtimeLinkAction.resync:
        _onResync();
      case RealtimeLinkAction.reconnect:
        if (_retry?.isActive ?? false) return;
        _retry = Timer(_tracker.nextDelay(), _reconnect);
    }
  }

  void _reconnect() {
    if (_disposed) return;
    _drop();
    _open();
  }

  void _drop() {
    final old = _channel;
    _channel = null;
    _generation++;
    if (old != null) unawaited(_remove(old));
  }

  static Future<void> _remove(RealtimeChannel channel) async {
    try {
      await RoomService.unsubscribe(channel);
    } catch (_) {
      // Already gone with the socket; nothing to clean up.
    }
  }

  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _drop();
  }
}
