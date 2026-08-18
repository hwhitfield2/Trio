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

  /// Reads the `ranges` object out of a status snapshot.
  ///
  /// Null for anything that is not a usable pair of bounds — an older host
  /// sending nothing, or a host whose low is not below its high. Callers fall
  /// back rather than colour by numbers that cannot be true.
  static GlucoseRanges? fromJson(Object? json) {
    if (json is! Map) return null;

    final low = (json['low'] as num?)?.toDouble();
    final high = (json['high'] as num?)?.toDouble();
    if (low == null || high == null) return null;
    if (!low.isFinite || !high.isFinite || low <= 0 || low >= high) return null;

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
