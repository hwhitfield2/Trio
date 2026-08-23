import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/status_snapshot.dart';

/// The readings and treatments from every snapshot the host has pushed,
/// folded together into one rolling window.
///
/// A single snapshot only carries a few hours — an APNS payload is 4 KB, and
/// that is all the readings that fit — so the longer chart durations can only
/// be drawn from what this device has collected itself. The window is bounded
/// by [retention], the longest duration the chart offers; beyond that the data
/// would only ever be pruned, never shown.
///
/// Honest about its gaps: hours where no push arrived (the app was off, the
/// host was offline) simply have no readings, and the chart draws them as the
/// empty stretches they were.
class ReadingHistory {
  const ReadingHistory({
    this.readings = const [],
    this.boluses = const [],
    this.carbs = const [],
  });

  static const empty = ReadingHistory();

  /// The longest window the chart can ask for.
  static const retention = Duration(hours: 48);

  /// Newest first, the same order a snapshot's own lists arrive in.
  final List<GlucoseReading> readings;
  final List<BolusEvent> boluses;
  final List<CarbEvent> carbs;

  bool get isEmpty => readings.isEmpty;

  /// Both kinds together, oldest first — the order a chart draws them in.
  List<TreatmentEvent> get treatments =>
      [...boluses, ...carbs]..sort((a, b) => a.date.compareTo(b.date));

  /// This history with a snapshot's readings and treatments folded in.
  ///
  /// Keyed by timestamp, so the overlap between consecutive snapshots — which
  /// resend most of the same window every five minutes — collapses instead of
  /// stacking. Where the host re-reports a reading it already sent, the newer
  /// copy wins: the host is the source of truth, and a backfilled or corrected
  /// value is a correction.
  ReadingHistory merge(StatusSnapshot snapshot) {
    final byDate = <int, GlucoseReading>{
      for (final reading in readings) reading.date.millisecondsSinceEpoch: reading,
      for (final reading in snapshot.readings) reading.date.millisecondsSinceEpoch: reading,
    };
    final merged = byDate.values.toList()..sort((a, b) => b.date.compareTo(a.date));

    // Pruned relative to the newest reading rather than the wall clock: a
    // night with the host unreachable should age the chart, not empty it.
    DateTime? cutoff;
    if (merged.isNotEmpty) {
      cutoff = merged.first.date.subtract(retention);
      merged.removeWhere((reading) => reading.date.isBefore(cutoff!));
    }

    // Treatments are keyed by time *and* amount: an SMB and a manual bolus can
    // land the same second, and collapsing those would erase insulin.
    final bolusesByKey = <String, BolusEvent>{
      for (final bolus in boluses) '${bolus.date.millisecondsSinceEpoch}/${bolus.units}': bolus,
      for (final bolus in snapshot.boluses)
        '${bolus.date.millisecondsSinceEpoch}/${bolus.units}': bolus,
    };
    final carbsByKey = <String, CarbEvent>{
      for (final carb in carbs) '${carb.date.millisecondsSinceEpoch}/${carb.grams}': carb,
      for (final carb in snapshot.carbs) '${carb.date.millisecondsSinceEpoch}/${carb.grams}': carb,
    };
    final mergedBoluses = bolusesByKey.values.toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    final mergedCarbs = carbsByKey.values.toList()..sort((a, b) => b.date.compareTo(a.date));
    if (cutoff != null) {
      mergedBoluses.removeWhere((bolus) => bolus.date.isBefore(cutoff!));
      mergedCarbs.removeWhere((carb) => carb.date.isBefore(cutoff!));
    }

    return ReadingHistory(
      readings: List.unmodifiable(merged),
      boluses: List.unmodifiable(mergedBoluses),
      carbs: List.unmodifiable(mergedCarbs),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'readings': [
          for (final reading in readings)
            <String, dynamic>{
              'sgv': reading.sgv,
              'date': reading.date.millisecondsSinceEpoch,
              if (reading.direction != null) 'direction': reading.direction,
            },
        ],
        'boluses': [
          for (final bolus in boluses)
            <String, dynamic>{
              'date': bolus.date.millisecondsSinceEpoch,
              'units': bolus.units,
              if (bolus.isAutomatic) 'auto': true,
            },
        ],
        'carbs': [
          for (final carb in carbs)
            <String, dynamic>{'date': carb.date.millisecondsSinceEpoch, 'grams': carb.grams},
        ],
      };

  /// A stored history, skipping any entry that is not one this app could have
  /// written rather than throwing the whole thing away.
  static ReadingHistory fromJson(Map<String, dynamic> json) {
    final rawReadings = json['readings'];
    final readings = <GlucoseReading>[
      if (rawReadings is List)
        for (final entry in rawReadings)
          if (entry is Map<String, dynamic>)
            if (entry['sgv'] case final num sgv)
              if (entry['date'] case final num date)
                GlucoseReading(
                  sgv: sgv.round(),
                  date: DateTime.fromMillisecondsSinceEpoch(date.round()),
                  direction: entry['direction'] as String?,
                ),
    ];

    final rawBoluses = json['boluses'];
    final boluses = <BolusEvent>[
      if (rawBoluses is List)
        for (final entry in rawBoluses)
          if (entry is Map<String, dynamic>)
            if (entry['date'] case final num date)
              if (entry['units'] case final num units)
                BolusEvent(
                  date: DateTime.fromMillisecondsSinceEpoch(date.round()),
                  units: units.toDouble(),
                  isAutomatic: entry['auto'] == true,
                ),
    ];

    final rawCarbs = json['carbs'];
    final carbs = <CarbEvent>[
      if (rawCarbs is List)
        for (final entry in rawCarbs)
          if (entry is Map<String, dynamic>)
            if (entry['date'] case final num date)
              if (entry['grams'] case final num grams)
                CarbEvent(
                  date: DateTime.fromMillisecondsSinceEpoch(date.round()),
                  grams: grams.toDouble(),
                ),
    ];

    return ReadingHistory(
      readings: List.unmodifiable(readings),
      boluses: List.unmodifiable(boluses),
      carbs: List.unmodifiable(carbs),
    );
  }
}

/// Persists the rolling history alongside the last snapshot, so the chart has
/// its whole window back immediately after a launch.
class ReadingHistoryStore {
  static const _key = 'trio_follower.reading_history';

  static Future<ReadingHistory> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return ReadingHistory.empty;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return ReadingHistory.empty;
      return ReadingHistory.fromJson(decoded);
    } catch (_) {
      return ReadingHistory.empty;
    }
  }

  static Future<void> save(ReadingHistory history) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(history.toJson()));
  }

  /// On unpairing or re-pairing: a different host's history would be a lie on
  /// this chart.
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
