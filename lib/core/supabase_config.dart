import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'constants.dart';
import 'network/request_timeout_client.dart';

Future<void>? _initSupabaseInFlight;

/// Initializes the Supabase client and starts the auth listener. Safe to call
/// from several places (startup, the shell's Retry, onboarding): concurrent
/// callers share one attempt, and a failed attempt can be retried.
Future<void> initSupabase() {
  if (SupabaseConfig._initialized) return Future.value();
  return _initSupabaseInFlight ??=
      _initSupabase().whenComplete(() => _initSupabaseInFlight = null);
}

Future<void> _initSupabase() async {
  final url = AppConstants.supabaseUrl;
  final key = AppConstants.supabaseAnonKey;
  if (url.isEmpty || key.isEmpty) {
    throw StateError(
      'Missing backend config. Pass --dart-define=SUPABASE_URL=... '
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

  await Supabase.initialize(
    url: url,
    // The same client the SDK would create itself, with a ceiling on how
    // long a request may go unanswered (see RequestTimeoutClient).
    httpClient: RequestTimeoutClient(http.Client()),
    // Same key, new parameter name: the SDK does publishableKey ?? anonKey.
    publishableKey: key,
    // Auth is anonymous-only, so no link is ever an auth callback. Left on,
    // any deep link carrying a `code` param — minigo://send?code=ABC234 from
    // a camera QR scan — was treated as a PKCE exchange that always fails.
    authOptions: const FlutterAuthClientOptions(detectSessionInUri: false),
  );
  SupabaseConfig._initialized = true;
  // Right away, not after other startup work: failed background refreshes
  // arrive on the auth stream and must have a handler (see below).
  SupabaseConfig.startAuthListener();
}

class SupabaseConfig {
  static bool _initialized = false;

  static bool get isInitialized => _initialized;

  static SupabaseClient get client {
    if (!_initialized) {
      // Developer-facing only — UI layers must catch this and show generic
      // "could not start" copy, never this text.
      throw StateError(
        'Backend client is not initialized. Check that .env contains valid '
        'SUPABASE_URL and SUPABASE_ANON_KEY.',
      );
    }
    return Supabase.instance.client;
  }

  static StreamSubscription<AuthState>? _authSub;

  /// Listens for token-expired events and refreshes the session automatically.
  static void startAuthListener() {
    _authSub?.cancel();
    _authSub = client.auth.onAuthStateChange.listen(
      (data) {
        if (data.event == AuthChangeEvent.tokenRefreshed) {
          // Token was refreshed — nothing to do, SDK handles it.
        }
      },
      // gotrue reports failed background refreshes (e.g. offline near token
      // expiry, every ~10 s) on this stream. Unhandled, each one reached
      // PlatformDispatcher.onError and was logged to Crashlytics as fatal.
      // The callers that need a session handle refresh failures themselves.
      onError: (Object _, StackTrace __) {},
    );
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
      await client.auth.refreshSession().timeout(const Duration(seconds: 18));
    }
  }
}
