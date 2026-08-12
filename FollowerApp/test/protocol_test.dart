import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:trio_follower/models/command.dart';
import 'package:trio_follower/models/pairing_bundle.dart';
import 'package:trio_follower/models/status_snapshot.dart';
import 'package:trio_follower/services/secure_messenger.dart';

const _sampleBundle = '''
{
  "v": 1,
  "type": "trio-follower-pairing",
  "follower_id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
  "follower_name": "Mom",
  "host_name": "Kid's iPhone",
  "secret": "u8Fyar0N5wCCPzXKvV9V3wJ0lC0T3rH2m8Q1a2b3c4d=",
  "apns": {
    "device_token": "abcdef0123456789",
    "bundle_id": "org.example.trio",
    "team_id": "TEAMID1234",
    "key_id": "KEYID12345",
    "apns_key": "-----BEGIN PRIVATE KEY-----\\nMIG...\\n-----END PRIVATE KEY-----",
    "production": true
  },
  "limits": {"max_bolus": 6.5, "max_carbs": 120, "units": "mg/dL"},
  "fcm_available": true
}
''';

void main() {
  group('PairingBundle', () {
    test('parses the host pairing payload', () {
      final bundle = PairingBundle.fromQrString(_sampleBundle);
      expect(bundle.followerId, '3F2504E0-4F89-11D3-9A0C-0305E82C3301');
      expect(bundle.followerName, 'Mom');
      expect(bundle.hostName, "Kid's iPhone");
      expect(bundle.apns.deviceToken, 'abcdef0123456789');
      expect(bundle.apns.production, isTrue);
      expect(bundle.fcmAvailable, isTrue);
      expect(bundle.limits.maxBolus, 6.5);
      // Pinned vector — TrioTests/FollowerPairingTests.swift asserts the same
      // code for the same secret on the host side.
      expect(bundle.verificationCode, '714600');
    });

    test('rejects non-pairing QR codes', () {
      expect(
        () => PairingBundle.fromQrString('https://example.com'),
        throwsA(isA<PairingParseException>()),
      );
      expect(
        () => PairingBundle.fromQrString('{"type": "something-else"}'),
        throwsA(isA<PairingParseException>()),
      );
    });

    test('round-trips through toJson', () {
      final bundle = PairingBundle.fromQrString(_sampleBundle);
      final reparsed = PairingBundle.fromQrString(jsonEncode(bundle.toJson()));
      expect(reparsed.secret, bundle.secret);
      expect(reparsed.verificationCode, bundle.verificationCode);
      expect(reparsed.apns.apnsKey, bundle.apns.apnsKey);
    });
  });

  group('TrioCommand payload', () {
    test('uses Trio CommandPayload field names', () {
      final payload = TrioCommand.meal(carbs: 45, fat: 10, protein: 20, bolusUnits: 2.5)
          .toPayload(user: 'Mom', sequence: 7);
      expect(payload['user'], 'Mom');
      expect(payload['command_type'], 'meal');
      expect(payload['sequence'], 7);
      expect(payload['carbs'], 45);
      expect(payload['fat'], 10);
      expect(payload['protein'], 20);
      expect(payload['bolus_amount'], 2.5);
      expect(payload['timestamp'], isA<double>());
    });

    test('temp target and override commands', () {
      final tt = TrioCommand.tempTarget(targetMgdl: 140, durationMinutes: 90)
          .toPayload(user: 'Mom', sequence: 1);
      expect(tt['command_type'], 'temp_target');
      expect(tt['target'], 140);
      expect(tt['duration'], 90);

      final override = TrioCommand.startOverride('Sports').toPayload(user: 'Mom', sequence: 2);
      expect(override['command_type'], 'start_override');
      // Trio's CodingKeys uses `overrideName` (not snake_case) for this field.
      expect(override['overrideName'], 'Sports');

      expect(
        TrioCommand.cancelTempTarget().toPayload(user: 'Mom', sequence: 3)['command_type'],
        'cancel_temp_target',
      );
      expect(
        TrioCommand.cancelOverride().toPayload(user: 'Mom', sequence: 4)['command_type'],
        'cancel_override',
      );
    });

    test('status request and push registration commands', () {
      expect(
        TrioCommand.statusRequest().toPayload(user: 'Mom', sequence: 5)['command_type'],
        'status_request',
      );

      final register = TrioCommand.registerFollower(
        pushToken: 'abc123',
        pushTransport: 'apns',
        pushBundleId: 'org.nightscout.triofollower',
        pushEnvironment: 'production',
      ).toPayload(user: 'Mom', sequence: 6);
      expect(register['command_type'], 'register_follower');
      expect(register['push_token'], 'abc123');
      expect(register['push_transport'], 'apns');
      expect(register['push_bundle_id'], 'org.nightscout.triofollower');
      expect(register['push_environment'], 'production');
    });

    test('live activity registration carries and clears the token', () {
      final register = TrioCommand.registerLiveActivity(liveActivityToken: 'deadbeef')
          .toPayload(user: 'Mom', sequence: 7);
      expect(register['command_type'], 'register_live_activity');
      expect(register['live_activity_token'], 'deadbeef');

      // Withdrawing sends an empty token rather than omitting the field, so the
      // host can tell "stop pushing" apart from a malformed command.
      final clear = TrioCommand.registerLiveActivity().toPayload(user: 'Mom', sequence: 8);
      expect(clear['command_type'], 'register_live_activity');
      expect(clear['live_activity_token'], '');
    });
  });

  group('StatusSnapshot', () {
    test('parses the host status payload', () {
      final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
      final snapshot = StatusSnapshot.fromJson({
        'type': 'status',
        'timestamp': now,
        'units': 'mg/dL',
        'readings': [
          {'sgv': 104, 'date': now - 60, 'direction': 'Flat'},
          {'sgv': 100, 'date': now - 360, 'direction': 'FortyFiveUp'},
        ],
        'iob': 1.25,
        'cob': 15,
        'last_loop': now - 120,
        'eventual_bg': 120,
        'temp_target': {'target': 140, 'name': 'Exercise', 'started_at': now - 600, 'duration': 120},
        'override': null,
        'max_bolus': 6.5,
        'max_carbs': 120,
      });

      expect(snapshot, isNotNull);
      expect(snapshot!.latest?.sgv, 104);
      expect(snapshot.latest?.trendArrow, '→');
      expect(snapshot.delta, 4);
      expect(snapshot.iob, 1.25);
      expect(snapshot.cob, 15);
      expect(snapshot.tempTarget?.target, 140);
      expect(snapshot.tempTarget?.until, isNotNull);
      expect(snapshot.override, isNull);
      expect(snapshot.maxBolus, 6.5);
    });

    test('rejects non-status payloads', () {
      expect(StatusSnapshot.fromJson({'type': 'other', 'timestamp': 1.0}), isNull);
      expect(StatusSnapshot.fromJson({'type': 'status'}), isNull);
    });
  });

  group('SecureMessenger', () {
    test('encrypts to nonce||ciphertext||tag and round-trips', () async {
      final messenger = SecureMessenger('shared-secret');
      final payload = {'user': 'Mom', 'command_type': 'bolus', 'bolus_amount': 1.5};

      final encrypted = await messenger.encrypt(payload);
      final combined = base64Decode(encrypted);
      // 12-byte nonce + ciphertext + 16-byte GCM tag, as Trio expects.
      expect(combined.length, greaterThan(12 + 16));

      final decrypted = await messenger.decrypt(encrypted);
      expect(decrypted, payload);
    });

    test('fails to decrypt with the wrong secret', () async {
      final encrypted = await SecureMessenger('secret-a').encrypt({'x': 1});
      expect(
        () => SecureMessenger('secret-b').decrypt(encrypted),
        throwsA(anything),
      );
    });
  });
}
