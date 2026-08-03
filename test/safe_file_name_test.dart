import 'package:flutter_test/flutter_test.dart';
import 'package:minigo/core/utils/safe_file_name.dart';

/// `transfer_files.file_name` is chosen by the sender and the receiver feeds it
/// to `File.copy('<dir>/<name>')`, so these are traversal-containment tests,
/// not cosmetic ones. Pure Dart — no platform channels.
void main() {
  /// The property that actually matters at the sink: joining the result onto a
  /// directory can never leave that directory.
  void staysInside(String input) {
    final out = safeFileName(input);
    expect(out, isNotEmpty, reason: 'input: $input');
    expect(out.contains('/'), isFalse, reason: 'input: $input');
    expect(out.contains('\\'), isFalse, reason: 'input: $input');
    expect(out.contains('..'), isFalse, reason: 'input: $input');
    expect(out, isNot(anyOf('.', '..')), reason: 'input: $input');
  }

  group('path traversal', () {
    test('escapes the download directory', () {
      const payloads = [
        '../../../../data/data/com.Zen.app/shared_prefs/x.xml',
        '..\\..\\..\\Windows\\System32\\evil.dll',
        '/etc/passwd',
        'C:\\Windows\\evil.dll',
        '....//....//evil.so',
        'subdir/nested/file.txt',
        '..',
        '.',
        '../',
        './../.',
      ];
      for (final p in payloads) {
        staysInside(p);
      }
    });

    test('neutralises separators without discarding the rest of the name', () {
      expect(safeFileName('a/b/c/report.pdf'), 'a_b_c_report.pdf');
      expect(safeFileName(r'a\b\c\report.pdf'), 'a_b_c_report.pdf');
      // The point of replacing rather than taking the basename.
      expect(safeFileName('2026/07 report.pdf'), '2026_07 report.pdf');
    });

    test('names that are only directory entries become a placeholder', () {
      expect(safeFileName('..'), 'unnamed_file');
      expect(safeFileName('.'), 'unnamed_file');
      expect(safeFileName('   '), 'unnamed_file');
      expect(safeFileName(''), 'unnamed_file');
      expect(safeFileName('...'), 'unnamed_file');
    });
  });

  group('url and control characters', () {
    test('strips characters that reparse a storage URL', () {
      // '#' truncated the object key into a URL fragment on the Supabase
      // Storage fallback upload; '%' was read as percent-encoding.
      expect(safeFileName('a#b.txt').contains('#'), isFalse);
      expect(safeFileName('a%2e%2e.txt').contains('%'), isFalse);
    });

    test('strips control characters', () {
      expect(safeFileName('evil\u0000.txt').contains('\u0000'), isFalse);
      expect(safeFileName('esc\u001b[2Jclear.txt').contains('\u001b'), isFalse);
      expect(safeFileName('del\u007f.txt').contains('\u007f'), isFalse);
    });
  });

  group('ordinary names survive', () {
    test('are left alone', () {
      for (final name in [
        'report.pdf',
        'My Photo 2026.jpeg',
        'notes-v2_final.txt',
        'résumé.docx',
        '写真.png',
        'archive.tar.gz',
      ]) {
        expect(safeFileName(name), name);
      }
    });
  });

  group('length', () {
    test('caps length while keeping the extension', () {
      final long = '${'a' * 400}.pdf';
      final out = safeFileName(long);
      expect(out.length, lessThanOrEqualTo(200));
      expect(out.endsWith('.pdf'), isTrue);
    });

    test('caps length when there is no plausible extension', () {
      final out = safeFileName('b' * 400);
      expect(out.length, lessThanOrEqualTo(200));
    });

    test('leaves room for caller decorations', () {
      // Upload prepends '<index>_', save may append '_(12)'.
      final out = safeFileName('c' * 400);
      expect('99_${out}_(12)'.length, lessThan(255));
    });
  });

  test('is idempotent', () {
    for (final name in [
      '../../etc/passwd',
      'a#b%c.txt',
      '..',
      'ordinary.png',
    ]) {
      expect(safeFileName(safeFileName(name)), safeFileName(name));
    }
  });
}
