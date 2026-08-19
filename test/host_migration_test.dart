import 'package:flutter_test/flutter_test.dart';
import 'package:trio_follower/models/pairing_bundle.dart';
import 'package:trio_follower/services/host_migration_service.dart';
import 'package:trio_follower/services/secure_messenger.dart';

/// The host side of this protocol lives in
/// Trio/Sources/Services/RemoteControl/FollowerHostMigration.swift — these
/// tests pin the wire schema from the follower's side.
void main() {
  const secret = 'u8Fyar0N5wCCPzXKvV9V3wJ0lC0T3rH2m8Q1a2b3c4d=';
  final messenger = SecureMessenger(secret);
  final service = HostMigrationService(secret);

  Map<String, dynamic> updateJson({Map<String, dynamic> extra = const {}}) => {
        'type': 'host_migration',
        'timestamp': DateTime.now().millisecondsSinceEpoch / 1000.0,
        'host_name': 'New iPhone',
        'apns': {
          'device_token': 'new-token',
          'bundle_id': 'org.example.trio',
          'production': true,
        },
        ...extra,
      };

  const bundle = PairingBundle(
    version: 1,
    followerId: 'F00',
    followerName: 'Mom',
    hostName: 'Old iPhone',
    secret: secret,
    apns: ApnsInfo(
      deviceToken: 'old-token',
      bundleId: 'org.example.trio',
      teamId: 'TEAM',
      keyId: 'KEY',
      apnsKey: '-----BEGIN PRIVATE KEY-----',
      production: false,
    ),
    limits: CommandLimits(maxBolus: 6.5, maxCarbs: 120, units: 'mg/dL'),
    fcmAvailable: true,
  );

  group('what the host sends', () {
    test('a fresh update decrypts and carries the new address', () async {
      final encrypted = await messenger.encrypt(updateJson());
      final update = await service.handleEncryptedHostUpdate(encrypted);

      expect(update, isNotNull);
      expect(update!.deviceToken, 'new-token');
      expect(update.hostName, 'New iPhone');
      expect(update.production, isTrue);
    });

    test('the wrong secret yields nothing', () async {
      final encrypted = await SecureMessenger('other-secret').encrypt(updateJson());
      expect(await service.handleEncryptedHostUpdate(encrypted), isNull);
    });

    test('a payload of another type yields nothing', () async {
      final encrypted = await messenger.encrypt(updateJson(extra: {'type': 'status'}));
      expect(await service.handleEncryptedHostUpdate(encrypted), isNull);
    });

    test('a missing device token yields nothing', () async {
      final encrypted = await messenger.encrypt(updateJson(extra: {
        'apns': {'device_token': '', 'bundle_id': 'b', 'production': true},
      }));
      expect(await service.handleEncryptedHostUpdate(encrypted), isNull);
    });

    test('a stale update is refused', () async {
      final old = DateTime.now().subtract(const Duration(days: 8));
      final encrypted = await messenger.encrypt(
        updateJson(extra: {'timestamp': old.millisecondsSinceEpoch / 1000.0}),
      );
      expect(await service.handleEncryptedHostUpdate(encrypted), isNull);
    });

    test('an update not newer than the last applied one is refused (replay)', () async {
      final encrypted = await messenger.encrypt(updateJson());
      final update = await service.handleEncryptedHostUpdate(encrypted);
      expect(update, isNotNull);

      // The very same push again, with its timestamp already applied.
      expect(
        await service.handleEncryptedHostUpdate(encrypted, lastApplied: update!.timestamp),
        isNull,
      );
    });
  });

  group('applying an update', () {
    test('moves only the address; secret, credentials and limits stay', () async {
      final encrypted = await messenger.encrypt(updateJson());
      final update = await service.handleEncryptedHostUpdate(encrypted);
      final moved = update!.applyTo(bundle);

      expect(moved.apns.deviceToken, 'new-token');
      expect(moved.apns.production, isTrue);
      expect(moved.hostName, 'New iPhone');

      expect(moved.secret, bundle.secret);
      expect(moved.followerId, bundle.followerId);
      expect(moved.apns.teamId, 'TEAM');
      expect(moved.apns.keyId, 'KEY');
      expect(moved.apns.apnsKey, '-----BEGIN PRIVATE KEY-----');
      expect(moved.limits.maxBolus, 6.5);
      expect(moved.fcmAvailable, isTrue);
    });

    test('an empty host name or bundle id keeps the stored values', () async {
      final encrypted = await messenger.encrypt(updateJson(extra: {
        'host_name': '',
        'apns': {'device_token': 't', 'bundle_id': '', 'production': true},
      }));
      final update = await service.handleEncryptedHostUpdate(encrypted);
      final moved = update!.applyTo(bundle);

      expect(moved.hostName, 'Old iPhone');
      expect(moved.apns.bundleId, 'org.example.trio');
      expect(moved.apns.deviceToken, 't');
    });
  });
}
