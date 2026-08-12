import 'dart:convert';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';

/// Byte-compatible counterpart of Trio's `SecureMessenger`
/// (Trio/Sources/Services/RemoteControl/SecureMessenger.swift).
///
/// Wire format: base64( nonce(12) || ciphertext || GCM tag(16) ), encrypted
/// with AES-256-GCM using key = SHA-256(UTF-8 bytes of the shared secret).
class SecureMessenger {
  SecureMessenger(String sharedSecret)
      : _key = hash.sha256.convert(utf8.encode(sharedSecret)).bytes;

  final List<int> _key;
  static final AesGcm _aesGcm = AesGcm.with256bits();

  Future<String> encrypt(Map<String, dynamic> payload) async {
    final plaintext = utf8.encode(jsonEncode(payload));
    final nonce = _aesGcm.newNonce(); // 12 bytes
    final box = await _aesGcm.encrypt(
      plaintext,
      secretKey: SecretKey(_key),
      nonce: nonce,
    );
    final combined = <int>[...box.nonce, ...box.cipherText, ...box.mac.bytes];
    return base64Encode(combined);
  }

  Future<Map<String, dynamic>> decrypt(String base64Combined) async {
    final combined = base64Decode(base64Combined);
    if (combined.length <= 12 + 16) {
      throw const FormatException('Encrypted message too short');
    }
    final nonce = combined.sublist(0, 12);
    final cipherText = combined.sublist(12, combined.length - 16);
    final mac = Mac(combined.sublist(combined.length - 16));
    final clear = await _aesGcm.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: mac),
      secretKey: SecretKey(_key),
    );
    return jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
  }
}
