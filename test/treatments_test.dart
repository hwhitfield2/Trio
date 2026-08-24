import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trio_follower/models/glucose_ranges.dart';
import 'package:trio_follower/models/status_snapshot.dart';
import 'package:trio_follower/widgets/glucose_chart.dart';

/// Newest first, the way the host sends them.
List<GlucoseReading> readingsEndingAt(DateTime newest, int count) => [
      for (var index = 0; index < count; index++)
        GlucoseReading(
          sgv: 120,
          date: newest.subtract(Duration(minutes: 5 * index)),
          direction: 'Flat',
        ),
    ];

void main() {
  final newest = DateTime(2026, 3, 1, 12);
  final seconds = newest.millisecondsSinceEpoch / 1000.0;

  group('what the host sends', () {
    StatusSnapshot? parse(Map<String, dynamic> extra) => StatusSnapshot.fromJson({
          'type': 'status',
          'timestamp': seconds,
          'units': 'mg/dL',
          'readings': [
            {'sgv': 120, 'date': seconds, 'direction': 'Flat'},
          ],
          ...extra,
        });

    test('boluses carry their amount, their time and who gave them', () {
      final snapshot = parse({
        'boluses': [
          {'a': 1.25, 't': seconds - 300, 's': true},
          {'a': 3.0, 't': seconds - 900},
        ],
      });

      expect(snapshot!.boluses, hasLength(2));
      expect(snapshot.boluses.first.units, 1.25);
      expect(snapshot.boluses.first.isAutomatic, isTrue);
      // A bolus somebody asked for says nothing about being automatic, rather
      // than saying it is not — the host leaves the key out to save the bytes.
      expect(snapshot.boluses[1].isAutomatic, isFalse);
      expect(snapshot.boluses[1].label, '3 U');
    });

    test('carb entries carry grams and time', () {
      final snapshot = parse({
        'carbs': [
          {'g': 30, 't': seconds - 600},
        ],
      });

      expect(snapshot!.carbs.single.grams, 30);
      expect(snapshot.carbs.single.label, '30 g');
      expect(snapshot.carbs.single.date, DateTime.fromMillisecondsSinceEpoch(
        ((seconds - 600) * 1000).round(),
      ));
    });

    test('a host that sends none leaves the chart as it was', () {
      final snapshot = parse({});
      expect(snapshot!.boluses, isEmpty);
      expect(snapshot.carbs, isEmpty);
      expect(snapshot.treatments, isEmpty);
    });

    test('entries missing an amount or a time are not drawn as treatments', () {
      final snapshot = parse({
        'boluses': [
          {'t': seconds},
          {'a': 0, 't': seconds},
          {'a': 1.0},
          {'a': 'lots', 't': seconds},
          {'a': 1.0, 't': seconds},
        ],
        'carbs': [
          {'g': -5, 't': seconds},
        ],
      });

      expect(snapshot!.boluses, hasLength(1));
      expect(snapshot.carbs, isEmpty);
    });

    test('both kinds come back as one list, oldest first', () {
      final snapshot = parse({
        'boluses': [
          {'a': 1.0, 't': seconds - 60},
        ],
        'carbs': [
          {'g': 20, 't': seconds - 600},
        ],
      });

      final treatments = snapshot!.treatments;
      expect(treatments.first, isA<CarbEvent>());
      expect(treatments.last, isA<BolusEvent>());
    });
  });

  group('insulin formatting', () {
    test('whole units lose the decimals nobody delivered', () {
      expect(formatInsulin(3), '3');
      expect(formatInsulin(1.25), '1.25');
      expect(formatInsulin(1.2), '1.2');
      expect(formatInsulin(0.05), '0.05');
    });
  });

  group('anchoring a treatment to a reading', () {
    test('it belongs to the reading it happened nearest', () {
      final scale = GlucoseChartScale(readingsEndingAt(newest, 4));
      // Readings at 11:45, 11:50, 11:55 and 12:00, oldest first.
      expect(scale.anchorFor(newest.subtract(const Duration(minutes: 14))), 0);
      expect(scale.anchorFor(newest.subtract(const Duration(minutes: 9))), 1);
      expect(scale.anchorFor(newest), 3);
    });

    test('one from outside the window has nothing to sit on', () {
      final scale = GlucoseChartScale(readingsEndingAt(newest, 4));
      expect(scale.anchorFor(newest.add(const Duration(hours: 1))), isNull);
      expect(scale.anchorFor(newest.subtract(const Duration(hours: 3))), isNull);
    });

    test('one logged just outside still belongs to the reading beside it', () {
      // Half a reading's gap of slack: a bolus a minute before the oldest
      // reading is part of this chart, not of the one before it.
      final scale = GlucoseChartScale(readingsEndingAt(newest, 4));
      expect(scale.anchorFor(newest.subtract(const Duration(minutes: 16))), 0);
    });

    test('nothing to anchor to when there are no readings', () {
      expect(GlucoseChartScale(const []).anchorFor(newest), isNull);
    });
  });

  // Trio's insulin blue and its carb orange, the colours the host's own chart
  // uses. A follower comparing the two screens should not have to learn a
  // second scheme.
  const insulinBlue = Color(0xFF1E96FC);
  const carbOrange = Color(0xFFFF9800);

  /// Matches one treatment bar of [color], optionally handing back its
  /// rectangle.
  ///
  /// `something` rather than `rect`, because the chart fills its in-range band
  /// with a rectangle first and `rect` has to match the very next draw of its
  /// kind. Colours are compared as packed ARGB rather than with `==`: a Paint
  /// keeps its colour as 32-bit floats, so the Color read back out of one is
  /// a few ulps from the Color that went in.
  bool Function(Symbol, List<dynamic>) bar(Color color, {void Function(Rect)? onMatch}) {
    return (Symbol method, List<dynamic> arguments) {
      if (method != #drawRect) return false;
      if ((arguments[1] as Paint).color.toARGB32() != color.toARGB32()) return false;
      onMatch?.call(arguments[0] as Rect);
      return true;
    };
  }

  group('drawing them', () {
    Future<void> pumpChart(WidgetTester tester, List<TreatmentEvent> treatments) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 300,
                  child: GlucoseChart(
                    readings: readingsEndingAt(newest, 4),
                    ranges: GlucoseRanges.defaults,
                    treatments: treatments,
                  ),
                ),
              ),
            ),
          ),
        );

    testWidgets('a bolus and a carb entry each get a marker of their own', (tester) async {
      await pumpChart(tester, [
        BolusEvent(date: newest, units: 2),
        CarbEvent(date: newest.subtract(const Duration(minutes: 5)), grams: 30),
      ]);

      // Trio's insulin blue and its carb orange, so the two screens read the
      // same way. Flat bars rather than triangles: at the dot sizes the longer
      // spans use, a triangle is a smudge, and a bar's length still reads as
      // an amount.
      expect(
        find.byType(GlucoseChart),
        paints
          ..something(bar(insulinBlue))
          ..something(bar(carbOrange)),
      );
    });

    testWidgets('insulin is drawn above its reading and carbs below', (tester) async {
      await pumpChart(tester, [
        BolusEvent(date: newest, units: 2),
        CarbEvent(date: newest, grams: 30),
      ]);

      // Both sit against the same reading, and which side of it they are on is
      // the only thing saying which is which — the same arrangement the host's
      // own chart uses.
      Rect? insulin;
      Rect? carbs;
      expect(
        find.byType(GlucoseChart),
        paints
          ..something(bar(insulinBlue, onMatch: (rect) => insulin = rect))
          ..something(bar(carbOrange, onMatch: (rect) => carbs = rect)),
      );

      expect(insulin!.bottom, lessThan(carbs!.top));
    });

    testWidgets('a treatment from outside the window is not drawn', (tester) async {
      await pumpChart(tester, [
        BolusEvent(date: newest.add(const Duration(hours: 2)), units: 2),
      ]);

      // The chart still fills its in-range band, so this has to name the
      // treatment colours rather than simply asking for no rectangles.
      expect(find.byType(GlucoseChart), isNot(paints..something(bar(insulinBlue))));
      expect(find.byType(GlucoseChart), isNot(paints..something(bar(carbOrange))));
    });

    testWidgets('the readout names what was given at the reading', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpChart(tester, [
        BolusEvent(date: newest, units: 1.25, isAutomatic: true),
        CarbEvent(date: newest, grams: 30),
      ]);

      // Nothing held: the newest reading, which is where both of these are.
      final readout = tester.getSemantics(find.bySemanticsLabel('Glucose chart')).value;
      expect(readout, contains('1.25 units automatic bolus'));
      expect(readout, contains('30 grams of carbs'));

      handle.dispose();
    });
  });
}
