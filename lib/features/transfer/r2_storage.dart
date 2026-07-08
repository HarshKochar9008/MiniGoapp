import '../../core/constants.dart';
import '../../core/supabase_config.dart';

/// Raised when a presigned R2 URL cannot be obtained — R2 secrets not set,
/// edge function not deployed, or the caller is not authorized for the
/// transfer. Callers treat this as "use the Supabase Storage path instead".
class R2SigningException implements Exception {
  final String message;
  R2SigningException(this.message);

  @override
  String toString() => 'R2 signing failed: $message';
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
      // FunctionException (503 r2_not_configured, 401/403/409/410) and plain
      // network failures all land here — every one of them means "this file
      // cannot go through R2 right now".
      throw R2SigningException(e.toString().replaceAll('Exception: ', ''));
    }
  }
}
