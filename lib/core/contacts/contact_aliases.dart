import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Device-local names you assign to other users so codes become memorable.
/// Nothing is sent to the server; the map lives only in SharedPreferences
/// (and is wiped by the full local reset, like every other local setting).
///
/// Display precedence everywhere: your alias > their nickname > their code.
class ContactAliases {
  static const _prefsKey = 'contact_aliases';
  static Map<String, String> _cache = {};
  static bool _loaded = false;

  /// Bumped on load and on every change so screens can listen and rebuild.
  static final ValueNotifier<int> revision = ValueNotifier(0);

  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw != null) {
      try {
        _cache = Map<String, String>.from(jsonDecode(raw) as Map);
      } catch (_) {
        _cache = {};
      }
    }
    _loaded = true;
    revision.value++;
  }

  static String? aliasFor(String? userId) {
    if (userId == null || userId.isEmpty) return null;
    return _cache[userId];
  }

  /// A null or empty [alias] removes the entry.
  static Future<void> setAlias(String userId, String? alias) async {
    final trimmed = alias?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      _cache.remove(userId);
    } else {
      _cache[userId] = trimmed;
    }
    revision.value++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(_cache));
  }
}
