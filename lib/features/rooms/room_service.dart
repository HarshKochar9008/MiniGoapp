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

  const Room({
    required this.id,
    required this.code,
    required this.name,
    required this.ownerId,
    this.memberCount = 0,
  });

  bool isOwnedBy(String userId) => ownerId == userId;
}

class RoomMember {
  final String userId;
  final String shortCode;
  final String? nickname;

  const RoomMember({
    required this.userId,
    required this.shortCode,
    this.nickname,
  });

  /// Falls back to the short code when the nickname is null OR blank —
  /// callers take `.characters.first` of this, which throws on ''.
  String get displayName {
    final nick = nickname?.trim();
    return (nick == null || nick.isEmpty) ? shortCode : nick;
  }
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
            .select('id, code, name, owner_id')
            .single();
        final room = Room(
          id: row['id'] as String,
          code: row['code'] as String,
          name: row['name'] as String,
          ownerId: row['owner_id'] as String,
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
        .select('id, code, name, owner_id')
        .eq('code', normalized)
        .maybeSingle();
    if (row == null) throw RoomNotFoundException(normalized);

    final room = Room(
      id: row['id'] as String,
      code: row['code'] as String,
      name: row['name'] as String,
      ownerId: row['owner_id'] as String,
    );

    try {
      await SupabaseConfig.client
          .from('room_members')
          .insert({'room_id': room.id, 'user_id': userId});
    } on PostgrestException catch (e) {
      if (e.message.contains('room_full')) throw RoomFullException();
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
        .select('id, code, name, owner_id, created_at, room_members(count)')
        .inFilter('id', roomIds)
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
        memberCount: count,
      );
    }).toList();
  }

  static Future<List<RoomMember>> listMembers(String roomId) async {
    await _ensureSession();
    final rows = await SupabaseConfig.client
        .from('room_members')
        .select('user_id, joined_at, users(short_code, nickname)')
        .eq('room_id', roomId)
        .order('joined_at', ascending: true);
    return rows.map<RoomMember>((row) {
      final user = row['users'] as Map<String, dynamic>?;
      return RoomMember(
        userId: row['user_id'] as String,
        shortCode: user?['short_code'] as String? ?? '??????',
        nickname: user?['nickname'] as String?,
      );
    }).toList();
  }
}
