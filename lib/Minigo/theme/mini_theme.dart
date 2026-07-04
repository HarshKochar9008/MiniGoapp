import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

class MiniColors {
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
  static TextStyle get display => GoogleFonts.outfit(
        fontSize: 32,
        fontWeight: FontWeight.w300,
        height: 1.1,
        color: MiniColors.ink,
        letterSpacing: -0.5,
      );

  static TextStyle get displayItalic => GoogleFonts.outfit(
        fontSize: 32,
        fontWeight: FontWeight.w300,
        height: 1.1,
        color: MiniColors.ink,
        letterSpacing: -0.5,
        fontStyle: FontStyle.italic,
      );

  static TextStyle get title => GoogleFonts.outfit(
        fontSize: 24,
        fontWeight: FontWeight.w300,
        height: 1.2,
        color: MiniColors.ink,
        letterSpacing: -0.3,
      );

  static TextStyle get titleItalic => GoogleFonts.outfit(
        fontSize: 24,
        fontWeight: FontWeight.w300,
        height: 1.2,
        color: MiniColors.ink,
        letterSpacing: -0.3,
        fontStyle: FontStyle.italic,
      );

  static TextStyle get body => GoogleFonts.outfit(
        fontSize: 14,
        fontWeight: FontWeight.w300,
        height: 1.5,
        color: MiniColors.ink,
      );

  static TextStyle get bodySoft => GoogleFonts.outfit(
        fontSize: 14,
        fontWeight: FontWeight.w300,
        height: 1.5,
        color: MiniColors.inkSoft,
      );

  static TextStyle get small => GoogleFonts.outfit(
        fontSize: 12,
        fontWeight: FontWeight.w300,
        height: 1.4,
        color: MiniColors.inkSoft,
      );

  static TextStyle get label => GoogleFonts.outfit(
        fontSize: 11,
        height: 1,
        color: MiniColors.inkSoft,
        letterSpacing: 1.6,
        fontWeight: FontWeight.w400,
      );

  static TextStyle get code => GoogleFonts.jetBrainsMono(
        fontSize: 18,
        height: 1.1,
        color: MiniColors.ink,
        letterSpacing: 1.2,
      );

  static TextStyle get codeLarge => GoogleFonts.jetBrainsMono(
        fontSize: 36,
        height: 1.05,
        color: MiniColors.ink,
        letterSpacing: 3,
        fontWeight: FontWeight.w400,
      );

  static TextStyle get codeSmall => GoogleFonts.jetBrainsMono(
        fontSize: 13,
        height: 1.2,
        color: MiniColors.ink,
        letterSpacing: 0.8,
      );
}

// ---------------------------------------------------------------------------
// Theme-adaptive color extension (replaces hardcoded MiniColors in widgets)
// ---------------------------------------------------------------------------

class ZenThemeExtension extends ThemeExtension<ZenThemeExtension> {
  final Color paper;
  final Color paperDeep;
  final Color ink;
  final Color inkSoft;
  final Color inkFaint;
  final Color sand;
  final Color sandDeep;
  final Color divider;
  final Color dividerSoft;

  /// Blue used as *text or icon color on paper* — lighter in dark mode so it
  /// stays readable on near-black. For filled-button backgrounds keep the
  /// static [ZenColors.blue600] (the white-on-blue pairing works both ways).
  final Color accent;

  const ZenThemeExtension({
    required this.paper,
    required this.paperDeep,
    required this.ink,
    required this.inkSoft,
    required this.inkFaint,
    required this.sand,
    required this.sandDeep,
    required this.divider,
    required this.dividerSoft,
    required this.accent,
  });

  static const light = ZenThemeExtension(
    paper: Color(0xFFFBFAF7),
    paperDeep: Color(0xFFF4F1EA),
    ink: Color(0xFF1A2230),
    inkSoft: Color(0xFF5A6478),
    inkFaint: Color(0xFF8A93A4),
    sand: Color(0xFFECE9E2),
    sandDeep: Color(0xFFDCD7C8),
    divider: Color(0x141A2230),
    dividerSoft: Color(0x0A1A2230),
    accent: Color(0xFF1558D6),
  );

  static const dark = ZenThemeExtension(
    paper: Color(0xFF0E1116),
    paperDeep: Color(0xFF161D27),
    ink: Color(0xFFE8E4DA),
    inkSoft: Color(0xFF8A9AB0),
    inkFaint: Color(0xFF4A5A6A),
    sand: Color(0xFF1A2230),
    sandDeep: Color(0xFF1E2840),
    divider: Color(0x1AE8E4DA),
    dividerSoft: Color(0x0DE8E4DA),
    accent: Color(0xFF7CA7F7),
  );

  @override
  ZenThemeExtension copyWith({
    Color? paper,
    Color? paperDeep,
    Color? ink,
    Color? inkSoft,
    Color? inkFaint,
    Color? sand,
    Color? sandDeep,
    Color? divider,
    Color? dividerSoft,
    Color? accent,
  }) =>
      ZenThemeExtension(
        paper: paper ?? this.paper,
        paperDeep: paperDeep ?? this.paperDeep,
        ink: ink ?? this.ink,
        inkSoft: inkSoft ?? this.inkSoft,
        inkFaint: inkFaint ?? this.inkFaint,
        sand: sand ?? this.sand,
        sandDeep: sandDeep ?? this.sandDeep,
        divider: divider ?? this.divider,
        dividerSoft: dividerSoft ?? this.dividerSoft,
        accent: accent ?? this.accent,
      );

  @override
  ZenThemeExtension lerp(ZenThemeExtension? other, double t) {
    if (other == null) return this;
    return ZenThemeExtension(
      paper: Color.lerp(paper, other.paper, t)!,
      paperDeep: Color.lerp(paperDeep, other.paperDeep, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      inkSoft: Color.lerp(inkSoft, other.inkSoft, t)!,
      inkFaint: Color.lerp(inkFaint, other.inkFaint, t)!,
      sand: Color.lerp(sand, other.sand, t)!,
      sandDeep: Color.lerp(sandDeep, other.sandDeep, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      dividerSoft: Color.lerp(dividerSoft, other.dividerSoft, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
    );
  }
}

extension ZenContextX on BuildContext {
  ZenThemeExtension get zen =>
      Theme.of(this).extension<ZenThemeExtension>() ?? ZenThemeExtension.light;
}

// ---------------------------------------------------------------------------
// Theme builders
// ---------------------------------------------------------------------------

ThemeData buildZenTheme() {
  return ThemeData(
    brightness: Brightness.light,
    scaffoldBackgroundColor: MiniColors.paper,
    colorScheme: const ColorScheme.light(
      primary: MiniColors.blue600,
      onPrimary: MiniColors.paper,
      surface: MiniColors.paper,
      onSurface: MiniColors.ink,
      secondary: MiniColors.ink,
      onSecondary: MiniColors.paper,
      error: MiniColors.danger,
    ),
    extensions: const [ZenThemeExtension.light],
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    textTheme: GoogleFonts.outfitTextTheme(ThemeData.light().textTheme).apply(
      fontSizeFactor: 1.0,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: MiniColors.paper,
      foregroundColor: MiniColors.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      systemOverlayStyle: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
      ),
      titleTextStyle: GoogleFonts.outfit(
        fontSize: 18,
        fontWeight: FontWeight.w300,
        color: MiniColors.ink,
        letterSpacing: -0.2,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: MiniColors.ink,
        foregroundColor: MiniColors.paper,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: GoogleFonts.outfit(fontSize: 14, fontWeight: FontWeight.w400),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: MiniColors.ink,
        side: const BorderSide(color: MiniColors.divider),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: GoogleFonts.outfit(fontSize: 14, fontWeight: FontWeight.w400),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: MiniColors.inkSoft,
        textStyle: GoogleFonts.outfit(fontSize: 13, fontWeight: FontWeight.w400),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: MiniColors.ink,
      contentTextStyle: GoogleFonts.outfit(
        color: MiniColors.paper,
        fontSize: 13,
        fontWeight: FontWeight.w300,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: MiniColors.blue500,
      linearTrackColor: MiniColors.divider,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: MiniColors.paper,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titleTextStyle: GoogleFonts.outfit(
        fontSize: 20,
        fontWeight: FontWeight.w300,
        color: MiniColors.ink,
        letterSpacing: -0.2,
      ),
      contentTextStyle: GoogleFonts.outfit(
        fontSize: 14,
        fontWeight: FontWeight.w300,
        color: MiniColors.inkSoft,
        height: 1.5,
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return MiniColors.paper;
        return MiniColors.inkFaint;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return MiniColors.ink;
        return MiniColors.divider;
      }),
    ),
  );
}

ThemeData buildZenDarkTheme() {
  const c = ZenThemeExtension.dark;
  return ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: c.paper,
    colorScheme: ColorScheme(
      brightness: Brightness.dark,
      primary: MiniColors.blue600,
      onPrimary: c.paper,
      secondary: c.ink,
      onSecondary: c.paper,
      error: MiniColors.danger,
      onError: c.paper,
      surface: c.paper,
      onSurface: c.ink,
    ),
    extensions: const [c],
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    textTheme: GoogleFonts.outfitTextTheme(ThemeData.dark().textTheme),
    appBarTheme: AppBarTheme(
      backgroundColor: c.paper,
      foregroundColor: c.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      systemOverlayStyle: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
      titleTextStyle: GoogleFonts.outfit(
        fontSize: 18,
        fontWeight: FontWeight.w300,
        color: c.ink,
        letterSpacing: -0.2,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.ink,
        foregroundColor: c.paper,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: GoogleFonts.outfit(fontSize: 14, fontWeight: FontWeight.w400),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.ink,
        side: BorderSide(color: c.divider),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: GoogleFonts.outfit(fontSize: 14, fontWeight: FontWeight.w400),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: c.inkSoft,
        textStyle: GoogleFonts.outfit(fontSize: 13, fontWeight: FontWeight.w400),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: c.ink,
      contentTextStyle: GoogleFonts.outfit(
        color: c.paper,
        fontSize: 13,
        fontWeight: FontWeight.w300,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: MiniColors.blue500,
      linearTrackColor: c.divider,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.paperDeep,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titleTextStyle: GoogleFonts.outfit(
        fontSize: 20,
        fontWeight: FontWeight.w300,
        color: c.ink,
        letterSpacing: -0.2,
      ),
      contentTextStyle: GoogleFonts.outfit(
        fontSize: 14,
        fontWeight: FontWeight.w300,
        color: c.inkSoft,
        height: 1.5,
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return c.paper;
        return c.inkFaint;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return MiniColors.blue600;
        return c.divider;
      }),
    ),
  );
}
