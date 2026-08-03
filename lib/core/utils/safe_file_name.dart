/// Reduces an untrusted file name to something safe to concatenate onto a
/// directory path or a URL.
///
/// This is a security primitive, not a formatting helper: `file_name` on
/// `transfer_files` is chosen by the *sender*, and the receiving device feeds
/// it to `File.copy('<dir>/<name>')`. A name like
/// `../../../../data/data/com.Zen.app/shared_prefs/x.xml` would otherwise
/// escape the download directory. Apply it at every sink that turns a remote
/// name into a path or a URL — never trust that the writer sanitized.
///
/// Guarantees about the result: non-empty, no directory separators, no `..`,
/// not a bare directory entry (`.`, `..`, all-whitespace), no control
/// characters, no characters that change how a URL parses, and short enough to
/// survive a caller's prefix/suffix plus the 255-byte filesystem limit.
/// Joining the result onto a directory can therefore never leave it.
String safeFileName(String name) {
  // Separators, path/URL metacharacters, Windows-illegal characters and
  // control characters all collapse to '_'. Replacing rather than dropping the
  // leading segments keeps an odd-but-legitimate name intact — '2026/07
  // report.pdf' stays '2026_07 report.pdf' instead of losing '2026'.
  //
  // '#' and '%' are in the set because the Supabase Storage fallback upload
  // interpolates this name into a URL: '#' would truncate the path into a
  // fragment and '%' would be read as percent-encoding, so the object would be
  // stored under a different key than the one recorded in `storage_path`.
  var safe = name.replaceAll(RegExp(r'[<>:"/\\|?*#%\x00-\x1F\x7F]'), '_');

  // Loop, because a single pass over '....' leaves a fresh '..' behind.
  while (safe.contains('..')) {
    safe = safe.replaceAll('..', '_');
  }

  safe = safe.trim();

  // '.', '  ', '...' and friends are directory entries, not file names.
  if (safe.isEmpty || RegExp(r'^[.\s_]*$').hasMatch(safe)) {
    return 'unnamed_file';
  }

  // Leave room for the caller's own decorations: the upload path prepends an
  // index (`3_`) and the save path may append a dedup counter (`_(2)`).
  const maxLength = 200;
  if (safe.length > maxLength) {
    final dot = safe.lastIndexOf('.');
    // Only treat a trailing dot group as an extension if it looks like one.
    if (dot > 0 && safe.length - dot <= 12) {
      final ext = safe.substring(dot);
      safe = safe.substring(0, maxLength - ext.length) + ext;
    } else {
      safe = safe.substring(0, maxLength);
    }
  }

  return safe;
}
