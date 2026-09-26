import 'package:flutter_dotenv/flutter_dotenv.dart';

class AppConstants {
  static final RegExp _shortCodePattern = RegExp(
    '^[$codeAlphabet]{$codeLength}\$',
  );

  static String _cleanEnvValue(String value) {
    final trimmed = value.trim();
    if (trimmed.length >= 2) {
      final startsWithSingle = trimmed.startsWith("'");
      final endsWithSingle = trimmed.endsWith("'");
      final startsWithDouble = trimmed.startsWith('"');
      final endsWithDouble = trimmed.endsWith('"');
      if ((startsWithSingle && endsWithSingle) ||
          (startsWithDouble && endsWithDouble)) {
        return trimmed.substring(1, trimmed.length - 1).trim();
      }
    }
    return trimmed;
  }

  static String get supabaseUrl {
    const fromDefine = String.fromEnvironment('SUPABASE_URL', defaultValue: '');
    if (fromDefine.isNotEmpty) return _cleanEnvValue(fromDefine);
    return _cleanEnvValue(dotenv.env['SUPABASE_URL'] ?? '');
  }

  static String get supabaseAnonKey {
    const fromDefine =
        String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: '');
    if (fromDefine.isNotEmpty) return _cleanEnvValue(fromDefine);
    return _cleanEnvValue(dotenv.env['SUPABASE_ANON_KEY'] ?? '');
  }
  //q ??? 

  /// When true, file bytes are stored on Cloudflare R2 via presigned URLs
  /// minted by the r2-sign-upload / r2-sign-download edge functions
  /// (docs/R2_SETUP.md). Supabase keeps auth, metadata, realtime and RLS.
  /// Safe to enable before R2 is fully set up: every file falls back to the
  /// Supabase Storage path when signing fails.
  static bool get useR2Storage {
    const fromDefine =
        String.fromEnvironment('USE_R2_STORAGE', defaultValue: '');
    final raw = fromDefine.isNotEmpty
        ? fromDefine
        : (dotenv.env['USE_R2_STORAGE'] ?? '');
    return _cleanEnvValue(raw).toLowerCase() == 'true';
  }

  // Support contact shown when the service is unavailable.
  static const supportEmail = 'harshkochar88@gmail.com';

  // Short code alphabet — ambiguous chars excluded (O, 0, I, 1, L)
  static const codeAlphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  static const codeLength = 6;

  // Rooms
  static const maxRoomMembers = 10;
  static const maxRoomNameLength = 50;

  /// Room lifetimes the user can pick at creation. Must match the
  /// `rooms_lifetime_minutes_allowed` CHECK constraint in the database.
  static const roomLifetimeMinutesOptions = [30, 60, 120];
  static const defaultRoomLifetimeMinutes = 60;

  // File limits
  static const maxFileSizeBytes = 100 * 1024 * 1024; // 100 MB
  static const maxFilesPerTransfer = 20;

  /// Wi‑Fi / non‑cellular: confirm “large upload” when total size is at or above this.
  static const largeUploadWarnThresholdBytes = 10 * 1024 * 1024; // 10 MB

  /// [ConnectivityResult.mobile]: confirm sooner so non‑trivial uploads are not silent on metered data.
  static const cellularMeteredWarnThresholdBytes = 5 * 1024 * 1024; // 5 MB

  // Transfer TTL
  static const transferTtlHours = 24;

  // Pagination
  static const transfersPageSize = 50;

  // SharedPreferences keys
  static const prefShortCode = 'short_code';
  static const prefUserDbId = 'user_db_id';
  static const prefAuthUid = 'auth_uid';
  static const prefNickname = 'nickname';

  static String normalizeShortCode(String value) => value.trim().toUpperCase();

  static bool isValidShortCodeFormat(String value) =>
      _shortCodePattern.hasMatch(normalizeShortCode(value));

  // Deep links — QR codes encode a link so the system camera can open the
  // app directly ("scan with normal camera → land on the send screen").
  static const deepLinkScheme = 'minigo';
  static const deepLinkSendHost = 'send';

  /// `minigo://send?code=A4X9K2`
  static String sendDeepLink(String code) =>
      '$deepLinkScheme://$deepLinkSendHost?code=${normalizeShortCode(code)}';

  /// What the user's QR encodes. An https link to the `qr` edge function,
  /// because stock camera apps only treat http(s) URLs as tappable — the
  /// page then bounces into the app. Falls back to the raw scheme link when
  /// the backend URL is unavailable (e.g. misconfigured build).
  static String qrPayloadForCode(String code) {
    final base = supabaseUrl;
    if (base.isEmpty) return sendDeepLink(code);
    return '$base/functions/v1/qr?code=${normalizeShortCode(code)}';
  }

  /// Extracts the recipient code from any MiniGo send link:
  /// `minigo://send?code=X`, the https QR-redirect link, or an intent URL
  /// resolved to the scheme. Returns null when [raw] is not one (e.g. a bare
  /// code from an older QR).
  static String? codeFromSendDeepLink(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null) return null;
    final scheme = uri.scheme.toLowerCase();
    final isSchemeLink =
        scheme == deepLinkScheme && uri.host.toLowerCase() == deepLinkSendHost;
    final isHttpsQrLink = (scheme == 'https' || scheme == 'http') &&
        uri.path.endsWith('/functions/v1/qr');
    if (!isSchemeLink && !isHttpsQrLink) return null;
    final code = normalizeShortCode(uri.queryParameters['code'] ?? '');
    return isValidShortCodeFormat(code) ? code : null;
  }
}
