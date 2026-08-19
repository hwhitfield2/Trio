import '../models/pairing_bundle.dart';
import 'secure_messenger.dart';

/// A host's announcement that it moved to a new device, decrypted from an
/// `encrypted_host_update` push payload.
///
/// The wire schema is produced by `FollowerHostUpdate` on the host
/// (Trio/Sources/Services/RemoteControl/FollowerHostMigration.swift) — keep
/// both sides in sync.
class HostUpdate {
  const HostUpdate({
    required this.timestamp,
    required this.hostName,
    required this.deviceToken,
    required this.bundleId,
    required this.production,
  });

  final DateTime timestamp;
  final String hostName;
  final String deviceToken;
  final String bundleId;
  final bool production;

  /// The stored pairing with the host's new address in place. Credentials and
  /// the secret are unchanged — only where commands are delivered moves.
  PairingBundle applyTo(PairingBundle current) => PairingBundle(
        version: current.version,
        followerId: current.followerId,
        followerName: current.followerName,
        hostName: hostName.isNotEmpty ? hostName : current.hostName,
        secret: current.secret,
        apns: ApnsInfo(
          deviceToken: deviceToken,
          bundleId: bundleId.isNotEmpty ? bundleId : current.apns.bundleId,
          teamId: current.apns.teamId,
          keyId: current.apns.keyId,
          apnsKey: current.apns.apnsKey,
          production: production,
        ),
        limits: current.limits,
        fcmAvailable: current.fcmAvailable,
      );
}

/// Decrypts and validates host-migration pushes. Encrypted with the same
/// per-follower secret as status snapshots, so only the paired host can move
/// this follower — and a replayed or delayed push can never move it *back*,
/// because only updates newer than the last applied one are accepted.
class HostMigrationService {
  HostMigrationService(String secret) : _messenger = SecureMessenger(secret);

  final SecureMessenger _messenger;

  /// Updates older than this are ignored outright, replay-window style: an
  /// update should arrive within seconds, and days-old ciphertext arriving
  /// now is more likely a replay than a delivery.
  static const staleAfter = Duration(days: 7);

  /// Returns the update, or null when the payload is not a valid, fresh
  /// host migration (wrong key, unknown type, stale, or not newer than
  /// [lastApplied]).
  Future<HostUpdate?> handleEncryptedHostUpdate(
    String encrypted, {
    DateTime? lastApplied,
  }) async {
    final Map<String, dynamic> json;
    try {
      json = await _messenger.decrypt(encrypted);
    } catch (_) {
      return null;
    }

    if (json['type'] != 'host_migration') return null;
    final timestampRaw = json['timestamp'];
    if (timestampRaw is! num) return null;
    final timestamp = DateTime.fromMillisecondsSinceEpoch((timestampRaw * 1000).round());

    if (DateTime.now().difference(timestamp) > staleAfter) return null;
    if (lastApplied != null && !timestamp.isAfter(lastApplied)) return null;

    final apns = json['apns'];
    if (apns is! Map<String, dynamic>) return null;
    final deviceToken = apns['device_token'];
    if (deviceToken is! String || deviceToken.isEmpty) return null;

    return HostUpdate(
      timestamp: timestamp,
      hostName: (json['host_name'] as String?) ?? '',
      deviceToken: deviceToken,
      bundleId: (apns['bundle_id'] as String?) ?? '',
      production: (apns['production'] as bool?) ?? true,
    );
  }
}
