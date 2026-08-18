import 'glucose_ranges.dart';

/// How the Live Activity and the home screen widgets should be laid out.
///
/// These are the follower's own choices, not the host's — the host has no idea
/// how this device likes to display things, and pushes only data. The widget
/// extension reads them straight from the shared app group, so a pushed update
/// and a locally built one are laid out identically.
///
/// Mirrors Trio's own Live Activity settings, minus its Total Daily Dose item:
/// the host's status snapshot carries no TDD, so there is nothing to show.
/// Keep the wire names in sync with `FollowerDisplayPreferences.swift`.
class DisplayPreferences {
  const DisplayPreferences({
    this.lockScreenStyle = WidgetStyle.simple,
    this.watchStyle = WidgetStyle.simple,
    this.glucoseColorScheme = GlucoseColorScheme.dynamicColor,
    this.glucoseLow,
    this.glucoseHigh,
    this.glucoseScheme = GlucoseSchemeChoice.followHost,
    this.items = LiveActivityItem.defaultItems,
  });

  /// Lock Screen layout.
  final WidgetStyle lockScreenStyle;

  /// Apple Watch Smart Stack and CarPlay layout. Separate from the Lock Screen
  /// on purpose: the watch face is much smaller, so the choice rarely matches.
  final WidgetStyle watchStyle;

  final GlucoseColorScheme glucoseColorScheme;

  /// This device's own display range, in mg/dL. Null follows the host's.
  ///
  /// The host's range is the right default — it is what the person wearing the
  /// CGM decided — but it is not always the right answer for whoever is
  /// watching: a parent at work wants to see trouble sooner than the host
  /// calls it trouble, and nobody should have to reconfigure the host to get
  /// that.
  final double? glucoseLow;
  final double? glucoseHigh;

  /// Which of the two colourings to use, or the host's choice.
  final GlucoseSchemeChoice glucoseScheme;

  /// Lowest and highest a follower may set, in mg/dL. The same window the host
  /// allows its own alert thresholds in.
  static const thresholdFloor = 40.0;
  static const thresholdCeiling = 400.0;

  /// Whether anything here overrides what the host reports.
  bool get followsHostRange =>
      glucoseLow == null && glucoseHigh == null && glucoseScheme == GlucoseSchemeChoice.followHost;

  /// The ranges to colour by: this device's choices where it has made any, and
  /// the host's for everything else.
  GlucoseRanges resolveRanges(GlucoseRanges host) {
    var low = glucoseLow ?? host.low;
    var high = glucoseHigh ?? host.high;
    // Overriding one end only can leave it the wrong side of the other; the
    // host's end gives way, since the overridden one is what was asked for.
    if (low >= high) {
      if (glucoseLow != null && glucoseHigh != null) return host;
      if (glucoseLow != null) {
        high = low + 1;
      } else {
        low = high - 1;
      }
    }

    return GlucoseRanges(
      low: low,
      high: high,
      // The target is the host's either way: it is a therapy setting, not a
      // display one, and only the dynamic sweep reads it.
      target: host.target,
      isDynamic: switch (glucoseScheme) {
        GlucoseSchemeChoice.followHost => host.isDynamic,
        GlucoseSchemeChoice.staticColor => false,
        GlucoseSchemeChoice.dynamicColor => true,
      },
    );
  }

  /// What the detailed layouts show beneath the chart, in order. Always four
  /// slots — `LiveActivityItem.empty` leaves one blank.
  final List<LiveActivityItem> items;

  static const itemSlots = 4;

  /// [glucoseLow] and [glucoseHigh] are passed through as given — including
  /// null, which is a meaningful value here ("follow the host") rather than
  /// "leave it alone". [followHostRange] is how a caller says that for both at
  /// once without naming either.
  DisplayPreferences copyWith({
    WidgetStyle? lockScreenStyle,
    WidgetStyle? watchStyle,
    GlucoseColorScheme? glucoseColorScheme,
    double? glucoseLow,
    double? glucoseHigh,
    bool followHostRange = false,
    GlucoseSchemeChoice? glucoseScheme,
    List<LiveActivityItem>? items,
  }) =>
      DisplayPreferences(
        lockScreenStyle: lockScreenStyle ?? this.lockScreenStyle,
        watchStyle: watchStyle ?? this.watchStyle,
        glucoseColorScheme: glucoseColorScheme ?? this.glucoseColorScheme,
        glucoseLow: followHostRange ? null : (glucoseLow ?? this.glucoseLow),
        glucoseHigh: followHostRange ? null : (glucoseHigh ?? this.glucoseHigh),
        glucoseScheme: glucoseScheme ?? this.glucoseScheme,
        items: items ?? this.items,
      );

  /// This device's own copy, in mg/dL like every other glucose value the app
  /// keeps.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'lock_screen': lockScreenStyle.id,
        'watch': watchStyle.id,
        'glucose_color': glucoseColorScheme.id,
        'glucose_low': glucoseLow,
        'glucose_high': glucoseHigh,
        'glucose_scheme': glucoseScheme.id,
        'items': [for (final item in items) item.id],
      };

  /// The copy the widget extension reads out of the shared app group.
  ///
  /// The thresholds are converted here rather than there: the extension
  /// compares them against readings that are already in the host's display
  /// units, and it has no business knowing which units those are. [convert] is
  /// the caller's own conversion, so a payload cannot end up half converted.
  Map<String, dynamic> toWidgetJson(double Function(double mgdl) convert) => <String, dynamic>{
        ...toJson(),
        'glucose_range': <String, dynamic>{
          'low': glucoseLow == null ? null : convert(glucoseLow!),
          'high': glucoseHigh == null ? null : convert(glucoseHigh!),
          'scheme': glucoseScheme.id,
        },
      };

  static DisplayPreferences fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    final items = <LiveActivityItem>[
      if (rawItems is List)
        for (final entry in rawItems)
          if (entry is String) LiveActivityItem.fromId(entry),
    ];

    return DisplayPreferences(
      lockScreenStyle: WidgetStyle.fromId(json['lock_screen'] as String?),
      watchStyle: WidgetStyle.fromId(json['watch'] as String?),
      glucoseColorScheme: GlucoseColorScheme.fromId(json['glucose_color'] as String?),
      glucoseLow: _threshold(json['glucose_low']),
      glucoseHigh: _threshold(json['glucose_high']),
      glucoseScheme: GlucoseSchemeChoice.fromId(json['glucose_scheme'] as String?),
      items: items.isEmpty ? LiveActivityItem.defaultItems : items,
    );
  }

  /// A stored threshold, or null for anything that is not one this app could
  /// have written — an absent key, or a number outside what it lets anyone set.
  static double? _threshold(Object? value) {
    if (value is! num) return null;
    final threshold = value.toDouble();
    if (!threshold.isFinite) return null;
    if (threshold < thresholdFloor || threshold > thresholdCeiling) return null;
    return threshold;
  }
}

/// Which colouring the follower wants, when it does not simply want the host's.
enum GlucoseSchemeChoice {
  followHost('host', 'Host'),
  staticColor('static', 'Static'),
  dynamicColor('dynamic', 'Dynamic');

  const GlucoseSchemeChoice(this.id, this.label);

  final String id;
  final String label;

  static GlucoseSchemeChoice fromId(String? id) => GlucoseSchemeChoice.values
      .firstWhere((scheme) => scheme.id == id, orElse: () => GlucoseSchemeChoice.followHost);

  String get description => switch (this) {
        GlucoseSchemeChoice.followHost =>
          'Colour the way the host does, whichever scheme it is set to.',
        GlucoseSchemeChoice.staticColor =>
          'Red below the low, green in range, orange at or above the high.',
        GlucoseSchemeChoice.dynamicColor =>
          'Shaded from red through green at the host target to violet, so a '
              'reading drifting inside the range still shows it.',
      };
}

enum WidgetStyle {
  simple('simple', 'Simple'),
  detailed('detailed', 'Detailed');

  const WidgetStyle(this.id, this.label);

  final String id;
  final String label;

  static WidgetStyle fromId(String? id) =>
      WidgetStyle.values.firstWhere((style) => style.id == id, orElse: () => WidgetStyle.simple);

  String get description => switch (this) {
        WidgetStyle.simple => 'Glucose, trend arrow, delta and the time of the reading.',
        WidgetStyle.detailed => 'A glucose chart as well, with the values chosen below beneath it.',
      };
}

enum GlucoseColorScheme {
  dynamicColor('dynamic', 'Colour by range'),
  staticColor('static', 'Single colour');

  const GlucoseColorScheme(this.id, this.label);

  final String id;
  final String label;

  static GlucoseColorScheme fromId(String? id) => GlucoseColorScheme.values
      .firstWhere((scheme) => scheme.id == id, orElse: () => GlucoseColorScheme.dynamicColor);

  String get description => switch (this) {
        GlucoseColorScheme.dynamicColor =>
          'Glucose turns red below the low threshold and orange above the high one.',
        GlucoseColorScheme.staticColor => 'Glucose is always drawn in the default text colour.',
      };
}

/// One slot in a detailed layout.
enum LiveActivityItem {
  currentGlucose('currentGlucose', 'Glucose'),
  currentGlucoseLarge('currentGlucoseLarge', 'Glucose (large)'),
  iob('iob', 'IOB'),
  cob('cob', 'COB'),
  eventualGlucose('eventualGlucose', 'Eventual glucose'),
  updatedLabel('updatedLabel', 'Last updated'),
  empty('empty', 'Empty');

  const LiveActivityItem(this.id, this.label);

  final String id;
  final String label;

  /// The same four Trio starts with.
  static const defaultItems = [
    LiveActivityItem.currentGlucoseLarge,
    LiveActivityItem.iob,
    LiveActivityItem.cob,
    LiveActivityItem.updatedLabel,
  ];

  static LiveActivityItem fromId(String? id) =>
      LiveActivityItem.values.firstWhere((item) => item.id == id, orElse: () => LiveActivityItem.empty);
}
