import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trio_follower/models/glucose_ranges.dart';
import 'package:trio_follower/models/status_snapshot.dart';
import 'package:trio_follower/widgets/glucose_colors.dart';

/// The hue the dynamic scheme landed on, which is what the host's own hue
/// sweep is defined in — comparing hues says what a colour comparison cannot:
/// which way along the rainbow a reading moved.
double hueOf(Color color) => HSVColor.fromColor(color).hue;

void main() {
  group('static colour scheme', () {
    const ranges = GlucoseRanges(low: 70, high: 180, target: 100);

    test('a reading below the host low is low, and one at it still is', () {
      expect(glucoseColorFor(54, ranges), glucoseLowColor);
      expect(glucoseColorFor(69, ranges), glucoseLowColor);
      // The host colours its own chart with >= and <=, so the boundary reading
      // is out of range on both screens or on neither.
      expect(glucoseColorFor(70, ranges), glucoseLowColor);
    });

    test('a reading between the host bounds is in range', () {
      expect(glucoseColorFor(71, ranges), glucoseInRangeColor);
      expect(glucoseColorFor(120, ranges), glucoseInRangeColor);
      expect(glucoseColorFor(179, ranges), glucoseInRangeColor);
    });

    test('a reading at or above the host high is high', () {
      expect(glucoseColorFor(180, ranges), glucoseHighColor);
      expect(glucoseColorFor(260, ranges), glucoseHighColor);
    });

    test('the host bounds decide, not the app defaults', () {
      // A host that displays 80–140 calls 150 high, even though the app's own
      // default range would have called it in range.
      const tight = GlucoseRanges(low: 80, high: 140, target: 100);
      expect(glucoseColorFor(150, tight), glucoseHighColor);
      expect(glucoseColorFor(75, tight), glucoseLowColor);
      expect(glucoseColorFor(100, tight), glucoseInRangeColor);
    });
  });

  group('dynamic colour scheme', () {
    const ranges = GlucoseRanges(low: 70, high: 180, target: 100, isDynamic: true);

    test('red at the bottom of the sweep, violet at the top', () {
      expect(hueOf(glucoseColorFor(40, ranges)), 0);
      expect(hueOf(glucoseColorFor(55, ranges)), 0);
      expect(hueOf(glucoseColorFor(220, ranges)), 270);
      expect(hueOf(glucoseColorFor(400, ranges)), 270);
    });

    test('green at the host target, whatever the target is', () {
      expect(hueOf(glucoseColorFor(100, ranges)), closeTo(120, 0.001));
      const higherTarget = GlucoseRanges(low: 70, high: 180, target: 120, isDynamic: true);
      expect(hueOf(glucoseColorFor(120, higherTarget)), closeTo(120, 0.001));
      // ...and the reading that was on target before is now short of it.
      expect(hueOf(glucoseColorFor(100, higherTarget)), lessThan(120));
    });

    test('the hue climbs with the reading, so no two levels read alike', () {
      final hues = [60, 80, 100, 140, 180, 210]
          .map((sgv) => hueOf(glucoseColorFor(sgv.toDouble(), ranges)))
          .toList();
      for (var index = 1; index < hues.length; index++) {
        expect(hues[index], greaterThan(hues[index - 1]));
      }
    });

    test('a target outside the sweep does not invert the colours', () {
      // Nothing sane sends this; if something does, the sweep still has to run
      // red to violet rather than backwards.
      const broken = GlucoseRanges(low: 70, high: 400, target: 350, isDynamic: true);
      expect(hueOf(glucoseColorFor(100, broken)), lessThan(120));
      expect(hueOf(glucoseColorFor(219, broken)), lessThanOrEqualTo(270));
      expect(hueOf(glucoseColorFor(50, broken)), 0);
    });
  });

  group('ranges from the host', () {
    test('reads the ranges object the host sends', () {
      final ranges = GlucoseRanges.fromJson(
        {'low': 80.0, 'high': 160.0, 'target': 110.0, 'scheme': 'dynamicColor'},
      );

      expect(ranges, isNotNull);
      expect(ranges!.low, 80);
      expect(ranges.high, 160);
      expect(ranges.target, 110);
      expect(ranges.isDynamic, isTrue);
    });

    test('anything but the dynamic scheme is the static one', () {
      expect(
        GlucoseRanges.fromJson({'low': 70, 'high': 180, 'scheme': 'staticColor'})!.isDynamic,
        isFalse,
      );
      // A scheme this build has never heard of is not a reason to guess.
      expect(
        GlucoseRanges.fromJson({'low': 70, 'high': 180, 'scheme': 'somethingNew'})!.isDynamic,
        isFalse,
      );
    });

    test('bounds that cannot be true are not coloured by', () {
      expect(GlucoseRanges.fromJson(null), isNull);
      expect(GlucoseRanges.fromJson({'high': 180}), isNull);
      expect(GlucoseRanges.fromJson({'low': 180, 'high': 70}), isNull);
      expect(GlucoseRanges.fromJson({'low': 0, 'high': 180}), isNull);
      expect(GlucoseRanges.fromJson({'low': double.nan, 'high': 180}), isNull);
    });

    test('a target outside its own range falls back to the middle of it', () {
      expect(GlucoseRanges.fromJson({'low': 70, 'high': 180})!.target, 125);
      expect(GlucoseRanges.fromJson({'low': 70, 'high': 180, 'target': 300})!.target, 125);
    });
  });

  group('what a snapshot is coloured by', () {
    StatusSnapshot? parse(Map<String, dynamic> extra) {
      final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
      return StatusSnapshot.fromJson({
        'type': 'status',
        'timestamp': now,
        'units': 'mg/dL',
        'readings': [
          {'sgv': 104, 'date': now - 60, 'direction': 'Flat'},
        ],
        ...extra,
      });
    }

    test('the host ranges, when the host sends them', () {
      final snapshot = parse({
        'low': 75,
        'high': 200,
        'ranges': {'low': 80, 'high': 160, 'target': 110, 'scheme': 'staticColor'},
      });

      // The alert thresholds are a different question with different numbers,
      // and the chart is not the place they get answered.
      expect(snapshot!.glucoseRanges.low, 80);
      expect(snapshot.glucoseRanges.high, 160);
      expect(snapshot.glucoseRanges.target, 110);
    });

    test('an older host without ranges still colours by what it does send', () {
      final snapshot = parse({'low': 75, 'high': 200});
      expect(snapshot!.glucoseRanges.low, 75);
      expect(snapshot.glucoseRanges.high, 200);
      expect(snapshot.glucoseRanges.isDynamic, isFalse);
    });

    test('a host that sends nothing usable falls back to the app defaults', () {
      expect(parse({})!.glucoseRanges, GlucoseRanges.defaults);
      expect(parse({'low': 200, 'high': 70})!.glucoseRanges, GlucoseRanges.defaults);
    });
  });
}
