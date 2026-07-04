import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// End-to-end encryption for transferred files.
///
/// Model
/// -----
/// Every device owns a long-lived X25519 key pair. The **private** key never
/// leaves the device (stored in the OS keystore via [FlutterSecureStorage]);
/// only the **public** key is uploaded to `users.public_key`.
///
/// To send a file the sender:
///   1. generates a random 256-bit *content key*,
///   2. encrypts the file bytes with AES-256-GCM under that content key
///      (chunked, so memory stays bounded for large files),
///   3. *seals* the content key to the recipient's public key (ECIES-style:
///      ephemeral X25519 + HKDF-SHA256 + AES-256-GCM) and stores the sealed
///      blob alongside the file metadata.
///
/// The server/storage only ever holds ciphertext and a sealed key it cannot
/// open, so it cannot read file contents. The recipient unseals the content
/// key with their private key and decrypts.
class E2ECrypto {
  E2ECrypto._();

  /// Algorithm tag persisted in `transfer_files.enc_algo`.
  static const algoTag = 'x25519-aesgcm-v1';

  /// Plaintext chunk size for the streaming file cipher (1 MiB).
  static const chunkSize = 1 << 20;

  /// GCM authentication tag length in bytes.
  static const _tagLen = 16;

  /// Random base-nonce length (8 bytes); per-chunk nonce = base ‖ uint32(index).
  static const _baseNonceLen = 8;

  static const _hkdfSalt = 'minigo-hkdf-salt-v1';
  static const _hkdfInfo = 'minigo-e2e-content-key';

  static final _x25519 = X25519();
  static final _aes = AesGcm.with256bits();
  static final _secureStorage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static String _privKeyStorageKey(String authUid) => 'e2e_x25519_priv_$authUid';

  // ── Identity key pair ─────────────────────────────────────────────────────

  /// Returns this device's base64url public key for [authUid], creating and
  /// persisting a key pair on first use.
  static Future<String> ensureLocalPublicKey(String authUid) async {
    final keyPair = await _loadOrCreateKeyPair(authUid);
    final pub = await keyPair.extractPublicKey();
    return base64UrlEncode(pub.bytes);
  }

  static Future<SimpleKeyPair> _loadOrCreateKeyPair(String authUid) async {
    final existing = await _loadKeyPair(authUid);
    if (existing != null) return existing;

    final keyPair = await _x25519.newKeyPair();
    final seed = await keyPair.extractPrivateKeyBytes();
    await _secureStorage.write(
      key: _privKeyStorageKey(authUid),
      value: base64UrlEncode(seed),
    );
    return keyPair;
  }

  static Future<SimpleKeyPair?> _loadKeyPair(String authUid) async {
    final stored = await _secureStorage.read(key: _privKeyStorageKey(authUid));
    if (stored == null || stored.isEmpty) return null;
    try {
      final seed = base64Url.decode(stored);
      return await _x25519.newKeyPairFromSeed(seed);
    } catch (e) {
      if (kDebugMode) debugPrint('E2ECrypto: bad stored key pair: $e');
      return null;
    }
  }

  /// True if this device holds a usable private key for [authUid] (i.e. it can
  /// decrypt files that were sealed to its public key).
  static Future<bool> hasPrivateKey(String authUid) async =>
      (await _loadKeyPair(authUid)) != null;

  // ── Sealing / unsealing the per-file content key ──────────────────────────

  /// Seals [contentKey] to [recipientPublicKeyB64] (base64url X25519 pubkey).
  /// Returns a base64url blob: ephPub(32) ‖ nonce(12) ‖ ciphertext ‖ tag(16).
  static Future<String> sealContentKey({
    required List<int> contentKey,
    required String recipientPublicKeyB64,
  }) async {
    final recipientPub = SimplePublicKey(
      base64Url.decode(recipientPublicKeyB64),
      type: KeyPairType.x25519,
    );

    final ephemeral = await _x25519.newKeyPair();
    final ephemeralPub = await ephemeral.extractPublicKey();
    final shared = await _x25519.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: recipientPub,
    );
    final wrapKey = await _deriveWrapKey(shared);

    final nonce = _aes.newNonce();
    final box = await _aes.encrypt(contentKey, secretKey: wrapKey, nonce: nonce);

    final blob = <int>[
      ...ephemeralPub.bytes,
      ...nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ];
    return base64UrlEncode(blob);
  }

  /// Unseals a content key produced by [sealContentKey] using this device's
  /// private key for [authUid]. Throws if the private key is missing or the
  /// blob does not authenticate.
  static Future<List<int>> unsealContentKey({
    required String wrappedKeyB64,
    required String authUid,
  }) async {
    final keyPair = await _loadKeyPair(authUid);
    if (keyPair == null) {
      throw const E2EDecryptException(
        'This device has no decryption key for these files. '
        'They were encrypted for the account that originally requested them.',
      );
    }

    final blob = base64Url.decode(wrappedKeyB64);
    const ephLen = 32;
    final nonceLen = _aes.nonceLength; // 12
    if (blob.length < ephLen + nonceLen + _tagLen) {
      throw const E2EDecryptException('Malformed sealed key.');
    }

    final ephBytes = blob.sublist(0, ephLen);
    final nonce = blob.sublist(ephLen, ephLen + nonceLen);
    final mac = blob.sublist(blob.length - _tagLen);
    final cipherText = blob.sublist(ephLen + nonceLen, blob.length - _tagLen);

    final ephPub = SimplePublicKey(ephBytes, type: KeyPairType.x25519);
    final shared = await _x25519.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: ephPub,
    );
    final wrapKey = await _deriveWrapKey(shared);

    try {
      return await _aes.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
        secretKey: wrapKey,
      );
    } catch (e) {
      throw const E2EDecryptException('Could not unseal the content key.');
    }
  }

  static Future<SecretKey> _deriveWrapKey(SecretKey shared) {
    return Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: shared,
      nonce: utf8.encode(_hkdfSalt),
      info: utf8.encode(_hkdfInfo),
    );
  }

  // ── File stream cipher (chunked AES-256-GCM) ──────────────────────────────

  /// A freshly generated content key + base nonce for one file.
  static E2EFileKey newFileKey() => E2EFileKey(
        contentKey: _randomBytes(32),
        baseNonce: _randomBytes(_baseNonceLen),
      );

  /// Encrypts [src] into [dst] under [contentKey]/[baseNonce]. Each 1 MiB
  /// plaintext chunk becomes `ciphertext ‖ tag` in [dst].
  static Future<void> encryptFile({
    required File src,
    required File dst,
    required List<int> contentKey,
    required List<int> baseNonce,
  }) async {
    final key = SecretKey(contentKey);
    final input = await src.open();
    final output = dst.openWrite();
    try {
      var index = 0;
      while (true) {
        final chunk = await _readFully(input, chunkSize);
        if (chunk.isEmpty) break;
        final box = await _aes.encrypt(
          chunk,
          secretKey: key,
          nonce: _chunkNonce(baseNonce, index),
        );
        output.add(box.cipherText);
        output.add(box.mac.bytes);
        index++;
        if (chunk.length < chunkSize) break;
      }
    } finally {
      await input.close();
      await output.close();
    }
  }

  /// Decrypts [src] (produced by [encryptFile]) into [dst]. Throws
  /// [E2EDecryptException] if any chunk fails authentication.
  static Future<void> decryptFile({
    required File src,
    required File dst,
    required List<int> contentKey,
    required List<int> baseNonce,
    int plaintextChunkSize = chunkSize,
  }) async {
    final encChunk = plaintextChunkSize + _tagLen;
    final key = SecretKey(contentKey);
    final input = await src.open();
    final output = dst.openWrite();
    try {
      var index = 0;
      while (true) {
        final block = await _readFully(input, encChunk);
        if (block.isEmpty) break;
        if (block.length < _tagLen) {
          throw const E2EDecryptException('Truncated encrypted file.');
        }
        final mac = block.sublist(block.length - _tagLen);
        final cipherText = block.sublist(0, block.length - _tagLen);
        try {
          final plain = await _aes.decrypt(
            SecretBox(cipherText, nonce: _chunkNonce(baseNonce, index),
                mac: Mac(mac)),
            secretKey: key,
          );
          output.add(plain);
        } catch (e) {
          throw const E2EDecryptException(
            'Decryption failed — file was tampered with or the wrong key was used.',
          );
        }
        index++;
        if (block.length < encChunk) break;
      }
    } finally {
      await input.close();
      await output.close();
    }
  }

  // ── helpers ────────────────────────────────────────────────────────────────

  /// Reads exactly [n] bytes from [raf], or fewer only at end-of-file.
  static Future<Uint8List> _readFully(RandomAccessFile raf, int n) async {
    final buffer = BytesBuilder(copy: false);
    var remaining = n;
    while (remaining > 0) {
      final part = await raf.read(remaining);
      if (part.isEmpty) break;
      buffer.add(part);
      remaining -= part.length;
    }
    return buffer.toBytes();
  }

  /// 12-byte per-chunk nonce: baseNonce(8) ‖ big-endian uint32(index).
  static Uint8List _chunkNonce(List<int> baseNonce, int index) {
    final nonce = Uint8List(12);
    nonce.setRange(0, _baseNonceLen, baseNonce);
    nonce[8] = (index >> 24) & 0xff;
    nonce[9] = (index >> 16) & 0xff;
    nonce[10] = (index >> 8) & 0xff;
    nonce[11] = index & 0xff;
    return nonce;
  }

  static Uint8List _randomBytes(int n) {
    final rnd = SecretKeyData.random(length: n);
    return Uint8List.fromList(rnd.bytes);
  }

  static String encodeB64(List<int> bytes) => base64UrlEncode(bytes);

  static List<int> decodeB64(String s) => base64Url.decode(s);
}

class E2EFileKey {
  final List<int> contentKey;
  final List<int> baseNonce;
  const E2EFileKey({required this.contentKey, required this.baseNonce});
}

class E2EDecryptException implements Exception {
  final String message;
  const E2EDecryptException(this.message);
  @override
  String toString() => message;
}
