import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/display_preferences.dart';

/// Persists the layout choices for the Live Activity and the widgets.
///
/// Kept in the app's own storage, and separately handed to the widget extension
/// through the shared app group by [WidgetBridge.publishPreferences] — the two
/// are different stores on iOS, and the extension can only read the second.
class DisplayPreferencesStore {
  static const _key = 'trio_follower.display_preferences';

  static Future<DisplayPreferences> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return const DisplayPreferences();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return const DisplayPreferences();
      return DisplayPreferences.fromJson(decoded);
    } catch (_) {
      return const DisplayPreferences();
    }
  }

  static Future<void> save(DisplayPreferences preferences) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(preferences.toJson()));
  }
}
