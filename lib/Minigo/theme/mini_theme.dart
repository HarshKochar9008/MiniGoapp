import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

/// Cross-theme constants. Prefer `context.mini.*` inside widgets — these are
/// for the theme builders and for tints that must read the same in light and
/// dark (success / warn / danger / the filled-button blue).
///
/// The palette is deliberately small: neutrals, one blue accent, and three
/// state colours. Those three carry meaning (ok / caution / failed) and are not
/// for decoration — anything purely ornamental uses ink or the accent.
class MiniColors {
  static const paper = Color(0xFFF5F5F7);
  static const paperDeep = Color(0xFFFFFFFF);
  static const ink = Color(0xFF0D0D12);
  static const inkSoft = Color(0xFF6A6A78);
  static const inkFaint = Color(0xFFA2A2B0);
  static const blue600 = Color(0xFF2B5BFF);
  static const blue500 = Color(0xFF4E78FF);
  static const blue200 = Color(0xFFBFCDFF);
  static const blue50 = Color(0xFFEEF1FF);
  static const sand = Color(0xFFEDEDF1);
  static const sandDeep = Color(0xFFDFDFE7);
  static const success = Color(0xFF12B76A);
  static const warn = Color(0xFFF79009);
  static const danger = Color(0xFFF04438);
  static const divider = Color(0x140D0D12);
  static const dividerSoft = Color(0x0A0D0D12);
}

/// Corner radii. Boxes read crisp and squared-off — cards are the roundest
/// rectangular surface, controls one step tighter. Pills stay fully round.
class MiniRadius {
  static const sheet = 22.0;
  static const card = 14.0;
  static const control = 11.0;
  static const tile = 11.0;
  static const chip = 8.0;
  static const pill = 999.0;
}

/// Format a 6-char code as "A4X · 9K2"
String fmtCode(String code) {
  if (code.length < 6) return code;
  return '${code.substring(0, 3)} · ${code.substring(3)}';
}

class MiniText {
  /// Palette the static text styles resolve against. Kept in sync with the
  /// active theme by MaterialApp.builder in app.dart, so every MiniText call
  /// site is theme-aware without needing a BuildContext.
  static MiniThemeExtension palette = MiniThemeExtension.light;

  /// Oversized figure — transfer counts, codes, score-style numerals.
  static TextStyle get displayXL => GoogleFonts.outfit(
        fontSize: 44,
        fontWeight: FontWeight.w600,
        height: 1,
        color: palette.ink,
        letterSpacing: -1.6,
      );

  static TextStyle get display => GoogleFonts.outfit(
        fontSize: 34,
        fontWeight: FontWeight.w600,
        height: 1.05,
        color: palette.ink,
        letterSpacing: -1.1,
      );

  static TextStyle get title => GoogleFonts.outfit(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        height: 1.15,
        color: palette.ink,
        letterSpacing: -0.5,
      );

  /// Card and section heading.
  static TextStyle get heading => GoogleFonts.outfit(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        height: 1.2,
        color: palette.ink,
        letterSpacing: -0.2,
      );

  static TextStyle get body => GoogleFonts.outfit(
        fontSize: 15,
        fontWeight: FontWeight.w400,
        height: 1.45,
        color: palette.ink,
      );

  static TextStyle get bodySoft => GoogleFonts.outfit(
        fontSize: 15,
        fontWeight: FontWeight.w400,
        height: 1.45,
        color: palette.inkSoft,
      );

  static TextStyle get small => GoogleFonts.outfit(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        height: 1.35,
        color: palette.inkSoft,
      );

  /// Small tracked caption above a group of content.
  static TextStyle get label => GoogleFonts.outfit(
        fontSize: 11,
        height: 1,
        color: palette.inkSoft,
        letterSpacing: 0.8,
        fontWeight: FontWeight.w600,
      );

  static TextStyle get button => GoogleFonts.outfit(
        fontSize: 15,
        fontWeight: FontWeight.w500,
        height: 1.1,
        color: palette.ink,
        letterSpacing: -0.1,
      );

  static TextStyle get code => GoogleFonts.jetBrainsMono(
        fontSize: 18,
        height: 1.1,
        color: palette.ink,
        letterSpacing: 1,
        fontWeight: FontWeight.w500,
      );

  static TextStyle get codeLarge => GoogleFonts.jetBrainsMono(
        fontSize: 36,
        height: 1.05,
        color: palette.ink,
        letterSpacing: 3,
        fontWeight: FontWeight.w600,
      );

  static TextStyle get codeSmall => GoogleFonts.jetBrainsMono(
        fontSize: 13,
        height: 1.2,
        color: palette.ink,
        letterSpacing: 0.6,
        fontWeight: FontWeight.w500,
      );
}

// ---------------------------------------------------------------------------
// Theme-adaptive color extension (replaces hardcoded MiniColors in widgets)
// ---------------------------------------------------------------------------

class MiniThemeExtension extends ThemeExtension<MiniThemeExtension> {
  /// Screen background — the recessed layer.
  final Color paper;

  /// Raised card surface. Sits *above* [paper]: white on light grey in light
  /// mode, lifted charcoal in dark mode.
  final Color paperDeep;
  final Color ink;
  final Color inkSoft;
  final Color inkFaint;

  /// Neutral fill for tracks, chips and inset wells.
  final Color sand;
  final Color sandDeep;
  final Color divider;
  final Color dividerSoft;

  /// Blue used as *text or icon color on paper* — lighter in dark mode so it
  /// stays readable on near-black. For filled-button backgrounds keep the
  /// static [MiniColors.blue600] (the white-on-blue pairing works both ways).
  final Color accent;

  /// Low-alpha accent wash for selected rows and icon plates.
  final Color accentSoft;

  /// Card drop shadow color. Near-invisible in dark mode, where the raised
  /// surface reads by lightness instead.
  final Color shadow;

  const MiniThemeExtension({
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
    required this.accentSoft,
    required this.shadow,
  });

  static const light = MiniThemeExtension(
    paper: Color(0xFFF5F5F7),
    paperDeep: Color(0xFFFFFFFF),
    ink: Color(0xFF0D0D12),
    inkSoft: Color(0xFF6A6A78),
    inkFaint: Color(0xFFA2A2B0),
    sand: Color(0xFFEDEDF1),
    sandDeep: Color(0xFFDFDFE7),
    divider: Color(0x140D0D12),
    dividerSoft: Color(0x0A0D0D12),
    accent: Color(0xFF2B5BFF),
    accentSoft: Color(0x142B5BFF),
    shadow: Color(0x120D0D12),
  );

  static const dark = MiniThemeExtension(
    paper: Color(0xFF0A0A0E),
    paperDeep: Color(0xFF15151C),
    ink: Color(0xFFF4F4F7),
    inkSoft: Color(0xFF9A9AAC),
    inkFaint: Color(0xFF5C5C6E),
    sand: Color(0xFF1F1F28),
    sandDeep: Color(0xFF2A2A36),
    divider: Color(0x1AF4F4F7),
    dividerSoft: Color(0x0DF4F4F7),
    accent: Color(0xFF7FA0FF),
    accentSoft: Color(0x1F7FA0FF),
    shadow: Color(0x00000000),
  );

  @override
  MiniThemeExtension copyWith({
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
    Color? accentSoft,
    Color? shadow,
  }) =>
      MiniThemeExtension(
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
        accentSoft: accentSoft ?? this.accentSoft,
        shadow: shadow ?? this.shadow,
      );

  @override
  MiniThemeExtension lerp(MiniThemeExtension? other, double t) {
    if (other == null) return this;
    return MiniThemeExtension(
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
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      shadow: Color.lerp(shadow, other.shadow, t)!,
    );
  }
}

extension MiniContextX on BuildContext {
  MiniThemeExtension get mini =>
      Theme.of(this).extension<MiniThemeExtension>() ??
      MiniThemeExtension.light;

  bool get isDarkMini => Theme.of(this).brightness == Brightness.dark;
}

// ---------------------------------------------------------------------------
// Surface helpers — cards read as raised panels, not outlined boxes.
// ---------------------------------------------------------------------------

/// Soft ambient lift for cards. Empty in dark mode, where the surface reads by
/// lightness rather than shadow.
List<BoxShadow> miniCardShadow(BuildContext context, {bool strong = false}) {
  if (context.isDarkMini) return const [];
  final s = context.mini.shadow;
  return [
    BoxShadow(
      color: s.withValues(alpha: strong ? 0.06 : 0.03),
      blurRadius: strong ? 17 : 10,
      offset: Offset(0, strong ? 6 : 3),
    ),
    BoxShadow(
      color: s.withValues(alpha: 0.018),
      blurRadius: 1.2,
      offset: const Offset(0, 0.6),
    ),
  ];
}

/// Standard raised card decoration. Dark mode swaps the shadow for a hairline
/// so the edge stays legible against near-black.
BoxDecoration miniCard(
  BuildContext context, {
  double radius = MiniRadius.card,
  Color? color,
  bool strong = false,
  Color? borderColor,
}) {
  final c = context.mini;
  return BoxDecoration(
    color: color ?? c.paperDeep,
    borderRadius: BorderRadius.circular(radius),
    boxShadow: miniCardShadow(context, strong: strong),
    border: borderColor != null
        ? Border.all(color: borderColor)
        : (context.isDarkMini ? Border.all(color: c.dividerSoft) : null),
  );
}

/// Inset well — recessed fill for read-only values and code displays.
BoxDecoration miniWell(
  BuildContext context, {
  double radius = MiniRadius.control,
  Color? color,
}) {
  final c = context.mini;
  return BoxDecoration(
    color: color ?? c.sand,
    borderRadius: BorderRadius.circular(radius),
  );
}

/// Diffuse color wash used behind hero art and feature icons.
RadialGradient miniGlow(Color tint, {double strength = 0.28}) => RadialGradient(
      colors: [
        tint.withValues(alpha: strength),
        tint.withValues(alpha: 0),
      ],
    );

// ---------------------------------------------------------------------------
// Theme builders
// ---------------------------------------------------------------------------

ThemeData buildMiniTheme() {
  const c = MiniThemeExtension.light;
  return ThemeData(
    brightness: Brightness.light,
    scaffoldBackgroundColor: c.paper,
    colorScheme: ColorScheme.light(
      primary: MiniColors.blue600,
      onPrimary: Colors.white,
      surface: c.paper,
      onSurface: c.ink,
      surfaceContainerHighest: c.paperDeep,
      secondary: c.ink,
      onSecondary: Colors.white,
      error: MiniColors.danger,
    ),
    extensions: const [c],
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    textTheme: GoogleFonts.outfitTextTheme(ThemeData.light().textTheme).apply(
      fontSizeFactor: 1.0,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: c.paper,
      foregroundColor: c.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      systemOverlayStyle: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
      ),
      titleTextStyle: GoogleFonts.outfit(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: c.ink,
        letterSpacing: -0.3,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.ink,
        foregroundColor: Colors.white,
        minimumSize: const Size(0, 54),
        padding: const EdgeInsets.symmetric(horizontal: 24),
        shape: const StadiumBorder(),
        textStyle:
            GoogleFonts.outfit(fontSize: 15, fontWeight: FontWeight.w500),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.ink,
        backgroundColor: c.paperDeep,
        minimumSize: const Size(0, 54),
        padding: const EdgeInsets.symmetric(horizontal: 24),
        side: BorderSide(color: c.divider),
        shape: const StadiumBorder(),
        textStyle:
            GoogleFonts.outfit(fontSize: 15, fontWeight: FontWeight.w500),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: c.accent,
        shape: const StadiumBorder(),
        textStyle:
            GoogleFonts.outfit(fontSize: 14, fontWeight: FontWeight.w500),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: c.ink,
      elevation: 6,
      contentTextStyle: GoogleFonts.outfit(
        color: Colors.white,
        fontSize: 14,
        fontWeight: FontWeight.w500,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(11)),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: MiniColors.blue600,
      linearTrackColor: c.sand,
      circularTrackColor: c.sand,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.paperDeep,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(MiniRadius.sheet),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.paperDeep,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(MiniRadius.card),
      ),
      titleTextStyle: GoogleFonts.outfit(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: c.ink,
        letterSpacing: -0.4,
      ),
      contentTextStyle: GoogleFonts.outfit(
        fontSize: 15,
        fontWeight: FontWeight.w400,
        color: c.inkSoft,
        height: 1.45,
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) => Colors.white),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return MiniColors.blue600;
        return c.sandDeep;
      }),
      trackOutlineColor:
          WidgetStateProperty.resolveWith((states) => Colors.transparent),
    ),
  );
}

ThemeData buildMiniDarkTheme() {
  const c = MiniThemeExtension.dark;
  return ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: c.paper,
    colorScheme: ColorScheme(
      brightness: Brightness.dark,
      primary: MiniColors.blue500,
      onPrimary: Colors.white,
      secondary: c.ink,
      onSecondary: c.paper,
      error: MiniColors.danger,
      onError: Colors.white,
      surface: c.paper,
      onSurface: c.ink,
      surfaceContainerHighest: c.paperDeep,
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
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: c.ink,
        letterSpacing: -0.3,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.ink,
        foregroundColor: c.paper,
        minimumSize: const Size(0, 54),
        padding: const EdgeInsets.symmetric(horizontal: 24),
        shape: const StadiumBorder(),
        textStyle:
            GoogleFonts.outfit(fontSize: 15, fontWeight: FontWeight.w500),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.ink,
        backgroundColor: c.paperDeep,
        minimumSize: const Size(0, 54),
        padding: const EdgeInsets.symmetric(horizontal: 24),
        side: BorderSide(color: c.divider),
        shape: const StadiumBorder(),
        textStyle:
            GoogleFonts.outfit(fontSize: 15, fontWeight: FontWeight.w500),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: c.accent,
        shape: const StadiumBorder(),
        textStyle:
            GoogleFonts.outfit(fontSize: 14, fontWeight: FontWeight.w500),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: c.sandDeep,
      elevation: 6,
      contentTextStyle: GoogleFonts.outfit(
        color: c.ink,
        fontSize: 14,
        fontWeight: FontWeight.w500,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(11)),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: MiniColors.blue500,
      linearTrackColor: c.sand,
      circularTrackColor: c.sand,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.paperDeep,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(MiniRadius.sheet),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.paperDeep,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(MiniRadius.card),
      ),
      titleTextStyle: GoogleFonts.outfit(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: c.ink,
        letterSpacing: -0.4,
      ),
      contentTextStyle: GoogleFonts.outfit(
        fontSize: 15,
        fontWeight: FontWeight.w400,
        color: c.inkSoft,
        height: 1.45,
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) => Colors.white),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return MiniColors.blue600;
        return c.sandDeep;
      }),
      trackOutlineColor:
          WidgetStateProperty.resolveWith((states) => Colors.transparent),
    ),
  );
}
