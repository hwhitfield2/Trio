import 'package:flutter_test/flutter_test.dart';
import 'package:trio_follower/models/display_preferences.dart';
import 'package:trio_follower/models/glucose_ranges.dart';
import 'package:trio_follower/models/status_snapshot.dart';
import 'package:trio_follower/services/live_activity_bridge.dart';
import 'package:trio_follower/services/widget_bridge.dart';

const host = GlucoseRanges(low: 70, high: 180, target: 100);

StatusSnapshot snapshotWith({GlucoseRanges ranges = host, String units = 'mg/dL'}) {
  final now = DateTime.now();
  return StatusSnapshot(
    timestamp: now,
    units: units,
    readings: [GlucoseReading(sgv: 120, date: now, direction: 'Flat')],
    ranges: ranges,
  );
}

void main() {
  group('following the host', () {
    test('a follower that has chosen nothing sees exactly what the host reports', () {
      const preferences = DisplayPreferences();
      expect(preferences.followsHostRange, isTrue);
      expect(preferences.resolveRanges(host), host);
    });

    test('the dynamic host scheme comes through untouched', () {
      const dynamicHost = GlucoseRanges(low: 70, high: 180, target: 100, isDynamic: true);
      expect(const DisplayPreferences().resolveRanges(dynamicHost).isDynamic, isTrue);
    });
  });

  group('the follower disagreeing with the host', () {
    test('either end can be moved on its own, and the other stays the host one', () {
      const lowOnly = DisplayPreferences(glucoseLow: 80);
      expect(lowOnly.resolveRanges(host).low, 80);
      expect(lowOnly.resolveRanges(host).high, 180);

      const highOnly = DisplayPreferences(glucoseHigh: 150);
      expect(highOnly.resolveRanges(host).low, 70);
      expect(highOnly.resolveRanges(host).high, 150);
    });

    test('the host target is left alone: it is a therapy setting, not a display one', () {
      const narrowed = DisplayPreferences(glucoseLow: 80, glucoseHigh: 140);
      expect(narrowed.resolveRanges(host).target, 100);
    });

    test('a scheme can be forced either way, whatever the host is set to', () {
      const forcedDynamic = DisplayPreferences(glucoseScheme: GlucoseSchemeChoice.dynamicColor);
      expect(forcedDynamic.resolveRanges(host).isDynamic, isTrue);

      const dynamicHost = GlucoseRanges(low: 70, high: 180, target: 100, isDynamic: true);
      const forcedStatic = DisplayPreferences(glucoseScheme: GlucoseSchemeChoice.staticColor);
      expect(forcedStatic.resolveRanges(dynamicHost).isDynamic, isFalse);
    });

    test('an override that would cross the host end pushes that end out of the way', () {
      // The host's high is 180 and the follower asks for a low of 200: what it
      // asked for is what it gets, and the host's end gives way.
      const highLow = DisplayPreferences(glucoseLow: 200);
      expect(highLow.resolveRanges(host).low, 200);
      expect(highLow.resolveRanges(host).high, greaterThan(200));

      const lowHigh = DisplayPreferences(glucoseHigh: 50);
      expect(lowHigh.resolveRanges(host).high, 50);
      expect(lowHigh.resolveRanges(host).low, lessThan(50));
    });

    test('a pair that crosses itself is not a range, so the host keeps the chart', () {
      const inverted = DisplayPreferences(glucoseLow: 190, glucoseHigh: 100);
      expect(inverted.resolveRanges(host), host);
    });

    test('stored thresholds outside what the app can set are not trusted', () {
      final restored = DisplayPreferences.fromJson({
        'glucose_low': 4.0,
        'glucose_high': 900.0,
      });
      expect(restored.glucoseLow, isNull);
      expect(restored.glucoseHigh, isNull);
    });

    test('the choices survive a round trip through storage', () {
      const preferences = DisplayPreferences(
        glucoseLow: 80,
        glucoseHigh: 150,
        glucoseScheme: GlucoseSchemeChoice.dynamicColor,
      );
      final restored = DisplayPreferences.fromJson(preferences.toJson());

      expect(restored.glucoseLow, 80);
      expect(restored.glucoseHigh, 150);
      expect(restored.glucoseScheme, GlucoseSchemeChoice.dynamicColor);
      expect(restored.followsHostRange, isFalse);
    });

    test('going back to the host clears both ends at once', () {
      const preferences = DisplayPreferences(glucoseLow: 80, glucoseHigh: 150);
      expect(preferences.copyWith(followHostRange: true).followsHostRange, isTrue);
    });
  });

  group('what the other surfaces are told', () {
    test('the widgets are drawn with the follower range, not the host one', () {
      const preferences = DisplayPreferences(glucoseLow: 80, glucoseHigh: 150);
      final payload = WidgetBridge.payloadFor(snapshotWith(), preferences: preferences);

      expect(payload['low'], 80);
      expect(payload['high'], 150);
      // ...and so is the bar underneath: 120 is in range on both, but the
      // stats have to be counted against what the dots are coloured by.
      expect((payload['color'] as Map)['scheme'], 'staticColor');
      expect(payload['stats'], isNotNull);
    });

    test('the Lock Screen is told the same, in display units', () {
      const preferences = DisplayPreferences(
        glucoseLow: 72,
        glucoseHigh: 180,
        glucoseScheme: GlucoseSchemeChoice.dynamicColor,
      );
      final state = LiveActivityBridge.stateFor(
        snapshotWith(units: 'mmol/L'),
        preferences: preferences,
      );

      expect(state['low'], closeTo(4.0, 0.001));
      expect(state['high'], closeTo(10.0, 0.001));
      expect((state['color'] as Map)['scheme'], 'dynamicColor');
    });

    test('the extension is handed the override in display units too', () {
      const preferences = DisplayPreferences(glucoseLow: 72, glucoseHigh: 180);
      final json = preferences.toWidgetJson((mgdl) => mgdl / 18.0);
      final range = json['glucose_range'] as Map;

      expect(range['low'], closeTo(4.0, 0.001));
      expect(range['high'], closeTo(10.0, 0.001));
      expect(range['scheme'], 'host');
    });

    test('following the host sends no numbers for the extension to apply', () {
      final range = const DisplayPreferences().toWidgetJson((mgdl) => mgdl)['glucose_range'] as Map;
      expect(range['low'], isNull);
      expect(range['high'], isNull);
    });
  });
}
