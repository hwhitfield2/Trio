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
  }

  Future<void> clear() async {
    await _storage.delete(key: _pairingKey);
    await _storage.delete(key: _sequenceKey);
    await _storage.delete(key: _registeredTokenKey);
  }

  /// The push token last successfully registered with the host, so we only
  /// re-send register_follower when the token actually changes.
  Future<String?> get registeredPushToken => _storage.read(key: _registeredTokenKey);

  Future<void> setRegisteredPushToken(String token) =>
      _storage.write(key: _registeredTokenKey, value: token);

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
