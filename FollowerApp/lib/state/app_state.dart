import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/command.dart';
import '../models/pairing_bundle.dart';
import '../models/status_snapshot.dart';
import '../services/command_service.dart';
import '../services/pairing_store.dart';
import '../services/push_service.dart';
import '../services/status_service.dart';
import '../services/widget_bridge.dart';

class AppState extends ChangeNotifier {
  AppState({PairingStore? store, PushService? push})
      : _store = store ?? PairingStore(),
        _push = push ?? PushService.instance;

  final PairingStore _store;
  final PushService _push;

  PairingBundle? bundle;
  CommandService? _commandService;
  StatusService? _statusService;

  bool initialized = false;

  /// Latest status received from the host device (the only data source).
  StatusSnapshot? snapshot;
  String? statusHint;
  List<CommandRecord> history = [];

  static const _historyKey = 'trio_follower.history';

  bool get isPaired => bundle != null;

  /// Live limits: prefer the host's latest snapshot over the pairing-time
  /// values.
  double get maxBolus => snapshot?.maxBolus ?? bundle?.limits.maxBolus ?? 10;
  double get maxCarbs => snapshot?.maxCarbs ?? bundle?.limits.maxCarbs ?? 250;
  String get units => snapshot?.units ?? bundle?.limits.units ?? 'mg/dL';

  Future<void> initialize() async {
    bundle = await _store.loadPairing();
    _rebuildServices();
    await _loadHistory();
    snapshot = await _statusService?.loadPersisted();
    initialized = true;
    await WidgetBridge.publish(snapshot);

    _push.onMessage(_handlePushData);
    _push.onNewToken((_) => registerPush(force: true));

    notifyListeners();

    if (isPaired) {
      await registerPush();
      // A registration also triggers a status push from the host; when the
      // token was already registered, ask explicitly so the UI is fresh.
      await requestStatus();
    }
  }

  Future<void> completePairing(PairingBundle newBundle) async {
    await _store.savePairing(newBundle);
    bundle = newBundle;
    snapshot = null;
    await StatusService.clearPersisted();
    _rebuildServices();
    notifyListeners();
    await WidgetBridge.clear();
    await registerPush(force: true);
  }

  Future<void> unpair() async {
    await _store.clear();
    await StatusService.clearPersisted();
    bundle = null;
    snapshot = null;
    _rebuildServices();
    notifyListeners();
    await WidgetBridge.clear();
  }

  /// Registers this device's push address with the host so it can deliver
  /// encrypted status snapshots. No-op when the token hasn't changed.
  Future<void> registerPush({bool force = false}) async {
    final service = _commandService;
    final currentBundle = bundle;
    if (service == null || currentBundle == null) return;

    await _push.requestPermission();
    final token = await _push.token;
    if (token == null || token.isEmpty) {
      statusHint = 'Push notifications are unavailable on this device, so live '
          'status from the host cannot be received.';
      notifyListeners();
      return;
    }

    if (!force && await _store.registeredPushToken == token) return;

    final record = await service.send(TrioCommand.registerFollower(
      pushToken: token,
      pushTransport: _push.transport,
      pushBundleId: await _push.bundleId,
      pushEnvironment: _push.environment,
    ));
    if (record.accepted) {
      await _store.setRegisteredPushToken(token);
      statusHint = null;
    } else {
      statusHint = 'Could not register with the host yet: ${record.detail}';
    }
    notifyListeners();
  }

  /// Asks the host for a fresh snapshot and waits briefly for it to arrive.
  Future<void> requestStatus() async {
    final service = _commandService;
    if (service == null) return;

    final before = snapshot?.timestamp;
    final record = await service.send(TrioCommand.statusRequest());
    if (!record.accepted) {
      statusHint = 'Could not reach the host: ${record.detail}';
      notifyListeners();
      return;
    }

    // Wait up to 15 s for the answering push.
    final arrived = await _waitForSnapshotChange(since: before, timeout: const Duration(seconds: 15));
    statusHint = arrived
        ? null
        : 'The host has not answered yet. It may be offline — the status will '
            'update as soon as it reconnects.';
    notifyListeners();
  }

  Future<CommandRecord?> sendCommand(TrioCommand command) async {
    final service = _commandService;
    if (service == null) return null;
    final record = await service.send(command);
    history.insert(0, record);
    if (history.length > 50) {
      history = history.sublist(0, 50);
    }
    await _saveHistory();
    notifyListeners();
    return record;
  }

  // MARK: incoming pushes

  Future<void> _handlePushData(Map<String?, Object?> data) async {
    final statusService = _statusService;
    final currentBundle = bundle;
    if (statusService == null || currentBundle == null) return;

    final followerId = data['follower_id'];
    if (followerId is String && followerId != currentBundle.followerId) return;

    final encrypted = data['encrypted_status'];
    if (encrypted is! String || encrypted.isEmpty) return;

    final updated = await statusService.handleEncryptedStatus(encrypted, current: snapshot);
    if (updated != null) {
      snapshot = updated;
      statusHint = null;
      notifyListeners();
      // Pushes are also delivered in the background, so the widgets stay
      // current without the app being opened.
      await WidgetBridge.publish(updated);
    }
  }

  Future<bool> _waitForSnapshotChange({DateTime? since, required Duration timeout}) async {
    final completer = Completer<bool>();
    void listener() {
      final current = snapshot?.timestamp;
      if (current != null && (since == null || current.isAfter(since))) {
        if (!completer.isCompleted) completer.complete(true);
      }
    }

    addListener(listener);
    // Check immediately in case the push already landed.
    listener();
    final result = await completer.future
        .timeout(timeout, onTimeout: () => false);
    removeListener(listener);
    return result;
  }

  void _rebuildServices() {
    final currentBundle = bundle;
    if (currentBundle == null) {
      _commandService = null;
      _statusService = null;
      return;
    }
    _commandService = CommandService(
      bundle: currentBundle,
      store: _store,
      followerName: currentBundle.followerName,
    );
    _statusService = StatusService(currentBundle.secret);
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_historyKey);
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        history = decoded
            .whereType<Map<String, dynamic>>()
            .map(CommandRecord.fromJson)
            .toList();
      }
    } catch (_) {
      history = [];
    }
  }

  Future<void> _saveHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_historyKey, jsonEncode(history.map((r) => r.toJson()).toList()));
  }
}
