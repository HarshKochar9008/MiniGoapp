import 'dart:io';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/utils/safe_file_name.dart';

class PermissionDeniedException implements Exception {
  final String message;
  PermissionDeniedException(this.message);
  @override
  String toString() => message;
}

class SaveFileException implements Exception {
  final String message;
  SaveFileException(this.message);
  @override
  String toString() => message;
}

/// Save a file to a user-visible location.
/// Images / videos → device gallery.  Everything else → Downloads / Documents.
///
/// [fileName] arrives from `transfer_files.file_name`, i.e. it is chosen by the
/// sender — it is sanitized here, at the sink, rather than trusted to have been
/// sanitized on the way in. See [safeFileName].
Future<String> saveFileToDevice(File file, String rawFileName) async {
  final fileName = safeFileName(rawFileName);
  final ext = fileName.split('.').last.toLowerCase();
  final isImage = _imageExts.contains(ext);
  final isVideo = _videoExts.contains(ext);

  if (isImage || isVideo) {
    await _ensureGalleryPermission();
    try {
      if (isImage) {
        await Gal.putImage(file.path, album: 'MiniGo');
      } else {
        await Gal.putVideo(file.path, album: 'MiniGo');
      }
      return 'Gallery (MiniGo album)';
    } catch (e) {
      throw SaveFileException('Could not save to gallery: $e');
    }
  }

  return _saveNonMedia(file, fileName);
}

Future<void> _ensureGalleryPermission() async {
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    final status = await Permission.photosAddOnly.request();
    if (!status.isGranted) {
      throw PermissionDeniedException(
        'Gallery access denied. Please enable it in Settings → Privacy → Photos.',
      );
    }
  } else if (defaultTargetPlatform == TargetPlatform.android) {
    // On Android, permission_handler automatically resolves the correct
    // permission based on the device's actual SDK version:
    //   - API 33+: READ_MEDIA_IMAGES / READ_MEDIA_VIDEO (granular)
    //   - API 29-32: READ_EXTERNAL_STORAGE
    //   - API ≤28: WRITE_EXTERNAL_STORAGE
    // The Gal plugin also handles MediaStore internally.
    // We request both granular permissions; permission_handler no-ops
    // on devices where they don't apply.
    final photos = await Permission.photos.request();
    final videos = await Permission.videos.request();

    // If both are permanently denied or restricted, fall back to storage
    if (!photos.isGranted && !videos.isGranted) {
      final storage = await Permission.storage.request();
      if (!storage.isGranted) {
        throw PermissionDeniedException(
          'Media access denied. Please enable it in Settings → App Permissions.',
        );
      }
    }
  }
}

Future<String> _saveNonMedia(File file, String fileName) async {
  if (defaultTargetPlatform == TargetPlatform.android) {
    final downloads = Directory('/storage/emulated/0/Download');
    if (await downloads.exists()) {
      final savePath = _uniquePath(downloads.path, fileName);
      await file.copy(savePath);
      return savePath;
    }

    final extDir = await getExternalStorageDirectory();
    if (extDir != null) {
      final savePath = _uniquePath(extDir.path, fileName);
      await file.copy(savePath);
      return savePath;
    }
  }

  // iOS or fallback
  final docsDir = await getApplicationDocumentsDirectory();
  final saveDir = Directory('${docsDir.path}/MiniGo');
  if (!await saveDir.exists()) {
    await saveDir.create(recursive: true);
  }
  final savePath = _uniquePath(saveDir.path, fileName);
  await file.copy(savePath);
  return savePath;
}

/// Generates a unique file path to avoid overwriting existing files.
String _uniquePath(String dir, String fileName) {
  var target = '$dir/$fileName';
  if (!File(target).existsSync()) return target;

  final dotIdx = fileName.lastIndexOf('.');
  final baseName = dotIdx > 0 ? fileName.substring(0, dotIdx) : fileName;
  final ext = dotIdx > 0 ? fileName.substring(dotIdx) : '';

  var counter = 1;
  do {
    target = '$dir/${baseName}_($counter)$ext';
    counter++;
  } while (File(target).existsSync());

  return target;
}

const _imageExts = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic'};
const _videoExts = {'mp4', 'mov', 'avi', 'mkv', 'webm', '3gp'};
