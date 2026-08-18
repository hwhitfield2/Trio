/// The glucose ranges the host colours by, as it reports them in the status
/// snapshot's `ranges` object.
///
/// Always mg/dL, like every other glucose number on the wire. These are not
/// the follower's alert thresholds: a follower picks those for itself, and
/// they say nothing about how the host displays a reading.
class GlucoseRanges {
  const GlucoseRanges({
    required this.low,
    required this.high,
    required this.target,
    this.isDynamic = false,
  });

  /// What the chart draws with until a host reports its own — Trio's own
  /// defaults, so a follower paired to a host that predates this looks like
  /// one paired to a host whose display settings are untouched.
  static const defaults = GlucoseRanges(low: 70, high: 180, target: 100);

  /// Below [low] a reading reads as low, at or above [high] as high; in
  /// between it is in range.
  final double low;
  final double high;

  /// The glucose target in force on the host when the snapshot was built.
  /// Only the dynamic scheme uses it — that is the value it shades to green.
  final double target;

  /// The host's `dynamicColor` scheme: a hue sweep from red through green at
  /// target to purple, rather than three fixed colours.
  final bool isDynamic;

  /// The window that sweep runs across, in mg/dL: red at [dynamicSweepLow],
  /// violet at [dynamicSweepHigh], green at [target] somewhere between.
  ///
  /// Hard-coded on the host too, and deliberately wider than the display range:
  /// shading from red at the low itself would crowd every in-range reading into
  /// the greens. Keep in step with `GlucoseChartView` in Trio.
  static const dynamicSweepLow = 55.0;
  static const dynamicSweepHigh = 220.0;

  /// The window a host-reported display range can plausibly sit in, in mg/dL:
  /// the same one Trio's own settings allow its low and high to be set in.
  ///
  /// Checked because the numbers are not always a display range. A host that
  /// predates the range being reported sends only the thresholds this follower
  /// is *alerted* on, and those are allowed anywhere between 40 and 400 — a
  /// low alert set at 300 is a legitimate alert setting and a nonsensical
  /// range, and colouring a whole chart red because of one is exactly the
  /// wrong answer.
  static const lowFloor = 40.0;
  static const lowCeiling = 150.0;
  static const highFloor = 100.0;
  static const highCeiling = 400.0;

  /// Whether a pair of numbers could be a display range at all.
  static bool isPlausible(double low, double high) =>
      low.isFinite &&
      high.isFinite &&
      low < high &&
      low >= lowFloor &&
      low <= lowCeiling &&
      high >= highFloor &&
      high <= highCeiling;

  /// What the host calls this scheme, and what the native widgets and the Lock
  /// Screen read back.
  String get schemeName => isDynamic ? 'dynamicColor' : 'staticColor';

  /// The colouring fields the platform widgets and the Live Activity need,
  /// in whatever units [convert] produces.
  ///
  /// Those surfaces already receive the display low and high alongside this,
  /// so only what the dynamic sweep needs travels here. [convert] is the
  /// caller's own unit conversion, so a payload cannot end up half converted.
  Map<String, dynamic> toPayload(double Function(double mgdl) convert) => <String, dynamic>{
        'scheme': schemeName,
        'target': convert(target),
        'sweepLow': convert(dynamicSweepLow),
        'sweepHigh': convert(dynamicSweepHigh),
      };

  /// Reads the `ranges` object out of a status snapshot.
  ///
  /// Null for anything that is not a usable pair of bounds — an older host
  /// sending nothing, or numbers no display range could be made of. Callers
  /// fall back rather than colour by numbers that cannot be true.
  static GlucoseRanges? fromJson(Object? json) {
    if (json is! Map) return null;

    final low = (json['low'] as num?)?.toDouble();
    final high = (json['high'] as num?)?.toDouble();
    if (low == null || high == null) return null;
    if (!isPlausible(low, high)) return null;

    final target = (json['target'] as num?)?.toDouble();
    return GlucoseRanges(
      low: low,
      high: high,
      // A target outside the range it belongs to cannot be shaded towards, and
      // an interpolation through it would run backwards; the midpoint is the
      // honest stand-in.
      target: target != null && target.isFinite && target > low && target < high
          ? target
          : (low + high) / 2,
      // Anything else — including a scheme this build does not know — is the
      // static three-colour one, which is Trio's own default.
      isDynamic: json['scheme'] == 'dynamicColor',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GlucoseRanges &&
      other.low == low &&
      other.high == high &&
      other.target == target &&
      other.isDynamic == isDynamic;

  @override
  int get hashCode => Object.hash(low, high, target, isDynamic);

  @override
  String toString() =>
      'GlucoseRanges(low: $low, high: $high, target: $target, isDynamic: $isDynamic)';
}
