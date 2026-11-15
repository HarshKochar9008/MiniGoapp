import 'package:flutter_test/flutter_test.dart';
import 'package:minigo/features/rooms/room_service.dart';
import 'package:minigo/features/send/send_destination.dart';

/// How a code typed on the Send screen is told apart as a person or a room,
/// and which lookups that costs. No backend, no widgets.
void main() {
  const me = 'me';
  final future = DateTime.now().toUtc().add(const Duration(hours: 1));
  final past = DateTime.now().toUtc().subtract(const Duration(hours: 1));

  Room room({String code = 'RRR234', DateTime? expiresAt}) => Room(
        id: 'room-$code',
        code: code,
        name: 'Trip photos',
        ownerId: 'owner',
        expiresAt: expiresAt ?? future,
      );

  const owner = RoomMember(userId: 'owner', shortCode: 'WNR234');
  const myself = RoomMember(userId: me, shortCode: 'MMM234');

  late List<String> calls;
  SendDestinationResolver resolver({
    Map<String, dynamic>? user,
    Room? remoteRoom,
    List<RoomMember> members = const [],
    Object? roomLookupError,
  }) {
    calls = [];
    return SendDestinationResolver(
      findUser: (code) async {
        calls.add('user:$code');
        return user;
      },
      lookupRoom: (code) async {
        calls.add('room:$code');
        if (roomLookupError != null) throw roomLookupError;
        return remoteRoom;
      },
      listMembers: (roomId) async {
        calls.add('members:$roomId');
        return members;
      },
    );
  }

  test('a person code resolves to that person without a room lookup', () async {
    final r = resolver(user: {
      'id': 'u1',
      'short_code': 'PPP234',
      'public_key': 'key',
      'nickname': '  Asha ',
    });
    final dest = await r.resolve(code: ' ppp234 ', myUserId: me);
    expect(dest, isA<PersonDestination>());
    dest as PersonDestination;
    expect(dest.userId, 'u1');
    expect(dest.code, 'PPP234');
    expect(dest.publicKey, 'key');
    expect(dest.nickname, 'Asha');
    expect(calls, ['user:PPP234']);
  });

  test('a blank nickname is no nickname', () async {
    final r = resolver(user: {'id': 'u1', 'nickname': '  '});
    final dest = await r.resolve(code: 'PPP234', myUserId: me);
    expect((dest as PersonDestination).nickname, isNull);
    expect(dest.publicKey, isNull);
  });

  test('a room I am in is matched locally, with no code lookups', () async {
    final r = resolver(members: [owner, myself]);
    final dest = await r.resolve(
      code: 'rrr234',
      myUserId: me,
      knownRooms: [room()],
    );
    dest as RoomDestination;
    expect(dest.isMember, isTrue);
    expect(dest.canShare, isTrue);
    expect(dest.recipients.map((m) => m.userId), ['owner']);
    expect(calls, ['members:room-RRR234']);
  });

  test('a code that is nobody\'s is then tried as a room', () async {
    final r = resolver(remoteRoom: room());
    final dest = await r.resolve(code: 'RRR234', myUserId: me);
    dest as RoomDestination;
    // Not a member: the membership-scoped list comes back empty.
    expect(dest.isMember, isFalse);
    expect(dest.canShare, isFalse);
    expect(dest.recipients, isEmpty);
    expect(calls, ['user:RRR234', 'room:RRR234', 'members:room-RRR234']);
  });

  test('a person wins over a room with the same code that I am not in',
      () async {
    final r = resolver(user: {'id': 'u1'}, remoteRoom: room());
    final dest = await r.resolve(code: 'RRR234', myUserId: me);
    expect(dest, isA<PersonDestination>());
    expect(calls, ['user:RRR234']);
  });

  test('neither a person nor a room resolves to null', () async {
    final r = resolver();
    expect(await r.resolve(code: 'XXX234', myUserId: me), isNull);
    expect(calls, ['user:XXX234', 'room:XXX234']);
  });

  test('an expired room is reported as expired, not as missing', () async {
    final r = resolver(remoteRoom: room(expiresAt: past));
    await expectLater(
      r.resolve(code: 'RRR234', myUserId: me),
      throwsA(isA<RoomExpiredException>()),
    );
  });

  test('an expired room in my list falls through to the normal lookups',
      () async {
    final r = resolver(user: {'id': 'u1'});
    final dest = await r.resolve(
      code: 'RRR234',
      myUserId: me,
      knownRooms: [room(expiresAt: past)],
    );
    expect(dest, isA<PersonDestination>());
  });

  test('a throttled room lookup surfaces as such', () async {
    final r = resolver(roomLookupError: RoomLookupThrottledException());
    await expectLater(
      r.resolve(code: 'RRR234', myUserId: me),
      throwsA(isA<RoomLookupThrottledException>()),
    );
  });

  group('RoomDestination', () {
    test('a member the host paused cannot share', () {
      final dest = RoomDestination(
        room: room(),
        members: [owner, myself.withCanShare(false)],
        myUserId: me,
      );
      expect(dest.isMember, isTrue);
      expect(dest.canShare, isFalse);
    });

    test('alone in my own room there is nobody to send to', () {
      final dest = RoomDestination(
        room: room(),
        members: const [myself],
        myUserId: me,
      );
      expect(dest.isMember, isTrue);
      expect(dest.recipients, isEmpty);
    });
  });
}
