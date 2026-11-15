import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../constants.dart';
import '../network/connection_status.dart';
import '../supabase_config.dart';

/// Where a backend failure actually lives, from the user's point of view.
enum BackendHealth {
  /// No probe has run yet, or the last one was inconclusive (it timed out,
  /// or the connection broke mid-way): neither "your connection" nor "our
  /// servers" can be claimed.
  unknown,

  /// The backend's health endpoint answered.
  healthy,

  /// No working internet path: the device has no network, or the one it has
  /// can't reach the internet (DNS failing, the network unreachable, a Wi‑Fi
  /// sign-in page redirecting or intercepting the connection).
  offline,

  /// The backend itself answered with a server error while the internet path
  /// works — i.e. "the app is down", not the user's connection.
  serviceDown,
}

/// One health probe's verdict and a short reason, for diagnostics.
typedef HealthProbeResult = ({BackendHealth health, String detail});

/// App-wide backend reachability, one step deeper than [ConnectionStatus]:
/// it distinguishes "your Wi‑Fi is off / has no internet" from "our servers
/// are down" by probing the Supabase auth health endpoint and classifying
/// how it fails (see [classifyResponse] and [classifyError]).
///
/// UI listens to [status]; error paths call [check] before deciding what to
/// show the user. Probes are coalesced and cached briefly so a burst of
/// failures triggers a single health check. A connectivity change throws the
/// cache away, and a "down" or "no internet" verdict is re-checked in the
/// background so it clears itself on recovery.
class ServiceHealth {
  ServiceHealth._() {
    ConnectionStatus.instance.online.addListener(_onConnectivityChanged);
  }
  static final ServiceHealth instance = ServiceHealth._();

  final ValueNotifier<BackendHealth> status =
      ValueNotifier<BackendHealth>(BackendHealth.unknown);

  DateTime? _lastCheckAt;
  Future<BackendHealth>? _inFlight;
  Future<BackendHealth>? _forcedFollowUp;
  Timer? _recheckTimer;

  static const Duration _cacheWindow = Duration(seconds: 20);

  /// Timeouts: DNS + TCP + TLS to a CDN edge takes well under 2 s even on
  /// poor 3G, so 6 s to connect is generous; the endpoint itself is trivial,
  /// so 8 s for the reply. Together the user gets a verdict within ~15 s. A
  /// timeout is never read as "the service is down": it is as likely to be
  /// packet loss on the user's network, so it yields [BackendHealth.unknown].
  static const Duration _connectTimeout = Duration(seconds: 6);
  static const Duration _responseTimeout = Duration(seconds: 8);
  static const Duration _recheckInterval = Duration(seconds: 30);

  /// Enough to tell a JSON health reply from a sign-in page.
  static const int _maxProbeBody = 16 * 1024;

  /// Probes device connectivity, then the backend, and updates [status].
  ///
  /// Concurrent callers share one probe; results are reused for
  /// [_cacheWindow] unless [force] is true. A forced check that arrives
  /// while a probe is running gets a fresh probe after it, since the running
  /// one may have started before whatever prompted the forced check.
  Future<BackendHealth> check({bool force = false}) {
    final inFlight = _inFlight;
    if (inFlight != null) {
      if (!force) return inFlight;
      return _forcedFollowUp ??= inFlight.then((_) {
        _forcedFollowUp = null;
        return check(force: true);
      });
    }

    final last = _lastCheckAt;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < _cacheWindow &&
        status.value != BackendHealth.unknown) {
      return Future.value(status.value);
    }

    final future = _run().whenComplete(() => _inFlight = null);
    _inFlight = future;
    return future;
  }

  Future<BackendHealth> _run() async {
    final BackendHealth result;
    final online = await ConnectionStatus.instance.refresh();
    if (!online) {
      result = BackendHealth.offline;
    } else {
      result = (await _probeBackend()).health;
    }
    _lastCheckAt = DateTime.now();
    _setStatus(result);
    return result;
  }

  /// What we knew was about the previous network: drop it. Going offline is
  /// certain; coming back re-probes anything that wasn't healthy.
  void _onConnectivityChanged() {
    _lastCheckAt = null;
    if (!ConnectionStatus.instance.online.value) {
      _setStatus(BackendHealth.offline);
    } else if (status.value == BackendHealth.offline ||
        status.value == BackendHealth.serviceDown) {
      unawaited(check(force: true));
    }
  }

  /// Updates [status] and, while the service is down or the network has no
  /// internet, keeps re-probing in the background so the state clears itself
  /// on recovery (signing in to a Wi‑Fi portal flips no connectivity event).
  void _setStatus(BackendHealth next) {
    if (status.value != next) status.value = next;
    _recheckTimer?.cancel();
    _recheckTimer = null;
    final recheck = next == BackendHealth.serviceDown ||
        (next == BackendHealth.offline &&
            ConnectionStatus.instance.online.value);
    if (recheck) {
      _recheckTimer = Timer(_recheckInterval, () {
        unawaited(check(force: true));
      });
    }
  }

  static String _backendUrl() {
    try {
      return AppConstants.supabaseUrl;
    } catch (_) {
      // dotenv not loaded (tests, dart-define-only builds without the key).
      return '';
    }
  }

  static String _anonKey() {
    try {
      return AppConstants.supabaseAnonKey;
    } catch (_) {
      return '';
    }
  }

  Future<HealthProbeResult> _probeBackend() async {
    final base = _backendUrl();
    final uri = Uri.tryParse('$base/auth/v1/health');
    if (base.isEmpty || uri == null || uri.host.isEmpty) {
      return (health: BackendHealth.unknown, detail: 'backend not configured');
    }
    final client = HttpClient()..connectionTimeout = _connectTimeout;
    try {
      final request = await client
          .getUrl(uri)
          .timeout(_connectTimeout + const Duration(seconds: 1));
      // A redirect is evidence (a sign-in page), not something to follow.
      request.followRedirects = false;
      request.headers
        ..add('apikey', _anonKey())
        ..set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(_responseTimeout);
      final body = await _readCapped(response).timeout(_responseTimeout);
      return classifyResponse(statusCode: response.statusCode, body: body);
    } catch (e) {
      return classifyError(e);
    } finally {
      client.close(force: true);
    }
  }

  static Future<String> _readCapped(HttpClientResponse response) async {
    final bytes = <int>[];
    await for (final chunk in response) {
      final room = _maxProbeBody - bytes.length;
      bytes.addAll(room >= chunk.length ? chunk : chunk.sublist(0, room));
      if (bytes.length >= _maxProbeBody) break;
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// Reads a health-endpoint reply. Supabase answers with JSON; anything
  /// else came from something in between.
  ///
  /// * 3xx, 407, 511, or a 2xx that isn't JSON → [BackendHealth.offline]:
  ///   the hallmarks of a Wi‑Fi sign-in page or a proxy wanting a login.
  /// * Other 5xx → [BackendHealth.serviceDown]: our host was reached and
  ///   reported a server error — the one case where "it's not your
  ///   connection" is a claim we can make.
  /// * 2xx/4xx with JSON → [BackendHealth.healthy]: the backend answered.
  /// * 4xx that isn't JSON → [BackendHealth.unknown]: something answered,
  ///   but it's unclear whose fault the failure is.
  static HealthProbeResult classifyResponse({
    required int statusCode,
    required String body,
  }) {
    if (statusCode == 407 || statusCode == 511) {
      return (
        health: BackendHealth.offline,
        detail: 'HTTP $statusCode: this network wants you to sign in',
      );
    }
    if (statusCode >= 300 && statusCode < 400) {
      return (
        health: BackendHealth.offline,
        detail: 'HTTP $statusCode redirect: likely a Wi‑Fi sign-in page',
      );
    }
    if (statusCode >= 500) {
      return (
        health: BackendHealth.serviceDown,
        detail: 'HTTP $statusCode from the server',
      );
    }
    final json = _isJson(body);
    if (statusCode >= 200 && statusCode < 300) {
      return json
          ? (health: BackendHealth.healthy, detail: 'HTTP $statusCode')
          : (
              health: BackendHealth.offline,
              detail: 'HTTP $statusCode but not from the server: likely a '
                  'Wi‑Fi sign-in page',
            );
    }
    return json
        ? (health: BackendHealth.healthy, detail: 'HTTP $statusCode')
        : (
            health: BackendHealth.unknown,
            detail: 'HTTP $statusCode from something other than the server',
          );
  }

  static bool _isJson(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return false;
    try {
      final decoded = jsonDecode(trimmed);
      return decoded is Map || decoded is List;
    } catch (_) {
      return false;
    }
  }

  /// Reads a probe that failed before any reply.
  ///
  /// * DNS failure, network/host unreachable, connection refused, and a
  ///   failed TLS handshake (a sign-in page or filter intercepting HTTPS) →
  ///   [BackendHealth.offline]: the problem is on the way out of this
  ///   network.
  /// * Timeouts, resets and anything else → [BackendHealth.unknown].
  ///
  /// [darwin] picks the errno table (iOS/macOS number errors differently
  /// from Linux/Android).
  static HealthProbeResult classifyError(Object error, {bool? darwin}) {
    if (error is TlsException) {
      return (
        health: BackendHealth.offline,
        detail: 'secure connection failed: something on this network '
            'intercepted it (often a Wi‑Fi sign-in page)',
      );
    }
    if (error is TimeoutException) {
      return (health: BackendHealth.unknown, detail: 'timed out');
    }
    if (error is SocketException) {
      final isDarwin = darwin ?? (Platform.isIOS || Platform.isMacOS);
      final code = error.osError?.errorCode;
      final text =
          '${error.message} ${error.osError?.message ?? ''}'.toLowerCase();
      bool errno(int linux, int mac) => code == (isDarwin ? mac : linux);

      if (text.contains('failed host lookup') ||
          text.contains('no address associated') ||
          text.contains('nodename nor servname') ||
          text.contains('name or service not known')) {
        return (health: BackendHealth.offline, detail: 'DNS lookup failed');
      }
      if (errno(101, 51) || text.contains('network is unreachable')) {
        return (health: BackendHealth.offline, detail: 'network unreachable');
      }
      if (errno(113, 65) || text.contains('no route to host')) {
        return (health: BackendHealth.offline, detail: 'no route to host');
      }
      if (errno(111, 61) || text.contains('connection refused')) {
        return (
          health: BackendHealth.offline,
          detail: 'connection refused: blocked on this network',
        );
      }
      if (errno(110, 60) || text.contains('timed out')) {
        return (health: BackendHealth.unknown, detail: 'timed out');
      }
      return (health: BackendHealth.unknown, detail: 'network error');
    }
    return (health: BackendHealth.unknown, detail: 'probe failed');
  }

  /// Clears a stale "down" status after a backend call succeeds, without
  /// waiting for the next probe.
  void markHealthy() {
    _lastCheckAt = DateTime.now();
    _setStatus(BackendHealth.healthy);
  }

  /// Back to "nothing known", as at process start (used by the app reset).
  void resetForNewSession() {
    _recheckTimer?.cancel();
    _recheckTimer = null;
    _lastCheckAt = null;
    status.value = BackendHealth.unknown;
  }

  /// Redacts backend vendor/host details from user-visible diagnostics text:
  /// exception strings embed the project hostname, and users should only ever
  /// see "server", not which provider or project we run on.
  static String _sanitizeForUsers(String text) {
    var out = text;
    final host = Uri.tryParse(_backendUrl())?.host ?? '';
    if (host.isNotEmpty) {
      out = out.replaceAll(host, 'server');
      final projectRef = host.split('.').first;
      if (projectRef.isNotEmpty) out = out.replaceAll(projectRef, 'server');
    }
    return out.replaceAll(RegExp('supabase', caseSensitive: false), 'server');
  }

  /// Full step-by-step report (connectivity, DNS, health endpoint, session)
  /// for the "Run diagnostics" UI. Also refreshes [status] from what it
  /// found, with the same rules as [check].
  Future<String> runDiagnosticsReport() async {
    final lines = <String>[];

    try {
      final connectivity = await Connectivity().checkConnectivity();
      lines.add('Connectivity: ${connectivity.map((e) => e.name).join(", ")}');
    } catch (e) {
      lines.add('Connectivity check failed: $e');
    }

    final online = await ConnectionStatus.instance.refresh();
    if (!online) {
      lines.add('Server health endpoint: SKIPPED (no network on this device)');
      _lastCheckAt = DateTime.now();
      _setStatus(BackendHealth.offline);
      return _sanitizeForUsers(lines.join('\n'));
    }

    final host = Uri.tryParse(_backendUrl())?.host ?? '';
    if (host.isNotEmpty) {
      try {
        final lookup =
            await InternetAddress.lookup(host).timeout(_connectTimeout);
        lines.add(
          'DNS lookup: OK '
          '(${lookup.map((e) => e.address).toSet().join(", ")})',
        );
      } catch (e) {
        lines.add('DNS lookup: FAILED ($e)');
      }
    }

    final probe = await _probeBackend();
    lines.add('Server health endpoint: ${probe.detail} '
        '→ ${probe.health.name}');
    _lastCheckAt = DateTime.now();
    _setStatus(probe.health);

    if (SupabaseConfig.isInitialized) {
      try {
        await SupabaseConfig.ensureValidSession();
        lines.add('Session refresh check: OK');
      } catch (e) {
        lines.add('Session refresh check: FAILED ($e)');
      }
    } else {
      lines.add('Session refresh check: SKIPPED (backend not configured)');
    }

    return _sanitizeForUsers(lines.join('\n'));
  }
}
