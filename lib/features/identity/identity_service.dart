import 'dart:async';
import 'dart:convert';

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

/// How far this process trusts the identity [IdentityService] hands out.
enum IdentityTrust {
  /// No identity: none created yet, or the last one was dropped.
  none,

  /// Read from this device's storage because the server couldn't be reached.
  /// Its row may since have been retired, or the session replaced, so nothing
  /// that writes to the server on its behalf should run until it's verified.
  provisional,

  /// Checked against the server in this process: the row exists, belongs to
  /// the current session, and isn't retired.
  verified,
}

/// Thrown by [IdentityService.initialize] while an app reset is under way.
class IdentityResetInProgressException implements Exception {
  const IdentityResetInProgressException();

  @override
  String toString() => 'The app is resetting.';
}

/// The device's anonymous identity: Supabase anonymous auth uid + its `users`
/// row (id, short code), mirrored into SharedPreferences.
///
/// Lifecycle (see [IdentityTrust]):
/// * A verified identity is kept for the rest of the process; [initialize]
///   returns it without another server round trip.
/// * Otherwise [initialize] checks the session and the row. If the server
///   can't be reached (network failure or 5xx) and the saved identity belongs
///   to the current session, it hands that out as provisional; callers ask
///   again later to verify it. Any other failure drops it.
/// * A changed auth uid means the old identity is gone: its row is queued for
///   retirement (a persisted job, retried until the server confirms), its
///   key is deleted, and a new identity is created.
/// * A retired row (account deleted, or swept as stale) is never adopted:
///   the session is dropped and a fresh identity is created.
class IdentityService {
  IdentityService._();

  static const _maxCodeAttempts = 10;

  /// Old anonymous auth uids whose `users` row still has to be retired.
  /// Survives a full app reset, which is what an offline reset relies on.
  static const pendingRetirementsKey = 'pending_identity_retirements_v1';

  /// A nickname edit that hasn't reached the server yet, as
  /// `{"id": userId, "nickname": value-or-null}`. While it's set, the local
  /// nickname wins over the server's on the next verified start.
  static const pendingNicknameKey = 'pending_nickname_sync_v1';

  /// A nickname typed before this device had any identity (onboarding's
  /// "Continue without a code"). The first identity adopted without a
  /// nickname of its own takes it; any adopted identity clears it.
  static const firstNicknameKey = 'pending_first_nickname_v1';

  /// Past this, a queued retirement is dropped: the server's stale-identity
  /// sweep has retired the row by then anyway (90 days without a session).
  static const _retirementJobMaxAge = Duration(days: 120);
  static const _maxRetirementJobs = 8;

  static UserIdentity? _cached;
  static IdentityTrust _trust = IdentityTrust.none;

  /// Fires whenever the current identity changes (startup, verification,
  /// nickname edit, replacement, reset). UI that holds an identity snapshot
  /// listens to stay in sync; [trust] has already been updated when it fires.
  static final ValueNotifier<UserIdentity?> identityNotifier =
      ValueNotifier<UserIdentity?>(null);

  static IdentityTrust get trust => _trust;
  static bool get isVerified =>
      _trust == IdentityTrust.verified && _cached != null;

  static Future<UserIdentity>? _initInFlight;

  /// Bumped by [beginReset]: a startup that began before the reset must not
  /// write its result into the freshly cleared storage.
  static int _epoch = 0;
  static bool _resetting = false;

  static bool get isResetting => _resetting;

  static UserIdentity? _publish(UserIdentity? identity, IdentityTrust trust) {
    _cached = identity;
    _trust = identity == null ? IdentityTrust.none : trust;
    identityNotifier.value = identity;
    return identity;
  }

  /// Returns the verified identity, or works one out (see the class doc).
  ///
  /// Overlapping callers (startup auto-retry, onboarding Retry, the shell's
  /// re-verification) share one attempt. Their `.timeout()`s don't cancel it,
  /// and on a first launch two concurrent attempts would each sign in
  /// anonymously and end up with two different accounts.
  static Future<UserIdentity> initialize() {
    if (_resetting) {
      return Future.error(const IdentityResetInProgressException());
    }
    final cached = _cached;
    if (cached != null && _trust == IdentityTrust.verified) {
      return Future.value(cached);
    }
    final inFlight = _initInFlight;
    if (inFlight != null) return inFlight;
    late final Future<UserIdentity> attempt;
    attempt = _initialize(_epoch).whenComplete(() {
      if (identical(_initInFlight, attempt)) _initInFlight = null;
    });
    _initInFlight = attempt;
    return attempt;
  }

  static void _ensureEpoch(int epoch) {
    if (epoch != _epoch) throw const IdentityResetInProgressException();
  }

  static Future<UserIdentity> _initialize(int epoch) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = identityFromPrefs(prefs);

    // Two passes at most: the second only after dropping a retired identity,
    // and a brand-new anonymous user can't have a retired row.
    for (var pass = 0; pass < 2; pass++) {
      final Session session;
      try {
        session = await _ensureSession();
      } catch (e) {
        _ensureEpoch(epoch);
        if (pass == 0 && saved != null && NetworkErrors.isTransient(e)) {
          return _publish(saved, IdentityTrust.provisional)!;
        }
        _publish(null, IdentityTrust.none);
        rethrow;
      }
      _ensureEpoch(epoch);
      final authUid = session.user.id;
      final savedAuthUid = prefs.getString(AppConstants.prefAuthUid);

      // The auth identity changed: the old one can't be signed back into, so
      // its code must stop resolving for senders. Retirement is a persisted
      // job, so it survives being offline right now.
      if (savedAuthUid != null && savedAuthUid != authUid) {
        _publish(null, IdentityTrust.none);
        await queueRetirement(savedAuthUid);
        await _clearStoredIdentity(prefs);
        unawaited(_clearLocalKey(savedAuthUid));
      }
      unawaited(flushPendingRetirements());

      // Ensure this device has an E2E key pair and publish its public key.
      final publicKey = await _localPublicKey(authUid);
      _ensureEpoch(epoch);

      final Map<String, dynamic>? existing;
      try {
        existing = await _findUserByAuthUid(authUid);
      } catch (e) {
        _ensureEpoch(epoch);
        final ownSaved = savedAuthUid == authUid ? saved : null;
        if (ownSaved != null && NetworkErrors.isTransient(e)) {
          return _publish(ownSaved, IdentityTrust.provisional)!;
        }
        _publish(null, IdentityTrust.none);
        rethrow;
      }
      _ensureEpoch(epoch);

      if (existing != null && _isRetired(existing)) {
        await _abandonRetiredIdentity(prefs, authUid);
        _ensureEpoch(epoch);
        continue;
      }

      final Map<String, dynamic> row;
      if (existing != null) {
        row = existing;
      } else {
        // First launch for this auth identity, or its row is missing.
        try {
          row = await _createUserRow(authUid, publicKey);
        } catch (e) {
          _ensureEpoch(epoch);
          _publish(null, IdentityTrust.none);
          rethrow;
        }
        _ensureEpoch(epoch);
        if (_isRetired(row)) {
          await _abandonRetiredIdentity(prefs, authUid);
          _ensureEpoch(epoch);
          continue;
        }
      }
      return _adopt(prefs, row, authUid, publicKey, epoch);
    }
    _publish(null, IdentityTrust.none);
    throw AuthFailedException(
      'Could not set up your account right now. '
      'Please try again in a few minutes.',
    );
  }

  /// Makes [row] the verified identity. A nickname edit the server hasn't
  /// seen yet wins over the row's value and is pushed now.
  static Future<UserIdentity> _adopt(
    SharedPreferences prefs,
    Map<String, dynamic> row,
    String authUid,
    String? publicKey,
    int epoch,
  ) async {
    var identity = _identityFromDbRow(row);
    final pending = await takePendingNickname(prefs, identity);
    if (pending != null) {
      identity = UserIdentity(
        id: identity.id,
        shortCode: identity.shortCode,
        nickname: pending.nickname,
      );
      unawaited(_pushNickname(identity.id, pending.nickname));
    }
    await _syncPublicKey(
      userId: identity.id,
      stored: row['public_key'] as String?,
      local: publicKey,
    );
    _ensureEpoch(epoch);
    await _persistIdentity(prefs: prefs, identity: identity, authUid: authUid);
    return _publish(identity, IdentityTrust.verified)!;
  }

  static bool _isRetired(Map<String, dynamic> row) => row['deleted_at'] != null;

  /// This auth identity's row was retired (account deleted, or swept as
  /// stale). Nothing may act for it again — in particular no FCM token may
  /// be written back onto it — so drop the session and start over.
  static Future<void> _abandonRetiredIdentity(
    SharedPreferences prefs,
    String authUid,
  ) async {
    _publish(null, IdentityTrust.none);
    await _clearStoredIdentity(prefs);
    await prefs.remove(pendingNicknameKey);
    unawaited(_clearLocalKey(authUid));
    try {
      await SupabaseConfig.client.auth
          .signOut(scope: SignOutScope.local)
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // signOut drops the local session before its network call, so the
      // next _ensureSession() signs in fresh either way.
    }
  }

  static Future<Map<String, dynamic>> _createUserRow(
    String authUid,
    String? publicKey,
  ) async {
    for (var attempt = 0; attempt < _maxCodeAttempts; attempt++) {
      final code = ShortCodeGenerator.generate();
      try {
        return await SupabaseConfig.client
            .from('users')
            .insert({
              'auth_uid': authUid,
              'short_code': code,
              if (publicKey != null) 'public_key': publicKey,
            })
            .select(_userColumns)
            .single()
            .timeout(const Duration(seconds: 20));
      } on PostgrestException catch (e) {
        final isDuplicate = e.code == '23505';
        if (!isDuplicate) rethrow;

        // If duplicate came from existing auth_uid row (race/previous partial
        // setup), recover that identity instead of generating a new mapping.
        final existing = await _findUserByAuthUid(authUid);
        if (existing != null) return existing;
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

  /// Forgets the in-memory identity (storage is left alone).
  static void clearCache() => _publish(null, IdentityTrust.none);

  /// Called by the app reset once it's past the point of no return: drops
  /// the identity, makes any startup still running discard its result, and
  /// refuses [initialize] until [endReset].
  static void beginReset() {
    _resetting = true;
    _epoch++;
    _initInFlight = null;
    _publish(null, IdentityTrust.none);
  }

  static void endReset() => _resetting = false;

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
        // initialize() sees the auth uid change and retires the old one.
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

  // ── Retiring replaced identities ──────────────────────────────────────────

  /// Queues [oldAuthUid]'s row for retirement. The `retire_previous_identity`
  /// RPC accepts any signed-in caller that knows the old (anonymous) auth
  /// uid — knowing it is the proof of ownership — so a later identity on
  /// this device can finish the job.
  static Future<void> queueRetirement(String oldAuthUid) async {
    if (oldAuthUid.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final jobs = _loadRetirements(prefs)
      ..removeWhere((j) => j.uid == oldAuthUid)
      ..add((uid: oldAuthUid, since: DateTime.now()));
    await _saveRetirements(prefs, jobs);
  }

  /// Auth uids still waiting to be retired, oldest first.
  static Future<List<String>> pendingRetirements() async {
    final prefs = await SharedPreferences.getInstance();
    return [for (final j in _loadRetirements(prefs)) j.uid];
  }

  static Future<void>? _flushInFlight;

  /// Retires every queued old identity it can. Safe to call often: a no-op
  /// without a session or without queued work. Stops at the first network
  /// failure; the rest wait for the next call.
  static Future<void> flushPendingRetirements() {
    return _flushInFlight ??=
        _flushRetirements().whenComplete(() => _flushInFlight = null);
  }

  static Future<void> _flushRetirements() async {
    if (!SupabaseConfig.isInitialized) return;
    final currentUid = SupabaseConfig.client.auth.currentUser?.id;
    if (currentUid == null) return;
    final prefs = await SharedPreferences.getInstance();
    final jobs = _loadRetirements(prefs);
    if (jobs.isEmpty) return;

    final done = <String>{};
    for (final job in jobs) {
      // Still signed in as it (a reset whose sign-out didn't stick): the
      // identity was kept, so there is nothing to retire.
      if (job.uid == currentUid) {
        done.add(job.uid);
        continue;
      }
      try {
        await SupabaseConfig.client.rpc('retire_previous_identity', params: {
          'p_old_auth_uid': job.uid,
        }).timeout(const Duration(seconds: 10));
        done.add(job.uid);
      } catch (e) {
        if (kDebugMode) debugPrint('retire_previous_identity failed: $e');
        if (NetworkErrors.isTransient(e)) break;
      }
    }
    if (done.isEmpty) return;
    // Re-read: a job queued while this ran must survive the write.
    final latest = _loadRetirements(prefs)
      ..removeWhere((j) => done.contains(j.uid));
    await _saveRetirements(prefs, latest);
  }

  static List<({String uid, DateTime since})> _loadRetirements(
    SharedPreferences prefs,
  ) {
    final raw = prefs.getString(pendingRetirementsKey);
    if (raw == null || raw.isEmpty) return [];
    final cutoff = DateTime.now().subtract(_retirementJobMaxAge);
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return [
        for (final item in decoded)
          if (item is Map &&
              item['uid'] is String &&
              (item['uid'] as String).isNotEmpty)
            (
              uid: item['uid'] as String,
              since: DateTime.fromMillisecondsSinceEpoch(
                (item['since'] as num?)?.toInt() ?? 0,
              ),
            ),
      ]..removeWhere((j) => j.since.isBefore(cutoff));
    } catch (_) {
      return [];
    }
  }

  static Future<void> _saveRetirements(
    SharedPreferences prefs,
    List<({String uid, DateTime since})> jobs,
  ) async {
    if (jobs.isEmpty) {
      await prefs.remove(pendingRetirementsKey);
      return;
    }
    final kept = jobs.length > _maxRetirementJobs
        ? jobs.sublist(jobs.length - _maxRetirementJobs)
        : jobs;
    await prefs.setString(
      pendingRetirementsKey,
      jsonEncode([
        for (final j in kept)
          {'uid': j.uid, 'since': j.since.millisecondsSinceEpoch},
      ]),
    );
  }

  static Future<void> _clearLocalKey(String authUid) async {
    try {
      await E2ECrypto.clearLocalKey(authUid);
    } catch (e) {
      if (kDebugMode) debugPrint('E2E key cleanup failed: $e');
    }
  }

  // ── Server rows ───────────────────────────────────────────────────────────

  static const _userColumns =
      'id, short_code, auth_uid, nickname, public_key, deleted_at';

  static UserIdentity _identityFromDbRow(Map<String, dynamic> row) {
    // Normalize blank nicknames to null so UI code that shows
    // `nickname ?? fallback` (or takes `.characters.first`) never
    // receives an empty string.
    return UserIdentity(
      id: row['id'] as String,
      shortCode: row['short_code'] as String,
      nickname: _cleanNickname(row['nickname'] as String?),
    );
  }

  static String? _cleanNickname(String? raw) {
    final trimmed = raw?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  static Future<Map<String, dynamic>?> _findUserByAuthUid(
      String authUid) async {
    await SupabaseConfig.ensureValidSession();
    return await SupabaseConfig.client
        .from('users')
        .select(_userColumns)
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

  // ── Local storage ─────────────────────────────────────────────────────────

  /// Writes all identity keys in one go: each setter updates the in-memory
  /// store as it's called, so no other code can observe a mix of old and new
  /// values. A crash can still leave a partial set on disk, which
  /// [identityFromPrefs] refuses.
  static Future<void> _persistIdentity({
    required SharedPreferences prefs,
    required UserIdentity identity,
    required String authUid,
  }) async {
    final nickname = identity.nickname;
    await Future.wait([
      prefs.setString(AppConstants.prefAuthUid, authUid),
      prefs.setString(AppConstants.prefUserDbId, identity.id),
      prefs.setString(AppConstants.prefShortCode, identity.shortCode),
      if (nickname != null)
        prefs.setString(AppConstants.prefNickname, nickname)
      else
        prefs.remove(AppConstants.prefNickname),
    ]);
  }

  static Future<void> _clearStoredIdentity(SharedPreferences prefs) async {
    await Future.wait([
      prefs.remove(AppConstants.prefShortCode),
      prefs.remove(AppConstants.prefUserDbId),
      prefs.remove(AppConstants.prefAuthUid),
      prefs.remove(AppConstants.prefNickname),
    ]);
  }

  /// The identity saved on this device, or null unless the row id, short
  /// code and owning auth uid are all present: a partial set (a crash
  /// mid-write) can't be tied to a session, so it's treated as no identity.
  @visibleForTesting
  static UserIdentity? identityFromPrefs(SharedPreferences prefs) {
    final id = prefs.getString(AppConstants.prefUserDbId);
    final shortCode = prefs.getString(AppConstants.prefShortCode);
    final authUid = prefs.getString(AppConstants.prefAuthUid);
    if (id == null ||
        id.isEmpty ||
        shortCode == null ||
        shortCode.isEmpty ||
        authUid == null ||
        authUid.isEmpty) {
      return null;
    }
    return UserIdentity(
      id: id,
      shortCode: shortCode,
      nickname: _cleanNickname(prefs.getString(AppConstants.prefNickname)),
    );
  }

  // ── Nickname ──────────────────────────────────────────────────────────────

  /// Sets the nickname locally right away and on the server when it can. An
  /// edit the server didn't get is remembered, and pushed (rather than
  /// overwritten by the server's old value) on the next verified start.
  static Future<void> setNickname(String? nickname) async {
    final prefs = await SharedPreferences.getInstance();
    final current = _cached ?? await initialize();
    final cleaned = _cleanNickname(nickname);
    final updated = UserIdentity(
      id: current.id,
      shortCode: current.shortCode,
      nickname: cleaned,
    );

    _publish(updated, _trust);
    await Future.wait([
      if (cleaned != null)
        prefs.setString(AppConstants.prefNickname, cleaned)
      else
        prefs.remove(AppConstants.prefNickname),
      prefs.setString(
        pendingNicknameKey,
        jsonEncode({'id': current.id, 'nickname': cleaned}),
      ),
    ]);
    await _pushNickname(current.id, cleaned);
  }

  /// Sends a nickname to the server and, if that edit is still the latest
  /// one queued, marks it delivered.
  static Future<void> _pushNickname(String userId, String? nickname) async {
    try {
      await SupabaseConfig.ensureValidSession();
      await SupabaseConfig.client
          .from('users')
          .update({'nickname': nickname})
          .eq('id', userId)
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      // Stays queued; local is the source of truth until it lands.
      if (kDebugMode) debugPrint('nickname sync failed: $e');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final pending = _readPendingNickname(prefs, userId);
    if (pending != null && pending.nickname == nickname) {
      await prefs.remove(pendingNicknameKey);
    }
  }

  /// Remembers [nickname] for the identity this device doesn't have yet. It
  /// is pushed like any queued edit once that identity is created.
  static Future<void> setNicknameForFirstIdentity(String? nickname) async {
    final prefs = await SharedPreferences.getInstance();
    final cleaned = _cleanNickname(nickname);
    if (cleaned == null) {
      await prefs.remove(firstNicknameKey);
    } else {
      await prefs.setString(firstNicknameKey, cleaned);
    }
  }

  /// The nickname that should win over [identity]'s server value, if any: an
  /// edit queued for this identity, or else a name typed before the device
  /// had any identity, when this one has no nickname of its own. The latter
  /// is re-queued as an ordinary edit, so a failed push is retried.
  @visibleForTesting
  static Future<({String? nickname})?> takePendingNickname(
    SharedPreferences prefs,
    UserIdentity identity,
  ) async {
    final queued = _readPendingNickname(prefs, identity.id);
    final first = _cleanNickname(prefs.getString(firstNicknameKey));
    if (prefs.containsKey(firstNicknameKey)) {
      await prefs.remove(firstNicknameKey);
    }
    if (queued != null) return queued;
    if (first == null || identity.nickname != null) return null;
    await prefs.setString(
      pendingNicknameKey,
      jsonEncode({'id': identity.id, 'nickname': first}),
    );
    return (nickname: first);
  }

  /// The queued nickname edit for [userId], or null if there's none (an
  /// edit queued for a different identity doesn't count).
  static ({String? nickname})? _readPendingNickname(
    SharedPreferences prefs,
    String userId,
  ) {
    final raw = prefs.getString(pendingNicknameKey);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['id'] != userId) return null;
      return (nickname: _cleanNickname(decoded['nickname'] as String?));
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  static void debugSetIdentity(UserIdentity? identity, IdentityTrust trust) {
    _publish(identity, trust);
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
