import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:package_info_plus/package_info_plus.dart';

enum UpdateStatus { upToDate, available, notListed }

class UpdateCheckResult {
  final UpdateStatus status;
  final String? storeVersion;
  final Uri? storeUrl;

  const UpdateCheckResult(this.status, {this.storeVersion, this.storeUrl});
}

/// True when [candidate] is a later dotted version than [current]
/// ("1.10.0" beats "1.9.2"). Build suffixes and non-numeric parts count as 0.
bool isNewerVersion(String candidate, String current) {
  List<int> parts(String v) => v
      .split(RegExp(r'[.+\-]'))
      .take(3)
      .map((p) => int.tryParse(p) ?? 0)
      .toList();
  final a = parts(candidate);
  final b = parts(current);
  for (var i = 0; i < 3; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}

/// Asks the App Store which version of MiniGo is live. Only Apple offers a
/// public lookup; on Android the Play listing itself shows any update.
abstract final class AppStoreUpdateCheck {
  static Future<UpdateCheckResult> run(PackageInfo info) async {
    final country = PlatformDispatcher.instance.locale.countryCode;
    final uri = Uri.https('itunes.apple.com', '/lookup', {
      'bundleId': info.packageName,
      if (country != null && country.isNotEmpty)
        'country': country.toLowerCase(),
    });

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(uri);
      final response =
          await request.close().timeout(const Duration(seconds: 15));
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'App Store lookup failed (${response.statusCode})',
          uri: uri,
        );
      }
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 15));
      final results = (jsonDecode(body) as Map<String, dynamic>)['results'];
      final listing = results is List
          ? results
              .whereType<Map<String, dynamic>>()
              .where((r) => _isMiniGo(r, info))
              .firstOrNull
          : null;
      final storeVersion = listing?['version']?.toString();
      if (listing == null || storeVersion == null) {
        return const UpdateCheckResult(UpdateStatus.notListed);
      }
      return UpdateCheckResult(
        isNewerVersion(storeVersion, info.version)
            ? UpdateStatus.available
            : UpdateStatus.upToDate,
        storeVersion: storeVersion,
        storeUrl: Uri.tryParse(listing['trackViewUrl']?.toString() ?? ''),
      );
    } finally {
      client.close(force: true);
    }
  }

  /// A bundle id is unique on the store but doesn't prove the listing is
  /// ours, so the name has to match too — another developer's app on the
  /// same id must never be offered as an update.
  static bool _isMiniGo(Map<String, dynamic> listing, PackageInfo info) {
    String normalize(String s) =>
        s.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
    final appName = normalize(info.appName.isEmpty ? 'MiniGo' : info.appName);
    return listing['bundleId'] == info.packageName &&
        normalize(listing['trackName']?.toString() ?? '').contains(appName);
  }
}
