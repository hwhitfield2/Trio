import 'glucose_ranges.dart';

/// Status snapshot pushed by the Trio host, decrypted from the
/// `encrypted_status` push field. Schema is produced by
/// `FollowerStatusPublisher` on the host — keep both sides in sync.
class StatusSnapshot {
  const StatusSnapshot({
    required this.timestamp,
    required this.units,
    required this.readings,
    this.iob,
    this.cob,
    this.lastLoop,
    this.eventualBg,
    this.tempTarget,
    this.override,
    this.maxBolus,
    this.maxCarbs,
    this.lowThreshold,
    this.highThreshold,
    this.ranges,
    this.suspended = false,
    this.suspendedBy,
    this.suspendedAt,
    this.suspendAcknowledged = false,
  });

  final DateTime timestamp;

  /// Host display units: 'mg/dL' or 'mmol/L'. Readings are always mg/dL.
  final String units;

  /// Newest first, up to 6 hours.
  final List<GlucoseReading> readings;
  final double? iob;
  final double? cob;
  final DateTime? lastLoop;
  final double? eventualBg;
  final ActiveTempTarget? tempTarget;
  final ActiveOverride? override;

  /// Live limits from the host; fresher than the ones in the pairing bundle.
  final double? maxBolus;
  final double? maxCarbs;

  /// The low and high glucose thresholds the host alerts on, in mg/dL. Null on
  /// hosts that predate per-follower alert settings; callers fall back to the
  /// app's own defaults.
  final double? lowThreshold;
  final double? highThreshold;

  /// The ranges the host colours glucose by, when it reports them. Not the
  /// same numbers as the alert thresholds above: the host displays by its own
  /// settings and alerts by this follower's.
  final GlucoseRanges? ranges;

  /// What to colour a reading by: the host's ranges when it sends them, and
  /// otherwise the alert thresholds, which are the closest an older host gets
  /// us to how it draws its own chart.
  GlucoseRanges get glucoseRanges {
    final reported = ranges;
    if (reported != null) return reported;

    final low = lowThreshold;
    final high = highThreshold;
    if (low == null || high == null) return GlucoseRanges.defaults;
    if (!low.isFinite || !high.isFinite || low <= 0 || low >= high) {
      return GlucoseRanges.defaults;
    }
    // No target on this path — nothing to shade towards, and nothing asks for
    // one: the dynamic scheme only comes from a host that reports its ranges.
    return GlucoseRanges(low: low, high: high, target: (low + high) / 2);
  }

  /// Whether insulin delivery is stopped on the host right now, as reported by
  /// the pump itself. This — and only this — is what tells a follower that an
  /// emergency suspension actually took effect.
  final bool suspended;

  /// The follower that asked for the suspension, when one did.
  final String? suspendedBy;
  final DateTime? suspendedAt;

  /// Whether someone holding the host phone has answered the alarm.
  final bool suspendAcknowledged;

  /// Insulin is stopped and nobody on the host has responded yet.
  bool get suspensionUnacknowledged => suspended && !suspendAcknowledged;

  GlucoseReading? get latest => readings.isEmpty ? null : readings.first;

  int? get delta {
    if (readings.length < 2) return null;
    return readings[0].sgv - readings[1].sgv;
  }

  static StatusSnapshot? fromJson(Map<String, dynamic> json) {
    if (json['type'] != 'status') return null;
    final timestamp = json['timestamp'];
    if (timestamp is! num) return null;

    final readings = <GlucoseReading>[];
    final rawReadings = json['readings'];
    if (rawReadings is List) {
      for (final entry in rawReadings) {
        if (entry is! Map<String, dynamic>) continue;
        final sgv = entry['sgv'];
        final date = entry['date'];
        if (sgv is! num || date is! num) continue;
        readings.add(GlucoseReading(
          sgv: sgv.round(),
          date: DateTime.fromMillisecondsSinceEpoch((date * 1000).round()),
          direction: entry['direction'] as String?,
        ));
      }
    }

    return StatusSnapshot(
      timestamp: DateTime.fromMillisecondsSinceEpoch((timestamp * 1000).round()),
      units: (json['units'] as String?) ?? 'mg/dL',
      readings: readings,
      iob: (json['iob'] as num?)?.toDouble(),
      cob: (json['cob'] as num?)?.toDouble(),
      lastLoop: json['last_loop'] is num
          ? DateTime.fromMillisecondsSinceEpoch(((json['last_loop'] as num) * 1000).round())
          : null,
      eventualBg: (json['eventual_bg'] as num?)?.toDouble(),
      tempTarget: json['temp_target'] is Map<String, dynamic>
          ? ActiveTempTarget.fromJson(json['temp_target'] as Map<String, dynamic>)
          : null,
      override: json['override'] is Map<String, dynamic>
          ? ActiveOverride.fromJson(json['override'] as Map<String, dynamic>)
          : null,
      maxBolus: (json['max_bolus'] as num?)?.toDouble(),
      maxCarbs: (json['max_carbs'] as num?)?.toDouble(),
      lowThreshold: (json['low'] as num?)?.toDouble(),
      highThreshold: (json['high'] as num?)?.toDouble(),
      ranges: GlucoseRanges.fromJson(json['ranges']),
      suspended: json['suspended'] == true,
      suspendedBy: json['suspended_by'] as String?,
      suspendedAt: json['suspended_at'] is num
          ? DateTime.fromMillisecondsSinceEpoch(((json['suspended_at'] as num) * 1000).round())
          : null,
      suspendAcknowledged: json['suspend_acknowledged'] == true,
    );
  }
}

class GlucoseReading {
  const GlucoseReading({required this.sgv, required this.date, this.direction});

  /// mg/dL
  final int sgv;
  final DateTime date;
  final String? direction;

  String get trendArrow {
    switch (direction) {
      case 'TripleUp':
        return '⇈';
      case 'DoubleUp':
        return '⇈';
      case 'SingleUp':
        return '↑';
      case 'FortyFiveUp':
        return '↗';
      case 'Flat':
        return '→';
      case 'FortyFiveDown':
        return '↘';
      case 'SingleDown':
        return '↓';
      case 'DoubleDown':
        return '⇊';
      case 'TripleDown':
        return '⇊';
      default:
        return '';
    }
  }
}

class ActiveTempTarget {
  const ActiveTempTarget({required this.target, required this.name, this.until});

  /// mg/dL
  final double target;
  final String name;
  final DateTime? until;

  static ActiveTempTarget? fromJson(Map<String, dynamic> json) {
    final target = json['target'];
    if (target is! num) return null;
    DateTime? until;
    final startedAt = json['started_at'];
    final duration = json['duration'];
    if (startedAt is num && duration is num) {
      until = DateTime.fromMillisecondsSinceEpoch(((startedAt + duration * 60) * 1000).round());
    }
    return ActiveTempTarget(
      target: target.toDouble(),
      name: (json['name'] as String?) ?? 'Temp Target',
      until: until,
    );
  }
}

class ActiveOverride {
  const ActiveOverride({required this.name, this.until});

  final String name;
  final DateTime? until;

  static ActiveOverride? fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    if (name is! String) return null;
    DateTime? until;
    final startedAt = json['started_at'];
    final duration = json['duration'];
    if (startedAt is num && duration is num && duration > 0) {
      until = DateTime.fromMillisecondsSinceEpoch(((startedAt + duration * 60) * 1000).round());
    }
    return ActiveOverride(name: name, until: until);
  }
}
