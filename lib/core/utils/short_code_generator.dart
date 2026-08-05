import 'dart:math';

import '../../core/constants.dart';

/// Generates random short codes from a safe alphabet.
/// Collision handling (DB uniqueness) is the caller's responsibility.
class ShortCodeGenerator {
  static final _random = Random.secure();

  static String generate() {
    return List.generate(
      AppConstants.codeLength,
      (_) => AppConstants
          .codeAlphabet[_random.nextInt(AppConstants.codeAlphabet.length)],
    ).join();
  }
}
