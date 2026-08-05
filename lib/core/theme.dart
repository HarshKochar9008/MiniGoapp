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
  static final ValueNotifier<ThemeMode> themeMode =
      ValueNotifier<ThemeMode>(ThemeMode.light);

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
      default:
        themeMode.value = ThemeMode.light;
    }
  }

  static Future<void> setThemeMode(ThemeMode mode) async {
    themeMode.value = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeModeKey, mode.name);
  }
}

ThemeData buildAppTheme() => buildMiniTheme();

ThemeData buildDarkAppTheme() => buildMiniDarkTheme();
