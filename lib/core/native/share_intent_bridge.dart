import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A file another app shared to us via the system share sheet, already
/// copied into our cache directory by the native side.
class SharedIncomingFile {
  final String path;
  final String name;
  final int size;
  const SharedIncomingFile({
    required this.path,
    required this.name,
    required this.size,
  });
}

class ShareIntentBridge {
  static const _channel = MethodChannel('minigo/share_intent');

  /// Returns files shared to the app from another app's share sheet (if any),
  /// then clears them natively so they are only handled once.
  static Future<List<SharedIncomingFile>> getAndClearSharedFiles() async {
    if (kIsWeb) return const [];
    try {
      final raw =
          await _channel.invokeListMethod<Map>('getAndClearSharedFiles');
      if (raw == null) return const [];
      return raw
          .map((entry) => SharedIncomingFile(
                path: entry['path'] as String,
                name: entry['name'] as String,
                size: (entry['size'] as num).toInt(),
              ))
          .toList();
    } catch (_) {
      return const [];
    }
  }
}
