import 'package:flutter_test/flutter_test.dart';
import 'package:trio_follower/models/command.dart';
import 'package:trio_follower/models/status_snapshot.dart';
import 'package:trio_follower/services/reading_history_store.dart';

/// Readings five minutes apart, newest first, ending at [newest].
List<GlucoseReading> run(DateTime newest, int count, {int sgv = 120}) => [
      for (var index = 0; index < count; index++)
        GlucoseReading(sgv: sgv, date: newest.subtract(Duration(minutes: 5 * index))),
    ];

void main() {
  final newest = DateTime(2026, 3, 1, 12);

  group('the command', () {
    test('carries the window it is asking for', () {
      final payload = TrioCommand.historyRequest(hours: 24)
          .toPayload(user: 'Mom', sequence: 1, now: newest);

      expect(payload['command_type'], 'history_request');
      expect(payload['hours'], 24);
    });

    test('asks the host for information, so it makes no sound there', () {
      final command = TrioCommand.historyRequest(hours: 48);
      expect(command.changesSomething, isFalse);
      expect(command.hostAlert(followerName: 'Mom'), isNull);
    });
  });

  group('a history push', () {
    Map<String, dynamic> historyJson({
      List<Map<String, dynamic>>? readings,
      int seq = 1,
      int of = 1,
    }) =>
        <String, dynamic>{
          'type': 'history',
          'seq': seq,
          'of': of,
          'readings': readings ??
              [
                {'sgv': 104, 'date': newest.millisecondsSinceEpoch / 1000},
              ],
        };

    test('parses its readings and its place in the run', () {
      final slice = GlucoseHistory.fromJson(historyJson(seq: 2, of: 3))!;

      expect(slice.readings.single.sgv, 104);
      expect(slice.readings.single.date, newest);
      expect(slice.sequence, 2);
      expect(slice.total, 3);
      expect(slice.isLast, isFalse);
    });

    test('the last slice says so, which is what ends the backfill', () {
      expect(GlucoseHistory.fromJson(historyJson(seq: 3, of: 3))!.isLast, isTrue);
      // A host that sends no counters is sending one slice.
      final bare = GlucoseHistory.fromJson({
        'type': 'history',
        'readings': <dynamic>[],
      })!;
      expect(bare.sequence, 1);
      expect(bare.total, 1);
      expect(bare.isLast, isTrue);
    });

    test('an empty slice is a slice, not a failure: the host had that stretch blank', () {
      final slice = GlucoseHistory.fromJson(historyJson(readings: []))!;
      expect(slice.readings, isEmpty);
      expect(slice.isLast, isTrue);
    });

    test('entries missing a value or a time are skipped, not fatal', () {
      final slice = GlucoseHistory.fromJson(historyJson(readings: [
        {'sgv': 104, 'date': newest.millisecondsSinceEpoch / 1000},
        {'sgv': 110},
        {'date': newest.millisecondsSinceEpoch / 1000},
      ]))!;

      expect(slice.readings.length, 1);
    });

    test('a status payload is not a history one, and the reverse', () {
      expect(GlucoseHistory.fromJson({'type': 'status', 'readings': <dynamic>[]}), isNull);
      // Which is exactly how the two share one encrypted push field.
      expect(StatusSnapshot.fromJson(historyJson()), isNull);
    });
  });

  group('folding a backfill into the rolling history', () {
    test('older readings extend how far back the chart reaches', () {
      // Four hours, the most a single status push carries.
      var history = ReadingHistory.empty.merge(StatusSnapshot(
        timestamp: newest,
        units: 'mg/dL',
        readings: run(newest, 48),
      ));
      expect(history.coverage, const Duration(hours: 3, minutes: 55));

      // A slice reaching back a further twenty hours, at the coarser
      // resolution a backfill uses.
      final older = [
        for (var index = 1; index <= 80; index++)
          GlucoseReading(sgv: 130, date: newest.subtract(Duration(minutes: 15 * index))),
      ];
      history = history.mergeHistory(older);

      expect(history.coverage, const Duration(hours: 20));
      expect(history.readings.first.date, newest);
    });

    test('ground the device already had is not duplicated', () {
      final snapshot = StatusSnapshot(
        timestamp: newest,
        units: 'mg/dL',
        readings: run(newest, 12),
      );
      final history = ReadingHistory.empty.merge(snapshot);
      final before = history.readings.length;

      // The same readings again, as a backfill that overlapped.
      final merged = history.mergeHistory(run(newest, 12));
      expect(merged.readings.length, before);
    });

    test('the host corrects itself: a re-reported reading takes the newer value', () {
      final history = ReadingHistory.empty.merge(StatusSnapshot(
        timestamp: newest,
        units: 'mg/dL',
        readings: run(newest, 3, sgv: 100),
      ));

      final corrected = history.mergeHistory([GlucoseReading(sgv: 155, date: newest)]);
      expect(corrected.readings.first.sgv, 155);
      expect(corrected.readings.length, 3);
    });

    test('an empty backfill leaves the history exactly as it was', () {
      final history = ReadingHistory.empty.merge(StatusSnapshot(
        timestamp: newest,
        units: 'mg/dL',
        readings: run(newest, 6),
      ));
      expect(identical(history.mergeHistory(const []), history), isTrue);
    });

    test('readings beyond the retention window are still pruned', () {
      final history = ReadingHistory.empty.merge(StatusSnapshot(
        timestamp: newest,
        units: 'mg/dL',
        readings: run(newest, 2),
      ));

      final tooOld = GlucoseReading(
        sgv: 90,
        date: newest.subtract(const Duration(hours: 49)),
      );
      final merged = history.mergeHistory([tooOld]);

      expect(merged.readings.any((reading) => reading.date == tooOld.date), isFalse);
    });

    test('treatments still on the chart survive a backfill', () {
      final history = ReadingHistory.empty.merge(StatusSnapshot(
        timestamp: newest,
        units: 'mg/dL',
        readings: run(newest, 6),
        boluses: [BolusEvent(date: newest, units: 1.5)],
        carbs: [CarbEvent(date: newest, grams: 30)],
      ));
      expect(history.treatments.length, 2);

      // Backfilling only ever adds older readings, so nothing on the chart
      // now can fall out of the window because of one.
      final merged = history.mergeHistory([
        GlucoseReading(sgv: 90, date: newest.subtract(const Duration(hours: 10))),
      ]);
      expect(merged.treatments.length, 2);
    });
  });

  group('coverage', () {
    test('is the span the kept readings actually reach across', () {
      final history = ReadingHistory.empty.merge(StatusSnapshot(
        timestamp: newest,
        units: 'mg/dL',
        readings: run(newest, 13),
      ));
      expect(history.coverage, const Duration(hours: 1));
    });

    test('a single reading covers nothing, and neither does none', () {
      expect(ReadingHistory.empty.coverage, Duration.zero);
      final one = ReadingHistory.empty.merge(StatusSnapshot(
        timestamp: newest,
        units: 'mg/dL',
        readings: run(newest, 1),
      ));
      expect(one.coverage, Duration.zero);
    });
  });
}
