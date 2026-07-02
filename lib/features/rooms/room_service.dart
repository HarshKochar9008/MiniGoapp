import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../../core/constants.dart';
import '../../core/network/network_errors.dart';
import '../../core/supabase_config.dart';
import '../../core/utils/short_code_generator.dart';

class Room {
  final String id;
  final String code;
  final String name;
  final String ownerId;
  final int memberCount;

  /// Rooms live 1 hour; the server deletes them (and their files) afterwards.
  final DateTime expiresAt;

  const Room({
    required this.id,
    required this.code,
    required this.name,
    required this.ownerId,
    required this.expiresAt,
    this.memberCount = 0,
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

  String get displayName => nickname ?? shortCode;

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
        await SupabaseConfig.client
            .from('room_members')
            .insert({'room_id': room.id, 'user_id': ownerId});
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
      await SupabaseConfig.client
          .from('room_members')
          .insert({'room_id': room.id, 'user_id': userId});
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
            'room_members(count)')
        .inFilter('id', roomIds)
        .gt('expires_at', DateTime.now().toUtc().toIso8601String())
        .order('created_at', ascending: false);
    return rows.map<Room>((row) {
      final counts = row['room_members'] as List?;
      final count = counts != null && counts.isNotEmpty
          ? (counts.first['count'] as num).toInt()
          : 0;
      return Room(
        id: row['id'] as String,
        code: row['code'] as String,
        name: row['name'] as String,
        ownerId: row['owner_id'] as String,
        expiresAt: Room.parseExpiry(row['expires_at']),
        memberCount: count,
      );
    }).toList();
  }

  static Future<List<RoomMember>> listMembers(String roomId) async {
    await _ensureSession();
    final rows = await SupabaseConfig.client
        .from('room_members')
        .select('user_id, joined_at, can_share, users(short_code, nickname)')
        .eq('room_id', roomId)
        .order('joined_at', ascending: true);
    return rows.map<RoomMember>((row) {
      final user = row['users'] as Map<String, dynamic>?;
      return RoomMember(
        userId: row['user_id'] as String,
        shortCode: user?['short_code'] as String? ?? '??????',
        nickname: user?['nickname'] as String?,
        canShare: row['can_share'] as bool? ?? true,
      );
    }).toList();
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
