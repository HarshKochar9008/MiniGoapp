import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../constants.dart';
import '../network/connection_status.dart';
import '../supabase_config.dart';

/// Where a backend failure actually lives, from the user's point of view.
enum BackendHealth {
  /// No probe has run yet this session.
  unknown,

  /// Device online and the Supabase health endpoint answered.
  healthy,

  /// The device itself has no network path.
  offline,

  /// Device is online but our backend is unreachable or returning 5xx —
  /// i.e. "the app is down", not the user's connection.
  serviceDown,
}

/// App-wide backend reachability, one step deeper than [ConnectionStatus]:
/// it distinguishes "your Wi‑Fi is off" from "our servers are down" by
/// probing the Supabase auth health endpoint.
///
/// UI listens to [status]; error paths call [check] before deciding what to
/// show the user. Probes are coalesced and cached briefly so a burst of
/// failures triggers a single health check.
class ServiceHealth {
  ServiceHealth._();
  static final ServiceHealth instance = ServiceHealth._();

  final ValueNotifier<BackendHealth> status =
      ValueNotifier<BackendHealth>(BackendHealth.unknown);

  DateTime? _lastCheckAt;
  Future<BackendHealth>? _inFlight;
  Timer? _recheckTimer;

  static const Duration _cacheWindow = Duration(seconds: 20);
  static const Duration _probeTimeout = Duration(seconds: 8);
  static const Duration _recheckInterval = Duration(seconds: 30);

  /// Probes device connectivity, then the backend, and updates [status].
  ///
  /// Concurrent callers share one probe; results are reused for
  /// [_cacheWindow] unless [force] is true.
  Future<BackendHealth> check({bool force = false}) {
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;

    final last = _lastCheckAt;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < _cacheWindow &&
        status.value != BackendHealth.unknown) {
      return Future.value(status.value);
    }

    final future = _run();
    _inFlight = future;
    return future.whenComplete(() => _inFlight = null);
  }

  Future<BackendHealth> _run() async {
    BackendHealth result;
    final online = await ConnectionStatus.instance.refresh();
    if (!online) {
      result = BackendHealth.offline;
    } else {
      result = await _probeBackend();
    }
    _lastCheckAt = DateTime.now();
    _setStatus(result);
    return result;
  }

  /// Updates [status] and, while the service is down, keeps re-probing in the
  /// background so the "service issues" state clears itself on recovery.
  void _setStatus(BackendHealth next) {
    if (status.value != next) status.value = next;
    _recheckTimer?.cancel();
    if (next == BackendHealth.serviceDown) {
      _recheckTimer = Timer(_recheckInterval, () {
        unawaited(check(force: true));
      });
    }
  }

  Future<BackendHealth> _probeBackend() async {
    final client = HttpClient()..connectionTimeout = _probeTimeout;
    try {
      final request = await client
          .getUrl(Uri.parse('${AppConstants.supabaseUrl}/auth/v1/health'))
          .timeout(_probeTimeout);
      request.headers.add('apikey', AppConstants.supabaseAnonKey);
      final response = await request.close().timeout(_probeTimeout);
      return response.statusCode >= 500
          ? BackendHealth.serviceDown
          : BackendHealth.healthy;
    } catch (_) {
      // Device reports a network path but our host is unreachable.
      return BackendHealth.serviceDown;
    } finally {
      client.close(force: true);
    }
  }

  /// Clears a stale "down" status after a backend call succeeds, without
  /// waiting for the next probe.
  void markHealthy() {
    _lastCheckAt = DateTime.now();
    _setStatus(BackendHealth.healthy);
  }

  /// Redacts backend vendor/host details from user-visible diagnostics text:
  /// exception strings embed the project hostname, and users should only ever
  /// see "server", not which provider or project we run on.
  static String _sanitizeForUsers(String text) {
    var out = text;
    final host = Uri.tryParse(AppConstants.supabaseUrl)?.host ?? '';
    if (host.isNotEmpty) {
      out = out.replaceAll(host, 'server');
      final projectRef = host.split('.').first;
      if (projectRef.isNotEmpty) out = out.replaceAll(projectRef, 'server');
    }
    return out.replaceAll(RegExp('supabase', caseSensitive: false), 'server');
  }

  /// Full step-by-step report (connectivity, DNS, health endpoint, session)
  /// for the "Run diagnostics" UI. Also refreshes [status] from the health
  /// endpoint result so the banner reflects what the report found.
  Future<String> runDiagnosticsReport() async {
    final lines = <String>[];

    try {
      final connectivity = await Connectivity().checkConnectivity();
      lines.add('Connectivity: ${connectivity.map((e) => e.name).join(", ")}');
    } catch (e) {
      lines.add('Connectivity check failed: $e');
    }

    final host = Uri.parse(AppConstants.supabaseUrl).host;
    try {
      final lookup = await InternetAddress.lookup(host);
      lines.add(
        'DNS lookup: OK (${lookup.map((e) => e.address).toSet().join(", ")})',
      );
    } catch (e) {
      lines.add('DNS lookup: FAILED ($e)');
    }

    final client = HttpClient()..connectionTimeout = _probeTimeout;
    try {
      final request = await client
          .getUrl(Uri.parse('${AppConstants.supabaseUrl}/auth/v1/health'));
      request.headers.add('apikey', AppConstants.supabaseAnonKey);
      final response = await request.close();
      lines.add('Server health endpoint: HTTP ${response.statusCode}');
      _lastCheckAt = DateTime.now();
      _setStatus(response.statusCode >= 500
          ? BackendHealth.serviceDown
          : BackendHealth.healthy);
    } catch (e) {
      lines.add('Server health endpoint: FAILED ($e)');
      _lastCheckAt = DateTime.now();
      _setStatus(BackendHealth.serviceDown);
    } finally {
      client.close(force: true);
    }

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
