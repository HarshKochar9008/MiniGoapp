import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:minigo/core/crypto/e2e_crypto.dart';

/// Verifies the chunked AES-256-GCM file cipher round-trips exactly across the
/// interesting boundaries (empty, sub-chunk, exact chunk, chunk+1, multi-chunk).
/// This is pure Dart and needs no platform channels / secure storage.
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('e2e_test_');
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Uint8List pattern(int n) {
    final b = Uint8List(n);
    for (var i = 0; i < n; i++) {
      b[i] = (i * 31 + 7) & 0xff;
    }
    return b;
  }

  Future<void> roundTrip(int size) async {
    final src = File('${tmp.path}/src_$size.bin');
    final enc = File('${tmp.path}/enc_$size.bin');
    final dec = File('${tmp.path}/dec_$size.bin');
    final plain = pattern(size);
    await src.writeAsBytes(plain, flush: true);

    final key = E2ECrypto.newFileKey();
    await E2ECrypto.encryptFile(
      src: src,
      dst: enc,
      contentKey: key.contentKey,
      baseNonce: key.baseNonce,
    );
    await E2ECrypto.decryptFile(
      src: enc,
      dst: dec,
      contentKey: key.contentKey,
      baseNonce: key.baseNonce,
    );

    final out = await dec.readAsBytes();
    expect(out.length, size, reason: 'length mismatch for size=$size');
    expect(out, equals(plain), reason: 'content mismatch for size=$size');
  }

  test('round-trips empty file', () => roundTrip(0));
  test('round-trips small file', () => roundTrip(100));
  test('round-trips exactly one chunk', () => roundTrip(E2ECrypto.chunkSize));
  test('round-trips one chunk + 1 byte',
      () => roundTrip(E2ECrypto.chunkSize + 1));
  test('round-trips multiple chunks',
      () => roundTrip(2 * E2ECrypto.chunkSize + 12345));

  test('wrong key fails authentication', () async {
    final src = File('${tmp.path}/src.bin');
    final enc = File('${tmp.path}/enc.bin');
    final dec = File('${tmp.path}/dec.bin');
    await src.writeAsBytes(pattern(5000), flush: true);

    final key = E2ECrypto.newFileKey();
    await E2ECrypto.encryptFile(
      src: src,
      dst: enc,
      contentKey: key.contentKey,
      baseNonce: key.baseNonce,
    );

    final wrong = E2ECrypto.newFileKey();
    expect(
      () => E2ECrypto.decryptFile(
        src: enc,
        dst: dec,
        contentKey: wrong.contentKey,
        baseNonce: key.baseNonce,
      ),
      throwsA(isA<E2EDecryptException>()),
    );
  });
}
