import 'dart:io';

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
}
