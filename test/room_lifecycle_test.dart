import 'package:flutter_test/flutter_test.dart';
import 'package:minigo/features/rooms/room_lifecycle.dart';
import 'package:minigo/features/rooms/room_service.dart';

/// The pure rules behind the rooms screens: expiry by server time, why a room
/// ended, who may share, which send refusals stop the whole run, and how
/// realtime reloads are ordered. No backend, no widgets.
void main() {
  final expiresAt = DateTime.utc(2026, 11, 13, 13);

  group('Room expiry by server time', () {
    final room = Room(
      id: 'r',
      code: 'ABC234',
      name: 'Room',
      ownerId: 'owner',
      expiresAt: expiresAt,
    );

    test('live before expires_at, expired at and after it', () {
      expect(room.isExpiredAt(expiresAt.subtract(const Duration(seconds: 1))),
          isFalse);
      expect(room.isExpiredAt(expiresAt), isTrue);
      expect(
          room.isExpiredAt(expiresAt.add(const Duration(minutes: 1))), isTrue);
    });

    test('time left never goes negative', () {
      expect(room.timeLeftAt(expiresAt.subtract(const Duration(minutes: 7))),
          const Duration(minutes: 7));
      expect(room.timeLeftAt(expiresAt.add(const Duration(hours: 1))),
          Duration.zero);
    });

    test('an unreadable expiry counts as expired, not immortal', () {
      expect(Room.parseExpiry('garbage').isBefore(DateTime.utc(2000)), isTrue);
    });
  });

  group('roomEndReason', () {
    test('a deletion well before expiry was the host closing it', () {
      expect(
        roomEndReason(
          expiresAt: expiresAt,
          serverNow: expiresAt.subtract(const Duration(minutes: 20)),
        ),
        RoomEndReason.closed,
      );
    });

    test('a deletion at or after expiry was the sweep', () {
      expect(
        roomEndReason(expiresAt: expiresAt, serverNow: expiresAt),
        RoomEndReason.expired,
      );
      expect(
        roomEndReason(
          expiresAt: expiresAt,
          serverNow: expiresAt.add(const Duration(minutes: 14)),
        ),
        RoomEndReason.expired,
      );
    });

    test('the grace window absorbs a slightly-off server-time estimate', () {
      expect(
        roomEndReason(
          expiresAt: expiresAt,
          serverNow: expiresAt.subtract(const Duration(seconds: 10)),
          grace: const Duration(seconds: 30),
        ),
        RoomEndReason.expired,
      );
      expect(
        roomEndReason(
          expiresAt: expiresAt,
          serverNow: expiresAt.subtract(const Duration(seconds: 31)),
          grace: const Duration(seconds: 30),
        ),
        RoomEndReason.closed,
      );
    });

    test('messages name the right cause', () {
      expect(roomEndMessage(RoomEndReason.expired, isOwner: false),
          'This room expired.');
      expect(roomEndMessage(RoomEndReason.closed, isOwner: false),
          'This room was closed by the host.');
      expect(roomEndMessage(RoomEndReason.closed, isOwner: true),
          'This room was closed.');
    });
  });

  group('countdown labels', () {
    test('room card', () {
      expect(
          roomCardTimeLeft(const Duration(hours: 1, minutes: 5)), '1h 5m left');
      expect(roomCardTimeLeft(const Duration(minutes: 12, seconds: 30)),
          '12m left');
      expect(roomCardTimeLeft(const Duration(seconds: 40)), '<1m left');
      expect(roomCardTimeLeft(Duration.zero), 'Expired');
    });

    test('room detail', () {
      expect(roomDetailExpiryLabel(const Duration(hours: 2)), 'Expires in 2 h');
      expect(roomDetailExpiryLabel(const Duration(hours: 1, minutes: 3)),
          'Expires in 1 h 3 min');
      expect(roomDetailExpiryLabel(const Duration(minutes: 9)),
          'Expires in 9 min');
      expect(roomDetailExpiryLabel(const Duration(seconds: 59)),
          'Expires in under a minute');
      expect(roomDetailExpiryLabel(Duration.zero), 'Room expired');
    });
  });

  group('canShareInRoom', () {
    const me = 'me';
    test('a member follows their can_share flag', () {
      expect(
        canShareInRoom(const [RoomMember(userId: me, shortCode: 'AAAAAA')], me),
        isTrue,
      );
      expect(
        canShareInRoom(const [
          RoomMember(userId: me, shortCode: 'AAAAAA', canShare: false),
        ], me),
        isFalse,
      );
    });

    test('not being in the list means no, not yes', () {
      expect(canShareInRoom(const [], me), isFalse);
      expect(
        canShareInRoom(
            const [RoomMember(userId: 'someone', shortCode: 'BBBBBB')], me),
        isFalse,
      );
    });
  });

  group('classifyRoomSendRefusal', () {
    test('maps the transfers_check_room errors', () {
      expect(
        classifyRoomSendRefusal(
            Exception('PostgrestException(message: room_share_denied)')),
        RoomSendRefusal.shareDenied,
      );
      expect(classifyRoomSendRefusal('room_recipient_not_member'),
          RoomSendRefusal.recipientNotMember);
      expect(
          classifyRoomSendRefusal('room_expired'), RoomSendRefusal.roomEnded);
      expect(
          classifyRoomSendRefusal('room_not_found'), RoomSendRefusal.roomEnded);
      expect(classifyRoomSendRefusal(Exception('socket closed')), isNull);
    });

    test('a sender who left is refused like a blocked one', () {
      expect(classifyRoomSendRefusal('room_not_member'),
          RoomSendRefusal.shareDenied);
    });

    test('only a recipient-specific refusal lets the run continue', () {
      expect(RoomSendRefusal.shareDenied.isRoomWide, isTrue);
      expect(RoomSendRefusal.roomEnded.isRoomWide, isTrue);
      expect(RoomSendRefusal.recipientNotMember.isRoomWide, isFalse);
    });
  });

  group('resolveRoomMemberKeys', () {
    test('keys are matched by user id, not position or code', () {
      final resolved = resolveRoomMemberKeys(
        ['u1', 'u2'],
        [
          {'user_id': 'u2', 'public_key': 'KEY2'},
          {'user_id': 'u1', 'public_key': 'KEY1'},
          {'user_id': 'me', 'public_key': 'MINE'},
        ],
      );
      expect(resolved.keys, {'u1': 'KEY1', 'u2': 'KEY2'});
      expect(resolved.notMembers, isEmpty);
    });

    test('no key, or a blank one, is "unencryptable" (null), not a failure',
        () {
      final resolved = resolveRoomMemberKeys(
        ['u1', 'u2'],
        [
          {'user_id': 'u1', 'public_key': null},
          {'user_id': 'u2', 'public_key': '   '},
        ],
      );
      expect(resolved.keys, {'u1': null, 'u2': null});
      expect(resolved.notMembers, isEmpty);
    });

    test('a target the server no longer lists has left the room', () {
      final resolved = resolveRoomMemberKeys(
        ['u1', 'gone'],
        [
          {'user_id': 'u1', 'public_key': ' KEY1 '},
        ],
      );
      expect(resolved.keys, {'u1': 'KEY1'});
      expect(resolved.notMembers, {'gone'});
    });
  });

  group('LiveReloadGate', () {
    test('an event with nothing in flight reloads now', () {
      final gate = LiveReloadGate();
      expect(gate.requestReload(), isTrue);
      expect(gate.hasPendingReload, isFalse);
    });

    test('an event during a load is queued and followed up once', () {
      final gate = LiveReloadGate();
      gate.begin();
      expect(gate.requestReload(), isFalse);
      expect(gate.requestReload(), isFalse); // a burst still means one
      expect(gate.hasPendingReload, isTrue);
      expect(gate.end(), isTrue);
      expect(gate.hasPendingReload, isFalse);
    });

    test('the follow-up waits for every overlapping load to finish', () {
      final gate = LiveReloadGate();
      gate.begin();
      gate.begin();
      gate.requestReload();
      expect(gate.end(), isFalse);
      expect(gate.end(), isTrue);
    });

    test('no event, no follow-up', () {
      final gate = LiveReloadGate();
      gate.begin();
      expect(gate.end(), isFalse);
    });

    test('only the last-started load may apply its result', () {
      final gate = LiveReloadGate();
      final first = gate.begin();
      final second = gate.begin();
      expect(gate.isCurrent(first), isFalse);
      expect(gate.isCurrent(second), isTrue);
    });

    test('invalidate retires in-flight loads and drops a queued reload', () {
      final gate = LiveReloadGate();
      final gen = gate.begin();
      gate.requestReload();
      gate.invalidate();
      expect(gate.isCurrent(gen), isFalse);
      expect(gate.end(), isFalse);
      expect(gate.isLoading, isFalse);
    });
  });
}
