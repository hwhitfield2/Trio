import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// intl exports a TextDirection of its own, which is not the one TextPainter
// wants.
import 'package:intl/intl.dart' hide TextDirection;

import '../models/glucose_ranges.dart';
import '../models/status_snapshot.dart';
import '../theme/trio_design.dart';
import 'glucose_colors.dart';

/// Maps readings onto the chart's horizontal axis, and back again.
///
/// Its own type rather than something private to the painter: the gesture
/// handler and the painter have to agree on where a point sits, and a reading
/// picked up by touch that then draws its marker somewhere else would be worse
/// than no touch handling at all.
class GlucoseChartScale {
  const GlucoseChartScale._(this.points, this.start, this.span);

  /// Without [window], the chart spans exactly the readings it was given.
  /// With one, it spans that duration ending at the newest reading, and
  /// readings from before the window are left out: an hour with no data is
  /// then an honest gap rather than the whole chart quietly stretching.
  factory GlucoseChartScale(List<GlucoseReading> readings, {Duration? window}) {
    final sorted = [...readings]..sort((a, b) => a.date.compareTo(b.date));

    if (window != null && sorted.isNotEmpty) {
      final end = sorted.last.date.millisecondsSinceEpoch.toDouble();
      final start = end - window.inMilliseconds;
      final visible =
          sorted.where((reading) => reading.date.millisecondsSinceEpoch >= start).toList();
      return GlucoseChartScale._(
        List.unmodifiable(visible),
        start,
        window.inMilliseconds.toDouble(),
      );
    }

    final start = sorted.isEmpty ? 0.0 : sorted.first.date.millisecondsSinceEpoch.toDouble();
    final end = sorted.isEmpty ? 0.0 : sorted.last.date.millisecondsSinceEpoch.toDouble();
    // A single reading — or several sharing a timestamp — would otherwise
    // divide by zero.
    return GlucoseChartScale._(List.unmodifiable(sorted), start, max(end - start, 1.0));
  }

  /// Oldest first, which is the order they are drawn and scrubbed in.
  final List<GlucoseReading> points;

  /// Epoch milliseconds where the chart begins, and the window it spans. With
  /// a fixed window the start can be well before the oldest reading.
  final double start;
  final double span;

  bool get isEmpty => points.isEmpty;

  double xFor(GlucoseReading reading, double width) =>
      (reading.date.millisecondsSinceEpoch - start) / span * width;

  /// Where a moment in time falls across [width], whether or not a reading
  /// sits there. What the suspension marker is drawn against.
  double xForDate(DateTime date, double width) =>
      (date.millisecondsSinceEpoch - start) / span * width;

  /// The index of the reading a treatment sits over, or null when it happened
  /// outside the window the chart covers.
  ///
  /// Anchored to a reading rather than plotted at its own height: a bolus has
  /// no glucose value of its own, and drawing it against the reading it was
  /// given for is what makes it readable — the same thing the host's chart
  /// does.
  int? anchorFor(DateTime date) {
    if (points.isEmpty) return null;
    final at = date.millisecondsSinceEpoch.toDouble();
    // Half a reading's gap of slack at each end, so a treatment logged just
    // before the oldest reading still belongs to it rather than vanishing.
    // Measured from the readings themselves, not [span] — with a fixed window
    // the span can be hours longer than the data it holds.
    final extent = (points.last.date.millisecondsSinceEpoch -
            points.first.date.millisecondsSinceEpoch)
        .toDouble();
    final slack = points.length > 1 ? extent / (points.length - 1) / 2 : 0;
    if (at < start - slack || at > start + span + slack) return null;

    var best = 0;
    var bestDistance = double.infinity;
    for (var index = 0; index < points.length; index++) {
      final distance =
          (points[index].date.millisecondsSinceEpoch - at).abs().toDouble();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = index;
      }
    }
    return best;
  }

  /// The reading nearest [dx], or null when there is nothing to point at.
  ///
  /// Nearest rather than "the one under the finger": readings are five minutes
  /// apart and a fingertip is wider than the gaps between them at the right
  /// edge, so anything stricter would leave dead spots on the chart.
  int? indexAt(double dx, double width) {
    if (points.isEmpty || width <= 0) return null;

    var best = 0;
    var bestDistance = double.infinity;
    for (var index = 0; index < points.length; index++) {
      final distance = (xFor(points[index], width) - dx).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = index;
      }
    }
    return best;
  }
}

/// Formats a reading for the scrubbing readout, in the host's display units.
///
/// Matches how the same number is written everywhere else in the app: whole
/// mg/dL, one decimal for mmol/L.
String glucoseReadoutValue(GlucoseReading reading, {required String units}) =>
    units == 'mmol/L' ? (reading.sgv / 18.0).toStringAsFixed(1) : reading.sgv.toString();

/// Where the vertical axis is labelled, in mg/dL. Round numbers in the
/// reader's own units — 100/200/300, or 4/8/12/16 mmol/L — not round numbers
/// in the wire format.
List<double> glucoseAxisGridlines(String units) =>
    units == 'mmol/L' ? const [72, 144, 216, 288] : const [100, 200, 300];

/// How an axis value reads, in the display units. Whole numbers both ways:
/// the gridlines are chosen to be whole in either unit, and "16.0" up the
/// side of a small chart is clutter.
String glucoseAxisLabel(double mgdl, String units) =>
    units == 'mmol/L' ? (mgdl / 18.0).round().toString() : mgdl.round().toString();

/// How far apart the time labels sit for a chart spanning [span]: roughly
/// three to four labels whatever the duration, so 48 hours does not mean a
/// picket fence of unreadable text.
Duration chartTimeTickInterval(Duration span) {
  if (span.inHours <= 3) return const Duration(hours: 1);
  if (span.inHours <= 6) return const Duration(hours: 2);
  if (span.inHours <= 12) return const Duration(hours: 3);
  if (span.inHours <= 24) return const Duration(hours: 6);
  return const Duration(hours: 12);
}

/// How big a dot is on a chart spanning [span].
///
/// A 48-hour window holds eight times the readings a six-hour one does in the
/// same width; drawn at the same size they merge into a band and stop being
/// readings at all.
double glucosePointRadius(Duration? span) {
  final hours = span?.inHours ?? 6;
  if (hours <= 6) return 3;
  if (hours <= 12) return 2.2;
  return 1.6;
}

/// Minimal dependency-free glucose sparkline for the readings pushed by the
/// host.
///
/// Touch and hold — or drag across it — to read off a single reading's value
/// and time. The readings are five minutes apart and the chart is small, so
/// there is no other way to tell what a given dot actually was.
class GlucoseChart extends StatefulWidget {
  const GlucoseChart({
    super.key,
    required this.readings,
    this.units = 'mg/dL',
    this.ranges = GlucoseRanges.defaults,
    this.treatments = const [],
    this.duration,
    this.suspendedAt,
  });

  final List<GlucoseReading> readings;

  /// The window the chart spans, ending at the newest reading. Null spans
  /// whatever the readings cover — the shape a chart with no duration picker
  /// always had.
  final Duration? duration;

  /// The host's display units: 'mg/dL' or 'mmol/L'. Readings themselves are
  /// always mg/dL; only the readout is converted.
  final String units;

  /// The ranges the host colours by, in mg/dL: they decide the guide lines and
  /// what colour each dot is drawn. Defaulted rather than optional, so a chart
  /// built before a snapshot arrives still draws something sensible.
  final GlucoseRanges ranges;

  /// Boluses and carbs from the same window, in any order. Each is drawn
  /// against the reading it happened nearest to, the way the host draws its
  /// own chart — a bolus means nothing except against the glucose it was
  /// given for.
  final List<TreatmentEvent> treatments;

  /// When insulin was stopped, if it is stopped now. Ruled onto the chart so
  /// the fall after it — or the absence of one — can be read against it.
  final DateTime? suspendedAt;

  /// The plot's own height. The time labels are drawn in a band beneath it, so
  /// the widget is a little taller than this.
  static const plotHeight = 174.0;

  @override
  State<GlucoseChart> createState() => _GlucoseChartState();
}

class _GlucoseChartState extends State<GlucoseChart> {
  late GlucoseChartScale _scale =
      GlucoseChartScale(widget.readings, window: widget.duration);

  /// Treatments by the index of the reading they sit over. Worked out once per
  /// snapshot rather than per frame: scrubbing repaints constantly, and this
  /// answer only changes when the data does.
  late Map<int, List<TreatmentEvent>> _anchored = _anchor();
  int? _selected;

  Map<int, List<TreatmentEvent>> _anchor() {
    final anchored = <int, List<TreatmentEvent>>{};
    for (final treatment in widget.treatments) {
      final index = _scale.anchorFor(treatment.date);
      if (index == null) continue;
      anchored.putIfAbsent(index, () => <TreatmentEvent>[]).add(treatment);
    }
    // Insulin before carbs at the same reading, so a meal bolus and its meal
    // always read in the same order.
    for (final events in anchored.values) {
      events.sort((a, b) => (a is BolusEvent ? 0 : 1).compareTo(b is BolusEvent ? 0 : 1));
    }
    return anchored;
  }

  @override
  void didUpdateWidget(covariant GlucoseChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sameReadings =
        identical(oldWidget.readings, widget.readings) && oldWidget.duration == widget.duration;
    final sameTreatments = identical(oldWidget.treatments, widget.treatments);
    if (sameReadings && sameTreatments) return;

    if (!sameReadings) {
      _scale = GlucoseChartScale(widget.readings, window: widget.duration);
      // A snapshot arriving mid-scrub reshapes the window; keep pointing at
      // something real rather than off the end of the new list.
      if (_selected != null) {
        _selected = _scale.isEmpty ? null : _selected!.clamp(0, _scale.points.length - 1);
      }
    }
    _anchored = _anchor();
  }

  void _select(double dx, double width) {
    final index = _scale.indexAt(dx, width);
    if (index == null || index == _selected) return;
    // Every reading the finger crosses gets its own tick, the way a picker
    // does — the readout is small, and this is what says it changed.
    HapticFeedback.selectionClick();
    setState(() => _selected = index);
  }

  void _clearSelection() {
    if (_selected == null) return;
    setState(() => _selected = null);
  }

  /// One reading in words: what the readout bubble says, for anyone who cannot
  /// see it. Painted text is invisible to screen readers, so without this the
  /// chart is a blank rectangle to VoiceOver.
  String _describe(GlucoseReading reading, int index) {
    final treatments = _anchored[index];
    final spoken = treatments == null
        ? ''
        : treatments.map((treatment) => ', ${treatment.spokenLabel}').join();
    return '${glucoseReadoutValue(reading, units: widget.units)} $_unitsLabel '
        'at ${DateFormat.jm().format(reading.date)}$spoken';
  }

  String get _unitsLabel => widget.units == 'mmol/L' ? 'mmol/L' : 'mg/dL';

  /// The selected reading, or the newest one when nothing is being scrubbed.
  String get _semanticsValue {
    if (_scale.isEmpty) return '';
    final index = _selected ?? _scale.points.length - 1;
    return _describe(_scale.points[index], index);
  }

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);

    return SizedBox(
      // The plot, plus room beneath it for the time labels.
      height: GlucoseChart.plotHeight + 18,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          return Semantics(
            container: true,
            label: 'Glucose chart',
            value: _semanticsValue,
            child: GestureDetector(
              // The whole box is scrubbable, not only where a dot happens to be.
              behavior: HitTestBehavior.opaque,
              // Hold, then drag. The long press is what makes this safe inside
              // a scrolling list: it cannot be mistaken for the start of a
              // scroll.
              onLongPressStart: (details) => _select(details.localPosition.dx, width),
              onLongPressMoveUpdate: (details) => _select(details.localPosition.dx, width),
              onLongPressEnd: (_) => _clearSelection(),
              onLongPressCancel: _clearSelection,
              // A straight sideways drag scrubs too, and still leaves the
              // list's vertical scrolling alone.
              onHorizontalDragStart: (details) => _select(details.localPosition.dx, width),
              onHorizontalDragUpdate: (details) => _select(details.localPosition.dx, width),
              onHorizontalDragEnd: (_) => _clearSelection(),
              onHorizontalDragCancel: _clearSelection,
              child: CustomPaint(
                painter: _GlucosePainter(
                  scale: _scale,
                  selected: _selected,
                  anchored: _anchored,
                  ranges: widget.ranges,
                  suspendedAt: widget.suspendedAt,
                  pointRadius: glucosePointRadius(widget.duration),
                  gridColor: colors.hairline,
                  boundColor: colors.rule,
                  crosshairColor: colors.inkFaint,
                  suspendColor: colors.dangerDeep,
                  readoutColor: colors.ink,
                  readoutStyle: TrioType.numeral(
                    size: 15,
                    weight: FontWeight.w600,
                    color: colors.panel,
                  ),
                  readoutCaptionStyle: TrioType.micro(
                    color: colors.panel,
                    size: 10,
                    weight: FontWeight.w500,
                    tracking: 0.08,
                  ),
                  axisStyle: TrioType.numeral(
                    size: 9.5,
                    weight: FontWeight.w400,
                    tracking: 0.08,
                    color: colors.inkFaint,
                  ),
                  formatValue: (reading) => glucoseReadoutValue(reading, units: widget.units),
                  unitsLabel: _unitsLabel,
                  textDirection: Directionality.of(context),
                  textScaler: MediaQuery.textScalerOf(context),
                ),
                size: Size.infinite,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _GlucosePainter extends CustomPainter {
  _GlucosePainter({
    required this.scale,
    required this.selected,
    required this.anchored,
    required this.ranges,
    required this.suspendedAt,
    required this.pointRadius,
    required this.gridColor,
    required this.boundColor,
    required this.crosshairColor,
    required this.suspendColor,
    required this.readoutColor,
    required this.readoutStyle,
    required this.readoutCaptionStyle,
    required this.axisStyle,
    required this.formatValue,
    required this.unitsLabel,
    required this.textDirection,
    required this.textScaler,
  });

  final GlucoseChartScale scale;
  final int? selected;

  /// Treatments by the index of the reading they are drawn against.
  final Map<int, List<TreatmentEvent>> anchored;
  final GlucoseRanges ranges;
  final DateTime? suspendedAt;
  final double pointRadius;

  /// The faint ruling: the time lines and the dashed value gridlines.
  final Color gridColor;

  /// The heavier ruling: the two bounds of the in-range band.
  final Color boundColor;
  final Color crosshairColor;
  final Color suspendColor;
  final Color readoutColor;
  final TextStyle readoutStyle;
  final TextStyle readoutCaptionStyle;
  final TextStyle axisStyle;
  final String Function(GlucoseReading reading) formatValue;
  final String unitsLabel;

  /// Read from the context rather than assumed: a painter is outside the
  /// widget tree, so nothing else would give the readout the reader's text
  /// size or writing direction.
  final TextDirection textDirection;
  final TextScaler textScaler;

  static const _minSgv = 40.0;
  static const _maxSgv = 300.0;

  /// Trio's own insulin blue, and the orange it draws carbs in. A follower
  /// looking at both screens should not have to learn two colour schemes; the
  /// side of the reading a bar sits on — insulin above, carbs below — is what
  /// tells them apart from each other.
  static const _bolusColor = TrioColors.insulin;
  static const _carbColor = TrioColors.carbs;

  /// A treatment bar's width, how far off the reading it starts, and how far
  /// each further bar at the same reading is stacked beyond it.
  static const _markerWidth = 3.0;
  static const _markerGap = 6.0;
  static const _markerStep = 3.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (scale.isEmpty) return;

    // The bottom band belongs to the time labels; everything else draws in
    // the plot above it.
    final plot = Size(size.width, max(1.0, size.height - _timeAxisBand()));

    double x(GlucoseReading e) => scale.xFor(e, size.width);
    double y(double sgv) =>
        plot.height - ((sgv.clamp(_minSgv, _maxSgv) - _minSgv) / (_maxSgv - _minSgv) * plot.height);

    _paintInRangeBand(canvas, plot, y);
    _paintTimeAxis(canvas, plot);
    _paintValueAxis(canvas, plot, y);

    // The bounds of the band, drawn over its fill and over the gridlines: they
    // are the two numbers the whole chart is read against.
    final boundPaint = Paint()
      ..color = boundColor
      ..strokeWidth = 1;
    for (final line in [ranges.low, ranges.high]) {
      canvas.drawLine(Offset(0, y(line)), Offset(size.width, y(line)), boundPaint);
    }

    for (final reading in scale.points) {
      final sgv = reading.sgv.toDouble();
      canvas.drawCircle(
        Offset(x(reading), y(sgv)),
        pointRadius,
        Paint()..color = _colorFor(sgv),
      );
    }

    _paintTreatments(canvas, x, y);
    _paintSuspension(canvas, plot);

    final index = selected;
    if (index != null && index < scale.points.length) {
      _paintSelection(canvas, plot, scale.points[index], anchored[index] ?? const [], x, y);
    }
  }

  /// The host's in-range window as a tinted band, so "in range" is somewhere a
  /// reading *is* rather than something to work out from two lines.
  void _paintInRangeBand(Canvas canvas, Size plot, double Function(double) y) {
    final top = y(ranges.high);
    final bottom = y(ranges.low);
    if (bottom <= top) return;
    canvas.drawRect(
      Rect.fromLTRB(0, top, plot.width, bottom),
      Paint()..color = TrioColors.inRange.withValues(alpha: 0.055),
    );
  }

  TextPainter _axisText(String text) => TextPainter(
        text: TextSpan(text: text, style: axisStyle),
        textDirection: textDirection,
        textScaler: textScaler,
      )..layout();

  /// The height the time labels need beneath the plot, at the reader's own
  /// text size.
  double _timeAxisBand() => _axisText('12 PM').height + 4;

  /// Vertical lines at round local times across the window, each with the time
  /// written beneath the plot.
  void _paintTimeAxis(Canvas canvas, Size plot) {
    final interval = chartTimeTickInterval(Duration(milliseconds: scale.span.round()));
    final linePaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;

    // The first round time at or before the window's start, aligned to a
    // multiple of the interval within its day — so a six-hour spacing lands on
    // midnight and 6 AM, not twenty past whatever hour the window opened.
    final windowStart = DateTime.fromMillisecondsSinceEpoch(scale.start.round());
    var tick = DateTime(windowStart.year, windowStart.month, windowStart.day, windowStart.hour);
    tick = tick.subtract(Duration(hours: tick.hour % interval.inHours));

    final end = scale.start + scale.span;
    while (tick.millisecondsSinceEpoch <= end) {
      final at = tick.millisecondsSinceEpoch.toDouble();
      if (at >= scale.start) {
        final dx = (at - scale.start) / scale.span * plot.width;
        canvas.drawLine(Offset(dx, 0), Offset(dx, plot.height), linePaint);
        final label = _axisText(DateFormat.j().format(tick).toUpperCase());
        // Centred under its line, but never past the chart's edges.
        final left =
            (dx - label.width / 2).clamp(0.0, max(0.0, plot.width - label.width)).toDouble();
        label.paint(canvas, Offset(left, plot.height + 4));
      }
      tick = tick.add(interval);
    }
  }

  /// Values up the right-hand edge, each written just above its own dashed
  /// gridline. Dashed rather than solid so they read as scaffolding and the
  /// two solid range bounds stay the lines that mean something.
  void _paintValueAxis(Canvas canvas, Size plot, double Function(double) y) {
    final linePaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;

    for (final mgdl in glucoseAxisGridlines(unitsLabel)) {
      final dy = y(mgdl);
      _dashedLine(canvas, Offset(0, dy), Offset(plot.width, dy), linePaint);
      final label = _axisText(glucoseAxisLabel(mgdl, unitsLabel));
      // Above the line, unless that would run off the top of the plot.
      final top = dy - label.height - 1 >= 0 ? dy - label.height - 1 : dy + 1;
      label.paint(canvas, Offset(plot.width - label.width - 2, top));
    }
  }

  /// A horizontal dashed run: one point on, three off, the way the design
  /// rules its gridlines.
  void _dashedLine(Canvas canvas, Offset from, Offset to, Paint paint) {
    const dash = 1.0;
    const gap = 3.0;
    for (var x = from.dx; x < to.dx; x += dash + gap) {
      canvas.drawLine(Offset(x, from.dy), Offset(min(x + dash, to.dx), to.dy), paint);
    }
  }

  /// Boluses above the reading they were given for, carbs below it — the same
  /// arrangement the host's own chart uses, and the only one that says which
  /// reading a treatment belongs to on a chart this small.
  ///
  /// Flat bars rather than triangles: at 1.6 points per dot a triangle is a
  /// smudge, and a bar's length still reads as an amount.
  void _paintTreatments(
    Canvas canvas,
    double Function(GlucoseReading) x,
    double Function(double) y,
  ) {
    anchored.forEach((index, events) {
      if (index >= scale.points.length) return;
      final reading = scale.points[index];
      final px = x(reading);
      final py = y(reading.sgv.toDouble());

      var above = py - _markerGap;
      var below = py + _markerGap;
      for (final event in events) {
        if (event is BolusEvent) {
          // A unit is a short mark and three a tall one; past about three the
          // length stops meaning anything on a chart this size.
          final length = (event.units * 5).clamp(5.0, 16.0).toDouble();
          canvas.drawRect(
            Rect.fromLTWH(px - _markerWidth / 2, above - length, _markerWidth, length),
            Paint()..color = _bolusColor,
          );
          above -= length + _markerStep;
        } else if (event is CarbEvent) {
          final length = (event.grams * 0.3).clamp(5.0, 16.0).toDouble();
          canvas.drawRect(
            Rect.fromLTWH(px - _markerWidth / 2, below, _markerWidth, length),
            Paint()..color = _carbColor,
          );
          below += length + _markerStep;
        }
      }
    });
  }

  /// The moment insulin stopped, ruled across the plot and labelled.
  ///
  /// Without it the fall after a suspension is just a fall; with it, whoever
  /// is watching can see whether the stop came before or after the drop, which
  /// is the first thing anyone asks.
  void _paintSuspension(Canvas canvas, Size plot) {
    final at = suspendedAt;
    if (at == null) return;
    final dx = scale.xForDate(at, plot.width);
    if (dx < 0 || dx > plot.width) return;

    canvas.drawRect(
      Rect.fromLTWH(dx - 0.75, 0, 1.5, plot.height),
      Paint()..color = suspendColor,
    );

    final label = TextPainter(
      text: TextSpan(
        text: 'SUSPENDED',
        style: axisStyle.copyWith(color: suspendColor, fontWeight: FontWeight.w600),
      ),
      textDirection: textDirection,
      textScaler: textScaler,
    )..layout();
    // To the left of its own line where there is room, so it never runs off
    // the right-hand edge of a chart the suspension happened near the end of.
    final left = (dx - label.width - 3) >= 0 ? dx - label.width - 3 : dx + 3;
    label.paint(canvas, Offset(min(left, max(0.0, plot.width - label.width)), 1));
  }

  /// What the host would have painted this reading, from the ranges it
  /// reported — which is the whole point of the dots being coloured at all.
  Color _colorFor(double sgv) => glucoseColorFor(sgv, ranges);

  /// Crosshair, an enlarged dot, and the value and time in a bubble that stays
  /// inside the chart however close to an edge the finger is.
  void _paintSelection(
    Canvas canvas,
    Size size,
    GlucoseReading reading,
    List<TreatmentEvent> treatments,
    double Function(GlucoseReading) x,
    double Function(double) y,
  ) {
    final sgv = reading.sgv.toDouble();
    final color = _colorFor(sgv);
    final px = x(reading);
    final py = y(sgv);

    canvas.drawLine(
      Offset(px, 0),
      Offset(px, size.height),
      Paint()
        ..color = crosshairColor
        ..strokeWidth = 1,
    );
    canvas.drawCircle(Offset(px, py), pointRadius + 4, Paint()..color = color.withValues(alpha: 0.25));
    canvas.drawCircle(Offset(px, py), pointRadius + 1.5, Paint()..color = color);

    final label = TextPainter(
      text: TextSpan(
        children: [
          TextSpan(text: formatValue(reading), style: readoutStyle),
          TextSpan(text: ' ${unitsLabel.toUpperCase()}', style: readoutCaptionStyle),
          TextSpan(
            text: '\n${DateFormat.jm().format(reading.date).toUpperCase()}',
            style: readoutCaptionStyle,
          ),
          // What was given or eaten at this reading, in the marker's own
          // colour: the bars say something happened, and this is where the
          // reader finds out what.
          for (final treatment in treatments)
            TextSpan(
              text: '\n${treatment.label}',
              style: readoutCaptionStyle.copyWith(
                color: treatment is BolusEvent ? _bolusColor : _carbColor,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
      textAlign: TextAlign.center,
      textDirection: textDirection,
      textScaler: textScaler,
    )..layout();

    const padding = EdgeInsets.symmetric(horizontal: 9, vertical: 6);
    final bubble = Size(label.width + padding.horizontal, label.height + padding.vertical);
    // Clamped rather than centred: at either end of the chart the finger is
    // already at the edge, and half a bubble hanging off it reads as nothing.
    final left =
        (px - bubble.width / 2).clamp(0.0, max(0.0, size.width - bubble.width)).toDouble();
    // Above the point, unless that is off the top — then below it, so the
    // bubble never covers the reading it is describing.
    final above = py - bubble.height - 10;
    final top = above >= 0 ? above : min(py + 10, max(0.0, size.height - bubble.height));

    canvas.drawRect(
      Rect.fromLTWH(left, top, bubble.width, bubble.height),
      Paint()..color = readoutColor.withValues(alpha: 0.94),
    );
    label.paint(canvas, Offset(left + padding.left, top + padding.top));
  }

  @override
  bool shouldRepaint(covariant _GlucosePainter oldDelegate) =>
      oldDelegate.scale != scale ||
      oldDelegate.selected != selected ||
      oldDelegate.anchored != anchored ||
      oldDelegate.ranges != ranges ||
      oldDelegate.suspendedAt != suspendedAt ||
      oldDelegate.pointRadius != pointRadius ||
      oldDelegate.unitsLabel != unitsLabel ||
      // A theme, text size or writing direction change redraws too; none of
      // them touch the readings, and all of them change what is on screen.
      oldDelegate.gridColor != gridColor ||
      oldDelegate.boundColor != boundColor ||
      oldDelegate.readoutColor != readoutColor ||
      oldDelegate.readoutStyle != readoutStyle ||
      oldDelegate.axisStyle != axisStyle ||
      oldDelegate.textScaler != textScaler ||
      oldDelegate.textDirection != textDirection;
}
