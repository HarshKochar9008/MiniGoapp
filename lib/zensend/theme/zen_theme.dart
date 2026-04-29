import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

class ZenColors {
  static const paper = Color(0xFFFBFAF7);
  static const paperDeep = Color(0xFFF4F1EA);
  static const ink = Color(0xFF1A2230);
  static const inkSoft = Color(0xFF5A6478);
  static const inkFaint = Color(0xFF8A93A4);
  static const blue600 = Color(0xFF1558D6);
  static const blue500 = Color(0xFF2E74F0);
  static const blue200 = Color(0xFFA3C0F8);
  static const blue50 = Color(0xFFEBF1FF);
  static const sand = Color(0xFFECE9E2);
  static const sandDeep = Color(0xFFDCD7C8);
  static const success = Color(0xFF4F8D6C);
  static const warn = Color(0xFFC97A4A);
  static const danger = Color(0xFFB44A4A);
  static const divider = Color(0x141A2230);
  static const dividerSoft = Color(0x0A1A2230);
}

/// Format a 6-char code as "A4X · 9K2"
String fmtCode(String code) {
  if (code.length < 6) return code;
  return '${code.substring(0, 3)} · ${code.substring(3)}';
}

class ZenText {
  static TextStyle get display => GoogleFonts.instrumentSerif(
        fontSize: 32,
        height: 1.1,
        color: ZenColors.ink,
        letterSpacing: -0.3,
      );

  static TextStyle get displayItalic => GoogleFonts.instrumentSerif(
        fontSize: 32,
        height: 1.1,
        color: ZenColors.ink,
        letterSpacing: -0.3,
        fontStyle: FontStyle.italic,
      );

  static TextStyle get title => GoogleFonts.instrumentSerif(
        fontSize: 24,
        height: 1.2,
        color: ZenColors.ink,
        letterSpacing: -0.2,
      );

  static TextStyle get titleItalic => GoogleFonts.instrumentSerif(
        fontSize: 24,
        height: 1.2,
        color: ZenColors.ink,
        letterSpacing: -0.2,
        fontStyle: FontStyle.italic,
      );

  static TextStyle get body => GoogleFonts.inter(
        fontSize: 14,
        height: 1.5,
        color: ZenColors.ink,
      );

  static TextStyle get bodySoft => GoogleFonts.inter(
        fontSize: 14,
        height: 1.5,
        color: ZenColors.inkSoft,
      );

  static TextStyle get small => GoogleFonts.inter(
        fontSize: 12,
        height: 1.4,
        color: ZenColors.inkSoft,
      );

  static TextStyle get label => GoogleFonts.inter(
        fontSize: 11,
        height: 1,
        color: ZenColors.inkSoft,
        letterSpacing: 1.6,
        fontWeight: FontWeight.w500,
      );

  static TextStyle get code => GoogleFonts.jetBrainsMono(
        fontSize: 18,
        height: 1.1,
        color: ZenColors.ink,
        letterSpacing: 1.2,
      );

  static TextStyle get codeLarge => GoogleFonts.jetBrainsMono(
        fontSize: 36,
        height: 1.05,
        color: ZenColors.ink,
        letterSpacing: 3,
        fontWeight: FontWeight.w500,
      );

  static TextStyle get codeSmall => GoogleFonts.jetBrainsMono(
        fontSize: 13,
        height: 1.2,
        color: ZenColors.ink,
        letterSpacing: 0.8,
      );
}

ThemeData buildZenTheme() {
  return ThemeData(
    brightness: Brightness.light,
    scaffoldBackgroundColor: ZenColors.paper,
    colorScheme: const ColorScheme.light(
      primary: ZenColors.blue600,
      onPrimary: ZenColors.paper,
      surface: ZenColors.paper,
      onSurface: ZenColors.ink,
      secondary: ZenColors.ink,
      onSecondary: ZenColors.paper,
      error: ZenColors.danger,
    ),
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    textTheme: GoogleFonts.interTextTheme(ThemeData.light().textTheme),
    appBarTheme: AppBarTheme(
      backgroundColor: ZenColors.paper,
      foregroundColor: ZenColors.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      systemOverlayStyle: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
      ),
      titleTextStyle: GoogleFonts.instrumentSerif(
        fontSize: 18,
        color: ZenColors.ink,
        letterSpacing: -0.1,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: ZenColors.ink,
        foregroundColor: ZenColors.paper,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w500),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: ZenColors.ink,
        side: const BorderSide(color: ZenColors.divider),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w500),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: ZenColors.inkSoft,
        textStyle: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w500),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: ZenColors.ink,
      contentTextStyle: GoogleFonts.inter(
        color: ZenColors.paper,
        fontSize: 13,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: ZenColors.blue500,
      linearTrackColor: ZenColors.divider,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: ZenColors.paper,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titleTextStyle: GoogleFonts.instrumentSerif(
        fontSize: 20,
        color: ZenColors.ink,
      ),
      contentTextStyle: GoogleFonts.inter(
        fontSize: 14,
        color: ZenColors.inkSoft,
        height: 1.5,
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return ZenColors.paper;
        return ZenColors.inkFaint;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return ZenColors.ink;
        return ZenColors.divider;
      }),
    ),
  );
}
