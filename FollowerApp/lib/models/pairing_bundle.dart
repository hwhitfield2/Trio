import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Everything the follower needs to talk to a Trio host, decoded from the
/// pairing QR code shown on the host device.
///
/// The JSON schema is produced by `FollowerPairingManager.makePairingPayload`
/// on the host — keep both sides in sync.
class PairingBundle {
  const PairingBundle({
    required this.version,
    required this.followerId,
    required this.followerName,
    required this.hostName,
    required this.secret,
    required this.apns,
    required this.limits,
    this.fcmAvailable = false,
    this.ai,
  });

  static const pairingType = 'trio-follower-pairing';

  final int version;
  final String followerId;

  /// Name the host user gave this follower device during pairing; sent as the
  /// `user` field on commands so it shows up in Trio's logs.
  final String followerName;
  final String hostName;

  /// Per-follower secret (opaque string). The AES key is SHA-256 of the UTF-8
  /// bytes of this string, matching Trio's `SecureMessenger`.
  final String secret;

  final ApnsInfo apns;
  final CommandLimits limits;

  /// Whether the host has FCM configured. Android followers receive status
  /// pushes only when this is true; commands work regardless.
  final bool fcmAvailable;

  /// The host's AI food search credentials, when the host had the feature
  /// configured at pairing time. Status snapshots carry the live value, which
  /// takes precedence — same rule as the limits.
  final AiConfig? ai;

  /// Six-digit code derived from the secret, shown to the user after scanning
  /// so they can compare it against the code on the host screen.
  String get verificationCode {
    final digest = sha256.convert(utf8.encode(secret)).bytes;
    var value = 0;
    for (final byte in digest.take(4)) {
      value = ((value << 8) | byte) & 0xFFFFFFFF;
    }
    return (value % 1000000).toString().padLeft(6, '0');
  }

  static PairingBundle fromQrString(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const PairingParseException('This QR code is not a Trio follower pairing code.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const PairingParseException('This QR code is not a Trio follower pairing code.');
    }
    final map = decoded;
    if (map['type'] != pairingType) {
      throw const PairingParseException('This QR code is not a Trio follower pairing code.');
    }
    final version = map['v'];
    if (version is! int || version != 1) {
      throw const PairingParseException(
        'This pairing code uses an unsupported version. Update the follower app.',
      );
    }
    final apnsMap = map['apns'];
    if (apnsMap is! Map<String, dynamic>) {
      throw const PairingParseException('The pairing code is missing push notification details.');
    }
    final limitsMap = map['limits'];
    try {
      return PairingBundle(
        version: version,
        followerId: map['follower_id'] as String,
        followerName: (map['follower_name'] as String?) ?? 'Follower',
        hostName: (map['host_name'] as String?) ?? 'Trio',
        secret: map['secret'] as String,
        apns: ApnsInfo.fromJson(apnsMap),
        limits: limitsMap is Map<String, dynamic>
            ? CommandLimits.fromJson(limitsMap)
            : const CommandLimits(maxBolus: 10, maxCarbs: 250, units: 'mg/dL'),
        fcmAvailable: (map['fcm_available'] as bool?) ?? false,
        ai: AiConfig.fromJson(map['ai']),
      );
    } catch (_) {
      throw const PairingParseException('The pairing code is incomplete or damaged. Generate a new one on the Trio host.');
    }
  }

  Map<String, dynamic> toJson() => {
        'v': version,
        'type': pairingType,
        'follower_id': followerId,
        'follower_name': followerName,
        'host_name': hostName,
        'secret': secret,
        'apns': apns.toJson(),
        'limits': limits.toJson(),
        'fcm_available': fcmAvailable,
        if (ai != null) 'ai': ai!.toJson(),
      };

  /// The same pairing with a different AI configuration — used when a status
  /// snapshot reports that the host changed, added or removed it.
  PairingBundle withAi(AiConfig? ai) => PairingBundle(
        version: version,
        followerId: followerId,
        followerName: followerName,
        hostName: hostName,
        secret: secret,
        apns: apns,
        limits: limits,
        fcmAvailable: fcmAvailable,
        ai: ai,
      );
}

/// The host's AI food search configuration — enough for this app to run the
/// same text lookup the host offers and send the result as a remote meal.
///
/// The JSON shape is produced by `FollowerAIConfig` on the host (pairing
/// bundle and status snapshots) — keep both sides in sync.
class AiConfig {
  const AiConfig({required this.apiKey, required this.model});

  final String apiKey;

  /// Model id the host uses for text food search.
  final String model;

  static AiConfig? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final key = json['api_key'];
    final model = json['model'];
    if (key is! String || key.trim().isEmpty) return null;
    return AiConfig(
      apiKey: key,
      model: model is String && model.isNotEmpty ? model : 'claude-sonnet-5',
    );
  }

  Map<String, dynamic> toJson() => {'api_key': apiKey, 'model': model};

  @override
  bool operator ==(Object other) =>
      other is AiConfig && other.apiKey == apiKey && other.model == model;

  @override
  int get hashCode => Object.hash(apiKey, model);
}

class ApnsInfo {
  const ApnsInfo({
    required this.deviceToken,
    required this.bundleId,
    required this.teamId,
    required this.keyId,
    required this.apnsKey,
    required this.production,
  });

  final String deviceToken;
  final String bundleId;
  final String teamId;
  final String keyId;

  /// Contents of the .p8 APNS auth key (PEM, PKCS#8).
  final String apnsKey;
  final bool production;

  factory ApnsInfo.fromJson(Map<String, dynamic> json) => ApnsInfo(
        deviceToken: json['device_token'] as String,
        bundleId: json['bundle_id'] as String,
        teamId: json['team_id'] as String,
        keyId: json['key_id'] as String,
        apnsKey: json['apns_key'] as String,
        production: (json['production'] as bool?) ?? true,
      );

  Map<String, dynamic> toJson() => {
        'device_token': deviceToken,
        'bundle_id': bundleId,
        'team_id': teamId,
        'key_id': keyId,
        'apns_key': apnsKey,
        'production': production,
      };
}

class CommandLimits {
  const CommandLimits({
    required this.maxBolus,
    required this.maxCarbs,
    required this.units,
  });

  final double maxBolus;
  final double maxCarbs;

  /// Host display units: 'mg/dL' or 'mmol/L'. Temp targets are always sent in
  /// mg/dL regardless of display units.
  final String units;

  factory CommandLimits.fromJson(Map<String, dynamic> json) => CommandLimits(
        maxBolus: (json['max_bolus'] as num?)?.toDouble() ?? 10,
        maxCarbs: (json['max_carbs'] as num?)?.toDouble() ?? 250,
        units: (json['units'] as String?) ?? 'mg/dL',
      );

  Map<String, dynamic> toJson() => {
        'max_bolus': maxBolus,
        'max_carbs': maxCarbs,
        'units': units,
      };
}

class PairingParseException implements Exception {
  const PairingParseException(this.message);
  final String message;

  @override
  String toString() => message;
}
