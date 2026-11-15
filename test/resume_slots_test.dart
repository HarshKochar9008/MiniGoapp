import 'package:flutter_test/flutter_test.dart';
import 'package:minigo/features/transfer/transfer_service.dart';

/// Resuming an interrupted send maps the current selection onto the saved
/// job's ORIGINAL file list. The slot — not the position in the new
/// selection — names each file's storage object (`<transfer>/<slot>_<name>`),
/// so a file already delivered keeps matching its `transfer_files` row and is
/// never uploaded twice, even when some saved files have since gone from the
/// device. Pure Dart.
void main() {
  const a = PendingUploadFile(name: 'a.jpg', path: '/d/a.jpg', size: 10);
  const b = PendingUploadFile(name: 'b.pdf', path: '/d/b.pdf', size: 20);
  const c = PendingUploadFile(name: 'c.mov', path: '/d/c.mov', size: 30);

  PendingUploadJob job({
    List<PendingUploadFile> files = const [a, b, c],
    String receiverId = 'r1',
    String? receiverCode = 'ABC234',
    String? roomId,
  }) =>
      PendingUploadJob(
        senderId: 's1',
        receiverId: receiverId,
        receiverCode: receiverCode,
        transferId: 't1',
        roomId: roomId,
        files: files,
        createdAt: DateTime.utc(2026, 11, 13),
      );

  List<int>? match(
    PendingUploadJob? pending,
    List<PendingUploadFile> selection, {
    String receiverId = 'r1',
    String? receiverCode = 'ABC234',
    String? roomId,
  }) =>
      TransferService.matchResumeSlots(
        pending,
        receiverId: receiverId,
        receiverCode: receiverCode,
        validFiles: selection,
        roomId: roomId,
      );

  group('same send', () {
    test('the full selection maps onto the original slots', () {
      expect(match(job(), [a, b, c]), [0, 1, 2]);
    });

    test('a subset keeps each file on its ORIGINAL slot', () {
      // b was removed from the device: c must stay slot 2, not become 1,
      // or a delivered c would look undelivered and go up twice.
      expect(match(job(), [a, c]), [0, 2]);
      expect(match(job(), [c]), [2]);
    });

    test('order of the new selection does not matter', () {
      expect(match(job(), [c, a]), [2, 0]);
    });

    test('the recipient code is compared normalized', () {
      expect(match(job(), [a], receiverCode: ' abc234 '), [0]);
    });

    test('a plain resume may continue a room job; it learns the room there',
        () {
      expect(match(job(roomId: 'room-1'), [a, b]), [0, 1]);
      expect(match(job(roomId: 'room-1'), [a], roomId: 'room-1'), [0]);
    });

    test('a file saved twice under one name maps to two distinct slots', () {
      const a2 = PendingUploadFile(name: 'a.jpg', path: '/e/a.jpg', size: 10);
      expect(match(job(files: const [a, a2]), [a2, a]), [1, 0]);
    });
  });

  group('a different send', () {
    test('any file the saved job lacks', () {
      const d = PendingUploadFile(name: 'd.txt', path: '/d/d.txt', size: 1);
      expect(match(job(), [a, d]), isNull);
    });

    test('a file whose size or path changed is not the saved file', () {
      expect(
        match(job(), [
          const PendingUploadFile(name: 'a.jpg', path: '/d/a.jpg', size: 11),
        ]),
        isNull,
      );
      expect(
        match(job(), [
          const PendingUploadFile(name: 'a.jpg', path: '/x/a.jpg', size: 10),
        ]),
        isNull,
      );
    });

    test('the same file selected twice cannot take one slot twice', () {
      expect(match(job(), [a, a]), isNull);
    });

    test('another recipient, code or room', () {
      expect(match(job(), [a], receiverId: 'r2'), isNull);
      expect(match(job(), [a], receiverCode: 'XYZ789'), isNull);
      expect(match(job(roomId: 'room-1'), [a], roomId: 'room-2'), isNull);
      expect(match(job(), [a], roomId: 'room-1'), isNull);
    });

    test('nothing saved, or nothing selected', () {
      expect(match(null, [a]), isNull);
      expect(match(job(), const []), isNull);
    });
  });
}
