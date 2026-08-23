import 'package:flutter_test/flutter_test.dart';
import 'package:trio_follower/models/status_snapshot.dart';
import 'package:trio_follower/services/reading_history_store.dart';

StatusSnapshot snapshotWith({
  required DateTime timestamp,
  List<GlucoseReading> readings = const [],
  List<BolusEvent> boluses = const [],
  List<CarbEvent> carbs = const [],
}) =>
    StatusSnapshot(
      timestamp: timestamp,
      units: 'mg/dL',
      readings: readings,
      boluses: boluses,
      carbs: carbs,
    );

/// Newest first, the way the host sends them.
List<GlucoseReading> readingsEndingAt(DateTime newest, List<int> valuesOldestFirst) {
  final count = valuesOldestFirst.length;
  return [
    for (var index = 0; index < count; index++)
      GlucoseReading(
        sgv: valuesOldestFirst[count - 1 - index],
        date: newest.subtract(Duration(minutes: 5 * index)),
      ),
  ];
}

void main() {
  final noon = DateTime(2026, 3, 1, 12);

  group('reading history merging', () {
    test('consecutive snapshots overlap into one window instead of stacking', () {
      // Two snapshots five minutes apart resend almost the same readings.
      final first = ReadingHistory.empty
          .merge(snapshotWith(timestamp: noon, readings: readingsEndingAt(noon, [100, 110, 120])));
      final later = noon.add(const Duration(minutes: 5));
      final merged = first
          .merge(snapshotWith(timestamp: later, readings: readingsEndingAt(later, [110, 120, 130])));

      expect(merged.readings.map((reading) => reading.sgv).toList(), [130, 120, 110, 100]);
    });

    test('a re-reported reading takes the newer value: the host corrects itself', () {
      final first = ReadingHistory.empty
          .merge(snapshotWith(timestamp: noon, readings: readingsEndingAt(noon, [100])));
      final corrected = first.merge(snapshotWith(
        timestamp: noon.add(const Duration(minutes: 1)),
        readings: [GlucoseReading(sgv: 104, date: noon)],
      ));

      expect(corrected.readings.single.sgv, 104);
    });

    test('readings older than the retention window are pruned', () {
      final old = ReadingHistory.empty.merge(snapshotWith(
        timestamp: noon,
        readings: [GlucoseReading(sgv: 100, date: noon)],
      ));
      final twoDaysOn = noon.add(ReadingHistory.retention + const Duration(minutes: 5));
      final merged = old.merge(snapshotWith(
        timestamp: twoDaysOn,
        readings: [GlucoseReading(sgv: 120, date: twoDaysOn)],
      ));

      expect(merged.readings.map((reading) => reading.sgv).toList(), [120]);
    });

    test('pruning follows the newest reading, not the wall clock', () {
      // The host has been unreachable for however long: nothing newer arrived,
      // so nothing ages out.
      final history = ReadingHistory.empty.merge(snapshotWith(
        timestamp: noon,
        readings: readingsEndingAt(noon, [100, 110]),
      ));
      final unchanged = history.merge(snapshotWith(timestamp: noon.add(const Duration(hours: 1))));

      expect(unchanged.readings.length, 2);
    });

    test('treatments dedupe by time and amount, so a resent bolus is one bolus', () {
      final bolus = BolusEvent(date: noon, units: 2.5);
      final first = ReadingHistory.empty.merge(snapshotWith(
        timestamp: noon,
        readings: [GlucoseReading(sgv: 100, date: noon)],
        boluses: [bolus],
        carbs: [CarbEvent(date: noon, grams: 30)],
      ));
      final again = first.merge(snapshotWith(
        timestamp: noon.add(const Duration(minutes: 5)),
        boluses: [BolusEvent(date: noon, units: 2.5)],
        carbs: [CarbEvent(date: noon, grams: 30)],
      ));

      expect(again.boluses.length, 1);
      expect(again.carbs.length, 1);
    });

    test('an SMB and a manual bolus in the same second both survive', () {
      final merged = ReadingHistory.empty.merge(snapshotWith(
        timestamp: noon,
        readings: [GlucoseReading(sgv: 100, date: noon)],
        boluses: [
          BolusEvent(date: noon, units: 1.0, isAutomatic: true),
          BolusEvent(date: noon, units: 2.5),
        ],
      ));

      expect(merged.boluses.length, 2);
    });

    test('treatments list both kinds oldest first, the order a chart draws in', () {
      final merged = ReadingHistory.empty.merge(snapshotWith(
        timestamp: noon,
        readings: [GlucoseReading(sgv: 100, date: noon)],
        boluses: [BolusEvent(date: noon, units: 1)],
        carbs: [CarbEvent(date: noon.subtract(const Duration(minutes: 10)), grams: 20)],
      ));

      expect(merged.treatments.first, isA<CarbEvent>());
      expect(merged.treatments.last, isA<BolusEvent>());
    });
  });

  group('reading history persistence', () {
    test('round-trips readings and treatments through JSON', () {
      final history = ReadingHistory.empty.merge(snapshotWith(
        timestamp: noon,
        readings: [GlucoseReading(sgv: 100, date: noon, direction: 'Flat')],
        boluses: [BolusEvent(date: noon, units: 2.5, isAutomatic: true)],
        carbs: [CarbEvent(date: noon, grams: 30)],
      ));

      final restored = ReadingHistory.fromJson(history.toJson());

      expect(restored.readings.single.sgv, 100);
      expect(restored.readings.single.date, noon);
      expect(restored.readings.single.direction, 'Flat');
      expect(restored.boluses.single.units, 2.5);
      expect(restored.boluses.single.isAutomatic, isTrue);
      expect(restored.carbs.single.grams, 30);
    });

    test('entries this app could not have written are skipped, not fatal', () {
      final restored = ReadingHistory.fromJson({
        'readings': [
          {'sgv': 100, 'date': noon.millisecondsSinceEpoch},
          {'sgv': 'high'},
          'not even a map',
        ],
        'boluses': {'wrong': 'shape'},
      });

      expect(restored.readings.single.sgv, 100);
      expect(restored.boluses, isEmpty);
    });
  });
}
