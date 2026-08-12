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
  });
}
