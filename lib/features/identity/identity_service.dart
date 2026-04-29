import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants.dart';
import '../../core/network/network_errors.dart';
import '../../core/supabase_config.dart';
import '../../core/utils/short_code_generator.dart';

class UserIdentity {
  final String id;
  final String shortCode;

  const UserIdentity({required this.id, required this.shortCode});
}

class IdentityService {
  static UserIdentity? _cached;
  static const _maxCodeAttempts = 10;

  static Future<UserIdentity> initialize() async {
    if (_cached != null) return _cached!;

    final prefs = await SharedPreferences.getInstance();
    final cachedIdentity = _identityFromPrefs(prefs);
    if (cachedIdentity != null) {
      _cached = cachedIdentity;
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

    // If auth identity changed, clear stale local mappings immediately.
    if (savedAuthUid != null && savedAuthUid != authUid) {
      await _clearStoredIdentity(prefs);
    }

    final existingByAuth = await _findUserByAuthUid(authUid);
    if (existingByAuth != null) {
      final identity = _identityFromDbRow(existingByAuth);
      await _persistIdentity(
        prefs: prefs,
        identity: identity,
        authUid: authUid,
      );
      _cached = identity;
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
        _cached = identity;
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
          _cached = identity;
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
        return await SupabaseConfig.client
            .from('users')
            .select('id, short_code')
            .eq('short_code', normalized)
            .maybeSingle()
            .timeout(const Duration(seconds: 22));
      } catch (e) {
        final last = attempt == maxAttempts - 1;
        if (!NetworkErrors.isRetryableFailure(e) || last) rethrow;
      }
    }
    throw StateError('findUserByCode: unreachable');
  }

  static void clearCache() => _cached = null;

  static Future<Session> _ensureSession() async {
    final current = SupabaseConfig.client.auth.currentSession;
    if (current != null) {
      try {
        await SupabaseConfig.ensureValidSession();
      } catch (e) {
        // If refresh fails due transient network issues, keep current cached
        // session so startup can continue and UI can recover gracefully.
        if (!NetworkErrors.isRetryableFailure(e)) rethrow;
        return current;
      }

      final refreshed = SupabaseConfig.client.auth.currentSession;
      if (refreshed != null) return refreshed;
      return current;
    }

    final authResponse = await SupabaseConfig.client.auth
        .signInAnonymously()
        .timeout(const Duration(seconds: 25));
    final user = authResponse.user;
    final session = authResponse.session ?? SupabaseConfig.client.auth.currentSession;
    if (user == null) {
      throw AuthFailedException(
        'Anonymous sign-in failed. '
        'Ensure anonymous auth is enabled in Supabase Dashboard '
        '→ Auth → Settings.',
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

  static UserIdentity _identityFromDbRow(Map<String, dynamic> row) {
    return UserIdentity(
      id: row['id'] as String,
      shortCode: row['short_code'] as String,
    );
  }

  static Future<Map<String, dynamic>?> _findUserByAuthUid(String authUid) async {
    await SupabaseConfig.ensureValidSession();
    return await SupabaseConfig.client
        .from('users')
        .select('id, short_code, auth_uid')
        .eq('auth_uid', authUid)
        .maybeSingle()
        .timeout(const Duration(seconds: 20));
  }

  static Future<void> _persistIdentity({
    required SharedPreferences prefs,
    required UserIdentity identity,
    required String authUid,
  }) async {
    await prefs.setString(AppConstants.prefShortCode, identity.shortCode);
    await prefs.setString(AppConstants.prefUserDbId, identity.id);
    await prefs.setString(AppConstants.prefAuthUid, authUid);
  }

  static Future<void> _clearStoredIdentity(SharedPreferences prefs) async {
    await prefs.remove(AppConstants.prefShortCode);
    await prefs.remove(AppConstants.prefUserDbId);
    await prefs.remove(AppConstants.prefAuthUid);
  }

  static UserIdentity? _identityFromPrefs(SharedPreferences prefs) {
    final id = prefs.getString(AppConstants.prefUserDbId);
    final shortCode = prefs.getString(AppConstants.prefShortCode);
    if (id == null || id.isEmpty || shortCode == null || shortCode.isEmpty) {
      return null;
    }
    return UserIdentity(id: id, shortCode: shortCode);
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
