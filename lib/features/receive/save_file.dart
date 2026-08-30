import 'dart:io';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart' show MethodChannel, PlatformException;
import 'package:gal/gal.dart';
import 'package:mime/mime.dart';
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

/// Where a saved file ended up: [label] for the UI, [open] as the handle
/// [openSavedFile] needs, or null when nothing on this platform can open it.
typedef SavedFile = ({String label, String? open});

/// Save a file to a user-visible location.
/// Images / videos → device gallery.  Everything else → Downloads / Documents.
///
/// [fileName] arrives from `transfer_files.file_name`, i.e. it is chosen by the
/// sender — it is sanitized here, at the sink, rather than trusted to have been
/// sanitized on the way in. See [safeFileName].
Future<SavedFile> saveFileToDevice(File file, String rawFileName) async {
  final fileName = safeFileName(rawFileName);
  final ext = fileName.split('.').last.toLowerCase();
  final isImage = _imageExts.contains(ext);
  final isVideo = _videoExts.contains(ext);

  // Android writes every kind through MediaStore itself: the plugin hands back
  // no handle for what it saved, so Open could only ever raise the gallery on
  // its own front page rather than the picture that just arrived.
  if (defaultTargetPlatform == TargetPlatform.android) {
    return _saveToAndroid(
      file,
      fileName,
      kind: isImage
          ? 'image'
          : isVideo
              ? 'video'
              : 'download',
    );
  }

  if (isImage || isVideo) {
    await _ensurePhotosPermission();
    try {
      if (isImage) {
        await Gal.putImage(file.path, album: 'MiniGo');
      } else {
        await Gal.putVideo(file.path, album: 'MiniGo');
      }
      // No URL scheme reaches one asset in Photos, so Quick Look previews the
      // downloaded copy instead — same bytes, and it opens in the app.
      // ponytail: the temp copy is the system's to purge, so a preview opened
      // long after the download can find it gone; the sheet says so.
      return (label: 'Gallery (MiniGo album)', open: file.path);
    } catch (e) {
      throw SaveFileException('Could not save to gallery: $e');
    }
  }

  return _saveToIosDocuments(file, fileName);
}

/// Shows the saved file itself: the viewer app on Android, a Quick Look sheet
/// on iOS. [target] is [SavedFile.open] — a MediaStore row or a file path.
Future<void> openSavedFile(String target) async {
  await _saveChannel.invokeMethod<void>('openFile', {'target': target});
}

/// iOS only. An app's own MediaStore entries need no permission on Android
/// API 29+, and the legacy branch asks for storage where it actually fails.
Future<void> _ensurePhotosPermission() async {
  final status = await Permission.photosAddOnly.request();
  if (!status.isGranted) {
    throw PermissionDeniedException(
      'Gallery access denied. Please enable it in Settings → Privacy → Photos.',
    );
  }
}

const _saveChannel = MethodChannel('minigo/native_save');

/// iOS: Documents is the directory the Files app exposes for this app.
Future<SavedFile> _saveToIosDocuments(File file, String fileName) async {
  final docsDir = await getApplicationDocumentsDirectory();
  final saveDir = Directory('${docsDir.path}/MiniGo');
  if (!await saveDir.exists()) {
    await saveDir.create(recursive: true);
  }
  final savePath = _uniquePath(saveDir.path, fileName);
  await file.copy(savePath);
  return (label: savePath, open: savePath);
}

/// Hands the file to the platform, which writes it through MediaStore — the
/// MiniGo album for `image` and `video`, Downloads for everything else — and
/// returns the `content://` row it created, or the file path on the legacy
/// branch.
///
/// Writing `/storage/emulated/0/Download` from Dart cannot work on API 29+ —
/// the manifest caps `WRITE_EXTERNAL_STORAGE` at 29 — and the directory still
/// reports as existing there, so the copy used to fail with EACCES after a
/// full download and decrypt. Only the legacy branch below API 29 needs a
/// permission, which is why `permission_denied` is retried once.
Future<SavedFile> _saveToAndroid(
  File file,
  String fileName, {
  required String kind,
}) async {
  for (var attempt = 0; attempt < 2; attempt++) {
    try {
      final saved = await _saveChannel.invokeMethod<String>('saveToMediaStore', {
        'sourcePath': file.path,
        'fileName': fileName,
        'mimeType': lookupMimeType(fileName),
        'kind': kind,
      });
      // Only a MediaStore row can be handed to ACTION_VIEW; the pre-Q branch
      // returns a bare path, which no other app is allowed to read.
      final uri = saved != null && saved.startsWith('content://') ? saved : null;
      return (
        label: kind == 'download' ? 'Downloads' : 'Gallery (MiniGo album)',
        open: uri,
      );
    } on PlatformException catch (e) {
      if (e.code == 'permission_denied' && attempt == 0) {
        if (await Permission.storage.request().isGranted) continue;
        throw PermissionDeniedException(
          'Storage access denied. Please enable it in Settings → App Permissions.',
        );
      }
      throw SaveFileException('Could not save the file: ${e.message ?? e.code}');
    }
  }
  throw SaveFileException('Could not save the file');
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
