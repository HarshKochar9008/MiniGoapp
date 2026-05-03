import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../zensend/theme/zen_theme.dart';

export '../zensend/theme/zen_theme.dart' show ZenColors, ZenText, fmtCode, ZenThemeExtension, ZenContextX;

/// AppColors — mapped to ZenColors for design consistency.
class AppColors {
  static const primary = ZenColors.blue600;
  static const primaryLight = ZenColors.blue500;
  static const primaryContainer = ZenColors.blue600;
  static const onPrimary = ZenColors.paper;

  static const secondary = ZenColors.success;
  static const secondaryContainer = Color(0xFFD4EDDA);

  static const tertiary = ZenColors.warn;
  static const tertiaryContainer = Color(0xFFFFF3CD);

  static const scaffold = ZenColors.paper;
  static const surface = ZenColors.paper;
  static const surfaceContainerLowest = ZenColors.paper;
  static const surfaceContainerLow = ZenColors.paperDeep;
  static const surfaceContainer = ZenColors.sand;
  static const surfaceContainerHigh = ZenColors.sand;
  static const surfaceContainerHighest = ZenColors.sandDeep;
  static const surfaceBright = ZenColors.paper;

  static const onSurface = ZenColors.ink;
  static const onSurfaceVariant = ZenColors.inkSoft;
  static const outline = ZenColors.inkFaint;
  static const outlineVariant = ZenColors.sandDeep;

  static const success = ZenColors.success;
  static const warning = ZenColors.warn;
  static const error = ZenColors.danger;

  static const dialogBg = ZenColors.paper;

  static const cardBg = ZenColors.paper;
  static const cardText = ZenColors.ink;
  static const cardTextSecondary = ZenColors.inkSoft;
  static const cardBorder = ZenColors.divider;

  static const navBarBg = ZenColors.paper;

  static const snackBarBg = ZenColors.ink;
  static const snackBarText = ZenColors.paper;
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

ThemeData buildAppTheme() => buildZenTheme();

ThemeData buildDarkAppTheme() => buildZenDarkTheme();
