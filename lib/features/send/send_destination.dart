import '../../core/constants.dart';
import '../identity/identity_service.dart';
import '../rooms/room_service.dart';

/// What a code typed on the Send screen turned out to be. People and rooms
/// share one code format, so the sender can't be asked which kind they hold —
/// the app works it out and shows which it found before anything is sent.
sealed class SendDestination {
  const SendDestination();
}

/// One person: a direct, single-recipient send.
class PersonDestination extends SendDestination {
  final String userId;
  final String code;

  /// Their X25519 public key; null or blank means their files can't be
  /// end-to-end encrypted.
  final String? publicKey;

  /// The name they chose for themselves, if any.
  final String? nickname;

  const PersonDestination({
    required this.userId,
    required this.code,
    this.publicKey,
    this.nickname,
  });
}

/// A room: the files go to every other member.
class RoomDestination extends SendDestination {
  final Room room;

  /// The members the sender is allowed to see. Empty when the sender isn't in
  /// the room: the member list is membership-scoped.
  final List<RoomMember> members;
  final String myUserId;

  const RoomDestination({
    required this.room,
    required this.members,
    required this.myUserId,
  });

  bool get isMember => members.any((m) => m.userId == myUserId);

  /// Whether the host lets the sender share. Only meaningful for a member;
  /// someone missing from the list is never allowed (the server refuses them).
  bool get canShare {
    for (final m in members) {
      if (m.userId == myUserId) return m.canShare;
    }
    return false;
  }

  /// Everyone who would receive the files.
  List<RoomMember> get recipients =>
      members.where((m) => m.userId != myUserId).toList();
}

/// Turns a code into a [SendDestination].
///
/// Order matters, because `lookup_room_by_code` is tightly metered (30 per 10
/// minutes per identity) and a normal send must not spend it:
///
///  1. a room the sender is already in is matched locally, at no lookup cost;
///  2. then the code is tried as a person;
///  3. only a code that is nobody's is tried as a room.
///
/// A person and a room the sender isn't in could in theory hold the same code
/// (separate tables, same generator, 31^6 values). The person wins: that is
/// what the Send screen has always meant, and the confirmation names who it
/// found either way.
class SendDestinationResolver {
  final Future<Map<String, dynamic>?> Function(String code) findUser;
  final Future<Room?> Function(String code) lookupRoom;
  final Future<List<RoomMember>> Function(String roomId) listMembers;

  const SendDestinationResolver({
    this.findUser = IdentityService.findUserByCode,
    this.lookupRoom = RoomService.lookupRoom,
    this.listMembers = RoomService.listMembers,
  });

  /// Null when [code] belongs to no person and no room.
  ///
  /// Throws [RoomExpiredException] when it is a room past its expiry,
  /// [RoomLookupThrottledException] when it is not a person and the room
  /// lookup is rate limited, and whatever the lookups throw on failure.
  Future<SendDestination?> resolve({
    required String code,
    required String myUserId,
    List<Room> knownRooms = const [],
  }) async {
    final normalized = AppConstants.normalizeShortCode(code);

    for (final room in knownRooms) {
      if (room.code == normalized && !room.isExpired) {
        return _room(room, myUserId);
      }
    }

    final user = await findUser(normalized);
    if (user != null) {
      final nickname = (user['nickname'] as String?)?.trim();
      return PersonDestination(
        userId: user['id'] as String,
        code: normalized,
        publicKey: user['public_key'] as String?,
        nickname: (nickname == null || nickname.isEmpty) ? null : nickname,
      );
    }

    final room = await lookupRoom(normalized);
    if (room == null) return null;
    if (room.isExpired) throw RoomExpiredException();
    return _room(room, myUserId);
  }

  /// Re-reads [room]'s members, e.g. after joining it.
  Future<RoomDestination> refreshRoom(Room room, String myUserId) =>
      _room(room, myUserId);

  Future<RoomDestination> _room(Room room, String myUserId) async {
    final members = await listMembers(room.id);
    return RoomDestination(room: room, members: members, myUserId: myUserId);
  }
}
