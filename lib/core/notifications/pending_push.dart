import 'dart:convert';

import 'package:flutter/material.dart';

import '../navigation/root_navigator.dart';
import '../../features/receive/receive_screen.dart';

/// A tapped incoming-transfer notification, waiting to be opened.
///
/// Taps can arrive before there is anywhere sensible to open them: during
/// onboarding, or while the shell is still setting up the identity. They wait
/// here until a shell with an identity calls [enableDelivery].
class PendingIncomingTransfer {
  static String? transferId;
  static String? senderCode;

  /// The shell that currently accepts deliveries, or null while none does.
  static Object? _deliveryOwner;

  static bool get canDeliver => _deliveryOwner != null;

  /// [owner] (the shell) has an identity: open any waiting tap, and later
  /// ones as they come.
  static void enableDelivery(Object owner) => _deliveryOwner = owner;

  /// Only [owner] can switch delivery off, so a shell being torn down can't
  /// disable the one replacing it.
  static void disableDelivery(Object owner) {
    if (identical(_deliveryOwner, owner)) _deliveryOwner = null;
  }

  static bool get hasPending =>
      transferId != null && transferId!.trim().isNotEmpty;

  static void setFromRemoteMessage(Map<String, dynamic> data) {
    transferId = _read(data, const ['transfer_id', 'transferId']);
    senderCode = _read(data, const ['sender_code', 'senderCode']) ?? '';
  }

  static String? readTransferId(Map<String, dynamic> data) =>
      _read(data, const ['transfer_id', 'transferId']);

  static String? _read(Map<String, dynamic> data, List<String> keys) {
    for (final k in keys) {
      final v = data[k];
      if (v != null && '$v'.trim().isNotEmpty) return '$v'.trim();
    }
    return null;
  }

  static void clear() {
    transferId = null;
    senderCode = null;
  }

  /// Call when user taps a local notification (foreground isolate).
  static void applyPayload(String? payload) {
    if (payload == null || payload.isEmpty) return;
    try {
      final map = jsonDecode(payload);
      if (map is Map<String, dynamic>) {
        setFromRemoteMessage(map);
      }
    } catch (_) {}
  }

  /// Push [ReceiveScreen] if a shell accepts deliveries and the navigator is
  /// ready; otherwise keep it pending for the shell.
  static void tryNavigateToReceive() {
    if (!hasPending || _deliveryOwner == null) return;
    final tid = transferId!;
    final code = senderCode ?? '';
    final nav = rootNavigatorKey.currentState;
    final ctx = nav?.context;
    if (nav != null && (ctx?.mounted ?? false)) {
      clear();
      nav.push(
        MaterialPageRoute<void>(
          builder: (_) => ReceiveScreen(
            transferId: tid,
            senderCode: code,
          ),
        ),
      );
    }
  }
}
