import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minigo/core/errors/service_health.dart';

/// "It's not your connection" is only claimed when the backend itself
/// answered with a server error; everything a Wi‑Fi sign-in page or a dead
/// network produces must read as "no internet", and anything ambiguous as
/// "unknown".
void main() {
  BackendHealth response(int status, String body) =>
      ServiceHealth.classifyResponse(statusCode: status, body: body).health;

  BackendHealth error(Object e, {bool darwin = false}) =>
      ServiceHealth.classifyError(e, darwin: darwin).health;

  group('health replies', () {
    test('a JSON reply means the backend answered', () {
      expect(response(200, '{"name":"GoTrue","version":"v2"}'),
          BackendHealth.healthy);
      expect(response(401, '{"message":"Invalid API key"}'),
          BackendHealth.healthy);
    });

    test('a sign-in page is no internet, not an outage', () {
      expect(response(200, '<html><body>Welcome to Cafe Wi‑Fi</body></html>'),
          BackendHealth.offline);
      expect(response(200, ''), BackendHealth.offline);
      expect(response(302, ''), BackendHealth.offline);
      expect(response(307, '<html></html>'), BackendHealth.offline);
      expect(response(511, '<html>Log in</html>'), BackendHealth.offline);
      expect(response(407, ''), BackendHealth.offline);
    });

    test('only a server error is an outage', () {
      expect(response(500, '{"message":"oops"}'), BackendHealth.serviceDown);
      expect(response(503, '<html>Service Unavailable</html>'),
          BackendHealth.serviceDown);
      expect(response(522, ''), BackendHealth.serviceDown);
    });

    test('a non-JSON 4xx is inconclusive', () {
      expect(
          response(403, '<html>Access denied</html>'), BackendHealth.unknown);
    });
  });

  group('probe failures', () {
    test('DNS failure is no internet', () {
      expect(
        error(const SocketException(
          "Failed host lookup: 'abc.supabase.co'",
          osError: OSError('No address associated with hostname', 7),
        )),
        BackendHealth.offline,
      );
      expect(
        error(
          const SocketException(
            "Failed host lookup: 'abc.supabase.co'",
            osError: OSError('nodename nor servname provided, or not known', 8),
          ),
          darwin: true,
        ),
        BackendHealth.offline,
      );
    });

    test('an unreachable network is no internet, on either errno table', () {
      expect(
        error(const SocketException('Connection failed',
            osError: OSError('', 101))),
        BackendHealth.offline,
      );
      expect(
        error(
          const SocketException('Connection failed', osError: OSError('', 51)),
          darwin: true,
        ),
        BackendHealth.offline,
      );
      expect(
        error(const SocketException('No route to host')),
        BackendHealth.offline,
      );
      expect(
        error(const SocketException('Connection refused',
            osError: OSError('Connection refused', 111))),
        BackendHealth.offline,
      );
    });

    test('an intercepted TLS handshake is no internet', () {
      expect(error(const HandshakeException('CERTIFICATE_VERIFY_FAILED')),
          BackendHealth.offline);
    });

    test('timeouts and resets are inconclusive, never an outage', () {
      expect(error(TimeoutException('probe')), BackendHealth.unknown);
      expect(
        error(const SocketException('Connection timed out',
            osError: OSError('', 110))),
        BackendHealth.unknown,
      );
      expect(
        error(const SocketException('Connection reset by peer',
            osError: OSError('', 104))),
        BackendHealth.unknown,
      );
      expect(error(StateError('anything else')), BackendHealth.unknown);
    });

    test('errno numbers are read from the right platform table', () {
      // 51 is ENETUNREACH on Darwin but means nothing network-ish on Linux.
      expect(
        error(const SocketException('x', osError: OSError('', 51))),
        BackendHealth.unknown,
      );
    });
  });
}
