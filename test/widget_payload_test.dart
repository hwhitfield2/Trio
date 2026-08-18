import 'package:flutter_test/flutter_test.dart';
import 'package:trio_follower/models/status_snapshot.dart';
import 'package:trio_follower/services/widget_bridge.dart';

StatusSnapshot snapshotWith(List<int> sgvs, {double? low, double? high, String units = 'mg/dL'}) {
  final now = DateTime.now();
  return StatusSnapshot(
    timestamp: now,
    units: units,
    // Newest first, like the host sends them.
    readings: [
      for (var index = 0; index < sgvs.length; index++)
        GlucoseReading(
          sgv: sgvs[index],
          date: now.subtract(Duration(minutes: 5 * index)),
          direction: 'Flat',
        ),
    ],
    lowThreshold: low,
    highThreshold: high,
  );
}

void main() {
  group('widget payload time in range', () {
    test('percentages sum to 100', () {
      final stats = WidgetBridge.statsFor(snapshotWith([60, 80, 120, 200, 90]));
      expect(stats, isNotNull);
      expect(stats!['low']! + stats['in_range']! + stats['high']!, 100);
    });

    test('classifies against the host thresholds, not the defaults', () {
      // 100 is in range by default, but low against a host low of 110.
      final withHostRange = WidgetBridge.statsFor(
        snapshotWith([100, 100, 100, 100], low: 110, high: 200),
      );
      expect(withHostRange!['low'], 100);
      expect(withHostRange['in_range'], 0);

      final withDefaults = WidgetBridge.statsFor(snapshotWith([100, 100, 100, 100]));
      expect(withDefaults!['in_range'], 100);
    });

    test('threshold values are inclusive at both ends', () {
      final stats = WidgetBridge.statsFor(snapshotWith([70, 180]));
      expect(stats!['low'], 50);
      expect(stats['high'], 50);
      expect(stats['in_range'], 0);
    });

    test('no readings means no stats rather than a divide by zero', () {
      expect(WidgetBridge.statsFor(snapshotWith(const [])), isNull);
    });
  });

  group('widget payload', () {
    test('carries the host thresholds converted to display units', () {
      final payload = WidgetBridge.payloadFor(
        snapshotWith([120], low: 72, high: 190, units: 'mmol/L'),
      );
      expect(payload['low'], closeTo(4.0, 0.001));
      expect(payload['high'], closeTo(10.6, 0.001));
      expect(payload['bg'], '6.7');
    });

    test('falls back to the app defaults when the host sends none', () {
      final payload = WidgetBridge.payloadFor(snapshotWith([120]));
      expect(payload['low'], 70.0);
      expect(payload['high'], 180.0);
    });

    test('chart points stay newest first with epoch milliseconds', () {
      final payload = WidgetBridge.payloadFor(snapshotWith([120, 118, 116]));
      final chart = payload['chart'] as List;
      expect(chart, hasLength(3));
      expect((chart.first as Map)['t'] as int, greaterThan((chart.last as Map)['t'] as int));
    });
  });
}
