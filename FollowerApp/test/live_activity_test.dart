import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:trio_follower/models/glucose_ranges.dart';
import 'package:trio_follower/models/status_snapshot.dart';
import 'package:trio_follower/services/live_activity_bridge.dart';

StatusSnapshot snapshotWith(
  int count, {
  String units = 'mg/dL',
  List<BolusEvent> boluses = const [],
  List<CarbEvent> carbs = const [],
}) {
  final now = DateTime.now();
  return StatusSnapshot(
    timestamp: now,
    units: units,
    readings: [
      for (var index = 0; index < count; index++)
        GlucoseReading(
          sgv: 100 + (index % 40),
          date: now.subtract(Duration(minutes: 5 * index)),
          direction: 'Flat',
        ),
    ],
    iob: 1.25,
    cob: 18.4,
    lowThreshold: 72,
    highThreshold: 190,
    boluses: boluses,
    carbs: carbs,
  );
}

void main() {
  group('live activity payload', () {
    test('trims the chart so the payload stays well inside ActivityKit budget', () {
      // The host can send 48 readings; the activity must not carry them all.
      final state = LiveActivityBridge.stateFor(snapshotWith(48));
      expect((state['chart'] as List).length, 24);

      // A proxy for ActivityKit's own 4 KB encoding, with a wide margin: Swift
      // re-encodes this and the attributes add a host name on top.
      final bytes = utf8.encode(jsonEncode(state)).length;
      expect(bytes, lessThan(3000));
    });

    test('keeps the newest readings, not the oldest', () {
      final snapshot = snapshotWith(48);
      final state = LiveActivityBridge.stateFor(snapshot);
      final chart = state['chart'] as List;
      final newest = snapshot.readings.first.date.millisecondsSinceEpoch ~/ 1000;
      expect((chart.first as Map)['t'], newest);
    });

    test('timestamps are seconds, not milliseconds', () {
      final state = LiveActivityBridge.stateFor(snapshotWith(3));
      final seconds = state['readingDate'] as int;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      expect((seconds - now).abs(), lessThan(60));
    });

    test('formats for mmol/L when the host displays it', () {
      final state = LiveActivityBridge.stateFor(snapshotWith(2, units: 'mmol/L'));
      expect(state['bg'], contains('.'));
      expect(state['low'], closeTo(4.0, 0.001));
    });

    test('carries insulin and carbs as display strings', () {
      final state = LiveActivityBridge.stateFor(snapshotWith(2));
      expect(state['iob'], '1.3');
      expect(state['cob'], '18');
    });

    test('field names are the ones ActivityKit decodes', () {
      // Shared with FollowerActivityAttributes.ContentState (which ActivityKit
      // decodes into) and with the host's FollowerLiveActivityState (which
      // pushes the same structure). A rename that misses one of the three stops
      // Live Activity updates silently.
      final state = LiveActivityBridge.stateFor(snapshotWith(2));
      expect(
        state.keys.toSet(),
        {
          'bg', 'direction', 'change', 'iob', 'cob', 'readingDate', 'low', 'high', 'color',
          'chart',
          // Drawn only by the detailed layouts, and null when the host sent
          // nothing for them.
          'eventual', 'overrideName', 'tempTargetName', 'lastLoop',
        },
      );
      final point = (state['chart'] as List).first as Map;
      expect(point.keys.cast<String>().toSet(), {'v', 't'});
      final color = state['color'] as Map;
      expect(color.keys.cast<String>().toSet(), {'scheme', 'target', 'sweepLow', 'sweepHigh'});
    });

    test('the Lock Screen colours by the host ranges, not the alert thresholds', () {
      final now = DateTime.now();
      final snapshot = StatusSnapshot(
        timestamp: now,
        units: 'mg/dL',
        readings: [GlucoseReading(sgv: 120, date: now, direction: 'Flat')],
        lowThreshold: 75,
        highThreshold: 200,
        ranges: const GlucoseRanges(low: 80, high: 160, target: 110, isDynamic: true),
      );

      final state = LiveActivityBridge.stateFor(snapshot);
      expect(state['low'], 80);
      expect(state['high'], 160);
      expect(state['color'], {
        'scheme': 'dynamicColor',
        'target': 110.0,
        'sweepLow': GlucoseRanges.dynamicSweepLow,
        'sweepHigh': GlucoseRanges.dynamicSweepHigh,
      });
    });

    test('the colouring travels in display units, like everything else here', () {
      // The widget extension compares these against the chart points it is
      // given, which are mmol/L on an mmol/L host; a sweep left in mg/dL would
      // paint every reading violet.
      final snapshot = StatusSnapshot(
        timestamp: DateTime.now(),
        units: 'mmol/L',
        readings: [GlucoseReading(sgv: 120, date: DateTime.now(), direction: 'Flat')],
        ranges: const GlucoseRanges(low: 72, high: 180, target: 108, isDynamic: true),
      );

      final color = LiveActivityBridge.stateFor(snapshot)['color'] as Map;
      expect(color['target'], closeTo(6.0, 0.001));
      expect(color['sweepLow'], closeTo(3.1, 0.001));
      expect(color['sweepHigh'], closeTo(12.2, 0.001));
    });

    test('what was given and eaten reaches the Lock Screen', () {
      final now = DateTime.now();
      final state = LiveActivityBridge.stateFor(snapshotWith(
        6,
        boluses: [BolusEvent(date: now, units: 1.25, isAutomatic: true)],
        carbs: [CarbEvent(date: now, grams: 30)],
      ));

      final bolus = (state['boluses'] as List).single as Map;
      expect(bolus['a'], 1.25);
      // Seconds, like everything else in a payload with 4 KB to live in.
      expect(bolus['t'], now.millisecondsSinceEpoch ~/ 1000);
      expect(bolus['s'], isTrue);
      expect(((state['carbs'] as List).single as Map)['g'], 30);
    });

    test('a treatment from before the plotted chart is left out', () {
      final now = DateTime.now();
      // The Lock Screen plots 24 readings — two hours. A bolus from three
      // hours ago has no reading on this chart to sit against.
      final state = LiveActivityBridge.stateFor(snapshotWith(
        48,
        boluses: [
          BolusEvent(date: now.subtract(const Duration(hours: 3)), units: 2),
          BolusEvent(date: now, units: 1),
        ],
      ));

      final boluses = state['boluses'] as List;
      expect(boluses, hasLength(1));
      expect((boluses.single as Map)['a'], 1);
    });

    test('nothing given leaves the keys out, keeping the budget for the chart', () {
      final state = LiveActivityBridge.stateFor(snapshotWith(6));
      expect(state.containsKey('boluses'), isFalse);
      expect(state.containsKey('carbs'), isFalse);
    });

    test('a busy few hours still fits ActivityKit', () {
      final now = DateTime.now();
      final state = LiveActivityBridge.stateFor(snapshotWith(
        48,
        boluses: [
          for (var index = 0; index < 20; index++)
            BolusEvent(date: now.subtract(Duration(minutes: index * 5)), units: 1.25),
        ],
        carbs: [
          for (var index = 0; index < 20; index++)
            CarbEvent(date: now.subtract(Duration(minutes: index * 5)), grams: 30),
        ],
      ));

      expect((state['boluses'] as List).length, lessThanOrEqualTo(8));
      expect((state['carbs'] as List).length, lessThanOrEqualTo(8));
      expect(utf8.encode(jsonEncode(state)).length, lessThan(3000));
    });

    test('matches the host formatting vector, value for value', () {
      // The same numbers appear in TrioTests/FollowerLiveActivityStateTests.
      // The host formats a remote update itself, so the two implementations
      // have to agree digit for digit or the Lock Screen would change when it
      // switched between local and remote updates.
      final now = DateTime.now();
      final snapshot = StatusSnapshot(
        timestamp: now,
        units: 'mg/dL',
        readings: [
          GlucoseReading(sgv: 120, date: now, direction: 'FortyFiveUp'),
          GlucoseReading(sgv: 114, date: now.subtract(const Duration(minutes: 5)), direction: 'Flat'),
        ],
        iob: 1.25,
        cob: 18.4,
        lowThreshold: 70,
        highThreshold: 180,
      );

      final mgdl = LiveActivityBridge.stateFor(snapshot);
      expect(mgdl['bg'], '120');
      expect(mgdl['direction'], '↗');
      expect(mgdl['change'], '+6');
      expect(mgdl['iob'], '1.3');
      expect(mgdl['cob'], '18');
      expect(mgdl['low'], 70);
      expect(mgdl['high'], 180);
    });

    test('carries what the detailed layouts draw', () {
      final now = DateTime.now();
      final snapshot = StatusSnapshot(
        timestamp: now,
        units: 'mg/dL',
        readings: [GlucoseReading(sgv: 120, date: now, direction: 'Flat')],
        eventualBg: 110,
        lastLoop: now.subtract(const Duration(minutes: 2)),
        tempTarget: const ActiveTempTarget(target: 140, name: 'Exercise'),
        override: const ActiveOverride(name: 'Sick day'),
      );

      final state = LiveActivityBridge.stateFor(snapshot);
      expect(state['eventual'], '110');
      expect(state['tempTargetName'], 'Exercise');
      expect(state['overrideName'], 'Sick day');
      expect(state['lastLoop'], now.subtract(const Duration(minutes: 2)).millisecondsSinceEpoch ~/ 1000);
    });

    test('leaves the detailed values null when the host sent none', () {
      final state = LiveActivityBridge.stateFor(snapshotWith(2));
      expect(state['eventual'], isNull);
      expect(state['tempTargetName'], isNull);
      expect(state['overrideName'], isNull);
      expect(state['lastLoop'], isNull);
    });

    test('mmol/L conversion matches the host vector', () {
      final now = DateTime.now();
      final snapshot = StatusSnapshot(
        timestamp: now,
        units: 'mmol/L',
        readings: [
          GlucoseReading(sgv: 120, date: now, direction: 'SingleDown'),
          GlucoseReading(sgv: 138, date: now.subtract(const Duration(minutes: 5)), direction: 'Flat'),
        ],
        lowThreshold: 70,
        highThreshold: 180,
      );

      final state = LiveActivityBridge.stateFor(snapshot);
      expect(state['bg'], '6.7');
      expect(state['direction'], '↓');
      expect(state['change'], '-1.0');
      expect(state['low'], 3.9);
      expect(state['high'], 10.0);
      expect(((state['chart'] as List).first as Map)['v'], 6.7);
    });
  });
}
