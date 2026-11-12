import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';

/// A [PlatformFile] for a file already on local disk that did not come out of
/// the picker: one shared in from another app, or one restored from a saved
/// upload job.
///
/// Since file_picker 12, [PlatformFile] is abstract and only each platform's
/// picker can build one, so the app needs its own to wrap a path.
base class LocalPlatformFile extends PlatformFile {
  LocalPlatformFile({required this.name, required String path, int? size})
      : uri = Uri.file(path),
        _size = size;

  @override
  final String name;

  @override
  final Uri uri;

  /// The size the source reported, if any. Null makes [length] read the file.
  final int? _size;

  @override
  XFile get xFile => XFile(uri.toFilePath(), name: name);

  @override
  int? lengthSync() => _size;

  @override
  Future<int?> length() async {
    if (_size != null) return _size;
    try {
      return await File(uri.toFilePath()).length();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Uint8List> readAsBytes() => xFile.readAsBytes();

  @override
  Stream<Uint8List> readAsByteStream() => xFile.openRead();
}
