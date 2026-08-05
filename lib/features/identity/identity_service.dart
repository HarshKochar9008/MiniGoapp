import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants.dart';
import '../../core/crypto/e2e_crypto.dart';
import '../../core/network/network_errors.dart';
import '../../core/supabase_config.dart';
import '../../core/utils/short_code_generator.dart';

class UserIdentity {
  final String id;
  final String shortCode;
  final String? nickname;

  const UserIdentity({
    required this.id,
    required this.shortCode,
    this.nickname,
  });
}

class IdentityService {
  static UserIdentity? _cached;
  static const _maxCodeAttempts = 10;

  /// Fires whenever the current identity changes (startup, nickname edit,
  /// reset). UI that holds an identity snapshot listens to stay in sync.
  static final ValueNotifier<UserIdentity?> identityNotifier =
      ValueNotifier<UserIdentity?>(null);

  static void _setCached(UserIdentity? identity) {
    _cached = identity;
    identityNotifier.value = identity;
  }

  static Future<UserIdentity> initialize() async {
    if (_cached != null) return _cached!;

    final prefs = await SharedPreferences.getInstance();
    final cachedIdentity = _identityFromPrefs(prefs);
    if (cachedIdentity != null) {
      _setCached(cachedIdentity);
    }

    Session session;
    try {
      session = await _ensureSession();
    } catch (e) {
      if (cachedIdentity != null && NetworkErrors.isRetryableFailure(e)) {
        return cachedIdentity;
      }
      rethrow;
    }
    final authUid = session.user.id;
    final savedAuthUid = prefs.getString(AppConstants.prefAuthUid);

    // If auth identity changed, retire the old server row (its code must stop
    // resolving for senders) and clear stale local mappings immediately.
    if (savedAuthUid != null && savedAuthUid != authUid) {
      unawaited(_retirePreviousIdentity(savedAuthUid));
      await _clearStoredIdentity(prefs);
    }

    // Ensure this device has an E2E key pair and publish its public key.
    final publicKey = await _localPublicKey(authUid);

    final existingByAuth = await _findUserByAuthUid(authUid);
    if (existingByAuth != null) {
      final identity = _identityFromDbRow(existingByAuth);
      await _persistIdentity(
        prefs: prefs,
        identity: identity,
        authUid: authUid,
      );
      await _syncPublicKey(
        userId: identity.id,
        stored: existingByAuth['public_key'] as String?,
        local: publicKey,
      );
      _setCached(identity);
      return identity;
    }

    // First launch for this auth identity, or user row missing.
    for (var attempt = 0; attempt < _maxCodeAttempts; attempt++) {
      final code = ShortCodeGenerator.generate();
      try {
        final dbUser = await SupabaseConfig.client
            .from('users')
            .insert({
              'auth_uid': authUid,
              'short_code': code,
              if (publicKey != null) 'public_key': publicKey,
            })
            .select()
            .single()
            .timeout(const Duration(seconds: 20));

        final identity = _identityFromDbRow(dbUser);
        await _persistIdentity(
          prefs: prefs,
          identity: identity,
          authUid: authUid,
        );
        _setCached(identity);
        return identity;
      } on PostgrestException catch (e) {
        final isDuplicate = e.code == '23505';
        if (!isDuplicate) rethrow;

        // If duplicate came from existing auth_uid row (race/previous partial setup),
        // recover that identity instead of generating a new local mapping.
        final existing = await _findUserByAuthUid(authUid);
        if (existing != null) {
          final identity = _identityFromDbRow(existing);
          await _persistIdentity(
            prefs: prefs,
            identity: identity,
            authUid: authUid,
          );
          await _syncPublicKey(
            userId: identity.id,
            stored: existing['public_key'] as String?,
            local: publicKey,
          );
          _setCached(identity);
          return identity;
        }
        if (attempt == _maxCodeAttempts - 1) rethrow;
      }
    }

    throw CodeGenerationException(
      'Could not generate a unique short code after $_maxCodeAttempts '
      'attempts. Please restart the app.',
    );
  }

  /// Resolves a recipient by short code. Returns `{id, short_code, public_key}`
  /// or null if no such user. Uses the `lookup_user_by_code` RPC so the caller
  /// never reads the full `users` table (RLS restricts direct reads to self).
  static Future<Map<String, dynamic>?> findUserByCode(String code) async {
    const maxAttempts = 4;
    final normalized = AppConstants.normalizeShortCode(code);

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(
          Duration(milliseconds: 400 * (1 << (attempt - 1))),
        );
      }
      try {
        try {
          await SupabaseConfig.ensureValidSession();
        } catch (e) {
          if (!NetworkErrors.isRetryableFailure(e)) rethrow;
        }
        final rows = await SupabaseConfig.client
            .rpc('lookup_user_by_code', params: {'p_code': normalized}).timeout(
                const Duration(seconds: 22));
        if (rows is List && rows.isNotEmpty) {
          return Map<String, dynamic>.from(rows.first as Map);
        }
        return null;
      } catch (e) {
        final last = attempt == maxAttempts - 1;
        if (!NetworkErrors.isRetryableFailure(e) || last) rethrow;
      }
    }
    throw StateError('findUserByCode: unreachable');
  }

  static void clearCache() => _setCached(null);

  static Future<Session> _ensureSession() async {
    final current = SupabaseConfig.client.auth.currentSession;
    if (current != null) {
      try {
        await SupabaseConfig.ensureValidSession();
        final refreshed = SupabaseConfig.client.auth.currentSession;
        return refreshed ?? current;
      } catch (e) {
        // If refresh fails due transient network issues, keep current cached
        // session so startup can continue and UI can recover gracefully.
        if (NetworkErrors.isRetryableFailure(e)) return current;
        if (e is! AuthException) rethrow;
        // The stored session is permanently dead — refresh token revoked or
        // the anonymous auth user deleted server-side. Retrying can never
        // succeed, so drop it and register a fresh anonymous identity below;
        // initialize() sees the auth uid change and clears stale local state.
        try {
          await SupabaseConfig.client.auth
              .signOut(scope: SignOutScope.local)
              .timeout(const Duration(seconds: 10));
        } catch (_) {
          // Best-effort: signInAnonymously() below replaces any leftover
          // local session anyway.
        }
      }
    }

    final authResponse = await SupabaseConfig.client.auth
        .signInAnonymously()
        .timeout(const Duration(seconds: 25));
    final user = authResponse.user;
    final session =
        authResponse.session ?? SupabaseConfig.client.auth.currentSession;
    if (user == null) {
      // Dev hint stays in the console only: anonymous auth must be enabled
      // in the backend dashboard (Auth → Settings).
      if (kDebugMode) {
        debugPrint('Anonymous sign-in returned no user — is anonymous auth '
            'enabled in the Supabase dashboard?');
      }
      throw AuthFailedException(
        'Could not set up your account right now. '
        'Please try again in a few minutes.',
      );
    }
    if (session == null) {
      throw AuthFailedException(
        'Anonymous sign-in completed without an active session. '
        'Please restart the app.',
      );
    }
    return session;
  }

  /// Soft-retires the `users` row of a replaced anonymous identity so its
  /// short code stops resolving for senders (same scrub as the in-app reset).
  /// Best-effort: must never block or fail startup — the row is also swept by
  /// the server-side stale-identity cleanup if this call is lost.
  static Future<void> _retirePreviousIdentity(String oldAuthUid) async {
    try {
      await SupabaseConfig.client.rpc('retire_previous_identity', params: {
        'p_old_auth_uid': oldAuthUid
      }).timeout(const Duration(seconds: 10));
    } catch (e) {
      if (kDebugMode) debugPrint('retire_previous_identity failed: $e');
    }
  }

  static UserIdentity _identityFromDbRow(Map<String, dynamic> row) {
    // Normalize blank nicknames to null so UI code that shows
    // `nickname ?? fallback` (or takes `.characters.first`) never
    // receives an empty string.
    final rawNick = (row['nickname'] as String?)?.trim();
    return UserIdentity(
      id: row['id'] as String,
      shortCode: row['short_code'] as String,
      nickname: (rawNick == null || rawNick.isEmpty) ? null : rawNick,
    );
  }

  static Future<Map<String, dynamic>?> _findUserByAuthUid(
      String authUid) async {
    await SupabaseConfig.ensureValidSession();
    return await SupabaseConfig.client
        .from('users')
        .select('id, short_code, auth_uid, nickname, public_key')
        .eq('auth_uid', authUid)
        .maybeSingle()
        .timeout(const Duration(seconds: 20));
  }

  /// This device's base64url X25519 public key, or null if key generation
  /// fails (encryption then degrades to plaintext for this session).
  static Future<String?> _localPublicKey(String authUid) async {
    try {
      return await E2ECrypto.ensureLocalPublicKey(authUid);
    } catch (e) {
      if (kDebugMode) debugPrint('E2E key generation failed: $e');
      return null;
    }
  }

  /// Publishes [local] to `users.public_key` when it differs from [stored].
  /// Best-effort: a network failure here never blocks startup.
  static Future<void> _syncPublicKey({
    required String userId,
    required String? stored,
    required String? local,
  }) async {
    if (local == null || local.isEmpty || stored == local) return;
    try {
      await SupabaseConfig.ensureValidSession();
      await SupabaseConfig.client
          .from('users')
          .update({'public_key': local})
          .eq('id', userId)
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      if (kDebugMode) debugPrint('public_key sync failed: $e');
    }
  }

  static Future<void> _persistIdentity({
    required SharedPreferences prefs,
    required UserIdentity identity,
    required String authUid,
  }) async {
    await prefs.setString(AppConstants.prefShortCode, identity.shortCode);
    await prefs.setString(AppConstants.prefUserDbId, identity.id);
    await prefs.setString(AppConstants.prefAuthUid, authUid);
    if (identity.nickname != null) {
      await prefs.setString(AppConstants.prefNickname, identity.nickname!);
    } else {
      await prefs.remove(AppConstants.prefNickname);
    }
  }

  static Future<void> _clearStoredIdentity(SharedPreferences prefs) async {
    await prefs.remove(AppConstants.prefShortCode);
    await prefs.remove(AppConstants.prefUserDbId);
    await prefs.remove(AppConstants.prefAuthUid);
    await prefs.remove(AppConstants.prefNickname);
  }

  static UserIdentity? _identityFromPrefs(SharedPreferences prefs) {
    final id = prefs.getString(AppConstants.prefUserDbId);
    final shortCode = prefs.getString(AppConstants.prefShortCode);
    final nickname = prefs.getString(AppConstants.prefNickname);
    if (id == null || id.isEmpty || shortCode == null || shortCode.isEmpty) {
      return null;
    }
    return UserIdentity(id: id, shortCode: shortCode, nickname: nickname);
  }

  // New methods to handle nickname
  static Future<void> setNickname(String? nickname) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await initialize();
    final updated = UserIdentity(
      id: current.id,
      shortCode: current.shortCode,
      nickname: nickname,
    );

    // Update local cache and prefs first
    _setCached(updated);
    await _persistIdentity(
      prefs: prefs,
      identity: updated,
      authUid: prefs.getString(AppConstants.prefAuthUid)!,
    );

    // Also update database if possible
    try {
      await SupabaseConfig.ensureValidSession();
      await SupabaseConfig.client
          .from('users')
          .update({'nickname': nickname})
          .eq('id', current.id)
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      // Ignore network errors - local is source of truth
    }
  }

  static Stream<UserIdentity> watchIdentity() async* {
    yield await initialize();
    // For now, just yield once; could add real-time later
  }
}

class AuthFailedException implements Exception {
  final String message;
  AuthFailedException(this.message);
  @override
  String toString() => message;
}

class CodeGenerationException implements Exception {
  final String message;
  CodeGenerationException(this.message);
  @override
  String toString() => message;
}
