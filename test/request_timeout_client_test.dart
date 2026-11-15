import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:minigo/core/network/network_errors.dart';
import 'package:minigo/core/network/request_timeout_client.dart';

/// Answers each request with whatever the test hands it.
class _ScriptedClient extends http.BaseClient {
  _ScriptedClient(this._respond);

  final Future<http.StreamedResponse> Function(http.BaseRequest) _respond;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _respond(request);

  @override
  void close() => closed = true;
}

void main() {
  final rest = Uri.parse('https://ref.supabase.co/rest/v1/rooms?id=eq.secret');
  final storage =
      Uri.parse('https://ref.supabase.co/storage/v1/object/transfers/a/b');

  // Real timers, kept short: the production limit is 30 s.
  const limit = Duration(milliseconds: 200);
  RequestTimeoutClient clientFor(
    Future<http.StreamedResponse> Function(http.BaseRequest) respond,
  ) =>
      RequestTimeoutClient(_ScriptedClient(respond), timeout: limit);

  test('a request that is never answered fails instead of hanging', () async {
    final client = clientFor((_) => Completer<http.StreamedResponse>().future);

    Object? error;
    try {
      await client.get(rest);
    } catch (e) {
      error = e;
    }

    expect(error, isA<TimeoutException>());
    // What the offline queues and error screens key off.
    expect(NetworkErrors.isRetryableFailure(error!), isTrue);
    // The path and query hold ids; only the host may be reported.
    expect(error.toString(), isNot(contains('secret')));
    expect(error.toString(), contains('ref.supabase.co'));
  });

  test('a body that stalls part-way fails instead of hanging', () async {
    final body = StreamController<List<int>>();
    addTearDown(body.close);
    final client =
        clientFor((_) async => http.StreamedResponse(body.stream, 200));

    final pending = client.get(rest);
    body.add([1, 2, 3]);

    await expectLater(
      pending,
      throwsA(isA<TimeoutException>()
          .having((e) => e.message, 'message', contains('stalled'))),
    );
  });

  test('a slow but steady response still arrives whole', () async {
    final body = StreamController<List<int>>();
    final client = clientFor((_) async => http.StreamedResponse(
          body.stream,
          201,
          headers: {'x-test': 'yes'},
          reasonPhrase: 'Created',
        ));

    final pending = client.get(rest);
    // Three chunks, each inside the limit; past it in total.
    for (final chunk in ['a', 'b', 'c']) {
      await Future<void>.delayed(limit * 0.5);
      body.add(chunk.codeUnits);
    }
    await body.close();
    final response = await pending;

    expect(response.statusCode, 201);
    expect(response.body, 'abc');
    expect(response.headers['x-test'], 'yes');
    expect(response.reasonPhrase, 'Created');
  });

  test('file transfers are not cut off', () async {
    final answer = Completer<http.StreamedResponse>();
    final client = clientFor((_) => answer.future);

    final pending = client.get(storage);
    await Future<void>.delayed(limit * 3);
    answer.complete(http.StreamedResponse(Stream.value([7]), 200));

    expect((await pending).bodyBytes, [7]);
  });

  test('closing closes the wrapped client', () {
    final inner = _ScriptedClient((_) async => throw StateError('unused'));
    RequestTimeoutClient(inner).close();
    expect(inner.closed, isTrue);
  });
}
