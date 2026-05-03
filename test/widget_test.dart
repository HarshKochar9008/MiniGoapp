import 'package:flutter_test/flutter_test.dart';
import 'package:whoosh/core/constants.dart';
import 'package:whoosh/core/utils/short_code_generator.dart';
import 'package:whoosh/features/transfer/transfer_service.dart';

void main() {
  group('ShortCodeGenerator', () {
    test('generates codes of correct length', () {
      final code = ShortCodeGenerator.generate();
      expect(code.length, equals(AppConstants.codeLength));
    });

    test('generates codes using only safe alphabet characters', () {
      for (var i = 0; i < 100; i++) {
        final code = ShortCodeGenerator.generate();
        for (final char in code.split('')) {
          expect(
            AppConstants.codeAlphabet.contains(char),
            isTrue,
            reason: 'Character "$char" not in safe alphabet',
          );
        }
      }
    });

    test('excludes ambiguous characters (O, 0, I, 1, L)', () {
      const ambiguous = ['O', '0', 'I', '1', 'L'];
      for (final char in ambiguous) {
        expect(
          AppConstants.codeAlphabet.contains(char),
          isFalse,
          reason: 'Alphabet should not contain "$char"',
        );
      }
    });

    test('generates unique codes (statistical uniqueness)', () {
      final codes = <String>{};
      for (var i = 0; i < 1000; i++) {
        codes.add(ShortCodeGenerator.generate());
      }
      // With 30^6 = 729 million possibilities, 1000 codes should all be unique
      expect(codes.length, equals(1000));
    });
  });

  group('TransferService.sanitizeFileName', () {
    test('strips path traversal characters', () {
      final result = TransferService.sanitizeFileName('../../etc/passwd');
      expect(result, isNot(contains('..')));
      expect(result, isNot(contains('/')));
      expect(result, isNot(contains('\\')));
    });

    test('strips angle brackets and quotes', () {
      expect(TransferService.sanitizeFileName('<script>evil</script>'),
          '_script_evil__script_');
    });

    test('strips control characters', () {
      expect(TransferService.sanitizeFileName('file\x00name'), 'file_name');
    });

    test('preserves normal file names', () {
      expect(TransferService.sanitizeFileName('photo.jpg'), 'photo.jpg');
      expect(TransferService.sanitizeFileName('my-document_v2.pdf'),
          'my-document_v2.pdf');
    });

    test('handles empty result', () {
      expect(TransferService.sanitizeFileName(''), 'unnamed_file');
    });

    test('strips pipe and wildcard characters', () {
      expect(TransferService.sanitizeFileName('file|name*.txt'),
          'file_name_.txt');
    });
  });

  group('TransferService.formatFileSize', () {
    test('formats bytes', () {
      expect(TransferService.formatFileSize(0), '0 B');
      expect(TransferService.formatFileSize(512), '512 B');
      expect(TransferService.formatFileSize(1023), '1023 B');
    });

    test('formats kilobytes', () {
      expect(TransferService.formatFileSize(1024), '1.0 KB');
      expect(TransferService.formatFileSize(1536), '1.5 KB');
    });

    test('formats megabytes', () {
      expect(TransferService.formatFileSize(1048576), '1.0 MB');
      expect(TransferService.formatFileSize(52428800), '50.0 MB');
    });

    test('formats gigabytes', () {
      expect(TransferService.formatFileSize(1073741824), '1.0 GB');
    });
  });

  group('AppConstants', () {
    test('code alphabet has correct exclusions', () {
      expect(AppConstants.codeAlphabet, isNot(contains('O')));
      expect(AppConstants.codeAlphabet, isNot(contains('0')));
      expect(AppConstants.codeAlphabet, isNot(contains('I')));
      expect(AppConstants.codeAlphabet, isNot(contains('1')));
      expect(AppConstants.codeAlphabet, isNot(contains('L')));
    });

    test('code length is between 6 and 8', () {
      expect(AppConstants.codeLength, greaterThanOrEqualTo(6));
      expect(AppConstants.codeLength, lessThanOrEqualTo(8));
    });

    test('max file size is 100 MB', () {
      expect(AppConstants.maxFileSizeBytes, equals(100 * 1024 * 1024));
    });

    test('max files per transfer is reasonable', () {
      expect(AppConstants.maxFilesPerTransfer, greaterThan(0));
      expect(AppConstants.maxFilesPerTransfer, lessThanOrEqualTo(50));
    });

    test('transfer TTL is defined', () {
      expect(AppConstants.transferTtlHours, greaterThan(0));
    });

    test('short code format validator rejects ambiguous characters', () {
      expect(AppConstants.isValidShortCodeFormat('ABC2K9'), isTrue);
      expect(AppConstants.isValidShortCodeFormat('abC2k9'), isTrue);
      expect(AppConstants.isValidShortCodeFormat('ABC0K9'), isFalse);
      expect(AppConstants.isValidShortCodeFormat('ABCIK9'), isFalse);
      expect(AppConstants.isValidShortCodeFormat('ABCLK9'), isFalse);
      expect(AppConstants.isValidShortCodeFormat('ABC1K9'), isFalse);
    });
  });
}
