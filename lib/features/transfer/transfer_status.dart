import '../../core/constants.dart';

/// Lifecycle of one `transfers` row, i.e. `transfers.status`.
///
/// The column is free text on the server (VARCHAR, or a legacy Postgres enum),
/// so every read goes through [parse] / [effectiveOf] and every "may I …?"
/// question through a named capability below. Call sites never compare raw
/// status strings: five screens and three edge functions used to each keep
/// their own idea of which statuses were final, and disagreed.
///
/// ```text
///            ┌──────────── resume ◄───────────┐
///            ▼                                │
///   insert ► pending ──► completed            │
///            │   └─────► partial ─────────────┤
///            │   └─────► failed ──────────────┘
///            │
///   any non-expired ──(server sweep / 24 h TTL)──► expired   (terminal)
/// ```
///
/// The server enforces the same rules (migration
/// 20261113000001_transfer_status_lifecycle): expired is terminal, completed
/// may only become expired, and only the service role may write expired.
enum TransferStatus {
  pending('pending'),

  /// Legacy value. This client never writes it; it reads as an upload in
  /// progress, exactly like [pending].
  uploading('uploading'),
  completed('completed'),
  partial('partial'),
  failed('failed'),
  expired('expired');

  const TransferStatus(this.dbValue);

  /// The value stored in `transfers.status`.
  final String dbValue;

  /// How long a transfer lives after `created_at`. Mirrors `TTL_HOURS` in the
  /// expire-transfers edge function.
  static const ttl = Duration(hours: AppConstants.transferTtlHours);

  /// Parses a stored status. Null, empty and unknown values read as [pending]:
  /// the column defaults to 'pending', and an unrecognised value must never
  /// unlock a capability (it can't be final, downloadable-only, etc. by
  /// accident of spelling).
  static TransferStatus parse(Object? raw) {
    final s = (raw ?? '').toString().trim().toLowerCase();
    for (final v in values) {
      if (v.dbValue == s) return v;
    }
    return pending;
  }

  /// The status as the client should act on it: the stored value, except that
  /// a transfer older than [ttl] is [expired] even before the server sweep
  /// (which runs every 15 minutes) has written that. Use this — not [parse] —
  /// for anything shown to the user or used to allow a download/upload.
  static TransferStatus effective(
    Object? rawStatus,
    Object? createdAt, {
    DateTime? now,
  }) {
    final status = parse(rawStatus);
    if (status == expired) return status;
    final created = createdAt is DateTime
        ? createdAt
        : DateTime.tryParse((createdAt ?? '').toString());
    if (created == null) return status;
    final cutoff = (now ?? DateTime.now()).toUtc().subtract(ttl);
    return created.toUtc().isBefore(cutoff) ? expired : status;
  }

  /// [effective] for a `transfers` row (or realtime record).
  static TransferStatus effectiveOf(
    Map<String, dynamic> row, {
    DateTime? now,
  }) =>
      effective(row['status'], row['created_at'], now: now);

  /// The sender's run may still be adding files: the receiver shows the
  /// sender's live per-file progress.
  bool get uploadActive => this == pending || this == uploading;

  /// Receiver: show the "Live from sender" progress list.
  bool get showLiveProgress => uploadActive;

  /// The sender's run has ended (for now). A settled [partial]/[failed]
  /// transfer can still be resumed, which moves it back to [pending].
  bool get isSettled => !uploadActive;

  /// The server still accepts file bytes and `transfer_files` rows.
  bool get acceptsUploads => this != completed && this != expired;

  /// Committed files can still be fetched.
  bool get downloadable => this != expired;

  /// A saved, interrupted send may continue into this transfer.
  bool get senderMayResume => acceptsUploads;

  /// Abandoning (discarding a saved send) may settle this transfer. Never
  /// from [completed], [partial] or [expired]: those already have a truthful
  /// outcome that a discard must not overwrite.
  bool get mayAbandon => this == pending || this == uploading || this == failed;

  /// History may let the user swipe the row away.
  bool get canHideFromHistory => isSettled;

  /// Files are, or were, ready for the receiver.
  bool get hasDeliveredFiles => this == completed || this == partial;

  /// Whether this client may move a transfer from this status to [next].
  /// Mirrors the server trigger, plus the client's own rules (a partial
  /// transfer is never abandoned to failed).
  bool canClientMoveTo(TransferStatus next) {
    // Server-only / legacy.
    if (next == expired || next == uploading) return false;
    switch (this) {
      case completed:
      case expired:
        return false;
      case pending:
      case uploading:
      case failed:
        return true;
      case partial:
        return next != failed;
    }
  }

  /// Statuses a conditional update to [next] must refuse to overwrite: the
  /// complement of the states [canClientMoveTo] allows.
  static Set<TransferStatus> protectedFrom(TransferStatus next) => {
        for (final s in values)
          if (!s.canClientMoveTo(next)) s,
      };
}
