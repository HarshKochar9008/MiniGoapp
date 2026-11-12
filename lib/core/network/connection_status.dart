import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// App-wide connectivity derived from [Connectivity].
///
/// This is a coarse signal (Wi‑Fi vs none); it does not prove Supabase is reachable.
/// Used for UI badges, preflight checks, and scheduling offline retry work.
class ConnectionStatus {
  ConnectionStatus._();
  static final ConnectionStatus instance = ConnectionStatus._();

  final ValueNotifier<bool> online = ValueNotifier<bool>(true);

  StreamSubscription<List<ConnectivityResult>>? _subscription;
  bool _started = false;

  void ensureStarted() {
    if (_started) return;
    _started = true;
    unawaited(refresh());
    _subscription =
        Connectivity().onConnectivityChanged.listen((_) => refresh());
  }

  /// Stops listening. Normally kept for app lifetime; tests may call [dispose].
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    _started = false;
  }

  /// Updates [online] from the platform and returns whether a path is present.
  Future<bool> refresh() async {
    try {
      final result = await Connectivity().checkConnectivity();
      final next = !result.contains(ConnectivityResult.none);
      if (online.value != next) {
        online.value = next;
      }
      return next;
    } catch (_) {
      if (!online.value) {
        online.value = true;
      }
      return online.value;
    }
  }

  /// Whether data is likely billed by the byte (mobile data), so a large
  /// transfer should ask first. A guess: a hotspot looks like Wi‑Fi.
  Future<bool> isLikelyMetered() async {
    try {
      final result = await Connectivity().checkConnectivity();
      return result.contains(ConnectivityResult.mobile);
    } catch (_) {
      return false;
    }
  }
}
