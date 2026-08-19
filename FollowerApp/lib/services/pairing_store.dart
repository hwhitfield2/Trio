import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/pairing_bundle.dart';

/// Persists the pairing bundle and the command sequence counter in the
/// platform secure enclave-backed store (iOS Keychain / Android Keystore).
class PairingStore {
  PairingStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  final FlutterSecureStorage _storage;

  static const _pairingKey = 'trio_follower.pairing';
  static const _sequenceKey = 'trio_follower.sequence';
  static const _registeredTokenKey = 'trio_follower.registered_push_token';
  static const _registeredVersionKey = 'trio_follower.registered_app_version';
  static const _hostUpdatedAtKey = 'trio_follower.host_updated_at';

  Future<PairingBundle?> loadPairing() async {
    final raw = await _storage.read(key: _pairingKey);
    if (raw == null) return null;
    try {
      return PairingBundle.fromQrString(raw);
    } on PairingParseException {
      return null;
    }
  }

  Future<void> savePairing(PairingBundle bundle) async {
    await _storage.write(key: _pairingKey, value: jsonEncode(bundle.toJson()));
    await _storage.write(key: _sequenceKey, value: '0');
    await _storage.delete(key: _hostUpdatedAtKey);
  }

  /// Rewrites the stored bundle WITHOUT touching the sequence counter.
  ///
  /// Used when the paired host moves to a new device: the migrated host kept
  /// this follower's `lastSequence`, so resetting the counter here would make
  /// every subsequent command look like a replay and be rejected.
  Future<void> updatePairing(PairingBundle bundle) async {
    await _storage.write(key: _pairingKey, value: jsonEncode(bundle.toJson()));
  }

  /// Timestamp of the last host migration applied, so an older (replayed)
  /// migration push can never point this follower back at a dead device.
  Future<DateTime?> get hostUpdatedAt async {
    final raw = await _storage.read(key: _hostUpdatedAtKey);
    final millis = int.tryParse(raw ?? '');
    return millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis);
  }

  Future<void> setHostUpdatedAt(DateTime timestamp) => _storage.write(
      key: _hostUpdatedAtKey, value: timestamp.millisecondsSinceEpoch.toString());

  Future<void> clear() async {
    await _storage.delete(key: _pairingKey);
    await _storage.delete(key: _sequenceKey);
    await _storage.delete(key: _registeredTokenKey);
    await _storage.delete(key: _registeredVersionKey);
    await _storage.delete(key: _hostUpdatedAtKey);
  }

  /// The push token last successfully registered with the host, so we only
  /// re-send register_follower when the token actually changes.
  Future<String?> get registeredPushToken => _storage.read(key: _registeredTokenKey);

  Future<void> setRegisteredPushToken(String token) =>
      _storage.write(key: _registeredTokenKey, value: token);

  /// The app version last reported to the host. An app update usually keeps the
  /// same push token, so without this the host would go on showing whichever
  /// version was current when the follower first registered.
  Future<String?> get registeredAppVersion => _storage.read(key: _registeredVersionKey);

  Future<void> setRegisteredAppVersion(String version) =>
      _storage.write(key: _registeredVersionKey, value: version);

  /// Reserves and returns the next sequence number. The counter is advanced
  /// *before* the command is sent: if a send fails after APNS may have seen
  /// it, the number is never reused, which the host requires for replay
  /// protection.
  Future<int> nextSequence() async {
    final raw = await _storage.read(key: _sequenceKey);
    final current = int.tryParse(raw ?? '0') ?? 0;
    final next = current + 1;
    await _storage.write(key: _sequenceKey, value: next.toString());
    return next;
  }
}
