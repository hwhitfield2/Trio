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
    this.liveActivityToken,
    this.appVersion,
    this.appBuild,
    this.appPlatform,
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

  /// APNS token of this device's running Live Activity, or the empty string to
  /// tell the host to stop pushing to it.
  final String? liveActivityToken;

  /// This follower build, reported with every registration so the host can show
  /// which of its followers are out of date.
  final String? appVersion;
  final String? appBuild;

  /// "ios" or "android".
  final String? appPlatform;

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

  /// Emergency stop: asks the host to suspend all insulin delivery.
  ///
  /// Nothing restarts it on its own — not the host's loop, which will not enact
  /// against a suspended pump, and not this app. Someone holding the host phone
  /// has to answer the alarm it raises.
  factory TrioCommand.suspendInsulin() => TrioCommand._(commandType: 'suspend_insulin');

  /// Tells the host where to deliver encrypted status pushes.
  factory TrioCommand.registerFollower({
    required String pushToken,
    required String pushTransport,
    String? pushBundleId,
    String? pushEnvironment,
    String? appVersion,
    String? appBuild,
    String? appPlatform,
  }) =>
      TrioCommand._(
        commandType: 'register_follower',
        pushToken: pushToken,
        pushTransport: pushTransport,
        pushBundleId: pushBundleId,
        pushEnvironment: pushEnvironment,
        appVersion: appVersion,
        appBuild: appBuild,
        appPlatform: appPlatform,
      );

  /// Hands the host the Live Activity's push token so it can update the Lock
  /// Screen directly, or clears it (empty token) when the user turns remote
  /// updates off.
  factory TrioCommand.registerLiveActivity({String? liveActivityToken}) => TrioCommand._(
        commandType: 'register_live_activity',
        liveActivityToken: liveActivityToken ?? '',
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
      if (liveActivityToken != null) 'live_activity_token': liveActivityToken,
      if (appVersion != null) 'app_version': appVersion,
      if (appBuild != null) 'app_build': appBuild,
      if (appPlatform != null) 'app_platform': appPlatform,
    };
  }

  /// Whether this command changes anything on the host, as opposed to only
  /// asking it for information or telling it where to send pushes.
  ///
  /// This decides whether the host's phone is allowed to make a sound about it.
  /// Status refreshes and registrations run on a schedule and in the
  /// background, so banners for those are pure noise on someone else's phone —
  /// they are sent silently. An unrecognized command type counts as changing
  /// something, so a newer command added later is announced by default rather
  /// than arriving unnoticed.
  bool get changesSomething {
    switch (commandType) {
      case 'status_request':
      case 'register_follower':
      case 'register_live_activity':
        return false;
      default:
        return true;
    }
  }

  /// The banner the host phone should show for this command, or null when it
  /// should show nothing at all.
  ///
  /// The title names the follower because the host may have several paired, and
  /// "a command arrived" is not worth waking someone for if they cannot tell
  /// who sent it or what it did.
  ({String title, String body})? hostAlert({required String followerName}) {
    if (!changesSomething) return null;
    final who = followerName.trim();
    return (
      title: who.isEmpty ? 'Remote command' : 'Remote command from $who',
      body: describe(),
    );
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
      case 'suspend_insulin':
        return 'Suspend all insulin delivery';
      case 'register_follower':
        return 'Push registration';
      case 'register_live_activity':
        return (liveActivityToken ?? '').isEmpty
            ? 'Live Activity updates off'
            : 'Live Activity registration';
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
