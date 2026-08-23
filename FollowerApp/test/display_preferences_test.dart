import 'package:flutter_test/flutter_test.dart';
import 'package:trio_follower/models/display_preferences.dart';

void main() {
  group('DisplayPreferences', () {
    test('defaults match the ones Trio starts with', () {
      const preferences = DisplayPreferences();
      expect(preferences.lockScreenStyle, WidgetStyle.simple);
      expect(preferences.watchStyle, WidgetStyle.simple);
      expect(preferences.glucoseColorScheme, GlucoseColorScheme.dynamicColor);
      expect(preferences.items, [
        LiveActivityItem.currentGlucoseLarge,
        LiveActivityItem.iob,
        LiveActivityItem.cob,
        LiveActivityItem.updatedLabel,
      ]);
    });

    test('round-trips through the wire format the widget extension reads', () {
      const preferences = DisplayPreferences(
        lockScreenStyle: WidgetStyle.detailed,
        watchStyle: WidgetStyle.detailed,
        glucoseColorScheme: GlucoseColorScheme.staticColor,
        items: [
          LiveActivityItem.currentGlucose,
          LiveActivityItem.eventualGlucose,
          LiveActivityItem.empty,
          LiveActivityItem.updatedLabel,
        ],
      );

      final json = preferences.toJson();
      // Keys and values are read by FollowerDisplayPreferences.swift; a rename
      // on either side silently reverts every choice to its default.
      expect(json['lock_screen'], 'detailed');
      expect(json['watch'], 'detailed');
      expect(json['glucose_color'], 'static');
      expect(json['items'], ['currentGlucose', 'eventualGlucose', 'empty', 'updatedLabel']);

      final restored = DisplayPreferences.fromJson(json);
      expect(restored.lockScreenStyle, WidgetStyle.detailed);
      expect(restored.watchStyle, WidgetStyle.detailed);
      expect(restored.glucoseColorScheme, GlucoseColorScheme.staticColor);
      expect(restored.items, preferences.items);
    });

    test('unknown or missing values fall back rather than throwing', () {
      // Written by a newer build, read by an older one.
      final restored = DisplayPreferences.fromJson({
        'lock_screen': 'holographic',
        'items': ['iob', 'somethingNew'],
      });

      expect(restored.lockScreenStyle, WidgetStyle.simple);
      expect(restored.watchStyle, WidgetStyle.simple);
      expect(restored.glucoseColorScheme, GlucoseColorScheme.dynamicColor);
      // The unknown slot becomes a blank, so the items around it keep the
      // position the user put them in.
      expect(restored.items, [LiveActivityItem.iob, LiveActivityItem.empty]);
    });

    test('an empty item list falls back to the defaults', () {
      final restored = DisplayPreferences.fromJson({'items': <String>[]});
      expect(restored.items, LiveActivityItem.defaultItems);
    });

    test('the chart span round-trips, and defaults to six hours', () {
      expect(const DisplayPreferences().chartHours, 6);

      const preferences = DisplayPreferences(chartHours: 24);
      final restored = DisplayPreferences.fromJson(preferences.toJson());
      expect(restored.chartHours, 24);
    });

    test('a chart span the picker never offered falls back to the default', () {
      expect(DisplayPreferences.fromJson({'chart_hours': 7}).chartHours, 6);
      expect(DisplayPreferences.fromJson({'chart_hours': 'lots'}).chartHours, 6);
      expect(DisplayPreferences.fromJson({}).chartHours, 6);
    });

    test('copyWith changes one choice and leaves the rest', () {
      const preferences = DisplayPreferences(lockScreenStyle: WidgetStyle.detailed);
      final updated = preferences.copyWith(watchStyle: WidgetStyle.detailed);

      expect(updated.lockScreenStyle, WidgetStyle.detailed);
      expect(updated.watchStyle, WidgetStyle.detailed);
      expect(updated.items, LiveActivityItem.defaultItems);
    });
  });
}
