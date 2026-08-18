import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// intl exports a TextDirection of its own, which is not the one TextPainter
// wants.
import 'package:intl/intl.dart' hide TextDirection;

import '../models/glucose_ranges.dart';
import '../models/status_snapshot.dart';
import 'glucose_colors.dart';

/// Maps readings onto the chart's horizontal axis, and back again.
///
/// Its own type rather than something private to the painter: the gesture
/// handler and the painter have to agree on where a point sits, and a reading
/// picked up by touch that then draws its marker somewhere else would be worse
/// than no touch handling at all.
class GlucoseChartScale {
  const GlucoseChartScale._(this.points, this.start, this.span);

  factory GlucoseChartScale(List<GlucoseReading> readings) {
    final sorted = [...readings]..sort((a, b) => a.date.compareTo(b.date));
    final start = sorted.isEmpty ? 0.0 : sorted.first.date.millisecondsSinceEpoch.toDouble();
    final end = sorted.isEmpty ? 0.0 : sorted.last.date.millisecondsSinceEpoch.toDouble();
    // A single reading — or several sharing a timestamp — would otherwise
    // divide by zero.
    return GlucoseChartScale._(List.unmodifiable(sorted), start, max(end - start, 1.0));
  }

  /// Oldest first, which is the order they are drawn and scrubbed in.
  final List<GlucoseReading> points;

  /// Epoch milliseconds of the oldest reading, and the window it spans.
  final double start;
  final double span;

  bool get isEmpty => points.isEmpty;

  double xFor(GlucoseReading reading, double width) =>
      (reading.date.millisecondsSinceEpoch - start) / span * width;

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

/// Minimal dependency-free glucose sparkline for the readings pushed by the
/// host (last few hours).
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
  });

  final List<GlucoseReading> readings;

  /// The host's display units: 'mg/dL' or 'mmol/L'. Readings themselves are
  /// always mg/dL; only the readout is converted.
  final String units;

  /// The ranges the host colours by, in mg/dL: they decide the guide lines and
  /// what colour each dot is drawn. Defaulted rather than optional, so a chart
  /// built before a snapshot arrives still draws something sensible.
  final GlucoseRanges ranges;

  @override
  State<GlucoseChart> createState() => _GlucoseChartState();
}

class _GlucoseChartState extends State<GlucoseChart> {
  late GlucoseChartScale _scale = GlucoseChartScale(widget.readings);
  int? _selected;

  @override
  void didUpdateWidget(covariant GlucoseChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.readings, widget.readings)) return;

    _scale = GlucoseChartScale(widget.readings);
    // A snapshot arriving mid-scrub reshapes the window; keep pointing at
    // something real rather than off the end of the new list.
    if (_selected != null) {
      _selected = _scale.isEmpty ? null : _selected!.clamp(0, _scale.points.length - 1);
    }
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
  String _describe(GlucoseReading reading) =>
      '${glucoseReadoutValue(reading, units: widget.units)} $_unitsLabel '
      'at ${DateFormat.jm().format(reading.date)}';

  String get _unitsLabel => widget.units == 'mmol/L' ? 'mmol/L' : 'mg/dL';

  /// The selected reading, or the newest one when nothing is being scrubbed.
  String get _semanticsValue {
    if (_scale.isEmpty) return '';
    final index = _selected;
    return _describe(index == null ? _scale.points.last : _scale.points[index]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SizedBox(
      height: 140,
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
                  ranges: widget.ranges,
                  gridColor: theme.colorScheme.outlineVariant,
                  crosshairColor: theme.colorScheme.outline,
                  readoutColor: theme.colorScheme.inverseSurface,
                  readoutStyle: (theme.textTheme.labelLarge ?? const TextStyle(fontSize: 14))
                      .copyWith(
                    color: theme.colorScheme.onInverseSurface,
                    fontWeight: FontWeight.bold,
                  ),
                  readoutCaptionStyle: (theme.textTheme.labelSmall ?? const TextStyle(fontSize: 11))
                      .copyWith(color: theme.colorScheme.onInverseSurface),
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
    required this.ranges,
    required this.gridColor,
    required this.crosshairColor,
    required this.readoutColor,
    required this.readoutStyle,
    required this.readoutCaptionStyle,
    required this.formatValue,
    required this.unitsLabel,
    required this.textDirection,
    required this.textScaler,
  });

  final GlucoseChartScale scale;
  final int? selected;
  final GlucoseRanges ranges;
  final Color gridColor;
  final Color crosshairColor;
  final Color readoutColor;
  final TextStyle readoutStyle;
  final TextStyle readoutCaptionStyle;
  final String Function(GlucoseReading reading) formatValue;
  final String unitsLabel;

  /// Read from the context rather than assumed: a painter is outside the
  /// widget tree, so nothing else would give the readout the reader's text
  /// size or writing direction.
  final TextDirection textDirection;
  final TextScaler textScaler;

  static const _minSgv = 40.0;
  static const _maxSgv = 300.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (scale.isEmpty) return;

    double x(GlucoseReading e) => scale.xFor(e, size.width);
    double y(double sgv) =>
        size.height - ((sgv.clamp(_minSgv, _maxSgv) - _minSgv) / (_maxSgv - _minSgv) * size.height);

    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (final line in [ranges.low, ranges.high]) {
      canvas.drawLine(Offset(0, y(line)), Offset(size.width, y(line)), gridPaint);
    }

    for (final reading in scale.points) {
      final sgv = reading.sgv.toDouble();
      canvas.drawCircle(
        Offset(x(reading), y(sgv)),
        2.5,
        Paint()..color = _colorFor(sgv),
      );
    }

    final index = selected;
    if (index != null && index < scale.points.length) {
      _paintSelection(canvas, size, scale.points[index], x, y);
    }
  }

  /// What the host would have painted this reading, from the ranges it
  /// reported — which is the whole point of the dots being coloured at all.
  Color _colorFor(double sgv) => glucoseColorFor(sgv, ranges);

  /// Crosshair, an enlarged marker, and the value and time in a bubble that
  /// stays inside the chart however close to an edge the finger is.
  void _paintSelection(
    Canvas canvas,
    Size size,
    GlucoseReading reading,
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
    canvas.drawCircle(Offset(px, py), 7, Paint()..color = color.withValues(alpha: 0.25));
    canvas.drawCircle(Offset(px, py), 4, Paint()..color = color);

    final label = TextPainter(
      text: TextSpan(
        children: [
          TextSpan(text: formatValue(reading), style: readoutStyle),
          TextSpan(text: ' $unitsLabel', style: readoutCaptionStyle),
          TextSpan(
            text: '\n${DateFormat.jm().format(reading.date)}',
            style: readoutCaptionStyle,
          ),
        ],
      ),
      textAlign: TextAlign.center,
      textDirection: textDirection,
      textScaler: textScaler,
    )..layout();

    const padding = EdgeInsets.symmetric(horizontal: 8, vertical: 5);
    final bubble = Size(label.width + padding.horizontal, label.height + padding.vertical);
    // Clamped rather than centred: at either end of the chart the finger is
    // already at the edge, and half a bubble hanging off it reads as nothing.
    final left =
        (px - bubble.width / 2).clamp(0.0, max(0.0, size.width - bubble.width)).toDouble();
    // Above the point, unless that is off the top — then below it, so the
    // bubble never covers the reading it is describing.
    final above = py - bubble.height - 10;
    final top = above >= 0 ? above : min(py + 10, max(0.0, size.height - bubble.height));

    final rect = Rect.fromLTWH(left, top, bubble.width, bubble.height);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(8)),
      Paint()..color = readoutColor.withValues(alpha: 0.92),
    );
    label.paint(canvas, Offset(left + padding.left, top + padding.top));
  }

  @override
  bool shouldRepaint(covariant _GlucosePainter oldDelegate) =>
      oldDelegate.scale != scale ||
      oldDelegate.selected != selected ||
      oldDelegate.ranges != ranges ||
      oldDelegate.unitsLabel != unitsLabel ||
      // A theme, text size or writing direction change redraws too; none of
      // them touch the readings, and all of them change what is on screen.
      oldDelegate.gridColor != gridColor ||
      oldDelegate.readoutColor != readoutColor ||
      oldDelegate.readoutStyle != readoutStyle ||
      oldDelegate.textScaler != textScaler ||
      oldDelegate.textDirection != textDirection;
}
