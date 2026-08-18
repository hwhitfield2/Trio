import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';

import '../models/display_preferences.dart';
import '../models/status_snapshot.dart';

/// Publishes the latest host status to the iOS and Android home screen widgets.
///
/// Everything the widgets display is formatted here rather than natively, so the
/// two platforms cannot drift apart from each other or from the in-app home
/// screen — the native side only lays out strings this class produced. Keep the
/// payload keys in sync with `TrioFollowerWidget.swift` and
/// `GlucoseWidgetProvider.kt`.
class WidgetBridge {
  /// App group shared with the iOS widget extension, injected at build time
  /// with `--dart-define` because it carries the Apple team id. Empty in builds
  /// that did not pass it; the iOS widget then simply has no data to read.
  static const appGroupId = String.fromEnvironment('APP_GROUP_ID');

  /// Key the native widgets read the payload from.
  static const payloadKey = 'trio_follower_status';

  /// Key the native widgets read the layout choices from. Written separately
  /// from the payload so a settings change redraws without waiting for the next
  /// status push.
  static const preferencesKey = 'trio_follower_display';

  /// The three widgets, as (iOS WidgetKit kind, Android provider class). Both
  /// platforms need every widget reloaded: WidgetCenter reloads one kind at a
  /// time, and each Android provider is its own broadcast receiver.
  static const _widgets = <List<String>>[
    ['TrioFollowerWidget', 'org.nightscout.trio_follower.GlucoseWidgetProvider'],
    ['TrioFollowerTrendWidget', 'org.nightscout.trio_follower.TrendWidgetProvider'],
    ['TrioFollowerLoopWidget', 'org.nightscout.trio_follower.LoopWidgetProvider'],
  ];


  /// Writes the snapshot to shared storage and asks both platforms to redraw.
  ///
  /// Never throws: a widget that cannot be updated must not take down a status
  /// push or app start with it.
  static Future<void> publish(StatusSnapshot? snapshot) async {
    try {
      if (appGroupId.isNotEmpty) {
        await HomeWidget.setAppGroupId(appGroupId);
      }
      await HomeWidget.saveWidgetData<String>(
        payloadKey,
        snapshot == null ? null : jsonEncode(payloadFor(snapshot)),
      );
      for (final widget in _widgets) {
        await HomeWidget.updateWidget(
          iOSName: widget[0],
          qualifiedAndroidName: widget[1],
        );
      }
    } catch (error) {
      debugPrint('Widget update skipped: $error');
    }
  }

  /// Clears the widgets, e.g. after unpairing, so they cannot keep showing
  /// glucose from a host this device is no longer paired with.
  static Future<void> clear() => publish(null);

  /// Shares the layout choices with the widget extension and redraws. The
  /// Live Activity reads the same key, so its layout follows too — see
  /// `LiveActivityBridge.publish`, which the caller runs alongside this.
  static Future<void> publishPreferences(DisplayPreferences preferences) async {
    try {
      if (appGroupId.isNotEmpty) {
        await HomeWidget.setAppGroupId(appGroupId);
      }
      await HomeWidget.saveWidgetData<String>(
        preferencesKey,
        jsonEncode(preferences.toJson()),
      );
      for (final widget in _widgets) {
        await HomeWidget.updateWidget(
          iOSName: widget[0],
          qualifiedAndroidName: widget[1],
        );
      }
    } catch (error) {
      debugPrint('Widget preferences update skipped: $error');
    }
  }

  @visibleForTesting
  static Map<String, dynamic> payloadFor(StatusSnapshot snapshot) {
    final mmol = snapshot.units == 'mmol/L';
    final latest = snapshot.latest;
    final delta = snapshot.delta;
    final ranges = snapshot.glucoseRanges;

    return <String, dynamic>{
      'units': snapshot.units,
      'bg': latest == null ? '--' : _formatGlucose(latest.sgv, mmol),
      'direction': latest?.trendArrow ?? '',
      'change': delta == null ? '' : _formatDelta(delta, mmol),
      // Milliseconds since epoch; the native side decides staleness from this.
      'glucoseDate': latest?.date.millisecondsSinceEpoch,
      'hostDate': snapshot.timestamp.millisecondsSinceEpoch,
      'lastLoop': snapshot.lastLoop?.millisecondsSinceEpoch,
      'iob': snapshot.iob == null ? null : _formatDecimal(snapshot.iob!),
      'cob': snapshot.cob == null ? null : snapshot.cob!.round().toString(),
      'eventualBg':
          snapshot.eventualBg == null ? null : _formatGlucose(snapshot.eventualBg!.round(), mmol),
      'tempTargetName': snapshot.tempTarget?.name,
      'overrideName': snapshot.override?.name,
      // The host's display range in display units, so the native side can draw
      // its guide lines and colour without repeating the unit conversion.
      'low': _convert(ranges.low, mmol),
      'high': _convert(ranges.high, mmol),
      // What the three colours cannot say on their own: which scheme the host
      // is using, and — for the dynamic one — where along the sweep a reading
      // falls. Same units as everything else here.
      'color': ranges.toPayload((mgdl) => _convert(mgdl, mmol)),
      'stats': statsFor(snapshot),
      'chart': [
        for (final reading in snapshot.readings)
          {'v': _convert(reading.sgv.toDouble(), mmol), 't': reading.date.millisecondsSinceEpoch},
      ],
    };
  }

  /// Share of the plotted readings below, inside and above the host's range.
  /// Percentages are whole numbers that always sum to 100, so the widgets can
  /// draw them as one stacked bar without rounding gaps.
  ///
  /// The host's display range decides this, the same one its dots are coloured
  /// by — a bar that disagreed with the chart above it would be worse than no
  /// bar at all.
  @visibleForTesting
  static Map<String, int>? statsFor(StatusSnapshot snapshot) {
    if (snapshot.readings.isEmpty) return null;

    final low = snapshot.glucoseRanges.low;
    final high = snapshot.glucoseRanges.high;
    final total = snapshot.readings.length;
    var below = 0;
    var above = 0;
    for (final reading in snapshot.readings) {
      if (reading.sgv <= low) {
        below++;
      } else if (reading.sgv >= high) {
        above++;
      }
    }

    final lowPct = (below * 100 / total).round();
    final highPct = (above * 100 / total).round();
    return <String, int>{
      'low': lowPct,
      'in_range': (100 - lowPct - highPct).clamp(0, 100).toInt(),
      'high': highPct,
    };
  }

  static double _convert(double mgdl, bool mmol) =>
      mmol ? double.parse((mgdl / 18.0).toStringAsFixed(1)) : mgdl;

  static String _formatGlucose(int sgv, bool mmol) =>
      mmol ? (sgv / 18.0).toStringAsFixed(1) : sgv.round().toString();

  static String _formatDelta(int delta, bool mmol) {
    final sign = delta >= 0 ? '+' : '';
    return mmol ? '$sign${(delta / 18.0).toStringAsFixed(1)}' : '$sign$delta';
  }

  static String _formatDecimal(double value) => value.toStringAsFixed(1);
}
