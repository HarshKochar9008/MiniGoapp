import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'constants.dart';

Future<void> initSupabase() async {
  final url = AppConstants.supabaseUrl;
  final key = AppConstants.supabaseAnonKey;
  if (url.isEmpty || key.isEmpty) {
    throw StateError(
      'Missing Supabase config. Pass --dart-define=SUPABASE_URL=... '
      'and --dart-define=SUPABASE_ANON_KEY=...',
    );
  }

  final parsed = Uri.tryParse(url);
  final malformed = parsed == null ||
      url.contains(' ') ||
      parsed.scheme != 'https' ||
      parsed.host.isEmpty ||
      !parsed.host.endsWith('.supabase.co');
  if (malformed) {
    throw StateError(
      'Invalid SUPABASE_URL: "$url". '
      'Use format: https://<project-ref>.supabase.co '
      '(no spaces, exact project ref).',
    );
  }

  // Use the default platform HTTP client so Android 14+ uses the system
  // certificate store (OkHttp) rather than Dart's IOClient, which avoids
  // TLS handshake aborts on stricter Android TLS policies.
  await Supabase.initialize(
    url: url,
    anonKey: key,
  );
  SupabaseConfig._initialized = true;
}

class SupabaseConfig {
  static bool _initialized = false;

  static bool get isInitialized => _initialized;

  static SupabaseClient get client {
    if (!_initialized) {
      throw StateError(
        'Supabase is not initialized. Check that .env contains valid SUPABASE_URL and SUPABASE_ANON_KEY.',
      );
    }
    return Supabase.instance.client;
  }

  static StreamSubscription<AuthState>? _authSub;

  /// Listens for token-expired events and refreshes the session automatically.
  static void startAuthListener() {
    _authSub?.cancel();
    _authSub = client.auth.onAuthStateChange.listen((data) {
      if (data.event == AuthChangeEvent.tokenRefreshed) {
        // Token was refreshed — nothing to do, SDK handles it.
      }
    });
  }

  static void stopAuthListener() {
    _authSub?.cancel();
    _authSub = null;
  }

  /// Ensures we have a valid session, refreshing if needed.
  static Future<void> ensureValidSession() async {
    final session = client.auth.currentSession;
    if (session == null) return;

    final expiresAt = session.expiresAt;
    if (expiresAt == null) return;

    final expiryDate =
        DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000, isUtc: true);
    final now = DateTime.now().toUtc();

    // Refresh if token expires within 60 seconds
    if (expiryDate.difference(now).inSeconds < 60) {
      await client.auth
          .refreshSession()
          .timeout(const Duration(seconds: 18));
    }
  }
}
