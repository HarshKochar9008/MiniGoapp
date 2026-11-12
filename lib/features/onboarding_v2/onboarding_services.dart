import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/notifications/notification_service.dart';
import '../../core/supabase_config.dart';
import '../identity/identity_service.dart';
import 'onboarding_content.dart';
import 'onboarding_sounds.dart';

/// A share card's look, as indexes into [onbCardTones] and [onbCardLines].
typedef OnbCardStyle = ({int tone, int line});

/// Everything the questionnaire onboarding does outside its own widgets.
///
/// Screens never call Supabase, Firebase, the share sheet or the audio player
/// directly — they go through this, so widget tests can pass a fake.
class OnbServices {
  const OnbServices();

  /// Creates (or loads) this device's identity — the same call the classic
  /// onboarding's "Crafting your code" step makes.
  Future<UserIdentity> createIdentity() async {
    if (!SupabaseConfig.isInitialized) {
      await initSupabase();
      SupabaseConfig.startAuthListener();
    }
    return IdentityService.initialize().timeout(const Duration(seconds: 20));
  }

  /// Sets up push (the app's existing setup, which shows the system prompt
  /// unless the OS has already decided) and reports whether notifications
  /// ended up allowed.
  Future<bool> requestNotifications() async {
    await NotificationService.initialize();
    return _notificationsAllowed();
  }

  Future<bool> _notificationsAllowed() async {
    try {
      if (Platform.isAndroid) return await Permission.notification.isGranted;
      // iOS: permission_handler needs Podfile macros to report notification
      // status, so ask Firebase Messaging, which the app already uses.
      final settings =
          await FirebaseMessaging.instance.getNotificationSettings();
      return switch (settings.authorizationStatus) {
        AuthorizationStatus.authorized ||
        AuthorizationStatus.provisional =>
          true,
        _ => false,
      };
    } catch (e) {
      if (kDebugMode) debugPrint('onboarding: notification status failed: $e');
      return false;
    }
  }

  Future<void> preloadSounds() => OnbSounds.preload();

  /// The slot machine's sound for [cue]: the lever, the reels, the code.
  Future<void> playSound(OnbSoundCue cue) => OnbSounds.play(cue);

  Future<void> disposeSounds() => OnbSounds.dispose();

  Future<void> saveNickname(String nickname) =>
      IdentityService.setNickname(nickname);

  Future<void> markComplete() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarding_complete', true);
  }

  /// Saves what the user told us, for later personalisation.
  Future<void> saveAnswers({required Set<OnbPain> relates}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('onb_relates', [for (final p in relates) p.name]);
  }

  /// Remembers the card they styled, so Settings can show it as My card.
  Future<void> saveCardStyle(OnbCardStyle style) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_cardToneKey, style.tone);
    await prefs.setInt(_cardLineKey, style.line);
  }

  /// The card saved by [saveCardStyle]; the first colour and line until then.
  Future<OnbCardStyle> loadCardStyle() async {
    final prefs = await SharedPreferences.getInstance();
    int read(String key, int count) =>
        (prefs.getInt(key) ?? 0).clamp(0, count - 1);
    return (
      tone: read(_cardToneKey, onbCardTones.length),
      line: read(_cardLineKey, onbCardLines.length),
    );
  }

  static const _cardToneKey = 'onb_card_tone';
  static const _cardLineKey = 'onb_card_line';

  /// Opens the share sheet with the card image (when there is one) and text.
  /// Returns true if the user picked a target.
  Future<bool> shareCard({
    required Uint8List? png,
    required String text,
    required String fileStem,
    Rect? origin,
  }) async {
    final files = <XFile>[];
    if (png != null) {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$fileStem.png');
      await file.writeAsBytes(png, flush: true);
      files.add(XFile(file.path, mimeType: 'image/png'));
    }
    final result = await SharePlus.instance.share(
      ShareParams(
        text: text,
        subject: 'MiniGo',
        files: files.isEmpty ? null : files,
        sharePositionOrigin: origin,
      ),
    );
    return result.status == ShareResultStatus.success;
  }
}
