import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:minigo/Minigo/theme/mini_theme.dart';

/// main.dart turns google_fonts' runtime fetching off, so a weight that isn't
/// in assets/google_fonts/ doesn't fail loudly: its text silently falls back
/// to the system font. Bundle a missing one with tool/fetch_fonts.py.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  const variants = {
    100: 'Thin',
    200: 'ExtraLight',
    300: 'Light',
    400: 'Regular',
    500: 'Medium',
    600: 'SemiBold',
    700: 'Bold',
    800: 'ExtraBold',
    900: 'Black',
  };

  /// `outfit`, 600 → assets/google_fonts/Outfit-SemiBold.ttf
  String asset(String method, int weight) {
    final family = method[0].toUpperCase() + method.substring(1);
    return 'assets/google_fonts/$family-${variants[weight]}.ttf';
  }

  test('every weight a GoogleFonts call names is bundled', () {
    final missing = <String>[];
    final call = RegExp(r'GoogleFonts\.(\w+)\(');
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));
    for (final file in files) {
      final source = file.readAsStringSync();
      for (final match in call.allMatches(source)) {
        final args = _arguments(source, match.end);
        final where = '${file.path}:${_line(source, match.start)}';
        expect(args.contains('FontStyle.italic'), isFalse,
            reason: '$where: no italic is bundled');
        final weights = [
          for (final w in RegExp(r'FontWeight\.w(\d00)').allMatches(args))
            int.parse(w.group(1)!),
        ];
        if (weights.isEmpty) {
          expect(args.contains('fontWeight:'), isFalse,
              reason: '$where: name the weight as FontWeight.wNNN so this '
                  'test can check it');
          // A textStyle: takes its weight from the theme, checked below.
          if (!args.contains('textStyle:')) weights.add(400);
        }
        for (final weight in weights) {
          final path = asset(match.group(1)!, weight);
          if (!File(path).existsSync()) missing.add('$path, for $where');
        }
      }
    }
    expect(missing, isEmpty);
  });

  test('every weight in the text theme is bundled', () {
    for (final theme in [buildMiniTheme(), buildMiniDarkTheme()]) {
      final t = theme.textTheme;
      for (final style in [
        t.displayLarge, t.displayMedium, t.displaySmall, //
        t.headlineLarge, t.headlineMedium, t.headlineSmall,
        t.titleLarge, t.titleMedium, t.titleSmall,
        t.bodyLarge, t.bodyMedium, t.bodySmall,
        t.labelLarge, t.labelMedium, t.labelSmall,
      ]) {
        expect(style?.fontFamily, startsWith('Outfit'));
        final path =
            asset('outfit', (style!.fontWeight ?? FontWeight.w400).value);
        expect(File(path).existsSync(), isTrue, reason: path);
      }
    }
  });

  test('google_fonts finds every bundled file under its name', () async {
    final styles = {
      'Outfit': (FontWeight w) => GoogleFonts.outfit(fontWeight: w),
      'JetBrainsMono': (FontWeight w) =>
          GoogleFonts.jetBrainsMono(fontWeight: w),
    };
    final bundled = Directory('assets/google_fonts')
        .listSync()
        .map((f) => f.uri.pathSegments.last)
        .where((name) => name.endsWith('.ttf'));
    for (final name in bundled) {
      final [family, variant] = name.replaceAll('.ttf', '').split('-');
      final weight = variants.entries.firstWhere((e) => e.value == variant);
      styles[family]!(FontWeight.values[weight.key ~/ 100 - 1]);
    }
    // Throws if any of them had to be fetched (fetching is off).
    await GoogleFonts.pendingFonts();
  });
}

/// The text between the parenthesis before [start] and its partner.
String _arguments(String source, int start) {
  var depth = 1;
  var i = start;
  while (depth > 0 && i < source.length) {
    final ch = source[i++];
    if (ch == '(') depth++;
    if (ch == ')') depth--;
  }
  return source.substring(start, i - 1);
}

int _line(String source, int offset) =>
    '\n'.allMatches(source.substring(0, offset)).length + 1;
