import 'dart:io';

import 'package:flutter/services.dart';

/// Whether the device can run Live Activities, and whether the user has left
/// them switched on for this app.
///
/// The two are separate on purpose: an app that hides its own toggle when the
/// user turns Live Activities off in iOS Settings gives them no way back.
class LiveActivitySupport {
  const LiveActivitySupport({required this.available, required this.enabled});

  /// The OS supports Live Activities (iOS 16.2+).
  final bool available;

  /// The user has not switched them off for this app.
  final bool enabled;

  static const unsupported = LiveActivitySupport(available: false, enabled: false);
}

/// Starts, updates and ends the Trio Follower Live Activity.
///
/// Every method is a no-op off iOS, so callers need no platform checks.
class TrioLiveActivity {
  static const MethodChannel _channel = MethodChannel('trio_follower/live_activity');

  static Future<LiveActivitySupport> support() async {
    if (!Platform.isIOS) return LiveActivitySupport.unsupported;
    try {
      final result = await _channel.invokeMapMethod<String, bool>('isSupported');
      if (result == null) return LiveActivitySupport.unsupported;
      return LiveActivitySupport(
        available: result['available'] ?? false,
        enabled: result['enabled'] ?? false,
      );
    } on PlatformException {
      return LiveActivitySupport.unsupported;
    } on MissingPluginException {
      return LiveActivitySupport.unsupported;
    }
  }

  /// Starts the activity, or updates it when one is already running.
  static Future<bool> start({required String hostName, required String state}) =>
      _invoke('start', {'hostName': hostName, 'state': state});

  /// Updates the running activity, starting one if the system already ended it.
  static Future<bool> update({required String hostName, required String state}) =>
      _invoke('update', {'hostName': hostName, 'state': state});

  static Future<bool> end() => _invoke('end', const {});

  static Future<bool> _invoke(String method, Map<String, dynamic> arguments) async {
    if (!Platform.isIOS) return false;
    try {
      return await _channel.invokeMethod<bool>(method, arguments) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
