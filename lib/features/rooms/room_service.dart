import 'package:supabase_flutter/supabase_flutter.dart'
    show
        PostgresChangeEvent,
        PostgresChangeFilter,
        PostgresChangeFilterType,
        PostgrestException,
        RealtimeChannel,
        RealtimeSubscribeStatus;

import '../../core/constants.dart';
import '../../core/network/network_errors.dart';
import '../../core/supabase_config.dart';
import '../../core/time/server_clock.dart';
import '../../core/utils/short_code_generator.dart';
import '../identity/identity_service.dart';

class Room {
  final String id;
  final String code;
  final String name;
  final String ownerId;
  final int memberCount;

  /// Display names (nickname or short code) of members, for avatar initials
  /// on the room card. Empty when not fetched (create/join paths).
  final List<String> memberNames;

  /// Rooms live for the lifetime chosen at creation (30 min, 1 h or 2 h);
  /// the server deletes them (and their files) once this passes.
  final DateTime expiresAt;

  const Room({
    required this.id,
    required this.code,
    required this.name,
    required this.ownerId,
    required this.expiresAt,
    this.memberCount = 0,
    this.memberNames = const [],
  });

  bool isOwnedBy(String userId) => ownerId == userId;

  /// Judged by server time ([ServerClock]): `expires_at` comes from the
  /// database clock, and that is the clock the server refuses joins and
  /// sends by.
  bool get isExpired => isExpiredAt(ServerClock.instance.now());

  Duration get timeLeft => timeLeftAt(ServerClock.instance.now());

  bool isExpiredAt(DateTime serverNow) =>
      !serverNow.toUtc().isBefore(expiresAt);

  Duration timeLeftAt(DateTime serverNow) {
    final left = expiresAt.difference(serverNow.toUtc());
    return left.isNegative ? Duration.zero : left;
  }

  static DateTime parseExpiry(Object? raw) {
    final parsed = DateTime.tryParse(raw?.toString() ?? '');
    // Missing/invalid expiry → treat as expired rather than immortal
    return (parsed ?? DateTime.fromMillisecondsSinceEpoch(0)).toUtc();
  }
}

class RoomMember {
  final String userId;
  final String shortCode;
  final String? nickname;

  /// Whether the host allows this member to share files (default on).
  final bool canShare;

  const RoomMember({
    required this.userId,
    required this.shortCode,
    this.nickname,
    this.canShare = true,
  });

  /// Falls back to the short code when the nickname is null OR blank —
  /// callers take `.characters.first` of this, which throws on ''.
  String get displayName {
    final nick = nickname?.trim();
    return (nick == null || nick.isEmpty) ? shortCode : nick;
  }

  RoomMember withCanShare(bool value) => RoomMember(
        userId: userId,
        shortCode: shortCode,
        nickname: nickname,
        canShare: value,
      );
}

class RoomFullException implements Exception {
  @override
  String toString() =>
      'This room is full (${AppConstants.maxRoomMembers} members max).';
}

class RoomNotFoundException implements Exception {
  final String code;
  const RoomNotFoundException(this.code);
  @override
  String toString() => 'No room found with code "$code".';
}

class RoomExpiredException implements Exception {
  @override
  String toString() => 'This room has expired.';
}

/// The room existed when its code was looked up but was gone by the time the
/// join reached it (the host closed it, or the expiry sweep removed it).
class RoomClosedException implements Exception {
  @override
  String toString() => 'This room is no longer available.';
}

/// `lookup_room_by_code` is metered per identity, so room codes can't be
/// enumerated.
class RoomLookupThrottledException implements Exception {
  @override
  String toString() =>
      'Too many room codes tried. Wait a few minutes and try again.';
}

/// Status callback for a room channel's `subscribe`.
typedef RealtimeStatusCallback = void Function(
    RealtimeSubscribeStatus status, Object? error);

/// Not the owner of this room (owner-only RPCs).
class RoomNotOwnerException implements Exception {
  @override
  String toString() => 'Only the host can do that.';
}

/// The person rejoined, so they're unblocked with the member switch instead.
class RoomMemberPresentException implements Exception {
  @override
  String toString() => 'They are back in the room — use their switch.';
}

/// The caller's relationship to a room, from `room_presence`.
enum RoomPresence {
  /// The room exists, hasn't expired, and the caller is a member.
  live,

  /// The room exists but is past `expires_at` (not swept yet).
  expired,

  /// The room exists and the caller is not in it (left or removed).
  notMember,

  /// The room row no longer exists (closed by the host, or swept).
  gone,
}

/// Someone the host blocked who has since left the room.
class RoomBlockedUser {
  final String userId;
  final String shortCode;
  final String? nickname;

  const RoomBlockedUser({
    required this.userId,
    required this.shortCode,
    this.nickname,
  });

  String get displayName {
    final nick = nickname?.trim();
    return (nick == null || nick.isEmpty) ? shortCode : nick;
  }
}

class RoomService {
  /// Whether [e] means the RPC isn't deployed yet (migration not applied):
  /// PostgREST's "function not found in schema cache", or Postgres's
  /// undefined_function.
  static bool isMissingRpc(Object e) =>
      e is PostgrestException && (e.code == 'PGRST202' || e.code == '42883');

  static Future<void> _ensureSession() async {
    try {
      await SupabaseConfig.ensureValidSession();
    } catch (e) {
      if (!NetworkErrors.isRetryableFailure(e)) rethrow;
    }
  }

  /// Server-time offset for expiry checks; measured once, never throws.
  static Future<void> _ensureServerTime() =>
      ServerClock.instance.ensureSynced();

  /// Creates a room with a fresh unique code and joins the owner to it.
  ///
  /// [lifetimeMinutes] must be one of
  /// [AppConstants.roomLifetimeMinutesOptions]; the server computes the
  /// actual `expires_at` from its own clock.
  static Future<Room> createRoom({
    required String ownerId,
    required String name,
    int lifetimeMinutes = AppConstants.defaultRoomLifetimeMinutes,
  }) async {
    await _ensureSession();
    await _ensureServerTime();
    const maxAttempts = 4;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final code = ShortCodeGenerator.generate();
      try {
        // One call, one transaction: the room and the owner's membership
        // commit together, so a dropped request can't leave a memberless
        // room nobody can see (20260930000001_create_room_atomic.sql).
        final row = Map<String, dynamic>.from(
          await SupabaseConfig.client.rpc('create_room', params: {
            'p_code': code,
            'p_name': name,
            'p_owner_id': ownerId,
            'p_lifetime_minutes': lifetimeMinutes,
          }) as Map,
        );
        return Room(
          id: row['id'] as String,
          code: row['code'] as String,
          name: row['name'] as String,
          ownerId: row['owner_id'] as String,
          expiresAt: Room.parseExpiry(row['expires_at']),
          memberCount: 1,
        );
      } on PostgrestException catch (e) {
        // Unique violation on code → regenerate and retry
        if (e.code == '23505' && attempt < maxAttempts - 1) continue;
        rethrow;
      }
    }
    throw StateError('createRoom: could not generate a unique room code');
  }

  /// Resolves [code] to its room without joining it, or null when no room
  /// has that code. Expired rooms are returned too (check [Room.isExpired]),
  /// so "expired" and "no such room" stay distinct.
  ///
  /// `rooms` SELECT is membership-scoped, so a code lookup cannot go through
  /// the table — it happens before membership exists. The narrow
  /// `lookup_room_by_code` RPC resolves exactly the columns a joiner needs
  /// (same pattern as `lookup_user_by_code` for recipients). It is metered
  /// per identity ([RoomLookupThrottledException]).
  static Future<Room?> lookupRoom(String code) async {
    await _ensureSession();
    await _ensureServerTime();
    final normalized = AppConstants.normalizeShortCode(code);
    final Object? rpcRows;
    try {
      rpcRows = await SupabaseConfig.client
          .rpc('lookup_room_by_code', params: {'p_code': normalized});
    } on PostgrestException catch (e) {
      if (e.message.contains('too many lookups')) {
        throw RoomLookupThrottledException();
      }
      rethrow;
    }
    final row = (rpcRows is List && rpcRows.isNotEmpty)
        ? Map<String, dynamic>.from(rpcRows.first as Map)
        : null;
    if (row == null) return null;
    return Room(
      id: row['id'] as String,
      code: row['code'] as String,
      name: row['name'] as String,
      ownerId: row['owner_id'] as String,
      expiresAt: Room.parseExpiry(row['expires_at']),
    );
  }

  /// Adds [userId] to an already resolved [room]. Succeeds silently if
  /// already a member.
  ///
  /// Expiry is the server's call: the join trigger refuses an expired room
  /// with 'room_expired' by its own clock, so no local pre-check can
  /// disagree with it.
  static Future<void> joinResolvedRoom({
    required Room room,
    required String userId,
  }) async {
    await _ensureSession();
    try {
      final me = IdentityService.identityNotifier.value;
      await SupabaseConfig.client.from('room_members').insert({
        'room_id': room.id,
        'user_id': userId,
        if (me?.shortCode != null) 'short_code': me!.shortCode,
        if (me?.nickname != null) 'nickname': me!.nickname,
      });
    } on PostgrestException catch (e) {
      if (e.message.contains('room_full')) throw RoomFullException();
      if (e.message.contains('room_expired')) throw RoomExpiredException();
      if (e.message.contains('room_not_found')) throw RoomClosedException();
      // Duplicate key → already a member, treat as success. Since
      // 20261113000003 the join trigger also reports a rejoin this way
      // before the member cap, so a member can reopen a full room.
      if (e.code != '23505') rethrow;
    }
  }

  /// Joins the room with [code]. Succeeds silently if already a member.
  static Future<Room> joinRoom({
    required String userId,
    required String code,
  }) async {
    final room = await lookupRoom(code);
    if (room == null) {
      throw RoomNotFoundException(AppConstants.normalizeShortCode(code));
    }
    await joinResolvedRoom(room: room, userId: userId);
    return room;
  }

  /// Leaving as owner disbands the room for everyone (cascade deletes members).
  static Future<void> leaveRoom({
    required Room room,
    required String userId,
  }) async {
    await _ensureSession();
    if (room.isOwnedBy(userId)) {
      await SupabaseConfig.client.from('rooms').delete().eq('id', room.id);
      return;
    }
    await SupabaseConfig.client
        .from('room_members')
        .delete()
        .eq('room_id', room.id)
        .eq('user_id', userId);
  }

  /// Rooms the user belongs to, with live member counts.
  static Future<List<Room>> listMyRooms(String userId) async {
    await _ensureSession();
    await _ensureServerTime();
    final memberships = await SupabaseConfig.client
        .from('room_members')
        .select('room_id')
        .eq('user_id', userId);
    final roomIds = memberships.map((row) => row['room_id'] as String).toList();
    if (roomIds.isEmpty) return const [];

    final rows = await SupabaseConfig.client
        .from('rooms')
        .select('id, code, name, owner_id, created_at, expires_at, '
            'room_members(short_code, nickname)')
        .inFilter('id', roomIds)
        .gt('expires_at', ServerClock.instance.now().toIso8601String())
        .order('created_at', ascending: false);
    return rows.map<Room>((row) {
      final members = (row['room_members'] as List?) ?? const [];
      final names = members
          .map((m) {
            final nick = (m['nickname'] as String?)?.trim();
            if (nick != null && nick.isNotEmpty) return nick;
            return (m['short_code'] as String?) ?? '';
          })
          .where((n) => n.isNotEmpty)
          .toList();
      return Room(
        id: row['id'] as String,
        code: row['code'] as String,
        name: row['name'] as String,
        ownerId: row['owner_id'] as String,
        expiresAt: Room.parseExpiry(row['expires_at']),
        memberCount: members.length,
        memberNames: names,
      );
    }).toList();
  }

  static Future<List<RoomMember>> listMembers(String roomId) async {
    await _ensureSession();
    // Prefer denormalized short_code/nickname on room_members; fall back to the
    // users join for rows created before the columns existed (that join now
    // returns null under owner-only RLS).
    final rows = await SupabaseConfig.client
        .from('room_members')
        .select(
            'user_id, joined_at, can_share, short_code, nickname, users(short_code, nickname)')
        .eq('room_id', roomId)
        .order('joined_at', ascending: true);
    return rows.map<RoomMember>((row) {
      final user = row['users'] as Map<String, dynamic>?;
      return RoomMember(
        userId: row['user_id'] as String,
        shortCode: (row['short_code'] as String?) ??
            (user?['short_code'] as String?) ??
            '??????',
        nickname:
            (row['nickname'] as String?) ?? (user?['nickname'] as String?),
        canShare: row['can_share'] as bool? ?? true,
      );
    }).toList();
  }

  /// Monotonic suffix so every subscription gets its own channel topic
  /// (same rationale as TransferService: shared topics die together).
  static int _channelSeq = 0;

  /// Live changes to the user's room list. RLS scopes INSERT/UPDATE events
  /// to rows the user can see; DELETE events can't be RLS-checked (the row is
  /// gone), so callers may also hear about other rooms' deletions — harmless,
  /// since they only trigger a reload. Payloads don't carry enough to patch
  /// the list locally — callers just reload on [onChange].
  ///
  /// [onStatus] receives the channel's subscription status (see
  /// RoomRealtimeLink, which resubscribes and resyncs on it).
  static RealtimeChannel? subscribeToMyRooms({
    required String userId,
    required void Function() onChange,
    RealtimeStatusCallback? onStatus,
  }) {
    try {
      final channel =
          SupabaseConfig.client.channel('my-rooms-$userId-${++_channelSeq}');
      channel.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'room_members',
        callback: (_) => onChange(),
      );
      channel.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'rooms',
        callback: (_) => onChange(),
      );
      channel.subscribe(onStatus);
      return channel;
    } catch (_) {
      return null;
    }
  }

  /// Live updates for one room: members joining/leaving/permission changes,
  /// plus [onRoomDeleted] when the room is disbanded while open.
  static RealtimeChannel? subscribeToRoom({
    required String roomId,
    required void Function() onMembersChanged,
    void Function()? onRoomDeleted,
    RealtimeStatusCallback? onStatus,
  }) {
    try {
      final channel =
          SupabaseConfig.client.channel('room-$roomId-${++_channelSeq}');
      channel.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'room_members',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'room_id',
          value: roomId,
        ),
        callback: (_) => onMembersChanged(),
      );
      channel.onPostgresChanges(
        event: PostgresChangeEvent.delete,
        schema: 'public',
        table: 'rooms',
        callback: (payload) {
          // Delete events can't be column-filtered; match on the old row's PK.
          if ((payload.oldRecord['id'] ?? '').toString() == roomId) {
            onRoomDeleted?.call();
          }
        },
      );
      channel.subscribe(onStatus);
      return channel;
    } catch (_) {
      return null;
    }
  }

  static Future<void> unsubscribe(RealtimeChannel channel) async {
    await SupabaseConfig.client.removeChannel(channel);
  }

  /// Host-only (enforced by RLS): allow or block a member from sharing files.
  static Future<void> setMemberCanShare({
    required String roomId,
    required String userId,
    required bool canShare,
  }) async {
    await _ensureSession();
    final List<dynamic> rows;
    try {
      rows = await SupabaseConfig.client
          .from('room_members')
          .update({'can_share': canShare})
          .eq('room_id', roomId)
          .eq('user_id', userId)
          .select('user_id');
    } on PostgrestException catch (e) {
      // 20261113000003: the switch is frozen once the room has expired.
      if (e.message.contains('room_expired')) throw RoomExpiredException();
      rethrow;
    }
    // RLS turns a disallowed update into "0 rows", not an error — without
    // this the switch shows a change the server never made.
    if (rows.isEmpty) {
      throw StateError('setMemberCanShare: no row updated');
    }
  }

  /// The caller's relationship to [roomId], or null when `room_presence` isn't
  /// deployed (20261113000005 not applied). Other failures throw.
  static Future<RoomPresence?> roomPresence(String roomId) async {
    await _ensureSession();
    try {
      final raw = await SupabaseConfig.client
          .rpc('room_presence', params: {'p_room_id': roomId});
      switch (raw?.toString()) {
        case 'live':
          return RoomPresence.live;
        case 'expired':
          return RoomPresence.expired;
        case 'not_member':
          return RoomPresence.notMember;
        case 'gone':
          return RoomPresence.gone;
      }
      throw StateError('room_presence: unexpected answer $raw');
    } catch (e) {
      if (isMissingRpc(e)) return null;
      rethrow;
    }
  }

  /// Host-only: people blocked in [roomId] who have since left it. Null when
  /// `list_room_blocks` isn't deployed yet.
  static Future<List<RoomBlockedUser>?> listBlockedUsers(String roomId) async {
    await _ensureSession();
    final Object? rows;
    try {
      rows = await SupabaseConfig.client
          .rpc('list_room_blocks', params: {'p_room_id': roomId});
    } catch (e) {
      if (isMissingRpc(e)) return null;
      throw _mapOwnerRpcError(e);
    }
    if (rows is! List) return const [];
    return [
      for (final raw in rows)
        if (raw is Map && raw['user_id'] != null)
          RoomBlockedUser(
            userId: raw['user_id'].toString(),
            shortCode: (raw['short_code'] as String?) ?? '??????',
            nickname: raw['nickname'] as String?,
          ),
    ];
  }

  /// Host-only: lifts the block on someone who left [roomId], so they can
  /// share again if they rejoin. A current member is unblocked with
  /// [setMemberCanShare] instead ([RoomMemberPresentException]).
  static Future<void> unblockUser({
    required String roomId,
    required String userId,
  }) async {
    await _ensureSession();
    try {
      await SupabaseConfig.client.rpc('unblock_room_user', params: {
        'p_room_id': roomId,
        'p_user_id': userId,
      });
    } catch (e) {
      throw _mapOwnerRpcError(e);
    }
  }

  static Object _mapOwnerRpcError(Object e) {
    if (e is PostgrestException) {
      if (e.message.contains('room_expired')) return RoomExpiredException();
      if (e.message.contains('room_not_owner')) return RoomNotOwnerException();
      if (e.message.contains('room_member_present')) {
        return RoomMemberPresentException();
      }
    }
    return e;
  }

  /// Every member's E2E public key, keyed by user id (null value: that
  /// member published none), from one `room_member_public_keys` call. Null
  /// when the RPC isn't deployed yet — callers fall back to per-member
  /// lookups. Refusals ('room_not_member', 'room_expired') and network
  /// failures throw.
  static Future<List<Map<String, dynamic>>?> memberPublicKeyRows(
      String roomId) async {
    await _ensureSession();
    try {
      final rows = await SupabaseConfig.client
          .rpc('room_member_public_keys', params: {'p_room_id': roomId});
      if (rows is! List) return const [];
      return [
        for (final r in rows)
          if (r is Map) Map<String, dynamic>.from(r),
      ];
    } catch (e) {
      if (isMissingRpc(e)) return null;
      rethrow;
    }
  }
}
