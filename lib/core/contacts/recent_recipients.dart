import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A recently-used recipient short code (device-local, most-recent-first).
/// [label] is an optional display name (your alias or their nickname) captured
/// at send time so the dropdown can show something friendlier than the code.
class RecentRecipient {
  final String code;
  final String? label;
  const RecentRecipient({required this.code, this.label});

  Map<String, dynamic> toJson() =>
      {'code': code, if (label != null) 'label': label};

  static RecentRecipient? fromJson(Object? json) {
    if (json is! Map) return null;
    final code = (json['code'] as String?)?.trim();
    if (code == null || code.isEmpty) return null;
    final label = (json['label'] as String?)?.trim();
    return RecentRecipient(
      code: code,
      label: (label == null || label.isEmpty) ? null : label,
    );
  }
}

/// Remembers the last few codes you sent to, so the Send screen can suggest
/// them as you type. Device-local (SharedPreferences); wiped by the full local
/// reset like every other local setting. Nothing is sent to the server.
class RecentRecipients {
  static const _prefsKey = 'recent_recipients';
  static const _maxEntries = 8;

  static List<RecentRecipient> _cache = [];
  static bool _loaded = false;

  /// Bumped on load and on every change so screens can listen and rebuild.
  static final ValueNotifier<int> revision = ValueNotifier(0);

  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List;
        _cache = list
            .map(RecentRecipient.fromJson)
            .whereType<RecentRecipient>()
            .toList();
      } catch (_) {
        _cache = [];
      }
    }
    _loaded = true;
    revision.value++;
  }

  /// All remembered recipients, most-recent-first.
  static List<RecentRecipient> get all => List.unmodifiable(_cache);

  /// Recipients whose code starts with [prefix] (case-insensitive), excluding
  /// an entry that exactly equals the full prefix (nothing to suggest then).
  static List<RecentRecipient> matching(String prefix) {
    final p = prefix.trim().toUpperCase();
    return _cache.where((r) => r.code.startsWith(p) && r.code != p).toList();
  }

  /// Records a successful send. Dedupes by code and moves it to the front.
  static Future<void> record(String code, {String? label}) async {
    final normalized = code.trim().toUpperCase();
    if (normalized.isEmpty) return;
    await ensureLoaded();
    _cache.removeWhere((r) => r.code == normalized);
    _cache.insert(0, RecentRecipient(code: normalized, label: label));
    if (_cache.length > _maxEntries) {
      _cache = _cache.sublist(0, _maxEntries);
    }
    revision.value++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(_cache.map((r) => r.toJson()).toList()),
    );
  }

  /// Removes a single remembered code (e.g. user swipes it away).
  static Future<void> remove(String code) async {
    final normalized = code.trim().toUpperCase();
    final before = _cache.length;
    _cache.removeWhere((r) => r.code == normalized);
    if (_cache.length == before) return;
    revision.value++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(_cache.map((r) => r.toJson()).toList()),
    );
  }
}
