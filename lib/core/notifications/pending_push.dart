import 'dart:convert';

import 'package:flutter/material.dart';

import '../navigation/root_navigator.dart';
import '../../features/receive/receive_screen.dart';

class PendingIncomingTransfer {
  static String? transferId;
  static String? senderCode;

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

  /// Push [ReceiveScreen] if navigator is ready; otherwise keep pending for [MainShell].
  static void tryNavigateToReceive() {
    if (!hasPending) return;
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
