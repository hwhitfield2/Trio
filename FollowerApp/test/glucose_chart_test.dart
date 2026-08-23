import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trio_follower/models/glucose_ranges.dart';
import 'package:trio_follower/models/status_snapshot.dart';
import 'package:trio_follower/widgets/glucose_chart.dart';
import 'package:trio_follower/widgets/glucose_colors.dart';

/// Newest first, the way the host sends them.
List<GlucoseReading> readingsEndingAt(DateTime newest, List<int> valuesOldestFirst) {
  final count = valuesOldestFirst.length;
  return [
    for (var index = 0; index < count; index++)
      GlucoseReading(
        sgv: valuesOldestFirst[count - 1 - index],
        date: newest.subtract(Duration(minutes: 5 * index)),
        direction: 'Flat',
      ),
  ];
}

void main() {
  final newest = DateTime(2026, 3, 1, 12);

  group('glucose chart scale', () {
    test('plots the readings oldest first, whatever order they arrive in', () {
      final scale = GlucoseChartScale(readingsEndingAt(newest, [90, 100, 110, 120]));
      expect(scale.points.map((reading) => reading.sgv).toList(), [90, 100, 110, 120]);
    });

    test('spans the window from the oldest reading to the newest', () {
      final scale = GlucoseChartScale(readingsEndingAt(newest, [90, 100, 110, 120]));
      expect(scale.xFor(scale.points.first, 200), 0);
      expect(scale.xFor(scale.points.last, 200), 200);
    });

    test('picks the reading nearest the finger', () {
      final scale = GlucoseChartScale(readingsEndingAt(newest, [90, 100, 110, 120]));
      // Four readings across 200 points: 0, 66.6, 133.3, 200.
      expect(scale.indexAt(0, 200), 0);
      expect(scale.indexAt(60, 200), 1);
      expect(scale.indexAt(140, 200), 2);
      expect(scale.indexAt(200, 200), 3);
    });

    test('a finger past either edge still lands on the end reading', () {
      final scale = GlucoseChartScale(readingsEndingAt(newest, [90, 100, 110, 120]));
      expect(scale.indexAt(-40, 200), 0);
      expect(scale.indexAt(999, 200), 3);
    });

    test('a single reading is selectable rather than a divide by zero', () {
      final scale = GlucoseChartScale(readingsEndingAt(newest, [120]));
      expect(scale.xFor(scale.points.single, 200), 0);
      expect(scale.indexAt(120, 200), 0);
    });

    test('nothing to point at when there are no readings', () {
      final scale = GlucoseChartScale(const []);
      expect(scale.isEmpty, isTrue);
      expect(scale.indexAt(50, 200), isNull);
    });
  });

  group('fixed-duration window', () {
    test('spans the chosen duration ending at the newest reading', () {
      final scale = GlucoseChartScale(
        readingsEndingAt(newest, [90, 100, 110, 120]),
        window: const Duration(hours: 1),
      );

      // The newest reading sits at the right edge; the others sit where their
      // time puts them, not spread to fill the width.
      expect(scale.xFor(scale.points.last, 200), 200);
      // 5 minutes before the end of a 60-minute window: 55/60 of the way.
      expect(scale.xFor(scale.points[2], 200), closeTo(200 * 55 / 60, 0.001));
    });

    test('readings from before the window are left out', () {
      final readings = [
        ...readingsEndingAt(newest, [100, 110, 120]),
        GlucoseReading(sgv: 90, date: newest.subtract(const Duration(hours: 2))),
      ];
      final scale = GlucoseChartScale(readings, window: const Duration(hours: 1));

      expect(scale.points.map((reading) => reading.sgv).toList(), [100, 110, 120]);
    });

    test('a gap in the history stays a gap on the axis', () {
      // Two readings three hours apart in a six-hour window: the older one
      // belongs at the halfway mark, however few readings there are.
      final scale = GlucoseChartScale(
        [
          GlucoseReading(sgv: 120, date: newest),
          GlucoseReading(sgv: 100, date: newest.subtract(const Duration(hours: 3))),
        ],
        window: const Duration(hours: 6),
      );

      expect(scale.xFor(scale.points.first, 200), 100);
      expect(scale.xFor(scale.points.last, 200), 200);
    });
  });

  group('axis scale', () {
    test('value gridlines are round numbers in the display units', () {
      expect(glucoseAxisGridlines('mg/dL'), [100, 200, 300]);
      // 4, 8, 12 and 16 mmol/L, carried as mg/dL like every other value.
      expect(glucoseAxisGridlines('mmol/L'), [72, 144, 216, 288]);
    });

    test('axis labels read whole in either unit', () {
      expect(glucoseAxisLabel(200, 'mg/dL'), '200');
      expect(glucoseAxisLabel(144, 'mmol/L'), '8');
    });

    test('time labels thin out as the window grows', () {
      expect(chartTimeTickInterval(const Duration(hours: 3)), const Duration(hours: 1));
      expect(chartTimeTickInterval(const Duration(hours: 6)), const Duration(hours: 2));
      expect(chartTimeTickInterval(const Duration(hours: 12)), const Duration(hours: 3));
      expect(chartTimeTickInterval(const Duration(hours: 24)), const Duration(hours: 6));
      expect(chartTimeTickInterval(const Duration(hours: 48)), const Duration(hours: 12));
    });
  });

  group('glucose readout', () {
    test('whole numbers for mg/dL', () {
      final reading = GlucoseReading(sgv: 120, date: newest);
      expect(glucoseReadoutValue(reading, units: 'mg/dL'), '120');
    });

    test('one decimal for mmol/L, matching the rest of the app', () {
      final reading = GlucoseReading(sgv: 120, date: newest);
      expect(glucoseReadoutValue(reading, units: 'mmol/L'), '6.7');
    });
  });

  group('dot colours', () {
    // A Paint reports a plain Color, never the MaterialColor it was set from,
    // and the two are not equal to each other.
    Color painted(Color color) => Color(color.toARGB32());

    Future<void> pumpChart(WidgetTester tester, List<GlucoseReading> readings, GlucoseRanges ranges) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                child: GlucoseChart(readings: readings, ranges: ranges),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('each dot is drawn for the level of its own reading', (tester) async {
      await pumpChart(
        tester,
        readingsEndingAt(newest, [60, 120, 250]),
        const GlucoseRanges(low: 70, high: 180, target: 100),
      );

      // Oldest first, which is the order they are plotted in: low, in range,
      // high — one colour each, not one colour for the lot.
      expect(
        find.byType(GlucoseChart),
        paints
          ..circle(color: painted(glucoseLowColor))
          ..circle(color: painted(glucoseInRangeColor))
          ..circle(color: painted(glucoseHighColor)),
      );
    });

    testWidgets('the host ranges decide, not the app defaults', (tester) async {
      // 150 is in range by the app's own 70–180, and high on a host that
      // displays 80–140. The host is the one that gets to say.
      await pumpChart(
        tester,
        readingsEndingAt(newest, [150]),
        const GlucoseRanges(low: 80, high: 140, target: 100),
      );

      expect(find.byType(GlucoseChart), paints..circle(color: painted(glucoseHighColor)));
    });

    testWidgets('the dynamic scheme shades a reading rather than binning it', (tester) async {
      const ranges = GlucoseRanges(low: 70, high: 180, target: 100, isDynamic: true);
      await pumpChart(tester, readingsEndingAt(newest, [100, 160]), ranges);

      // Both readings are in range, and the static scheme would paint them the
      // same green; the host's dynamic one puts the higher of the two further
      // along its sweep, and the chart follows it there.
      final onTarget = painted(glucoseColorFor(100, ranges));
      final drifting = painted(glucoseColorFor(160, ranges));
      expect(onTarget, isNot(drifting));

      expect(
        find.byType(GlucoseChart),
        paints
          ..circle(color: onTarget)
          ..circle(color: drifting),
      );
    });
  });

  group('scrubbing', () {
    Future<void> pumpChart(WidgetTester tester, List<GlucoseReading> readings) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(width: 300, child: GlucoseChart(readings: readings)),
            ),
          ),
        ),
      );
    }

    testWidgets('holding the chart reads off the reading under the finger', (tester) async {
      final handle = tester.ensureSemantics();
      final readings = readingsEndingAt(newest, [90, 100, 110, 120]);
      await pumpChart(tester, readings);

      String readout() => tester.getSemantics(find.bySemanticsLabel('Glucose chart')).value;

      // Nothing held: the newest reading, which is what the rest of the card
      // is showing.
      expect(readout(), startsWith('120'));

      final chart = tester.getRect(find.byType(GlucoseChart));
      final gesture = await tester.startGesture(chart.centerLeft + const Offset(1, 0));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      expect(readout(), startsWith('90'));

      // Dragging without lifting walks along the readings. Two thirds of the
      // way along is the third of four, exactly.
      await gesture.moveTo(chart.centerLeft + Offset(chart.width * 2 / 3, 0));
      await tester.pump();
      expect(readout(), startsWith('110'));

      // Letting go puts the newest reading back.
      await gesture.up();
      await tester.pump();
      expect(readout(), startsWith('120'));

      handle.dispose();
    });

    testWidgets('a sideways drag scrubs without needing the hold first', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpChart(tester, readingsEndingAt(newest, [90, 100, 110, 120]));

      String readout() => tester.getSemantics(find.bySemanticsLabel('Glucose chart')).value;

      final chart = tester.getRect(find.byType(GlucoseChart));
      final gesture = await tester.startGesture(chart.center);
      await tester.pump();
      await gesture.moveTo(chart.centerRight - const Offset(1, 0));
      await tester.pump();
      expect(readout(), startsWith('120'));

      await gesture.up();
      await tester.pump();

      handle.dispose();
    });

    testWidgets('the readout follows the host units', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                child: GlucoseChart(
                  readings: readingsEndingAt(newest, [90, 120]),
                  units: 'mmol/L',
                ),
              ),
            ),
          ),
        ),
      );

      expect(
        tester.getSemantics(find.bySemanticsLabel('Glucose chart')).value,
        startsWith('6.7 mmol/L'),
      );

      handle.dispose();
    });
  });
}
