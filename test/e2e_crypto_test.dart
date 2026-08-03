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

  // The v1 format authenticated each chunk independently with no associated
  // data, so lopping whole chunks off the end decrypted cleanly to a short
  // file. These pin the v2 property that makes that detectable.
  group('truncation and extension (v2)', () {
    /// Encrypts [size] bytes and returns (key, ciphertext file).
    Future<(E2EFileKey, File)> encrypted(String tag, int size) async {
      final src = File('${tmp.path}/src_$tag.bin');
      final enc = File('${tmp.path}/enc_$tag.bin');
      await src.writeAsBytes(pattern(size), flush: true);
      final key = E2ECrypto.newFileKey();
      await E2ECrypto.encryptFile(
        src: src,
        dst: enc,
        contentKey: key.contentKey,
        baseNonce: key.baseNonce,
      );
      return (key, enc);
    }

    Future<void> expectRejected(E2EFileKey key, File enc, String tag) async {
      await expectLater(
        () => E2ECrypto.decryptFile(
          src: enc,
          dst: File('${tmp.path}/dec_$tag.bin'),
          contentKey: key.contentKey,
          baseNonce: key.baseNonce,
        ),
        throwsA(isA<E2EDecryptException>()),
      );
    }

    test('rejects a stream cut at an exact chunk boundary', () async {
      // The case v1 could not see: two full chunks plus a final short one,
      // truncated to just the two full chunks.
      const encChunk = E2ECrypto.chunkSize + 16;
      final (key, enc) = await encrypted('cut', 2 * E2ECrypto.chunkSize + 500);
      final bytes = await enc.readAsBytes();
      await enc.writeAsBytes(bytes.sublist(0, 2 * encChunk), flush: true);
      await expectRejected(key, enc, 'cut');
    });

    test('rejects a stream with its final chunk removed', () async {
      const encChunk = E2ECrypto.chunkSize + 16;
      final (key, enc) = await encrypted('drop', E2ECrypto.chunkSize + 42);
      final bytes = await enc.readAsBytes();
      await enc.writeAsBytes(bytes.sublist(0, encChunk), flush: true);
      await expectRejected(key, enc, 'drop');
    });

    test('rejects a mid-chunk truncation', () async {
      final (key, enc) = await encrypted('mid', 5000);
      final bytes = await enc.readAsBytes();
      await enc.writeAsBytes(bytes.sublist(0, bytes.length - 64), flush: true);
      await expectRejected(key, enc, 'mid');
    });

    test('rejects an emptied ciphertext', () async {
      final (key, enc) = await encrypted('empty', 5000);
      await enc.writeAsBytes(const <int>[], flush: true);
      await expectRejected(key, enc, 'empty');
    });

    test('rejects appended data', () async {
      final (key, enc) = await encrypted('append', 5000);
      final bytes = await enc.readAsBytes();
      await enc.writeAsBytes([...bytes, ...pattern(E2ECrypto.chunkSize + 16)],
          flush: true);
      await expectRejected(key, enc, 'append');
    });

    test('rejects a flipped byte in the payload', () async {
      final (key, enc) = await encrypted('flip', 5000);
      final bytes = await enc.readAsBytes();
      bytes[10] ^= 0xff;
      await enc.writeAsBytes(bytes, flush: true);
      await expectRejected(key, enc, 'flip');
    });

    test('an empty file still carries a final-chunk marker', () async {
      final (_, enc) = await encrypted('zero', 0);
      // One bare tag: without it, "empty file" and "cut to nothing" would be
      // the same bytes on disk.
      expect(await enc.length(), 16);
    });
  });

  group('format tagging', () {
    test('rejects an unknown enc_algo instead of guessing', () async {
      final src = File('${tmp.path}/src_algo.bin');
      final enc = File('${tmp.path}/enc_algo.bin');
      await src.writeAsBytes(pattern(2048), flush: true);
      final key = E2ECrypto.newFileKey();
      await E2ECrypto.encryptFile(
        src: src,
        dst: enc,
        contentKey: key.contentKey,
        baseNonce: key.baseNonce,
      );

      await expectLater(
        () => E2ECrypto.decryptFile(
          src: enc,
          dst: File('${tmp.path}/dec_algo.bin'),
          contentKey: key.contentKey,
          baseNonce: key.baseNonce,
          algo: 'x25519-aesgcm-v99',
        ),
        throwsA(isA<E2EDecryptException>()),
      );
    });

    test('v2 ciphertext does not silently decrypt under the v1 reader',
        () async {
      // Guards the rollout: a v2 file whose row somehow says v1 must fail
      // loudly rather than produce garbage.
      final src = File('${tmp.path}/src_x.bin');
      final enc = File('${tmp.path}/enc_x.bin');
      await src.writeAsBytes(pattern(2048), flush: true);
      final key = E2ECrypto.newFileKey();
      await E2ECrypto.encryptFile(
        src: src,
        dst: enc,
        contentKey: key.contentKey,
        baseNonce: key.baseNonce,
      );

      await expectLater(
        () => E2ECrypto.decryptFile(
          src: enc,
          dst: File('${tmp.path}/dec_x.bin'),
          contentKey: key.contentKey,
          baseNonce: key.baseNonce,
          algo: E2ECrypto.algoTagV1,
        ),
        throwsA(isA<E2EDecryptException>()),
      );
    });

    test('current algoTag is what the sender records', () {
      expect(E2ECrypto.algoTag, E2ECrypto.algoTagV2);
    });
  });
}
