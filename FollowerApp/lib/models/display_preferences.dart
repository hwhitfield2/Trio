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
    this.items = LiveActivityItem.defaultItems,
  });

  /// Lock Screen layout.
  final WidgetStyle lockScreenStyle;

  /// Apple Watch Smart Stack and CarPlay layout. Separate from the Lock Screen
  /// on purpose: the watch face is much smaller, so the choice rarely matches.
  final WidgetStyle watchStyle;

  final GlucoseColorScheme glucoseColorScheme;

  /// What the detailed layouts show beneath the chart, in order. Always four
  /// slots — `LiveActivityItem.empty` leaves one blank.
  final List<LiveActivityItem> items;

  static const itemSlots = 4;

  DisplayPreferences copyWith({
    WidgetStyle? lockScreenStyle,
    WidgetStyle? watchStyle,
    GlucoseColorScheme? glucoseColorScheme,
    List<LiveActivityItem>? items,
  }) =>
      DisplayPreferences(
        lockScreenStyle: lockScreenStyle ?? this.lockScreenStyle,
        watchStyle: watchStyle ?? this.watchStyle,
        glucoseColorScheme: glucoseColorScheme ?? this.glucoseColorScheme,
        items: items ?? this.items,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'lock_screen': lockScreenStyle.id,
        'watch': watchStyle.id,
        'glucose_color': glucoseColorScheme.id,
        'items': [for (final item in items) item.id],
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
      items: items.isEmpty ? LiveActivityItem.defaultItems : items,
    );
  }
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
