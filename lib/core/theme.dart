import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../Minigo/theme/mini_theme.dart';

export '../Minigo/theme/mini_theme.dart' show MiniColors, MiniText, fmtCode, MiniThemeExtension, MiniContextX;

/// AppColors — mapped to MiniColors for design consistency.
class AppColors {
  static const primary = MiniColors.blue600;
  static const primaryLight = MiniColors.blue500;
  static const primaryContainer = MiniColors.blue600;
  static const onPrimary = MiniColors.paper;

  static const secondary = MiniColors.success;
  static const secondaryContainer = Color(0xFFD4EDDA);

  static const tertiary = MiniColors.warn;
  static const tertiaryContainer = Color(0xFFFFF3CD);

  static const scaffold = MiniColors.paper;
  static const surface = MiniColors.paper;
  static const surfaceContainerLowest = MiniColors.paper;
  static const surfaceContainerLow = MiniColors.paperDeep;
  static const surfaceContainer = MiniColors.sand;
  static const surfaceContainerHigh = MiniColors.sand;
  static const surfaceContainerHighest = MiniColors.sandDeep;
  static const surfaceBright = MiniColors.paper;

  static const onSurface = MiniColors.ink;
  static const onSurfaceVariant = MiniColors.inkSoft;
  static const outline = MiniColors.inkFaint;
  static const outlineVariant = MiniColors.sandDeep;

  static const success = MiniColors.success;
  static const warning = MiniColors.warn;
  static const error = MiniColors.danger;

  static const dialogBg = MiniColors.paper;

  static const cardBg = MiniColors.paper;
  static const cardText = MiniColors.ink;
  static const cardTextSecondary = MiniColors.inkSoft;
  static const cardBorder = MiniColors.divider;

  static const navBarBg = MiniColors.paper;

  static const snackBarBg = MiniColors.ink;
  static const snackBarText = MiniColors.paper;
}

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
