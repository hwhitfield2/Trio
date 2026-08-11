/// Remote command payload, JSON-compatible with Trio's `CommandPayload`
/// (Trio/Sources/Models/CommandPayload.swift). Field names must match the
/// Swift `CodingKeys` exactly.
class TrioCommand {
  TrioCommand._({
    required this.commandType,
    this.bolusAmount,
    this.target,
    this.duration,
    this.carbs,
    this.protein,
    this.fat,
    this.overrideName,
    this.scheduledTime,
    this.pushToken,
    this.pushTransport,
    this.pushBundleId,
    this.pushEnvironment,
  });

  final String commandType;
  final double? bolusAmount;

  /// Temp target in mg/dL.
  final int? target;

  /// Duration in minutes.
  final int? duration;
  final int? carbs;
  final int? protein;
  final int? fat;
  final String? overrideName;
  final double? scheduledTime;
  final String? pushToken;
  final String? pushTransport;
  final String? pushBundleId;
  final String? pushEnvironment;

  factory TrioCommand.bolus(double units) => TrioCommand._(commandType: 'bolus', bolusAmount: units);

  factory TrioCommand.meal({
    required int carbs,
    int? protein,
    int? fat,
    double? bolusUnits,
    DateTime? scheduledTime,
  }) =>
      TrioCommand._(
        commandType: 'meal',
        carbs: carbs,
        protein: protein,
        fat: fat,
        bolusAmount: bolusUnits,
        scheduledTime: scheduledTime == null ? null : scheduledTime.millisecondsSinceEpoch / 1000.0,
      );

  factory TrioCommand.tempTarget({required int targetMgdl, required int durationMinutes}) =>
      TrioCommand._(commandType: 'temp_target', target: targetMgdl, duration: durationMinutes);

  factory TrioCommand.cancelTempTarget() => TrioCommand._(commandType: 'cancel_temp_target');

  factory TrioCommand.startOverride(String name) =>
      TrioCommand._(commandType: 'start_override', overrideName: name);

  factory TrioCommand.cancelOverride() => TrioCommand._(commandType: 'cancel_override');

  /// Asks the host to push a fresh status snapshot to this follower.
  factory TrioCommand.statusRequest() => TrioCommand._(commandType: 'status_request');

  /// Tells the host where to deliver encrypted status pushes.
  factory TrioCommand.registerFollower({
    required String pushToken,
    required String pushTransport,
    String? pushBundleId,
    String? pushEnvironment,
  }) =>
      TrioCommand._(
        commandType: 'register_follower',
        pushToken: pushToken,
        pushTransport: pushTransport,
        pushBundleId: pushBundleId,
        pushEnvironment: pushEnvironment,
      );

  /// Builds the payload that gets encrypted. `user` identifies this follower
  /// in Trio's logs and notifications; `sequence` provides replay protection.
  Map<String, dynamic> toPayload({
    required String user,
    required int sequence,
    DateTime? now,
  }) {
    final timestamp = (now ?? DateTime.now()).millisecondsSinceEpoch / 1000.0;
    return {
      'user': user,
      'timestamp': timestamp,
      'command_type': commandType,
      'sequence': sequence,
      if (bolusAmount != null) 'bolus_amount': bolusAmount,
      if (target != null) 'target': target,
      if (duration != null) 'duration': duration,
      if (carbs != null) 'carbs': carbs,
      if (protein != null) 'protein': protein,
      if (fat != null) 'fat': fat,
      if (overrideName != null) 'overrideName': overrideName,
      if (scheduledTime != null) 'scheduled_time': scheduledTime,
      if (pushToken != null) 'push_token': pushToken,
      if (pushTransport != null) 'push_transport': pushTransport,
      if (pushBundleId != null) 'push_bundle_id': pushBundleId,
      if (pushEnvironment != null) 'push_environment': pushEnvironment,
    };
  }

  String describe() {
    switch (commandType) {
      case 'bolus':
        return 'Bolus ${bolusAmount?.toStringAsFixed(2)} U';
      case 'meal':
        final parts = <String>['Meal $carbs g carbs'];
        if (fat != null && fat! > 0) parts.add('$fat g fat');
        if (protein != null && protein! > 0) parts.add('$protein g protein');
        if (bolusAmount != null) parts.add('bolus ${bolusAmount!.toStringAsFixed(2)} U');
        return parts.join(', ');
      case 'temp_target':
        return 'Temp target $target mg/dL for $duration min';
      case 'cancel_temp_target':
        return 'Cancel temp target';
      case 'start_override':
        return 'Start override "$overrideName"';
      case 'cancel_override':
        return 'Cancel override';
      case 'status_request':
        return 'Status refresh';
      case 'register_follower':
        return 'Push registration';
      default:
        return commandType;
    }
  }
}

/// Result of one command submission, kept in the local history list.
class CommandRecord {
  CommandRecord({
    required this.description,
    required this.sentAt,
    required this.accepted,
    this.detail,
  });

  final String description;
  final DateTime sentAt;

  /// Whether APNS accepted the push. Execution on the host is confirmed by
  /// the status snapshot the host pushes back after handling the command.
  final bool accepted;
  final String? detail;

  Map<String, dynamic> toJson() => {
        'description': description,
        'sent_at': sentAt.toIso8601String(),
        'accepted': accepted,
        if (detail != null) 'detail': detail,
      };

  factory CommandRecord.fromJson(Map<String, dynamic> json) => CommandRecord(
        description: json['description'] as String,
        sentAt: DateTime.parse(json['sent_at'] as String),
        accepted: (json['accepted'] as bool?) ?? false,
        detail: json['detail'] as String?,
      );
}
