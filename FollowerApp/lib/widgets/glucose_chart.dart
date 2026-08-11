import 'package:flutter/material.dart';

import '../services/nightscout_service.dart';

/// Minimal dependency-free glucose sparkline for the last few hours.
class GlucoseChart extends StatelessWidget {
  const GlucoseChart({super.key, required this.entries, this.mmol = false});

  final List<GlucoseEntry> entries;
  final bool mmol;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 140,
      child: CustomPaint(
        painter: _GlucosePainter(
          entries: entries,
          lineColor: Theme.of(context).colorScheme.primary,
          gridColor: Theme.of(context).colorScheme.outlineVariant,
          inRangeColor: Colors.green,
          lowColor: Colors.red,
          highColor: Colors.orange,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _GlucosePainter extends CustomPainter {
  _GlucosePainter({
    required this.entries,
    required this.lineColor,
    required this.gridColor,
    required this.inRangeColor,
    required this.lowColor,
    required this.highColor,
  });

  final List<GlucoseEntry> entries;
  final Color lineColor;
  final Color gridColor;
  final Color inRangeColor;
  final Color lowColor;
  final Color highColor;

  static const _minSgv = 40.0;
  static const _maxSgv = 300.0;
  static const _lowLine = 70.0;
  static const _highLine = 180.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (entries.isEmpty) return;

    final sorted = [...entries]..sort((a, b) => a.date.compareTo(b.date));
    final start = sorted.first.date.millisecondsSinceEpoch.toDouble();
    final end = sorted.last.date.millisecondsSinceEpoch.toDouble();
    final span = (end - start).clamp(1.0, double.infinity);

    double x(GlucoseEntry e) => (e.date.millisecondsSinceEpoch - start) / span * size.width;
    double y(double sgv) =>
        size.height - ((sgv.clamp(_minSgv, _maxSgv) - _minSgv) / (_maxSgv - _minSgv) * size.height);

    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (final line in [_lowLine, _highLine]) {
      canvas.drawLine(Offset(0, y(line)), Offset(size.width, y(line)), gridPaint);
    }

    for (final entry in sorted) {
      final sgv = entry.sgv.toDouble();
      final color = sgv < _lowLine
          ? lowColor
          : sgv > _highLine
              ? highColor
              : inRangeColor;
      canvas.drawCircle(
        Offset(x(entry), y(sgv)),
        2.5,
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GlucosePainter oldDelegate) => oldDelegate.entries != entries;
}
