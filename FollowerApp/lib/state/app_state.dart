import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/command.dart';
import '../models/pairing_bundle.dart';
import '../models/status_snapshot.dart';
import '../services/command_service.dart';
import '../services/pairing_store.dart';
import '../services/push_service.dart';
import '../services/status_service.dart';
import '../services/live_activity_bridge.dart';
import '../services/sync_scheduler.dart';
import '../services/widget_bridge.dart';

class AppState extends ChangeNotifier with WidgetsBindingObserver {
  AppState({PairingStore? store, PushService? push, SyncScheduler? scheduler})
      : _store = store ?? PairingStore(),
        _push = push ?? PushService.instance,
        _scheduler = scheduler ?? SyncScheduler();

  final PairingStore _store;
  final PushService _push;
  final SyncScheduler _scheduler;

  PairingBundle? bundle;
  CommandService? _commandService;
  StatusService? _statusService;

  bool initialized = false;

  /// Latest status received from the host device (the only data source).
  StatusSnapshot? snapshot;

  /// Whether this device can run Live Activities, and whether the user has left
  /// them switched on for the app in iOS Settings.
  LiveActivitySupport liveActivitySupport = LiveActivitySupport.unsupported;
  bool liveActivityEnabled = false;

  /// Whether the host may update the Live Activity directly over APNS. Off
  /// unless the user turns it on: it is the one path where the push service
  /// carries readable data rather than ciphertext.
  bool liveActivityRemoteUpdates = false;
  String? statusHint;
  List<CommandRecord> history = [];

  static const _historyKey = 'trio_follower.history';

  /// How often the app re-checks, while it is on screen, whether the status is
  /// still fresh. Also the cadence at which the "from host x min ago" label is
  /// redrawn, since that text ages on its own.
  static const _tickInterval = Duration(seconds: 30);

  Timer? _ticker;
  bool _observingLifecycle = false;
  bool _statusRequestInFlight = false;

  /// Last Live Activity token the host acknowledged, so a token that has not
  /// changed is not re-sent on every activity update.
  String? _registeredLiveActivityToken;

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
    liveActivitySupport = await LiveActivityBridge.support();
    liveActivityEnabled = await LiveActivityBridge.isEnabled();
    liveActivityRemoteUpdates = await LiveActivityBridge.remoteUpdatesEnabled();
    initialized = true;
    await WidgetBridge.publish(snapshot);
    await LiveActivityBridge.publish(snapshot, hostName: _hostName);

    _push.onMessage(_handlePushData);
    _push.onNewToken((_) => registerPush(force: true));
    LiveActivityBridge.onPushToken(_handleLiveActivityToken);

    if (!_observingLifecycle) {
      WidgetsBinding.instance.addObserver(this);
      _observingLifecycle = true;
    }

    notifyListeners();

    if (isPaired) {
      _startTicker();
      await registerPush();
      // Re-register the Live Activity token: an activity started before the
      // app was last killed is still running, and the host may have been
      // re-paired or restored since.
      await _handleLiveActivityToken(await LiveActivityBridge.pushToken());
      // A registration also triggers a status push from the host; when the
      // token was already registered, ask explicitly so the UI is fresh.
      await requestStatus();
    }
  }

  @override
  void dispose() {
    _stopTicker();
    if (_observingLifecycle) {
      WidgetsBinding.instance.removeObserver(this);
      _observingLifecycle = false;
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!isPaired) return;
      _startTicker();
      // Status pushes are silent background pushes, which the system drops or
      // defers while the app is not running, so what is on screen right after
      // a resume can be many minutes old.
      unawaited(_syncIfStale());
    } else {
      _stopTicker();
    }
  }

  Future<void> completePairing(PairingBundle newBundle) async {
    await _store.savePairing(newBundle);
    bundle = newBundle;
    snapshot = null;
    await StatusService.clearPersisted();
    _rebuildServices();
    _scheduler.reset();
    _registeredLiveActivityToken = null;
    _startTicker();
    notifyListeners();
    await WidgetBridge.clear();
    await LiveActivityBridge.stop();
    await registerPush(force: true);
  }

  Future<void> unpair() async {
    await _store.clear();
    await StatusService.clearPersisted();
    bundle = null;
    snapshot = null;
    _rebuildServices();
    _scheduler.reset();
    _registeredLiveActivityToken = null;
    _stopTicker();
    notifyListeners();
    await WidgetBridge.clear();
    await LiveActivityBridge.stop();
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
  ///
  /// Used both by pull-to-refresh and by the app itself when a push has not
  /// arrived in time; a request already in flight is never doubled up.
  Future<void> requestStatus() async {
    final service = _commandService;
    if (service == null || _statusRequestInFlight) return;

    _statusRequestInFlight = true;
    _scheduler.recordRequest(DateTime.now());
    try {
      final before = snapshot?.timestamp;
      final record = await service.send(TrioCommand.statusRequest());
      if (!record.accepted) {
        _scheduler.recordFailure();
        statusHint = 'Could not reach the host: ${record.detail}';
        notifyListeners();
        return;
      }

      // Wait up to 15 s for the answering push.
      final arrived = await _waitForSnapshotChange(since: before, timeout: const Duration(seconds: 15));
      if (arrived) {
        _scheduler.recordSuccess();
        statusHint = null;
      } else {
        _scheduler.recordFailure();
        statusHint = 'The host has not answered yet. It may be offline — the '
            'status will update as soon as it reconnects.';
      }
      notifyListeners();
    } finally {
      _statusRequestInFlight = false;
    }
  }

  /// Asks the host for a snapshot when none has been pushed for a while. Free
  /// in the normal case: as long as pushes keep arriving, the scheduler finds
  /// the status fresh and nothing is sent.
  Future<void> _syncIfStale() async {
    if (!isPaired || _statusRequestInFlight) return;
    if (!_scheduler.shouldRequest(now: DateTime.now(), snapshotAt: snapshot?.timestamp)) return;
    await requestStatus();
  }

  /// Runs only while the app is on screen — a Dart timer does not fire once
  /// the app is suspended, and the host keeps the widgets and the Live
  /// Activity current from its side in the meantime.
  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(_tickInterval, (_) {
      // The freshness line is relative to now, so it needs a rebuild even when
      // no new snapshot arrived.
      notifyListeners();
      unawaited(_syncIfStale());
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
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
      // Pushes are getting through; no need to ask the host for anything.
      _scheduler.recordSuccess();
      notifyListeners();
      // Pushes are also delivered in the background, so the widgets and the
      // Live Activity stay current without the app being opened.
      await WidgetBridge.publish(updated);
      await LiveActivityBridge.publish(updated, hostName: _hostName);
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

  /// Turns the Live Activity on or off, starting or ending it immediately so
  /// the switch has a visible effect.
  Future<void> setLiveActivityEnabled(bool enabled) async {
    liveActivityEnabled = enabled;
    notifyListeners();
    await LiveActivityBridge.setEnabled(enabled);
    if (enabled) {
      await LiveActivityBridge.publish(snapshot, hostName: _hostName);
    }
  }

  /// Lets the host update the Live Activity directly, or takes that back.
  ///
  /// Switching on restarts the activity: the system only issues a push token
  /// at the moment an activity is requested, so one that is already running
  /// can never gain one.
  Future<void> setLiveActivityRemoteUpdates(bool enabled) async {
    liveActivityRemoteUpdates = enabled;
    notifyListeners();
    await LiveActivityBridge.setRemoteUpdatesEnabled(enabled);

    if (enabled) {
      await LiveActivityBridge.restart(snapshot, hostName: _hostName);
      // The token usually arrives on the stream a moment later, but ask too:
      // an activity that was already running with a token has nothing new to
      // report.
      await _handleLiveActivityToken(await LiveActivityBridge.pushToken());
    } else {
      // Forced: this app may have been restarted since the token was
      // registered, so it cannot tell from memory whether the host still holds
      // one. Withdrawing has to reach the host either way — the activity keeps
      // running, so nothing else would stop the pushes.
      await _sendLiveActivityToken('', force: true);
    }
  }

  /// The system issued, rotated or dropped the Live Activity's push token.
  Future<void> _handleLiveActivityToken(String? token) async {
    if (!liveActivityRemoteUpdates) return;
    await _sendLiveActivityToken(token ?? '');
  }

  /// Registers (or clears) the Live Activity token on the host, skipping the
  /// send when the host already has this exact token.
  Future<void> _sendLiveActivityToken(String token, {bool force = false}) async {
    final service = _commandService;
    if (service == null) return;
    // A null registration and an empty token both mean "the host has nothing".
    if (!force && token == (_registeredLiveActivityToken ?? '')) return;

    final record = await service.send(TrioCommand.registerLiveActivity(liveActivityToken: token));
    if (record.accepted) {
      _registeredLiveActivityToken = token;
    }
  }

  String get _hostName => bundle?.hostName ?? 'Trio';

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
