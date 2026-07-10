import 'package:supabase_flutter/supabase_flutter.dart'
    show
        PostgresChangeEvent,
        PostgresChangeFilter,
        PostgresChangeFilterType,
        PostgrestException,
        RealtimeChannel;

import '../../core/constants.dart';
import '../../core/network/network_errors.dart';
import '../../core/supabase_config.dart';
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

  /// Rooms live 1 hour; the server deletes them (and their files) afterwards.
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

  bool get isExpired => !DateTime.now().toUtc().isBefore(expiresAt);

  Duration get timeLeft {
    final left = expiresAt.difference(DateTime.now().toUtc());
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

class RoomService {
  static Future<void> _ensureSession() async {
    try {
      await SupabaseConfig.ensureValidSession();
    } catch (e) {
      if (!NetworkErrors.isRetryableFailure(e)) rethrow;
    }
  }

  /// Creates a room with a fresh unique code and joins the owner to it.
  static Future<Room> createRoom({
    required String ownerId,
    required String name,
  }) async {
    await _ensureSession();
    const maxAttempts = 4;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final code = ShortCodeGenerator.generate();
      try {
        final row = await SupabaseConfig.client
            .from('rooms')
            .insert({'code': code, 'name': name, 'owner_id': ownerId})
            .select('id, code, name, owner_id, expires_at')
            .single();
        final room = Room(
          id: row['id'] as String,
          code: row['code'] as String,
          name: row['name'] as String,
          ownerId: row['owner_id'] as String,
          expiresAt: Room.parseExpiry(row['expires_at']),
          memberCount: 1,
        );
        final me = IdentityService.identityNotifier.value;
        await SupabaseConfig.client.from('room_members').insert({
          'room_id': room.id,
          'user_id': ownerId,
          if (me?.shortCode != null) 'short_code': me!.shortCode,
          if (me?.nickname != null) 'nickname': me!.nickname,
        });
        return room;
      } on PostgrestException catch (e) {
        // Unique violation on code → regenerate and retry
        if (e.code == '23505' && attempt < maxAttempts - 1) continue;
        rethrow;
      }
    }
    throw StateError('createRoom: could not generate a unique room code');
  }

  /// Joins the room with [code]. Succeeds silently if already a member.
  static Future<Room> joinRoom({
    required String userId,
    required String code,
  }) async {
    await _ensureSession();
    final normalized = AppConstants.normalizeShortCode(code);
    final row = await SupabaseConfig.client
        .from('rooms')
        .select('id, code, name, owner_id, expires_at')
        .eq('code', normalized)
        .maybeSingle();
    if (row == null) throw RoomNotFoundException(normalized);

    final room = Room(
      id: row['id'] as String,
      code: row['code'] as String,
      name: row['name'] as String,
      ownerId: row['owner_id'] as String,
      expiresAt: Room.parseExpiry(row['expires_at']),
    );
    if (room.isExpired) throw RoomExpiredException();

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
      // Duplicate key → already a member, treat as success
      if (e.code != '23505') rethrow;
    }
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
    final memberships = await SupabaseConfig.client
        .from('room_members')
        .select('room_id')
        .eq('user_id', userId);
    final roomIds = memberships
        .map((row) => row['room_id'] as String)
        .toList();
    if (roomIds.isEmpty) return const [];

    final rows = await SupabaseConfig.client
        .from('rooms')
        .select('id, code, name, owner_id, created_at, expires_at, '
            'room_members(short_code, nickname)')
        .inFilter('id', roomIds)
        .gt('expires_at', DateTime.now().toUtc().toIso8601String())
        .order('created_at', ascending: false);
    return rows.map<Room>((row) {
      final members = (row['room_members'] as List?) ?? const [];
      final names = members.map((m) {
        final nick = (m['nickname'] as String?)?.trim();
        if (nick != null && nick.isNotEmpty) return nick;
        return (m['short_code'] as String?) ?? '';
      }).where((n) => n.isNotEmpty).toList();
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

  /// Live changes to the user's room list. RLS scopes events to rows the
  /// user can see, so an unfiltered room_members listener only fires for
  /// rooms they belong to. Payloads don't carry enough to patch the list
  /// locally — callers just reload on [onChange].
  static RealtimeChannel? subscribeToMyRooms({
    required String userId,
    required void Function() onChange,
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
      channel.subscribe();
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
      channel.subscribe();
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
    await SupabaseConfig.client
        .from('room_members')
        .update({'can_share': canShare})
        .eq('room_id', roomId)
        .eq('user_id', userId);
  }
}
