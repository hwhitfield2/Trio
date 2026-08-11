import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:push/push.dart';

/// Wraps the `push` plugin: raw APNS on iOS, FCM on Android. Exposes the
/// device push address the host needs and a stream of incoming payloads.
class PushService {
  PushService._();

  static final PushService instance = PushService._();

  /// "apns" on iOS, "fcm" on Android — matches the host's transport values.
  String get transport => Platform.isIOS ? 'apns' : 'fcm';

  /// APNS environment of this build (iOS only). Debug builds register
  /// sandbox tokens; release/TestFlight/App Store builds use production. The
  /// host retries the other environment once if this guess is wrong.
  String get environment => kReleaseMode || kProfileMode ? 'production' : 'sandbox';

  Future<String?> get bundleId async {
    if (!Platform.isIOS) return null;
    final info = await PackageInfo.fromPlatform();
    return info.packageName;
  }

  Future<bool> requestPermission() async {
    try {
      return await Push.instance.requestPermission();
    } catch (_) {
      // Data-only pushes work without notification permission; don't block
      // registration on a denied prompt.
      return false;
    }
  }

  Future<String?> get token async {
    try {
      return await Push.instance.token;
    } catch (_) {
      // e.g. Android without a google-services.json: commands still work,
      // only status pushes are unavailable.
      return null;
    }
  }

  /// Fires when the OS rotates the push token; the host must be re-registered.
  void onNewToken(void Function(String token) handler) {
    Push.instance.onNewToken.listen(handler);
  }

  /// Fires for pushes received while the app is running (foreground or
  /// background). The map is the raw payload data from the host.
  void onMessage(void Function(Map<String?, Object?> data) handler) {
    Push.instance.addOnMessage((message) {
      final data = message.data;
      if (data != null) handler(data);
    });
    Push.instance.addOnBackgroundMessage((message) {
      final data = message.data;
      if (data != null) handler(data);
    });
  }
}
