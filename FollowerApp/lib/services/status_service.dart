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

    // The AI credentials ride the snapshot but do not belong in plain
    // SharedPreferences: AppState folds them into the securely stored pairing
    // bundle instead, so the persisted copy is stripped.
    await _persist(Map<String, dynamic>.from(json)..remove('ai'));
    return snapshot;
  }

  /// Decrypts a pushed history blob — the host's answer to a history request.
  ///
  /// Null for anything that is not one, which is how a status push and a
  /// history push share the same `encrypted_status` field: each side reads
  /// `type` and ignores what it was not looking for.
  ///
  /// Unlike a status, a history slice is not checked for staleness or ordering.
  /// It is old readings by definition, and the slices are merged by timestamp,
  /// so they may arrive late, out of order, or not at all.
  Future<GlucoseHistory?> handleEncryptedHistory(String encrypted) async {
    final Map<String, dynamic> json;
    try {
      json = await _messenger.decrypt(encrypted);
    } catch (_) {
      return null;
    }
    return GlucoseHistory.fromJson(json);
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
