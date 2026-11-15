import 'dart:async';

import 'package:http/http.dart' as http;

/// Bounds how long a backend request may sit without an answer.
///
/// The SDK's REST, RPC, auth and edge-function calls have no timeout of their
/// own, so on a stalled connection (captive portal, dead Wi‑Fi that still
/// reports "connected") they waited on the OS socket timeout — minutes — and
/// every spinner that awaited one never stopped. This fails them with a
/// [TimeoutException] instead, which the app already treats as a retryable
/// network failure (see NetworkErrors).
///
/// Storage requests are left alone: a file body can legitimately take far
/// longer than [timeout], and those paths watch for stalls themselves.
class RequestTimeoutClient extends http.BaseClient {
  RequestTimeoutClient(
    this._inner, {
    this.timeout = const Duration(seconds: 30),
  });

  final http.Client _inner;

  /// The longest wait for response headers, and between chunks of the body.
  final Duration timeout;

  /// Whether [url] is a short request/response call, as opposed to a file
  /// transfer.
  static bool appliesTo(Uri url) => !url.path.contains('/storage/v1/');

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!appliesTo(request.url)) return _inner.send(request);

    // Host only: paths and queries carry ids and filters.
    final host = request.url.host;
    final response = await _inner.send(request).timeout(
          timeout,
          onTimeout: () => throw TimeoutException(
            'No response from $host',
            timeout,
          ),
        );
    final body = response.stream.timeout(
      timeout,
      onTimeout: (sink) {
        sink.addError(
          TimeoutException('Response from $host stalled', timeout),
        );
        sink.close();
      },
    );
    return http.StreamedResponse(
      body,
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() => _inner.close();
}
