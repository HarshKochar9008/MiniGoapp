import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// MiniGo's disposable on-device files.
///
/// Covers what the app (or a plugin acting for it) writes while moving files:
/// partial and decrypted downloads, encrypted upload copies, files picked or
/// shared in for sending, and the TUS resume state of interrupted uploads.
/// None of it is needed once a transfer finishes, and the OS may purge the
/// temp directory on its own at any time.
///
/// Cleanup is targeted rather than wiping the whole temp directory: platform
/// SDKs (crash reporting, URL caches) keep working files there too, and the
/// app is still running when the cache is cleared.
class LocalCache {
  LocalCache._();

  /// Temp subfolders holding copies of user files: encrypted upload copies
  /// (TransferService), files picked for sending (file_picker on Android) and
  /// files shared into the app (MainActivity). Loose files at the top level
  /// are MiniGo's partial and decrypted downloads.
  static const _ownedSubfolders = {'enc_out', 'file_picker', 'shared_in'};

  /// Bytes [clear] would free.
  static Future<int> measure() async {
    var total = 0;
    for (final entity in await _entries()) {
      total += await _sizeOf(entity);
    }
    return total;
  }

  /// Deletes the cache and returns the bytes freed. An entry that can't be
  /// removed (held open by the OS, say) is skipped rather than failing the
  /// rest.
  static Future<int> clear() async {
    var freed = 0;
    for (final entity in await _entries()) {
      final size = await _sizeOf(entity);
      try {
        await entity.delete(recursive: true);
        freed += size;
      } catch (e) {
        if (kDebugMode) debugPrint('LocalCache: kept ${entity.path}: $e');
      }
    }
    return freed;
  }

  /// Removes the TUS resume state of interrupted uploads. Only safe while no
  /// send is uploading — check TransferService.isSendInFlight first.
  static Future<void> clearUploadResumeState() async {
    final support = await getApplicationSupportDirectory();
    final tus = Directory('${support.path}/tus');
    try {
      if (await tus.exists()) await tus.delete(recursive: true);
    } catch (e) {
      if (kDebugMode) debugPrint('LocalCache: kept ${tus.path}: $e');
    }
  }

  static Future<List<FileSystemEntity>> _entries() async {
    final out = <FileSystemEntity>[];
    final temp = await getTemporaryDirectory();
    if (await temp.exists()) {
      await for (final entity in temp.list(followLinks: false)) {
        final name = entity.path.split(Platform.pathSeparator).last;
        if (entity is File || _ownedSubfolders.contains(name)) {
          out.add(entity);
        }
      }
    }

    // iOS puts file_picker copies in the app's tmp/, outside Library/Caches
    // (which is what getTemporaryDirectory() returns there). tmp/ is the
    // app's own sandboxed scratch space, so all of it counts.
    if (Platform.isIOS) {
      final scratch = Directory.systemTemp;
      if (scratch.absolute.path != temp.absolute.path &&
          await scratch.exists()) {
        out.addAll(await scratch.list(followLinks: false).toList());
      }
    }
    return out;
  }

  static Future<int> _sizeOf(FileSystemEntity entity) async {
    try {
      if (entity is File) return await entity.length();
      if (entity is! Directory) return 0;
      var total = 0;
      await for (final child
          in entity.list(recursive: true, followLinks: false)) {
        if (child is File) {
          try {
            total += await child.length();
          } catch (_) {
            // Vanished mid-walk — another cleanup got there first.
          }
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }
}
