// Pure room-lifecycle rules shared by the rooms screens. No Flutter, no
// backend: everything here takes the current (server) time as an argument so
// it can be unit-tested.

import 'room_service.dart';

/// Why a room the user was looking at stopped existing.
enum RoomEndReason {
  /// It reached its `expires_at` and the server swept it.
  expired,

  /// The host closed it before its time was up.
  closed,
}

/// Rooms are deleted either by the host or by the expiry sweep, and both look
/// the same on the wire (a DELETE of the `rooms` row). The sweep only deletes
/// rooms past `expires_at`, so a deletion at or after that moment — allowing
/// [grace] for the client's server-time estimate — was the expiry.
RoomEndReason roomEndReason({
  required DateTime expiresAt,
  required DateTime serverNow,
  Duration grace = const Duration(seconds: 30),
}) {
  return serverNow.toUtc().isBefore(expiresAt.toUtc().subtract(grace))
      ? RoomEndReason.closed
      : RoomEndReason.expired;
}

/// Snackbar / banner copy for a room that ended while open.
String roomEndMessage(RoomEndReason reason, {required bool isOwner}) {
  switch (reason) {
    case RoomEndReason.expired:
      return 'This room expired.';
    case RoomEndReason.closed:
      return isOwner
          ? 'This room was closed.'
          : 'This room was closed by the host.';
  }
}

/// Compact time-left label for a room card: `1h 5m left`, `12m left`,
/// `<1m left`, or `Expired`.
String roomCardTimeLeft(Duration left) {
  if (left <= Duration.zero) return 'Expired';
  if (left.inHours > 0) return '${left.inHours}h ${left.inMinutes % 60}m left';
  if (left.inMinutes < 1) return '<1m left';
  return '${left.inMinutes}m left';
}

/// Expiry line on the room detail screen.
String roomDetailExpiryLabel(Duration left) {
  if (left <= Duration.zero) return 'Room expired';
  if (left.inMinutes < 1) return 'Expires in under a minute';
  if (left.inHours >= 1) {
    final mins = left.inMinutes % 60;
    return 'Expires in ${left.inHours} h${mins > 0 ? ' $mins min' : ''}';
  }
  return 'Expires in ${left.inMinutes} min';
}

/// Whether [userId] may share files in a room with these [members].
///
/// Someone missing from the list is not a member — they left, were removed,
/// or the room is gone — and the server refuses their room sends
/// (`transfers_check_room`), so "not found" means no, never yes.
bool canShareInRoom(Iterable<RoomMember> members, String userId) {
  for (final m in members) {
    if (m.userId == userId) return m.canShare;
  }
  return false;
}

/// Server refusals of a room transfer (`transfers_check_room`), plus the
/// room-row errors a send can hit.
enum RoomSendRefusal {
  /// The sender is blocked, or no longer a member.
  shareDenied,

  /// This recipient left the room.
  recipientNotMember,

  /// The room expired or was deleted.
  roomEnded;

  /// Refusals that apply to every remaining recipient, so the send loop
  /// should stop instead of trying each one.
  bool get isRoomWide => this != RoomSendRefusal.recipientNotMember;

  String get message {
    switch (this) {
      case RoomSendRefusal.shareDenied:
        return 'Sharing is not available in this room right now';
      case RoomSendRefusal.recipientNotMember:
        return 'No longer in this room';
      case RoomSendRefusal.roomEnded:
        return 'This room has ended';
    }
  }
}

/// Classifies [error] as a room refusal, or null for any other failure.
/// The server raises these as plain strings (see
/// 20261029000001_transfer_insert_hardening.sql), so this matches on text.
RoomSendRefusal? classifyRoomSendRefusal(Object error) {
  final raw = error.toString();
  if (raw.contains('room_share_denied')) return RoomSendRefusal.shareDenied;
  // From room_member_public_keys (20261113000005): the sender left.
  if (raw.contains('room_not_member')) return RoomSendRefusal.shareDenied;
  if (raw.contains('room_recipient_not_member')) {
    return RoomSendRefusal.recipientNotMember;
  }
  if (raw.contains('room_expired') || raw.contains('room_not_found')) {
    return RoomSendRefusal.roomEnded;
  }
  return null;
}

/// Encryption keys for a room send, resolved from `room_member_public_keys`.
class RoomMemberKeys {
  /// Key per target user id; null means that member published no key (the
  /// send asks before uploading to them unencrypted).
  final Map<String, String?> keys;

  /// Targets the server no longer lists as members (they left). Their send
  /// would be refused, so they are failed up front.
  final Set<String> notMembers;

  const RoomMemberKeys({required this.keys, required this.notMembers});
}

/// Matches [targetUserIds] to the `{user_id, public_key}` [rows] by user id —
/// the transfer goes to that user, so their key must come from the same row.
/// A blank key counts as none.
RoomMemberKeys resolveRoomMemberKeys(
  Iterable<String> targetUserIds,
  Iterable<Map<String, dynamic>> rows,
) {
  final byUser = <String, String?>{};
  for (final row in rows) {
    final id = row['user_id']?.toString();
    if (id == null || id.isEmpty) continue;
    final key = (row['public_key'] as String?)?.trim();
    byUser[id] = (key == null || key.isEmpty) ? null : key;
  }
  final keys = <String, String?>{};
  final notMembers = <String>{};
  for (final id in targetUserIds) {
    if (byUser.containsKey(id)) {
      keys[id] = byUser[id];
    } else {
      notMembers.add(id);
    }
  }
  return RoomMemberKeys(keys: keys, notMembers: notMembers);
}

/// Orders reloads driven by realtime events against reloads the user asks
/// for.
///
/// * Every load gets a generation; only the most recently started one may
///   apply its result ([isCurrent]), so a slow older load can't overwrite a
///   newer list.
/// * A change event that arrives while a load is in flight is remembered
///   ([requestReload] returns false) instead of dropped: the in-flight query
///   may have read before the change committed. When the last in-flight load
///   ends, [end] says to run one more.
class LiveReloadGate {
  int _generation = 0;
  int _inFlight = 0;
  bool _pending = false;

  bool get isLoading => _inFlight > 0;
  bool get hasPendingReload => _pending;

  /// Call when a load starts; returns its generation.
  int begin() {
    _inFlight++;
    return ++_generation;
  }

  /// Whether the load with [generation] is the latest one started.
  bool isCurrent(int generation) => generation == _generation;

  /// Call when a load finishes (success or failure). Returns true when a
  /// change arrived during the load and a follow-up reload should run now.
  bool end() {
    if (_inFlight > 0) _inFlight--;
    if (_inFlight == 0 && _pending) {
      _pending = false;
      return true;
    }
    return false;
  }

  /// Call when a change event arrives. Returns true when a reload should
  /// start now; false when one is in flight (it will be followed up).
  bool requestReload() {
    if (_inFlight > 0) {
      _pending = true;
      return false;
    }
    return true;
  }

  /// Starts over, e.g. when the screen switches to another identity: results
  /// of loads already in flight are no longer current.
  void invalidate() {
    _generation++;
    _pending = false;
  }
}
