import 'package:flutter_test/flutter_test.dart';
import 'package:trio_follower/models/glucose_ranges.dart';
import 'package:trio_follower/models/status_snapshot.dart';
import 'package:trio_follower/services/widget_bridge.dart';

StatusSnapshot snapshotWith(
  List<int> sgvs, {
  double? low,
  double? high,
  GlucoseRanges? ranges,
  List<BolusEvent> boluses = const [],
  List<CarbEvent> carbs = const [],
  String units = 'mg/dL',
}) {
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
    ranges: ranges,
    boluses: boluses,
    carbs: carbs,
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

    test('the host display range wins over the follower alert thresholds', () {
      // The bar under the chart has to agree with the dots above it, and the
      // dots are the host's ranges.
      final stats = WidgetBridge.statsFor(
        snapshotWith(
          [100, 100, 100, 100],
          low: 60,
          high: 250,
          ranges: const GlucoseRanges(low: 110, high: 200, target: 150),
        ),
      );
      expect(stats!['low'], 100);
      expect(stats['in_range'], 0);
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

    test('tells the native side how the host colours, in display units', () {
      final payload = WidgetBridge.payloadFor(
        snapshotWith(
          [120],
          ranges: const GlucoseRanges(low: 72, high: 180, target: 108, isDynamic: true),
          units: 'mmol/L',
        ),
      );

      // The widgets compare these against the chart points they are handed, so
      // a sweep left in mg/dL would paint every reading violet.
      expect(payload['low'], closeTo(4.0, 0.001));
      expect(payload['high'], closeTo(10.0, 0.001));
      final color = payload['color'] as Map;
      expect(color['scheme'], 'dynamicColor');
      expect(color['target'], closeTo(6.0, 0.001));
      expect(color['sweepLow'], closeTo(3.1, 0.001));
      expect(color['sweepHigh'], closeTo(12.2, 0.001));
    });

    test('a host on the static scheme says so, rather than saying nothing', () {
      final payload = WidgetBridge.payloadFor(
        snapshotWith([120], ranges: const GlucoseRanges(low: 70, high: 180, target: 100)),
      );
      expect((payload['color'] as Map)['scheme'], 'staticColor');
    });

    test('the widgets are told what was given and eaten', () {
      final now = DateTime.now();
      final payload = WidgetBridge.payloadFor(
        snapshotWith(
          [120],
          boluses: [BolusEvent(date: now, units: 1.25, isAutomatic: true)],
          carbs: [CarbEvent(date: now, grams: 30)],
        ),
      );

      final bolus = (payload['boluses'] as List).single as Map;
      expect(bolus['a'], 1.25);
      // Milliseconds, like the chart points beside them.
      expect(bolus['t'], now.millisecondsSinceEpoch);
      expect(bolus['s'], isTrue);

      final carb = (payload['carbs'] as List).single as Map;
      expect(carb['g'], 30);
      expect(carb['t'], now.millisecondsSinceEpoch);
    });

    test('a bolus somebody asked for says nothing about being automatic', () {
      final payload = WidgetBridge.payloadFor(
        snapshotWith([120], boluses: [BolusEvent(date: DateTime.now(), units: 3)]),
      );
      expect(((payload['boluses'] as List).single as Map).containsKey('s'), isFalse);
    });

    test('nothing given means no keys at all, rather than empty arrays', () {
      final payload = WidgetBridge.payloadFor(snapshotWith([120]));
      expect(payload.containsKey('boluses'), isFalse);
      expect(payload.containsKey('carbs'), isFalse);
    });

    test('chart points stay newest first with epoch milliseconds', () {
      final payload = WidgetBridge.payloadFor(snapshotWith([120, 118, 116]));
      final chart = payload['chart'] as List;
      expect(chart, hasLength(3));
      expect((chart.first as Map)['t'] as int, greaterThan((chart.last as Map)['t'] as int));
    });
  });
}
