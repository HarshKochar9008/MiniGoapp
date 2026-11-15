import 'dart:async';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Shared classification of transport-level failures for retry / offline queues.
class NetworkErrors {
  NetworkErrors._();

  /// Returns true for DNS, timeouts, broken pipes, and similar transient issues.
  static bool isRetryableFailure(Object error) {
    if (error is SocketException) return true;
    final s = error.toString().toLowerCase();
    return s.contains('socketexception') ||
        s.contains('failed host lookup') ||
        s.contains('connection timed out') ||
        s.contains('timed out') ||
        s.contains('timeoutexception') ||
        s.contains('authretryablefetchexception') ||
        s.contains('connection reset') ||
        s.contains('software caused connection abort') ||
        s.contains('network is unreachable') ||
        s.contains('connection refused') ||
        s.contains('clientexception') ||
        s.contains('handshake exception');
  }

  /// True when the backend answered with a 5xx: it's temporarily unable to
  /// serve, which says nothing about whether the request itself was valid.
  static bool isServerFailure(Object error) {
    if (error is PostgrestException) return _isServerStatus(error.code);
    if (error is AuthException) return _isServerStatus(error.statusCode);
    if (error is StorageException) return _isServerStatus(error.statusCode);
    return false;
  }

  /// A failure worth retrying later: the network or the server, not the
  /// request.
  static bool isTransient(Object error) =>
      error is TimeoutException ||
      isRetryableFailure(error) ||
      isServerFailure(error);

  static bool _isServerStatus(String? code) {
    final parsed = int.tryParse(code ?? '');
    return parsed != null && parsed >= 500;
  }
}
