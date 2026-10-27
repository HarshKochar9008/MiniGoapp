import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../Minigo/theme/mini_theme.dart';

export '../Minigo/theme/mini_theme.dart'
    show
        MiniColors,
        MiniRadius,
        MiniText,
        fmtCode,
        MiniThemeExtension,
        MiniContextX,
        miniCard,
        miniCardShadow,
        miniWell,
        miniGlow;

class ThemeController {
  static const _themeModeKey = 'theme_mode';

  /// What a fresh install uses, and what resetting preferences returns to.
  static const defaultMode = ThemeMode.light;

  static final ValueNotifier<ThemeMode> themeMode =
      ValueNotifier<ThemeMode>(defaultMode);

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final savedMode = prefs.getString(_themeModeKey);
    switch (savedMode) {
      case 'dark':
        themeMode.value = ThemeMode.dark;
        break;
      case 'system':
        themeMode.value = ThemeMode.system;
        break;
      case 'light':
        themeMode.value = ThemeMode.light;
        break;
      default:
        themeMode.value = defaultMode;
    }
  }

  static Future<void> setThemeMode(ThemeMode mode) async {
    themeMode.value = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeModeKey, mode.name);
  }

  /// Forgets the saved choice so the app follows [defaultMode] again.
  static Future<void> reset() async {
    themeMode.value = defaultMode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_themeModeKey);
  }
}

ThemeData buildAppTheme() => buildMiniTheme();

ThemeData buildDarkAppTheme() => buildMiniDarkTheme();
