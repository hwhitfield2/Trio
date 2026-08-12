import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trio_live_activity/trio_live_activity.dart';

import '../models/status_snapshot.dart';
import 'widget_bridge.dart';

// Callers deal in the bridge, not the plugin, so the one type they need to name
// comes along with it.
export 'package:trio_live_activity/trio_live_activity.dart' show LiveActivitySupport;

/// Keeps the iOS Live Activity in step with the host's status.
///
/// Like the widgets, every displayed value is formatted here rather than in
/// Swift, so the lock screen cannot disagree with the app. Unlike the widgets,
/// the payload has to fit ActivityKit's 4 KB budget, so the chart is trimmed and
/// timestamps are seconds rather than milliseconds.
class LiveActivityBridge {
  static const _enabledKey = 'trio_follower.live_activity_enabled';
  static const _remoteUpdatesKey = 'trio_follower.live_activity_remote_updates';

  /// Roughly two hours at a five-minute cadence. The lock screen chart is small
  /// enough that more points would not be visible, and the budget is real.
  static const _maxChartPoints = 24;

  static Future<LiveActivitySupport> support() => TrioLiveActivity.support();

  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_enabledKey) ?? false;
  }

  static Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, enabled);
    if (!enabled) await TrioLiveActivity.end();
  }

  /// Whether the user has agreed to let the host update the Lock Screen
  /// directly, by handing it the activity's push token.
  ///
  /// Off by default, and deliberately separate from [isEnabled]: ActivityKit
  /// decodes the pushed content itself, so — unlike every other byte this app
  /// exchanges with the host — a remote Live Activity update cannot be
  /// end-to-end encrypted. Turning this on means Apple's push service carries
  /// the displayed glucose, trend, IOB and COB as plain text.
  static Future<bool> remoteUpdatesEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_remoteUpdatesKey) ?? false;
  }

  static Future<void> setRemoteUpdatesEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_remoteUpdatesKey, enabled);
  }

  /// The running activity's push token, or null when there is none.
  static Future<String?> pushToken() => TrioLiveActivity.pushToken();

  /// Watches for the system issuing or rotating the activity's push token.
  static void onPushToken(void Function(String? token) handler) =>
      TrioLiveActivity.onPushToken(handler);

  /// Ends the activity and starts a fresh one for [snapshot].
  ///
  /// Used when remote updates are switched on: an activity only gets a push
  /// token from the system at the moment it is requested, so one that is
  /// already running can never gain one.
  static Future<void> restart(StatusSnapshot? snapshot, {required String hostName}) async {
    await stop();
    await publish(snapshot, hostName: hostName);
  }

  /// Starts or refreshes the activity for a snapshot, if the user turned it on.
  ///
  /// Never throws: a Live Activity that cannot be updated must not take down a
  /// status push.
  static Future<void> publish(StatusSnapshot? snapshot, {required String hostName}) async {
    try {
      if (!await isEnabled()) return;

      if (snapshot == null || snapshot.latest == null) {
        await TrioLiveActivity.end();
        return;
      }

      await TrioLiveActivity.update(
        hostName: hostName,
        state: jsonEncode(stateFor(snapshot)),
      );
    } catch (error) {
      debugPrint('Live Activity update skipped: $error');
    }
  }

  static Future<void> stop() async {
    try {
      await TrioLiveActivity.end();
    } catch (error) {
      debugPrint('Live Activity stop skipped: $error');
    }
  }

  @visibleForTesting
  static Map<String, dynamic> stateFor(StatusSnapshot snapshot) {
    final mmol = snapshot.units == 'mmol/L';
    final latest = snapshot.latest;
    final delta = snapshot.delta;
    final low = snapshot.lowThreshold ?? WidgetBridge.lowThreshold;
    final high = snapshot.highThreshold ?? WidgetBridge.highThreshold;

    double convert(double mgdl) =>
        mmol ? double.parse((mgdl / 18.0).toStringAsFixed(1)) : mgdl;

    String formatGlucose(int sgv) =>
        mmol ? (sgv / 18.0).toStringAsFixed(1) : sgv.toString();

    return <String, dynamic>{
      'bg': latest == null ? '--' : formatGlucose(latest.sgv),
      'direction': latest?.trendArrow ?? '',
      'change': delta == null
          ? ''
          : '${delta >= 0 ? '+' : ''}${mmol ? (delta / 18.0).toStringAsFixed(1) : delta}',
      'iob': snapshot.iob?.toStringAsFixed(1) ?? '--',
      'cob': snapshot.cob?.round().toString() ?? '--',
      // Seconds, not milliseconds: the chart dominates a 4 KB budget.
      'readingDate':
          (latest?.date ?? snapshot.timestamp).millisecondsSinceEpoch ~/ 1000,
      'low': convert(low),
      'high': convert(high),
      'chart': [
        for (final reading in snapshot.readings.take(_maxChartPoints))
          {
            'v': convert(reading.sgv.toDouble()),
            't': reading.date.millisecondsSinceEpoch ~/ 1000,
          },
      ],
    };
  }
}
