import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class WidgetBridge {
  static const _channel = MethodChannel('whoosh/widget');

  /// Call after identity loads so the widget shows the current short code.
  static Future<void> refresh() async {
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod<void>('refreshWidget');
    } catch (_) {}
  }

  /// Returns the action string ('send' or 'qr') if the app was launched via a
  /// widget button, then clears it. Returns null on normal launch.
  static Future<String?> getAndClearAction() async {
    if (kIsWeb) return null;
    try {
      return await _channel.invokeMethod<String>('getAndClearAction');
    } catch (_) {
      return null;
    }
  }
}
