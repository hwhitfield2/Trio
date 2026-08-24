import 'package:flutter/material.dart';

/// The follower's visual language: an instrument panel, not a stack of cards.
///
/// Full-bleed panels separated by hairlines and an 8-point gutter of ground,
/// every number set in IBM Plex Mono with tabular figures so columns line up
/// and a glance lands in the same place every time. Nothing is rounded and
/// nothing floats — elevation is spent on the one thing that matters, which is
/// telling panels apart from the ground behind them.
///
/// Trio's own glucose, insulin and carb colours are carried through unchanged
/// in both themes: a reading has to be the same colour here as on the host's
/// chart, and a follower comparing two screens should never have to translate.
class TrioColors {
  const TrioColors({
    required this.ground,
    required this.panel,
    required this.hairline,
    required this.hairlineSoft,
    required this.rule,
    required this.ink,
    required this.inkMuted,
    required this.inkFaint,
    required this.accent,
    required this.onAccent,
    required this.accentWash,
    required this.danger,
    required this.dangerDeep,
    required this.onDangerDeep,
    required this.dangerWash,
    required this.dangerWashLine,
  });

  /// What the panels sit on, and what shows through the gaps between them.
  final Color ground;

  /// A panel's own fill. Everything the app draws lives on one of these.
  final Color panel;

  /// The line between a panel and what follows it, and under a section header.
  final Color hairline;

  /// The lighter line between rows *inside* one panel — a list of treatments
  /// is one object, and ruling it as hard as a panel edge would break it up.
  final Color hairlineSoft;

  /// The heavier line: control borders, and the chart's range bounds.
  final Color rule;

  final Color ink;
  final Color inkMuted;
  final Color inkFaint;

  /// Trio's seed violet. The only colour in the app that means "you can act on
  /// this"; everything else is either data or structure.
  final Color accent;
  final Color onAccent;

  /// The tint behind a chosen preset row.
  final Color accentWash;

  /// Outlined danger — the suspend control before it has been used.
  final Color danger;

  /// Filled danger: the suspension banner and the guard sheet's header. Deeper
  /// than [danger] because it carries white text across a large area.
  final Color dangerDeep;
  final Color onDangerDeep;

  /// The quiet danger tint, for "this is already running and you are about to
  /// replace it".
  final Color dangerWash;
  final Color dangerWashLine;

  /// Trio's own data colours, identical in both themes.
  static const low = Color(0xFFF44336);
  static const inRange = Color(0xFF4CAF50);
  static const high = Color(0xFFFF9800);
  static const insulin = Color(0xFF1E96FC);
  static const carbs = Color(0xFFFF9800);

  static const light = TrioColors(
    ground: Color(0xFFEEEDF0),
    panel: Color(0xFFFFFFFF),
    hairline: Color(0xFFDAD8DE),
    hairlineSoft: Color(0xFFEEEDF0),
    rule: Color(0xFFC3C0CA),
    ink: Color(0xFF16151A),
    inkMuted: Color(0xFF56535E),
    inkFaint: Color(0xFF86828E),
    accent: Color(0xFF5B2A86),
    onAccent: Color(0xFFFFFFFF),
    accentWash: Color(0xFFF6F2FA),
    danger: Color(0xFFB3261E),
    dangerDeep: Color(0xFF8C1D18),
    onDangerDeep: Color(0xFFFFFFFF),
    dangerWash: Color(0xFFFFF3F2),
    dangerWashLine: Color(0xFFF0D9D6),
  );

  /// The same system after dark, built by swapping ground for ink rather than
  /// by dimming: the panels stay the lit surfaces and the gutters stay the
  /// dark ones, so the layout reads the same way at 3 AM as at noon.
  ///
  /// The accent is the violet the design itself uses on its dark canvas — the
  /// seed is too dark to carry white text against a dark panel.
  static const dark = TrioColors(
    ground: Color(0xFF0E0D11),
    panel: Color(0xFF1B1A20),
    hairline: Color(0xFF2C2A33),
    hairlineSoft: Color(0xFF232128),
    rule: Color(0xFF3A3843),
    ink: Color(0xFFF5F4F7),
    inkMuted: Color(0xFFA9A5B2),
    inkFaint: Color(0xFF8B8794),
    accent: Color(0xFFA97FD0),
    onAccent: Color(0xFF16151A),
    accentWash: Color(0xFF251A31),
    danger: Color(0xFFF2B8B5),
    dangerDeep: Color(0xFF8C1D18),
    onDangerDeep: Color(0xFFFFFFFF),
    dangerWash: Color(0xFF2B1513),
    dangerWashLine: Color(0xFF4A211D),
  );
}

/// Carries [TrioColors] down the tree, so a widget can ask for the palette
/// without every caller threading it through.
class TrioTheme extends InheritedWidget {
  const TrioTheme({super.key, required this.colors, required super.child});

  final TrioColors colors;

  static TrioColors of(BuildContext context) {
    final theme = context.dependOnInheritedWidgetOfExactType<TrioTheme>();
    if (theme != null) return theme.colors;
    // A widget pumped on its own in a test has no TrioTheme above it; follow
    // the ambient brightness rather than throwing.
    return Theme.of(context).brightness == Brightness.dark
        ? TrioColors.dark
        : TrioColors.light;
  }

  @override
  bool updateShouldNotify(TrioTheme oldWidget) => oldWidget.colors != colors;
}

/// The two typefaces, and the rules for setting them.
///
/// Prose is IBM Plex Sans. Everything that is a *quantity* — glucose, insulin,
/// carbs, times, durations, codes — is IBM Plex Mono with tabular figures, so
/// a number changing never moves the ones beside it.
class TrioType {
  const TrioType._();

  static const sans = 'IBMPlexSans';
  static const mono = 'IBMPlexMono';

  /// Tabular figures. The reason the numbers are mono in the first place: a
  /// glucose reading that reflows the row every five minutes is unreadable at
  /// a glance, which is the only way this screen is ever read.
  static const _tabular = <FontFeature>[FontFeature.tabularFigures()];

  /// A number. [tracking] is in ems, the way the design states it, and is
  /// resolved against [size] here so a style change cannot desynchronise them.
  static TextStyle numeral({
    required double size,
    required Color color,
    FontWeight weight = FontWeight.w500,
    double tracking = 0,
    double? height,
  }) =>
      TextStyle(
        fontFamily: mono,
        fontSize: size,
        fontWeight: weight,
        color: color,
        letterSpacing: tracking * size,
        height: height,
        fontFeatures: _tabular,
      );

  /// The wide, uppercase mono micro-label: section headers, stat captions,
  /// button text, status strips. The app's connective tissue.
  static TextStyle micro({
    required Color color,
    double size = 9.5,
    FontWeight weight = FontWeight.w600,
    double tracking = 0.16,
  }) =>
      TextStyle(
        fontFamily: mono,
        fontSize: size,
        fontWeight: weight,
        color: color,
        letterSpacing: tracking * size,
        fontFeatures: _tabular,
      );

  /// Ordinary prose.
  static TextStyle body({
    required Color color,
    double size = 13,
    FontWeight weight = FontWeight.w400,
    double height = 1.55,
    double tracking = 0,
  }) =>
      TextStyle(
        fontFamily: sans,
        fontSize: size,
        fontWeight: weight,
        color: color,
        height: height,
        letterSpacing: tracking * size,
      );

  /// A row's name, or anything else that labels rather than explains.
  static TextStyle label({
    required Color color,
    double size = 14.5,
    FontWeight weight = FontWeight.w500,
  }) =>
      TextStyle(
        fontFamily: sans,
        fontSize: size,
        fontWeight: weight,
        color: color,
        letterSpacing: -0.1,
      );

  /// A heading.
  static TextStyle title({
    required Color color,
    double size = 16,
    FontWeight weight = FontWeight.w600,
    double tracking = -0.0125,
    double? height,
  }) =>
      TextStyle(
        fontFamily: sans,
        fontSize: size,
        fontWeight: weight,
        color: color,
        height: height,
        letterSpacing: tracking * size,
      );
}

/// Measurements the design repeats often enough to be worth naming.
class TrioMetrics {
  const TrioMetrics._();

  /// The ground showing between two panels.
  static const gutter = 8.0;

  /// A panel's own horizontal padding.
  static const inset = 16.0;

  /// A section header strip.
  static const headerHeight = 32.0;

  /// An ordinary settings or detail row.
  static const rowHeight = 52.0;

  /// The primary action at the foot of a screen.
  static const actionHeight = 56.0;

  /// Nothing in this design is rounded.
  static const radius = BorderRadius.zero;
}

/// The app-wide [ThemeData], built so that anything still drawn by a stock
/// Material widget lands in the same palette as everything hand-drawn.
ThemeData trioThemeData(TrioColors colors, Brightness brightness) {
  final scheme = ColorScheme(
    brightness: brightness,
    primary: colors.accent,
    onPrimary: colors.onAccent,
    secondary: colors.accent,
    onSecondary: colors.onAccent,
    error: colors.danger,
    onError: colors.onDangerDeep,
    surface: colors.panel,
    onSurface: colors.ink,
    outline: colors.inkFaint,
    outlineVariant: colors.hairline,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: colors.ground,
    canvasColor: colors.panel,
    dividerColor: colors.hairline,
    fontFamily: TrioType.sans,
    splashFactory: InkSparkle.splashFactory,
    // Sharp corners everywhere a Material widget would otherwise round them.
    cardTheme: CardThemeData(
      color: colors.panel,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: const RoundedRectangleBorder(borderRadius: TrioMetrics.radius),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: colors.panel,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: TrioMetrics.radius),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: colors.panel,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: TrioMetrics.radius),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: colors.ink,
      contentTextStyle: TrioType.body(color: colors.ground, size: 13),
      shape: const RoundedRectangleBorder(borderRadius: TrioMetrics.radius),
      behavior: SnackBarBehavior.floating,
    ),
    textSelectionTheme: TextSelectionThemeData(cursorColor: colors.accent),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: colors.accent),
  );
}
