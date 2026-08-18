import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:trio_follower/models/status_snapshot.dart';
import 'package:trio_follower/services/live_activity_bridge.dart';

StatusSnapshot snapshotWith(int count, {String units = 'mg/dL'}) {
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
          'bg', 'direction', 'change', 'iob', 'cob', 'readingDate', 'low', 'high', 'chart',
          // Drawn only by the detailed layouts, and null when the host sent
          // nothing for them.
          'eventual', 'overrideName', 'tempTargetName', 'lastLoop',
        },
      );
      final point = (state['chart'] as List).first as Map;
      expect(point.keys.cast<String>().toSet(), {'v', 't'});
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
