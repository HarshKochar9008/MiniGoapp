import 'package:supabase_flutter/supabase_flutter.dart' show FunctionException;

import '../../core/constants.dart';
import '../../core/supabase_config.dart';

/// R2 cannot be used right now — R2 secrets not set (503
/// `r2_not_configured`), edge function not deployed, a 5xx, or a network
/// failure. Callers treat this as "use the Supabase Storage path instead".
class R2SigningException implements Exception {
  final String message;
  R2SigningException(this.message);

  @override
  String toString() => 'R2 signing failed: $message';
}

/// The signer answered and said no: 401 (session), 403 (not a party to this
/// transfer), 409 (transfer no longer accepts uploads) or 410 (transfer
/// expired). Deliberately NOT an [R2SigningException]: falling back to
/// Supabase Storage here would route around the server's decision, because
/// Supabase Storage was the path the refusal exists to close.
class R2RefusedException implements Exception {
  final int status;
  final String message;
  R2RefusedException(this.status, this.message);

  /// 409 from r2-sign-upload: the transfer is completed or expired.
  bool get notAcceptingUploads => status == 409;

  /// 410 from r2-sign-download: the transfer has expired.
  bool get expired => status == 410;

  @override
  String toString() => 'R2 signing refused ($status): $message';
}

/// Client for the Cloudflare R2 hybrid storage path.
///
/// File bytes go directly to R2 via presigned URLs minted by the
/// `r2-sign-upload` / `r2-sign-download` Supabase edge functions, which
/// enforce the same sender/receiver rules as the storage.objects RLS
/// policies. Auth, metadata, realtime and RLS all stay on Supabase.
/// Object keys are identical to `transfer_files.storage_path`
/// (`<transferId>/<fileName>`), so no schema change is needed.
class R2Storage {
  static bool get enabled => AppConstants.useR2Storage;

  /// Statuses the signers use to refuse a request outright.
  static const refusalStatuses = {401, 403, 409, 410};

  /// Presigned PUT URL for one file of a transfer the caller is sending.
  static Future<String> getUploadUrl({
    required String transferId,
    required String fileName,
  }) =>
      _sign('r2-sign-upload', {
        'transfer_id': transferId,
        'file_name': fileName,
      });

  /// Presigned GET URL for a stored file the caller may download.
  static Future<String> getDownloadUrl(String storagePath) =>
      _sign('r2-sign-download', {'storage_path': storagePath});

  /// Maps a signer failure to refused vs unavailable. Pure; unit-tested.
  static Exception classifyFailure(Object error, String functionName) {
    if (error is FunctionException && refusalStatuses.contains(error.status)) {
      final details = error.details;
      final reason = details is Map && details['error'] != null
          ? details['error'].toString()
          : (error.reasonPhrase ?? 'refused');
      return R2RefusedException(error.status, reason);
    }
    // 503 r2_not_configured, other 5xx, FunctionsFetchException (status 0)
    // and plain network errors: R2 is unavailable, not refusing.
    return R2SigningException(
      '$functionName: ${error.toString().replaceAll('Exception: ', '')}',
    );
  }

  static Future<String> _sign(
    String functionName,
    Map<String, dynamic> body,
  ) async {
    try {
      await SupabaseConfig.ensureValidSession();
      final res = await SupabaseConfig.client.functions.invoke(
        functionName,
        body: body,
      );
      final data = res.data;
      final url = (data is Map) ? data['url']?.toString() : null;
      if (url == null || url.isEmpty) {
        throw R2SigningException('no url in $functionName response');
      }
      return url;
    } on R2SigningException {
      rethrow;
    } catch (e) {
      throw classifyFailure(e, functionName);
    }
  }
}
