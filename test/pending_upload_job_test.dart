import 'package:flutter_test/flutter_test.dart';
import 'package:minigo/features/transfer/transfer_service.dart';

/// Resume matches stored files to the selection by index, so the saved job
/// must keep every file — an entry silently dropped here shifts every later
/// file's index and turns a resume into duplicate uploads. Pure Dart.
void main() {
  Map<String, dynamic> job(List<Map<String, dynamic>> files) => {
        'sender_id': 'sender',
        'receiver_id': 'receiver',
        'files': files,
      };

  test('a 0-byte file survives a save/load round trip', () {
    const files = [
      PendingUploadFile(name: 'empty.txt', path: '/tmp/empty.txt', size: 0),
      PendingUploadFile(name: 'a.jpg', path: '/tmp/a.jpg', size: 1024),
    ];
    final parsed = PendingUploadJob.fromJson(
      job(files.map((f) => f.toJson()).toList()),
    );
    expect(parsed, isNotNull);
    expect(parsed!.files.map((f) => f.name), ['empty.txt', 'a.jpg']);
    expect(parsed.files.first.size, 0);
  });

  test('entries with a missing or invalid size are still rejected', () {
    expect(
      PendingUploadFile.fromJson({'name': 'a', 'path': '/tmp/a'}),
      isNull,
    );
    expect(
      PendingUploadFile.fromJson({'name': 'a', 'path': '/tmp/a', 'size': -1}),
      isNull,
    );
    expect(
      PendingUploadFile.fromJson({'name': 'a', 'path': '/tmp/a', 'size': 'x'}),
      isNull,
    );
  });
}
