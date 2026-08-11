import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/status_snapshot.dart';
import 'secure_messenger.dart';

/// Decrypts and persists status snapshots pushed by the host. The host is the
/// only data source — snapshots arrive as `encrypted_status` push payloads
/// encrypted with this follower's secret.
class StatusService {
  StatusService(String secret) : _messenger = SecureMessenger(secret);

  final SecureMessenger _messenger;

  static const _snapshotKey = 'trio_follower.last_snapshot';

  /// Maximum age of an acceptable snapshot; anything older is treated as
  /// stale noise (e.g. a long-delayed push).
  static const staleAfter = Duration(hours: 12);

  /// Decrypts a pushed status blob. Returns null when the payload is not a
  /// valid status snapshot (wrong key, corrupted, unknown type) or is older
  /// than the snapshot we already have.
  Future<StatusSnapshot?> handleEncryptedStatus(
    String encrypted, {
    StatusSnapshot? current,
  }) async {
    final Map<String, dynamic> json;
    try {
      json = await _messenger.decrypt(encrypted);
    } catch (_) {
      return null;
    }

    final snapshot = StatusSnapshot.fromJson(json);
    if (snapshot == null) return null;
    if (DateTime.now().difference(snapshot.timestamp) > staleAfter) return null;
    // Ignore out-of-order pushes: only ever move forward in time.
    if (current != null && !snapshot.timestamp.isAfter(current.timestamp)) return null;

    await _persist(json);
    return snapshot;
  }

  /// Restores the last received snapshot so the app has data immediately
  /// after launch, before the next push arrives.
  Future<StatusSnapshot?> loadPersisted() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_snapshotKey);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return StatusSnapshot.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  Future<void> _persist(Map<String, dynamic> json) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_snapshotKey, jsonEncode(json));
  }

  static Future<void> clearPersisted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_snapshotKey);
  }
}
